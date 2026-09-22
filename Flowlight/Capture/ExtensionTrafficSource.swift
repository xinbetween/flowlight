import Foundation

/// Receives per-second batches from the system extension over XPC.
final class ExtensionTrafficSource: NSObject, TrafficSource, FlowlightAppXPC, @unchecked Sendable {
    let displayName = "Network Extension"
    private var connection: NSXPCConnection?
    private var sink: (([TrafficBatch]) -> Void)?
    private var status: ((String) -> Void)?
    private var retryTimer: Timer?
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
            self?.status?(ok ? "Connected to filter extension \(version)" : "Extension refused registration")
        }
    }

    private func scheduleReconnect(_ message: String) {
        status?(message)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.connection = nil
            self.retryTimer?.invalidate()
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.connect() }
        }
    }

    func deliver(payload: Data, reply: @escaping () -> Void) {
        let batches = TrafficCoding.decode(payload)
        if !batches.isEmpty { sink?(batches) }
        reply()
    }
}
