import Foundation
import os.log

/// Vends the Mach service and pushes per-second batches to the connected host app.
final class IPCServer: NSObject, NSXPCListenerDelegate, FlowlightProviderXPC, @unchecked Sendable {
    static let shared = IPCServer()

    private var listener: NSXPCListener?
    private var client: NSXPCConnection?
    private var clientGeneration: UInt64 = 0
    private var pending: [(seq: UInt64, batch: TrafficBatch)] = []
    private var nextSeq: UInt64 = 0
    private var inFlight = false
    /// Refused connections waiting to be recorded by the app, on their own queue so they never wait behind an
    /// hour of buffered traffic. Evidence is never evicted before durable acknowledgment; a persistent write failure
    /// starts the normal fail-open grace so new refusals stop while the retained queue retries.
    private var blocks = DurableEventQueue<BlockEvent>()
    private let eventDeliverySession = UUID()
    private var nextBlockSequence: Int64 = 0
    /// Connections a rule decided, on the same footing and for the same reason.
    private var decisions = DurableEventQueue<RuleEvent>()
    private var nextDecisionSequence: Int64 = 0
    /// Managed-pack hits are coalesced before IPC. Every immutable explanation field participates so a snapshot
    /// change cannot make an older decision appear to come from newer pack content or a different agent.
    private struct PackEventKey: Hashable {
        var bucket: Int64
        var packID: String
        var packVersion: String
        var entryID: UInt32
        var category: String
        var match: String
        var action: String
        var bundleID: String
        var appName: String
        var agentKey: String
        var agentName: String
        var host: String
        var matchedHost: String
        var port: UInt16

        init(_ event: RulePackEvent) {
            bucket = event.bucket
            packID = event.packID
            packVersion = event.packVersion
            entryID = event.entryID
            category = event.category.rawValue
            match = event.match.rawValue
            action = event.action.rawValue
            bundleID = event.bundleID
            appName = event.appName
            agentKey = event.agentKey
            agentName = event.agentName
            host = event.host
            matchedHost = event.matchedHost
            port = event.port
        }
    }
    private var packEvents: [PackEventKey: RulePackEvent] = [:]
    /// Removed from the mutable map before sending. New hits for the same key therefore cannot be erased by its ack.
    private var packEventBatch: RulePackEventBatch?
    private let packDeliverySession = UUID()
    private var nextPackSequence: Int64 = 0
    private var packEventsInFlight = false
    private var packFlushScheduled = false
    private enum DurableChannel: Hashable { case blocks, decisions, packs }
    private var durableHealth = DurableDeliveryHealth<DurableChannel>()
    private var durableEventsEnabled = false
    private var enforcementSynchronized = false
    private static let durableEventProtocol = 1
    private var droppedPackHits: Int64 = 0
    private var droppedPackKeys: Int64 = 0
    private var packTransfer = RulePackTransferBuffer()
    private let durableChunkSize = 500
    private let maxPackEventKeys = 4_096
    private let queue = DispatchQueue(label: "flowlight.ipc")
    /// Seconds of traffic held while no app is connected — the whole time the app is on the nettop sampler, or
    /// quit. An hour of it is worth keeping now that the newest second is delivered first (see `flushLocked`);
    /// when the oldest went first, a backlog this size left the live view empty until it had all drained.
    private let maxPendingBatches = 3600
    private let chunkSize = 300

    private var machServiceName: String {
        let ne = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        return (ne?["NEMachServiceName"] as? String) ?? FlowlightConstants.machServiceName
    }

    func startListener() {
        #if APP_STORE
        guard listener == nil else { return }
        #endif
        BlockEnforcer.shared.report = { [weak self] event in self?.report(event) }
        BlockEnforcer.shared.reportDecision = { [weak self] event in self?.report(decision: event) }
        BlockEnforcer.shared.reportPack = { [weak self] event in self?.report(pack: event) }
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        extensionLog.info("XPC listener on \(self.machServiceName, privacy: .public)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only our own host app, signed by our team, may connect.
        var requirement = "identifier \"\(FlowlightConstants.hostBundleIdentifier)\" and anchor apple generic"
        if let team = FlowlightConstants.teamIdentifier {
            requirement += " and certificate leaf[subject.OU] = \"\(team)\""
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: FlowlightProviderXPC.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: FlowlightAppXPC.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.queue.async {
                guard let self, self.client === connection else { return }
                self.client = nil
                self.clientGeneration &+= 1
                self.inFlight = false
                self.blocks.resetDelivery()
                self.decisions.resetDelivery()
                self.packEventsInFlight = false
                self.packTransfer.reset()
                self.durableEventsEnabled = false
                self.enforcementSynchronized = false
                self.durableHealth.reset()
                BlockEnforcer.shared.appConnectionChanged(connected: false)
            }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }

    func filterState(withReply reply: @escaping (Bool, String) -> Void) {
        let state = FilterDataProvider.filterStarted.withLock { $0 }
        reply(state.running, state.detail)
    }

    func register(withReply reply: @escaping (Bool, String) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false, "no connection"); return }
        queue.async {
            self.client = connection
            self.clientGeneration &+= 1
            self.inFlight = false
            self.blocks.resetDelivery()
            self.decisions.resetDelivery()
            self.packEventsInFlight = false
            self.packTransfer.reset()
            self.durableEventsEnabled = false
            self.enforcementSynchronized = false
            self.durableHealth.reset()
            // A reconnect begins fail-open. The app may have disabled or narrowed any of these while disconnected;
            // stale state must not become active during the policy/rule/pack synchronization that follows register.
            _ = BlockEnforcer.shared.apply([])
            _ = BlockEnforcer.shared.apply(RuleSet())
            _ = BlockEnforcer.shared.clearPacks()
            BlockEnforcer.shared.appConnectionChanged(connected: false)
            self.flushLocked()
            // Durable evidence waits for an exact-build app to opt in. Calling a new reply-block ABI before the
            // registration version check would make a mixed-version upgrade lose its connection and possibly backlog.
            // Registration is the synchronization barrier: the app may publish rules only after this reset is done.
            let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            reply(true, build.isEmpty ? shortVersion : "\(shortVersion)/\(build)")
        }
    }

    func enableDurableEvents(appProtocol: Int, withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false); return }
        queue.async {
            guard self.client === connection,
                  appProtocol == Self.durableEventProtocol else {
                reply(false)
                return
            }
            self.durableEventsEnabled = true
            self.flushBlocksLocked()
            self.flushDecisionsLocked()
            self.flushPackEventsLocked()
            self.updateEnforcementConnectionState()
            reply(true)
        }
    }

    func setEnforcement(payload: Data, withReply reply: @escaping (Int) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(-1); return }
        queue.async {
            guard self.client === connection else { reply(-1); return }
            let policies = payload.isEmpty ? [] : (BlockCoding.decode([AgentPolicy].self, from: payload) ?? [])
            let count = BlockEnforcer.shared.apply(policies)
            // Rules are synchronized first. Once both ordinary policy sources are installed, enforcement can safely
            // run; managed packs remain independently cleared until their own commit or clear succeeds.
            self.enforcementSynchronized = true
            self.updateEnforcementConnectionState()
            extensionLog.info("Enforcing \(count, privacy: .public) allowlists")
            reply(count)
        }
    }

    func setRules(payload: Data, withReply reply: @escaping (Int) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(-1); return }
        queue.async {
            guard self.client === connection else { reply(-1); return }
            let set = payload.isEmpty ? RuleSet() : (BlockCoding.decode(RuleSet.self, from: payload) ?? RuleSet())
            let count = BlockEnforcer.shared.apply(set)
            extensionLog.info("Carrying out \(count, privacy: .public) rules")
            reply(count)
        }
    }

    func claimRule(payload: Data, withReply reply: @escaping (Int) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(-1); return }
        queue.async {
            guard self.client === connection,
                  let claim = BlockCoding.decode(RuleClaim.self, from: payload),
                  let claimed = BlockEnforcer.shared.claimRule(claim) else {
                reply(-1)
                return
            }
            reply(claimed ? 1 : 0)
        }
    }

    func rulePackHello(appProtocol: Int, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(Data()); return }
        queue.async {
            guard self.client === connection else { reply(Data()); return }
            reply(BlockCoding.encode(BlockEnforcer.shared.packHandshake()))
        }
    }

    func beginRulePack(payload: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "No registered app connection")))
            return
        }
        queue.async {
            guard self.client === connection else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "Superseded app connection")))
                return
            }
            guard let header = BlockCoding.decode(RulePackTransferHeader.self, from: payload) else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "Unreadable pack transfer")))
                return
            }
            let result = self.packTransfer.begin(header, active: BlockEnforcer.shared.packHandshake())
            reply(BlockCoding.encode(result))
        }
    }

    func appendRulePack(generation: String, index: Int, payload: Data, withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else { reply(false); return }
        queue.async {
            guard self.client === connection else { reply(false); return }
            reply(self.packTransfer.append(generation: generation, index: index, payload: payload))
        }
    }

    func commitRulePack(generation: String, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "No registered app connection")))
            return
        }
        queue.async {
            guard self.client === connection else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "Superseded app connection")))
                return
            }
            switch self.packTransfer.commit(generation: generation, active: BlockEnforcer.shared.packHandshake()) {
            case .rejected(let result):
                reply(BlockCoding.encode(result))
            case .payload(let data, let header):
                guard let snapshot = BlockCoding.decode(RulePackSnapshot.self, from: data),
                      snapshot.generation == header.generation, snapshot.digest == header.digest else {
                    reply(BlockCoding.encode(RulePackApplyResult(status: .invalid,
                                                                 detail: "Pack generation or digest mismatch")))
                    return
                }
                do {
                    let result = try BlockEnforcer.shared.apply(snapshot)
                    self.updateEnforcementConnectionState()
                    reply(BlockCoding.encode(result))
                } catch {
                    reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "\(error)")))
                }
            }
        }
    }

    func clearRulePacks(payload: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "No registered app connection")))
            return
        }
        queue.async {
            guard self.client === connection else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "Superseded app connection")))
                return
            }
            guard let request = BlockCoding.decode(RulePackClearRequest.self, from: payload) else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .invalid, detail: "Unreadable clear request")))
                return
            }
            let active = BlockEnforcer.shared.packHandshake()
            guard request.expectedActiveGeneration == active.activeGeneration else {
                reply(BlockCoding.encode(RulePackApplyResult(status: .stale, generation: active.activeGeneration,
                                                             activeDigest: active.activeDigest,
                                                             detail: "The active pack generation changed.")))
                return
            }
            self.packTransfer.reset()
            let result = BlockEnforcer.shared.clearPacks()
            self.updateEnforcementConnectionState()
            reply(BlockCoding.encode(result))
        }
    }

    func send(_ batches: [TrafficBatch]) {
        queue.async {
            for batch in batches {
                self.nextSeq += 1
                self.pending.append((self.nextSeq, batch))
            }
            if self.pending.count > self.maxPendingBatches {
                self.pending.removeFirst(self.pending.count - self.maxPendingBatches)
            }
            self.flushLocked()
        }
    }

    func report(pack event: RulePackEvent) {
        queue.async {
            self.durableDeliveryBegan(.packs)
            let key = PackEventKey(event)
            if var existing = self.packEvents[key] {
                existing.count += event.count
                existing.firstAt = min(existing.firstAt, event.firstAt)
                existing.lastAt = max(existing.lastAt, event.lastAt)
                self.packEvents[key] = existing
            } else if self.packEvents.count < self.maxPackEventKeys {
                self.packEvents[key] = event
            } else {
                self.droppedPackHits = self.saturatingAdd(self.droppedPackHits, Int64(event.count))
                self.droppedPackKeys = self.saturatingAdd(self.droppedPackKeys, 1)
            }
            guard !self.packFlushScheduled else { return }
            self.packFlushScheduled = true
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.packFlushScheduled = false
                self.flushPackEventsLocked()
            }
        }
    }

    /// A connection the filter refused, on its way to being recorded as an alert.
    func report(_ event: BlockEvent) {
        queue.async {
            var event = event
            self.nextBlockSequence = self.saturatingAdd(self.nextBlockSequence, 1)
            event.deliverySession = self.eventDeliverySession
            event.deliverySequence = self.nextBlockSequence
            self.durableDeliveryBegan(.blocks)
            self.blocks.append(event)
            self.flushBlocksLocked()
        }
    }

    /// A connection a rule decided, refusal or relaxation, on its way to the violations feed.
    func report(decision event: RuleEvent) {
        queue.async {
            var event = event
            self.nextDecisionSequence = self.saturatingAdd(self.nextDecisionSequence, 1)
            event.deliverySession = self.eventDeliverySession
            event.deliverySequence = self.nextDecisionSequence
            self.durableDeliveryBegan(.decisions)
            self.decisions.append(event)
            self.flushDecisionsLocked()
        }
    }

    private func flushPackEventsLocked() {
        guard durableEventsEnabled, !packEventsInFlight, let client else { return }
        if packEventBatch == nil {
            guard !packEvents.isEmpty || droppedPackHits > 0 else { return }
            let keys = Array(packEvents.keys.prefix(300))
            let events = keys.compactMap { packEvents.removeValue(forKey: $0) }
            nextPackSequence = saturatingAdd(nextPackSequence, 1)
            packEventBatch = RulePackEventBatch(deliverySession: packDeliverySession, sequence: nextPackSequence,
                                                events: events, droppedHits: droppedPackHits,
                                                droppedKeys: droppedPackKeys)
            droppedPackHits = 0
            droppedPackKeys = 0
        }
        guard let batch = packEventBatch else { return }
        durableDeliveryBegan(.packs)
        let capturedClient = client
        let capturedClientID = ObjectIdentifier(capturedClient)
        let proxy = capturedClient.remoteObjectProxyWithErrorHandler { [weak self, weak capturedClient] error in
            extensionLog.error("rulePackEvents() failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async {
                guard let self, self.client === capturedClient, self.packEventBatch?.id == batch.id else { return }
                self.packEventsInFlight = false
                self.durableDeliveryFailed(.packs)
                self.schedulePackRetryLocked()
            }
        } as? FlowlightAppXPC
        guard let proxy else {
            durableDeliveryFailed(.packs)
            schedulePackRetryLocked()
            return
        }
        packEventsInFlight = true
        proxy.rulePackEvents(payload: BlockCoding.encode(batch)) { [weak self] accepted in
            self?.queue.async {
                guard let self, self.client.map(ObjectIdentifier.init) == capturedClientID,
                      self.packEventBatch?.id == batch.id else { return }
                self.packEventsInFlight = false
                if accepted {
                    self.packEventBatch = nil
                    self.flushPackEventsLocked()
                    if self.packEventBatch == nil {
                        self.durableDeliverySucceeded(.packs)
                    }
                } else {
                    self.durableDeliveryFailed(.packs)
                    self.schedulePackRetryLocked()
                }
            }
        }
    }

    private func schedulePackRetryLocked() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushPackEventsLocked() }
    }

    private func updateEnforcementConnectionState() {
        BlockEnforcer.shared.appConnectionChanged(
            connected: client != nil && durableEventsEnabled && enforcementSynchronized
                && durableHealth.isHealthy
        )
    }

    private func durableDeliveryBegan(_ channel: DurableChannel) {
        durableHealth.begin(channel)
        updateEnforcementConnectionState()
    }

    private func durableDeliveryFailed(_ channel: DurableChannel) {
        durableHealth.failed(channel)
        updateEnforcementConnectionState()
    }

    private func durableDeliverySucceeded(_ channel: DurableChannel) {
        durableHealth.succeeded(channel)
        updateEnforcementConnectionState()
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private func flushDecisionsLocked() {
        guard durableEventsEnabled, let client,
              let delivery = decisions.begin(clientGeneration: clientGeneration, limit: durableChunkSize, id: \.id)
        else { return }
        durableDeliveryBegan(.decisions)
        let generation = delivery.clientGeneration
        let token = delivery.token
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            extensionLog.error("ruleDecisions() failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async {
                guard let self, self.clientGeneration == generation,
                      self.decisions.complete(token: token, clientGeneration: generation,
                                              committed: false, id: \.id) else { return }
                self.durableDeliveryFailed(.decisions)
                self.scheduleDecisionRetryLocked()
            }
        } as? FlowlightAppXPC
        guard let proxy else {
            _ = decisions.complete(token: token, clientGeneration: generation, committed: false, id: \.id)
            durableDeliveryFailed(.decisions)
            scheduleDecisionRetryLocked()
            return
        }
        proxy.ruleDecisionsDurably(payload: BlockCoding.encode(delivery.events)) { [weak self] committed in
            self?.queue.async {
                guard let self, self.clientGeneration == generation,
                      self.decisions.complete(token: token, clientGeneration: generation,
                                              committed: committed, id: \.id) else { return }
                if committed {
                    self.flushDecisionsLocked()
                    if self.decisions.isEmpty {
                        self.durableDeliverySucceeded(.decisions)
                    }
                } else {
                    self.durableDeliveryFailed(.decisions)
                    self.scheduleDecisionRetryLocked()
                }
            }
        }
    }

    private func scheduleDecisionRetryLocked() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushDecisionsLocked() }
    }

    private func flushBlocksLocked() {
        guard durableEventsEnabled, let client,
              let delivery = blocks.begin(clientGeneration: clientGeneration, limit: durableChunkSize, id: \.id)
        else { return }
        durableDeliveryBegan(.blocks)
        let generation = delivery.clientGeneration
        let token = delivery.token
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            extensionLog.error("blocked() failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async {
                guard let self, self.clientGeneration == generation,
                      self.blocks.complete(token: token, clientGeneration: generation,
                                           committed: false, id: \.id) else { return }
                self.durableDeliveryFailed(.blocks)
                self.scheduleBlockRetryLocked()
            }
        } as? FlowlightAppXPC
        guard let proxy else {
            _ = blocks.complete(token: token, clientGeneration: generation, committed: false, id: \.id)
            durableDeliveryFailed(.blocks)
            scheduleBlockRetryLocked()
            return
        }
        proxy.blockedDurably(payload: BlockCoding.encode(delivery.events)) { [weak self] committed in
            self?.queue.async {
                guard let self, self.clientGeneration == generation,
                      self.blocks.complete(token: token, clientGeneration: generation,
                                           committed: committed, id: \.id) else { return }
                if committed {
                    self.flushBlocksLocked()
                    if self.blocks.isEmpty {
                        self.durableDeliverySucceeded(.blocks)
                    }
                } else {
                    self.durableDeliveryFailed(.blocks)
                    self.scheduleBlockRetryLocked()
                }
            }
        }
    }

    private func scheduleBlockRetryLocked() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.flushBlocksLocked() }
    }

    /// Sends one chunk at a time; batches leave the queue only after the app acknowledges them.
    ///
    /// Newest first. An app that has just connected needs the current second before anything else — that is what
    /// its live view is made of — and the backlog behind it is history, which is just as useful arriving second.
    /// Sending oldest-first instead meant a long gap had to drain completely before anything current appeared.
    private func flushLocked() {
        guard !inFlight, let client, !pending.isEmpty else { return }
        let chunk = Array(pending.suffix(chunkSize))
        let firstSeq = chunk.first!.seq, lastSeq = chunk.last!.seq
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            extensionLog.error("deliver failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async { self?.inFlight = false }
        } as? FlowlightAppXPC
        guard let proxy else { return }
        inFlight = true
        proxy.deliver(payload: TrafficCoding.encode(chunk.map(\.batch))) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.inFlight = false
                self.pending.removeAll { $0.seq >= firstSeq && $0.seq <= lastSeq }
                self.flushLocked()
            }
        }
    }
}
