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
    private let queue = DispatchQueue(label: "flowlight.ipc")
    /// Seconds of traffic held while no app is connected — which is the whole time the app is using the nettop
    /// sampler instead. It used to be an hour, and switching back to the extension replayed every second of it
    /// oldest-first, ahead of anything current: the live view stayed empty for as long as the backlog took to
    /// drain, and looked broken. Five minutes covers a restart or an extension upgrade and drains at once.
    private let maxPendingBatches = 300
    private let chunkSize = 300

    private var machServiceName: String {
        let ne = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        return (ne?["NEMachServiceName"] as? String) ?? FlowlightConstants.machServiceName
    }

    func startListener() {
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
            self.flushLocked()
        }
        reply(true, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
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

    /// Sends one chunk at a time; batches leave the queue only after the app acknowledges them.
    private func flushLocked() {
        guard !inFlight, let client, !pending.isEmpty else { return }
        let chunk = pending.prefix(chunkSize)
        let lastSeq = chunk.last!.seq
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
                self.pending.removeAll { $0.seq <= lastSeq }
                self.flushLocked()
            }
        }
    }
}
