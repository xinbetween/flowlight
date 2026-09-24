import Foundation

/// Receives per-second batches from the system extension over XPC.
final class ExtensionTrafficSource: NSObject, TrafficSource, FlowlightAppXPC, @unchecked Sendable {
    let displayName = "Network Extension"
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

        let connection = NSXPCConnection(machServiceName: FlowlightConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: FlowlightProviderXPC.self)
        connection.exportedInterface = NSXPCInterface(with: FlowlightAppXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.scheduleReconnect("Extension connection invalidated", from: connection)
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.scheduleReconnect("Extension connection interrupted", from: connection)
        }
        connection.resume()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            self?.scheduleReconnect("Extension unreachable: \(error.localizedDescription)", from: connection)
        } as? FlowlightProviderXPC
        proxy?.register { [weak self, weak connection] ok, version in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.connection === connection else { return }   // a reply from a superseded attempt
                self.version = version
                guard ok else { self.status?("Extension refused registration"); return }
                self.status?(self.sawTraffic ? "Connected to filter extension \(version)"
                                             : "Connected to filter extension \(version) — no traffic from it yet")
                self.startHeartbeat()
                self.pushEnforcement()
                self.pushRules()
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
                    ? "macOS hasn't started Flowlight's filter. It runs one content filter at a time, and another "
                      + "one — a VPN or a security agent such as Palo Alto Networks GlobalProtect or CrowdStrike Falcon — already "
                      + "has that slot. The extension can't capture anything on this Mac until that changes."
                    : "macOS refused to start Flowlight's filter: \(detail)"
                self.status?(detail.isEmpty ? "Connected to the extension \(version), but it isn't filtering" : "The filter couldn't start")
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
    private func scheduleReconnect(_ message: String, from connection: NSXPCConnection?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            guard self.connection === connection else { return }
            self.status?(message)
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
            self.connection = nil
            self.retryTimer?.invalidate()
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.connect() }
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
    private func pushEnforcement() {
        guard let connection else { return }
        let payload = enforcement.isEmpty ? Data() : BlockCoding.encode(enforcement)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FlowlightProviderXPC
        proxy?.setEnforcement(payload: payload) { _ in }
    }

    func setRules(_ rules: RuleSet) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ruleSet = rules
            self.pushRules()
        }
    }

    private func pushRules() {
        guard let connection else { return }
        let payload = ruleSet.rules.isEmpty && ruleSet.pausedUntil == nil ? Data() : BlockCoding.encode(ruleSet)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FlowlightProviderXPC
        proxy?.setRules(payload: payload) { _ in }
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
            DispatchQueue.main.async { [weak self] in self?.status?("Connected to filter extension \(version)") }
        }
        // Empty deliveries are passed on too: ingest reads them as "capture is alive, nothing moved".
        sink?(batches)
        reply()
    }
}
