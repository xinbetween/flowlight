import Foundation

/// Serializes access to the extension's one mutable transfer buffer. Repeating the active epoch is redundant; a newer
/// epoch is coalesced and starts only after the active attempt reaches a terminal callback.
struct RulePackPushGate {
    private(set) var activeEpoch: UInt64?
    private var hasPendingNewerEpoch = false

    mutating func begin(epoch: UInt64) -> Bool {
        guard let activeEpoch else {
            self.activeEpoch = epoch
            return true
        }
        if activeEpoch != epoch { hasPendingNewerEpoch = true }
        return false
    }

    mutating func finish(epoch: UInt64) -> Bool? {
        guard activeEpoch == epoch else { return nil }
        activeEpoch = nil
        defer { hasPendingNewerEpoch = false }
        return hasPendingNewerEpoch
    }

    mutating func reset() {
        activeEpoch = nil
        hasPendingNewerEpoch = false
    }
}

/// Receives per-second batches from the system extension over XPC.
final class ExtensionTrafficSource: NSObject, TrafficSource, FlowlightAppXPC, @unchecked Sendable {
    static func acceptsRegisteredVersion(_ actual: String, expected: String) -> Bool {
        !expected.isEmpty && actual == expected
    }
    var displayName: String { L("Network Extension") }
    private var connection: NSXPCConnection?
    private var sink: (([TrafficBatch]) -> Void)?
    private var status: ((String) -> Void)?
    private var retryTimer: Timer?
    /// Tells the app that capture is alive during a quiet second. The extension only sends when there is traffic,
    /// so without this the status goes orange on an idle Mac even though the filter is working perfectly.
    private var heartbeatTimer: Timer?
    private var stopped = true
    /// Set once a batch with actual traffic in it arrives. Until then the connection being up says only that the
    /// extension is running — not that it is filtering anything, which is a different failure and looks identical.
    private var sawTraffic = false
    private var version = ""
    /// Called when macOS has the extension running but isn't letting it filter — a state the user can only fix by
    /// switching source, so it needs to reach the UI as something more than a line of status text.
    var onFilterUnavailable: ((String) -> Void)?
    /// Connections the filter refused, on their way to being recorded as alerts.
    var onBlocked: (([BlockEvent]) -> Void)?
    /// The enforcing allowlists, kept here so a reconnect re-sends them without the app being asked again. The
    /// extension never persists them: with no app to record a refusal, nothing should be refused.
    private var enforcement: [AgentPolicy] = []
    /// The rule list, kept for the same reason and re-sent on the same reconnect.
    private var ruleSet = RuleSet()
    /// Connections a rule decided, refusals and relaxations alike.
    var onRuleDecisions: (([RuleEvent]) -> Void)?
    /// Aggregated managed-pack decisions. These never enter the ordinary block-alert path.
    var onRulePackEvents: ((RulePackEventBatch, @escaping @Sendable (Bool) -> Void) -> Void)?
    var onRulePackStatus: ((RulePackApplyResult) -> Void)?
    private var rulePackSnapshot: RulePackSnapshot?
    /// Invalidates every callback from a superseded desired snapshot or XPC connection.
    private var rulePackPushEpoch: UInt64 = 0
    /// The extension owns one mutable transfer buffer, so overlapping handshakes must never race to reset it.
    private var rulePackPushGate = RulePackPushGate()
    /// The escalation ladder for a connection that keeps failing. Only touched on the main thread, like
    /// `connection`, because a decision made from two queues at once is no decision at all.
    private var recovery = ExtensionRecovery()
    /// Asked when redialling has stopped being worth it and the two builds should be compared. The source can't
    /// do that itself — submitting system extension requests belongs to `ExtensionManager`.
    var onRepairRequested: (() -> Void)?
    /// The extension isn't going to answer. Whoever owns the source should capture some other way and say so.
    var onGaveUp: ((String) -> Void)?

    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void) {
        self.sink = sink
        self.status = status
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        // async, never sync: stop() is called from the main actor today, and a sync hop from anywhere else
        // would deadlock. Teardown only touches this instance, so a later hop is harmless.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.teardown() }
            return
        }
        teardown()
    }

    private func teardown() {
        retryTimer?.invalidate()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.invalidate()
        connection = nil
    }

    /// Always on the main thread: `connection` is read from XPC callbacks, the retry timer and stop(), and
    /// comparing identities is only meaningful if one thread owns the property.
    private func connect() {
        guard Thread.isMainThread else { DispatchQueue.main.async { [weak self] in self?.connect() }; return }
        guard !stopped else { return }
        // Drop the previous attempt before making another. Left alive, its handlers keep firing long after it is
        // irrelevant — reporting "unreachable" over a working connection and tearing it down to retry.
        let superseded = connection
        connection = nil
        superseded?.invalidate()
        rulePackPushEpoch &+= 1
        rulePackPushGate.reset()

        let connection = NSXPCConnection(machServiceName: FlowlightConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: FlowlightProviderXPC.self)
        connection.exportedInterface = NSXPCInterface(with: FlowlightAppXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.scheduleReconnect(L("Extension connection invalidated"), from: connection)
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.scheduleReconnect(L("Extension connection interrupted"), from: connection)
        }
        connection.resume()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            self?.scheduleReconnect(L("Extension unreachable: %@", error.localizedDescription), from: connection)
        } as? FlowlightProviderXPC
        proxy?.register { [weak self, weak connection] ok, version in
            guard let self else { return }
            DispatchQueue.main.async {
                // A reply from a superseded attempt, or from one already torn down — two nils compare identical.
                guard let connection, self.connection === connection else { return }
                self.version = version
                // A refusal used to end here, with a line of status text and no timer: connected, registered at
                // nothing, and never going to try again. It is a failure like any other, so it goes on the ladder.
                guard ok else { self.scheduleReconnect(L("Extension refused registration"), from: connection); return }
                // Exact ordinary rules are encoded as an additive Rule field. An older filter would ignore that field
                // and widen a collector host to its whole product domain, so publish nothing until the full embedded
                // version/build is running. Registration reset the old filter to fail-open before this check.
                let expected = ExtensionManager.expectedExtensionVersion
                guard Self.acceptsRegisteredVersion(version, expected: expected) else {
                    self.status?(L("The installed filter extension is %@ and this app is %@ — macOS is replacing it. Capture resumes once it has.",
                                   version, expected))
                    self.onRepairRequested?()
                    self.scheduleReconnect(L("Trying the filter extension again…"), from: connection)
                    return
                }
                self.recovery.succeeded()
                self.status?(self.sawTraffic ? L("Connected to filter extension %@", version)
                                             : L("Connected to filter extension %@ — no traffic from it yet", version))
                self.startHeartbeat()
                self.reportPackStatus(.init(status: .accepted, detail: "Synchronizing managed packs"))
                // Initial synchronization is ordered: explicit user allows exist before AgentPolicy is enabled.
                // Managed packs remain independently cleared until their own commit or clear acknowledges.
                self.pushRules {
                    self.pushEnforcement {
                        self.pushRulePacks()
                    }
                }
                self.checkFilterState(on: connection, version: version)
            }
        }
    }

    /// Connecting proves the extension is running, not that macOS is letting it filter. macOS runs one content
    /// filter at a time, so on a Mac where a security product already holds that slot ours is started and then
    /// never asked for anything — connected, and permanently empty. Worth saying so rather than looking fine.
    private func checkFilterState(on connection: NSXPCConnection?, version: String) {
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FlowlightProviderXPC
        proxy?.filterState { [weak self] running, detail in
            guard let self, running == false else { return }
            DispatchQueue.main.async {
                guard self.connection === connection, !self.sawTraffic else { return }
                let message = detail.isEmpty
                    ? L("macOS hasn't started Flowlight's filter. It runs one content filter at a time, and another one — a VPN or a security agent such as Palo Alto Networks GlobalProtect or CrowdStrike Falcon — already has that slot. The extension can't capture anything on this Mac until that changes.")
                    : L("macOS refused to start Flowlight's filter: %@", detail)
                self.status?(detail.isEmpty ? L("Connected to the extension %@, but it isn't filtering", version)
                                            : L("The filter couldn't start"))
                self.onFilterUnavailable?(message)
            }
        }
    }

    /// While the connection is up, a quiet second still counts as capture being alive.
    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.sink?([])   // green straight away rather than after the first second
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.sink?([])
            }
        }
    }

    /// `connection` identifies the attempt this came from. Anything but the current one is ignored: an old
    /// connection failing says nothing about the one in use, and acting on it was what made a working extension
    /// report "Extension unreachable" indefinitely.
    ///
    /// What happens next comes from `recovery` rather than from a fixed five-second timer. Some invalidations are
    /// permanent — a stale extension left behind by an app update is the usual one — and redialling those every
    /// five seconds until the app is quit is how a Mac ends up showing an enabled filter and no traffic all day.
    private func scheduleReconnect(_ message: String, from connection: NSXPCConnection?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            // `let connection` as well as the identity, because two nils are identical and a late error handler
            // for an attempt that has already been cleaned up would otherwise count as a fresh failure.
            guard let connection, self.connection === connection else { return }
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
            self.connection = nil
            // Let go of it properly rather than just dropping the reference: a connection whose registration was
            // refused is still live, and the extension goes on holding a client it will never hear from again.
            connection.invalidate()
            self.retryTimer?.invalidate()
            self.retryTimer = nil

            let step = self.recovery.next()
            self.status?(ExtensionRecovery.statusLine(message, step: step, attempt: self.recovery.attempts))
            switch step {
            case .fallBack:
                self.onGaveUp?(message)
            case .repairVersion(let after):
                self.onRepairRequested?()
                self.retry(after: after)
            case .redial(let after):
                self.retry(after: after)
            }
        }
    }

    private func retry(after delay: TimeInterval) {
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.connect() }
    }

    /// A stale extension is being replaced. Told about it, the ladder can be patient again: the fault it was
    /// escalating towards is the one now being fixed, and the redial after a repair deserves the full run.
    func versionRepairStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.recovery.repairStarted()
        }
    }

    func setEnforcement(_ policies: [AgentPolicy]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforcement = policies
            self.pushEnforcement()
        }
    }

    /// Always on the main thread, like `connect()`, and always the whole list: the extension holds no state of its
    /// own about this, so one message either describes the current rules completely or turns blocking off.
    private func pushEnforcement(completion: (() -> Void)? = nil) {
        guard let connection else { return }
        let payload = enforcement.isEmpty ? Data() : BlockCoding.encode(enforcement)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            self?.scheduleReconnect(L("Extension unreachable: %@", error.localizedDescription), from: connection)
        } as? FlowlightProviderXPC
        guard let proxy else {
            scheduleReconnect(L("Extension unreachable: %@", "policy update"), from: connection)
            return
        }
        proxy.setEnforcement(payload: payload) { [weak self, weak connection] _ in
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                completion?()
            }
        }
    }

    func setRules(_ rules: RuleSet) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ruleSet = rules
            self.pushRules()
        }
    }

    private func pushRules(completion: (() -> Void)? = nil) {
        guard let connection else { return }
        let sentGeneration = ruleSet.generation
        let payload = BlockCoding.encode(ruleSet)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            self?.scheduleReconnect(L("Extension unreachable: %@", error.localizedDescription), from: connection)
        } as? FlowlightProviderXPC
        guard let proxy else {
            scheduleReconnect(L("Extension unreachable: %@", "rule update"), from: connection)
            return
        }
        proxy.setRules(payload: payload) { [weak self, weak connection] _ in
            DispatchQueue.main.async { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                guard self.ruleSet.generation == sentGeneration else {
                    // The initial handshake chains enforcement and packs from this reply. If a newer whole-list
                    // publication overtook it, restart that chain with the current generation instead of stranding
                    // the source half-synchronized.
                    if completion != nil {
                        self.pushRules(completion: completion)
                    }
                    return
                }
                completion?()
            }
        }
    }

    func claimRule(_ claim: RuleClaim, completion: @escaping @Sendable (Bool?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let connection = self.connection else {
                completion(nil)
                return
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in completion(nil) }
                as? FlowlightProviderXPC
            guard let proxy else {
                completion(nil)
                return
            }
            proxy.claimRule(payload: BlockCoding.encode(claim)) { [weak self, weak connection] result in
                DispatchQueue.main.async { [weak self, weak connection] in
                    guard let self, let connection, self.connection === connection else {
                        completion(nil)
                        return
                    }
                    completion(result < 0 ? nil : result == 1)
                }
            }
        }
    }

    func setRulePacks(_ snapshot: RulePackSnapshot?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rulePackSnapshot = snapshot
            self.rulePackPushEpoch &+= 1
            self.pushRulePacks()
        }
    }

    private func pushRulePacks() {
        guard let connection else { return }
        let epoch = rulePackPushEpoch
        guard rulePackPushGate.begin(epoch: epoch) else { return }
        let desiredGeneration = rulePackSnapshot?.generation
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                appLog.error("pack sync XPC failed epoch \(epoch, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.finishRulePackPush(
                    epoch: epoch,
                    status: .init(status: .invalid, detail: error.localizedDescription)
                )
            }
        } as? FlowlightProviderXPC
        guard let proxy else {
            appLog.error("pack sync proxy unavailable epoch \(epoch, privacy: .public)")
            finishRulePackPush(
                epoch: epoch,
                status: .init(status: .invalid, detail: "The extension pack interface is unavailable.")
            )
            return
        }
        proxy.rulePackHello(appProtocol: Int(RulePackSnapshot.protocolVersion)) { [weak self, weak connection] (data: Data) in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                guard self.rulePackPushEpoch == epoch,
                      self.rulePackSnapshot?.generation == desiredGeneration else {
                    self.finishRulePackPush(epoch: epoch)
                    return
                }
                guard let handshake = BlockCoding.decode(RulePackHandshake.self, from: data) else {
                    self.finishRulePackPush(
                        epoch: epoch,
                        status: .init(status: .invalid, detail: "The extension returned an unreadable pack handshake.")
                    )
                    return
                }
                guard handshake.protocolVersion == RulePackSnapshot.protocolVersion else {
                    self.finishRulePackPush(
                        epoch: epoch,
                        status: .init(
                            status: .incompatible,
                            activeDigest: handshake.activeDigest,
                            detail: "The installed extension does not support this pack format."
                        )
                    )
                    return
                }
                guard let snapshot = self.rulePackSnapshot else {
                    let request = RulePackClearRequest(expectedActiveGeneration: handshake.activeGeneration)
                    proxy.clearRulePacks(payload: BlockCoding.encode(request)) { [weak self, weak connection] data in
                        DispatchQueue.main.async {
                            guard let self, let connection, self.connection === connection else { return }
                            guard self.rulePackPushEpoch == epoch, self.rulePackSnapshot == nil else {
                                self.finishRulePackPush(epoch: epoch)
                                return
                            }
                            self.finishRulePackPush(epoch: epoch, statusData: data)
                        }
                    }
                    return
                }
                guard handshake.activeDigest != snapshot.digest else {
                    self.finishRulePackPush(
                        epoch: epoch,
                        status: .init(
                            status: .committed,
                            generation: handshake.activeGeneration,
                            activeDigest: handshake.activeDigest,
                            activePacks: snapshot.configurations.filter(\.enabled).count
                        )
                    )
                    return
                }
                let payload = BlockCoding.encode(snapshot)
                let chunkSize = 64 * 1_024
                let chunks = stride(from: 0, to: payload.count, by: chunkSize).map {
                    payload.subdata(in: $0..<min(payload.count, $0 + chunkSize))
                }
                let header = RulePackTransferHeader(protocolVersion: RulePackSnapshot.protocolVersion,
                                                    generation: snapshot.generation, digest: snapshot.digest,
                                                    totalBytes: payload.count, chunks: chunks.count,
                                                    expectedActiveGeneration: handshake.activeGeneration)
                proxy.beginRulePack(payload: BlockCoding.encode(header)) { [weak self, weak connection] reply in
                    DispatchQueue.main.async {
                        guard let self, let connection, self.connection === connection else { return }
                        guard self.rulePackPushEpoch == epoch,
                              self.rulePackSnapshot?.generation == snapshot.generation else {
                            self.finishRulePackPush(epoch: epoch)
                            return
                        }
                        guard BlockCoding.decode(RulePackApplyResult.self, from: reply)?.status == .accepted else {
                            self.finishRulePackPush(epoch: epoch, statusData: reply)
                            return
                        }
                        self.appendPackChunks(chunks, index: 0, snapshot: snapshot, epoch: epoch,
                                              connection: connection, proxy: proxy)
                    }
                }
            }
        }
    }

    private func appendPackChunks(_ chunks: [Data], index: Int, snapshot: RulePackSnapshot, epoch: UInt64,
                                  connection: NSXPCConnection, proxy: FlowlightProviderXPC) {
        guard self.connection === connection, rulePackPushEpoch == epoch,
              rulePackSnapshot?.generation == snapshot.generation else {
            finishRulePackPush(epoch: epoch)
            return
        }
        guard index < chunks.count else {
            proxy.commitRulePack(generation: snapshot.generation.uuidString) { [weak self, weak connection] data in
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    guard self.rulePackPushEpoch == epoch,
                          self.rulePackSnapshot?.generation == snapshot.generation else {
                        self.finishRulePackPush(epoch: epoch)
                        return
                    }
                    self.finishRulePackPush(epoch: epoch, statusData: data)
                }
            }
            return
        }
        proxy.appendRulePack(generation: snapshot.generation.uuidString, index: index, payload: chunks[index]) {
            [weak self, weak connection] accepted in
            DispatchQueue.main.async {
                guard let self, let connection, self.connection === connection else { return }
                guard self.rulePackPushEpoch == epoch,
                      self.rulePackSnapshot?.generation == snapshot.generation else {
                    self.finishRulePackPush(epoch: epoch)
                    return
                }
                guard accepted else {
                    self.finishRulePackPush(
                        epoch: epoch,
                        status: .init(
                            status: .invalid,
                            generation: snapshot.generation,
                            detail: "The extension rejected pack chunk \(index + 1)."
                        )
                    )
                    return
                }
                self.appendPackChunks(chunks, index: index + 1, snapshot: snapshot, epoch: epoch,
                                      connection: connection, proxy: proxy)
            }
        }
    }

    private func finishRulePackPush(epoch: UInt64, statusData: Data) {
        let status = BlockCoding.decode(RulePackApplyResult.self, from: statusData)
            ?? .init(status: .invalid, detail: "The extension returned an unreadable pack status.")
        finishRulePackPush(epoch: epoch, status: status)
    }

    private func finishRulePackPush(epoch: UInt64, status: RulePackApplyResult? = nil) {
        guard let hasPendingNewerEpoch = rulePackPushGate.finish(epoch: epoch) else { return }
        if let status {
            if status.status == .stale {
                reportPackStatus(
                    .init(
                        status: .accepted,
                        generation: status.generation,
                        activeDigest: status.activeDigest,
                        detail: status.detail
                    )
                )
            } else {
                reportPackStatus(status)
            }
        }
        if hasPendingNewerEpoch || status?.status == .stale {
            pushRulePacks()
        }
    }

    private func reportPackStatus(_ status: RulePackApplyResult) {
        if Thread.isMainThread {
            onRulePackStatus?(status)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onRulePackStatus?(status) }
        }
    }

    func rulePackEvents(payload: Data, reply: @escaping @Sendable (Bool) -> Void) {
        guard let batch = BlockCoding.decode(RulePackEventBatch.self, from: payload),
              let onRulePackEvents else {
            reply(false)
            return
        }
        onRulePackEvents(batch, reply)
    }

    func ruleDecisions(payload: Data, reply: @escaping () -> Void) {
        let events = BlockCoding.decode([RuleEvent].self, from: payload) ?? []
        if !events.isEmpty { onRuleDecisions?(events) }
        reply()
    }

    func blocked(payload: Data, reply: @escaping () -> Void) {
        let events = BlockCoding.decode([BlockEvent].self, from: payload) ?? []
        if !events.isEmpty { onBlocked?(events) }
        reply()
    }

    func deliver(payload: Data, reply: @escaping () -> Void) {
        let batches = TrafficCoding.decode(payload)
        if !batches.isEmpty, !sawTraffic {
            sawTraffic = true
            let version = self.version
            DispatchQueue.main.async { [weak self] in self?.status?(L("Connected to filter extension %@", version)) }
        }
        // Empty deliveries are passed on too: ingest reads them as "capture is alive, nothing moved".
        sink?(batches)
        reply()
    }
}
