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
                self.status?(ok ? "Connected to filter extension \(version)" : "Extension refused registration")
                if ok { self.startHeartbeat() }
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

    func deliver(payload: Data, reply: @escaping () -> Void) {
        // Empty deliveries are passed on too: ingest reads them as "capture is alive, nothing moved".
        sink?(TrafficCoding.decode(payload))
        reply()
    }
}
