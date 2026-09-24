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
        retryTimer?.invalidate()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.invalidate()
        connection = nil
    }

    private func connect() {
        guard !stopped else { return }
        let connection = NSXPCConnection(machServiceName: FlowlightConstants.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: FlowlightProviderXPC.self)
        connection.exportedInterface = NSXPCInterface(with: FlowlightAppXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.scheduleReconnect("Extension connection invalidated") }
        connection.interruptionHandler = { [weak self] in self?.scheduleReconnect("Extension connection interrupted") }
        connection.resume()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.scheduleReconnect("Extension unreachable: \(error.localizedDescription)")
        } as? FlowlightProviderXPC
        proxy?.register { [weak self] ok, version in
            guard let self else { return }
            self.status?(ok ? "Connected to filter extension \(version)" : "Extension refused registration")
            if ok { self.startHeartbeat() }
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

    private func scheduleReconnect(_ message: String) {
        status?(message)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
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
