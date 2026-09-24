import Foundation
import os.log

/// Vends the Mach service and pushes per-second batches to the connected host app.
final class IPCServer: NSObject, NSXPCListenerDelegate, FlowlightProviderXPC, @unchecked Sendable {
    static let shared = IPCServer()

    private var listener: NSXPCListener?
    private var client: NSXPCConnection?
    private var pending: [(seq: UInt64, batch: TrafficBatch)] = []
    private var nextSeq: UInt64 = 0
    private var inFlight = false
    /// Refused connections waiting to be recorded by the app, on their own queue so they never wait behind an
    /// hour of buffered traffic. Kept small: enforcement lapses when the app is away, so this can't pile up.
    private var blocks: [BlockEvent] = []
    private var blocksInFlight = false
    /// Connections a rule decided, on the same footing and for the same reason.
    private var decisions: [RuleEvent] = []
    private var decisionsInFlight = false
    private let maxPendingBlocks = 500
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
        BlockEnforcer.shared.report = { [weak self] event in self?.report(event) }
        BlockEnforcer.shared.reportDecision = { [weak self] event in self?.report(decision: event) }
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
                self.inFlight = false
                self.blocksInFlight = false
                self.decisionsInFlight = false
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
            self.inFlight = false
            self.blocksInFlight = false
            self.decisionsInFlight = false
            BlockEnforcer.shared.appConnectionChanged(connected: true)
            self.flushLocked()
            self.flushBlocksLocked()
            self.flushDecisionsLocked()
        }
        reply(true, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    func setEnforcement(payload: Data, withReply reply: @escaping (Int) -> Void) {
        let policies = payload.isEmpty ? [] : (BlockCoding.decode([AgentPolicy].self, from: payload) ?? [])
        let count = BlockEnforcer.shared.apply(policies)
        extensionLog.info("Enforcing \(count, privacy: .public) allowlists")
        reply(count)
    }

    func setRules(payload: Data, withReply reply: @escaping (Int) -> Void) {
        let set = payload.isEmpty ? RuleSet() : (BlockCoding.decode(RuleSet.self, from: payload) ?? RuleSet())
        let count = BlockEnforcer.shared.apply(set)
        extensionLog.info("Carrying out \(count, privacy: .public) rules")
        reply(count)
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

    /// A connection the filter refused, on its way to being recorded as an alert.
    func report(_ event: BlockEvent) {
        queue.async {
            self.blocks.append(event)
            if self.blocks.count > self.maxPendingBlocks {
                self.blocks.removeFirst(self.blocks.count - self.maxPendingBlocks)
            }
            self.flushBlocksLocked()
        }
    }

    /// A connection a rule decided, refusal or relaxation, on its way to the violations feed.
    func report(decision event: RuleEvent) {
        queue.async {
            self.decisions.append(event)
            if self.decisions.count > self.maxPendingBlocks {
                self.decisions.removeFirst(self.decisions.count - self.maxPendingBlocks)
            }
            self.flushDecisionsLocked()
        }
    }

    private func flushDecisionsLocked() {
        guard !decisionsInFlight, let client, !decisions.isEmpty else { return }
        let chunk = decisions
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            extensionLog.error("ruleDecisions() failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async { self?.decisionsInFlight = false }
        } as? FlowlightAppXPC
        guard let proxy else { return }
        decisionsInFlight = true
        proxy.ruleDecisions(payload: BlockCoding.encode(chunk)) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.decisionsInFlight = false
                self.decisions.removeFirst(min(chunk.count, self.decisions.count))
                self.flushDecisionsLocked()
            }
        }
    }

    private func flushBlocksLocked() {
        guard !blocksInFlight, let client, !blocks.isEmpty else { return }
        let chunk = blocks
        let proxy = client.remoteObjectProxyWithErrorHandler { [weak self] error in
            extensionLog.error("blocked() failed: \(error.localizedDescription, privacy: .public)")
            self?.queue.async { self?.blocksInFlight = false }
        } as? FlowlightAppXPC
        guard let proxy else { return }
        blocksInFlight = true
        proxy.blocked(payload: BlockCoding.encode(chunk)) { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.blocksInFlight = false
                self.blocks.removeFirst(min(chunk.count, self.blocks.count))
                self.flushBlocksLocked()
            }
        }
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
