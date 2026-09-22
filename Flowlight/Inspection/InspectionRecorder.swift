import Darwin
import Foundation

/// One request and its response, decrypted by the inspection proxy.
struct HTTPExchange: Identifiable, Equatable, Sendable {
    var id: Int64?
    var started: Date
    var duration: Double
    var scheme: String
    var host: String
    var port: Int
    var method: String
    var path: String
    var status: Int?
    var requestHeaders: [HTTPHeader]
    var requestBody: Data
    var requestSize: Int
    var requestTruncated: Bool
    var responseHeaders: [HTTPHeader]
    var responseBody: Data
    var responseSize: Int
    var responseTruncated: Bool
    var contentType: String
    var pid: Int32
    var bundleID: String
    var appName: String
    /// The agent this process works for (itself, or the agent that started it).
    var agent: String?
    var agentName: String?
    var mcpServer: String?
    var toolCalls: [ToolCall]
    /// Set when there's no exchange to show, e.g. the app rejected Flowlight's certificate.
    var note: String?

    var url: String {
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)\(defaultPort ? "" : ":\(port)")\(path)"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Which process owns a TCP connection to the proxy, found from the client's source port.
enum SocketOwner {
    /// The pid with a TCP socket whose local port is `clientPort` and remote port is `proxyPort`. Scans the current
    /// user's processes with libproc; typically a few milliseconds.
    static func pid(clientPort: UInt16, proxyPort: UInt16) -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 && pid != me {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: n)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == SOCKINFO_TCP else { continue }
                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if local == clientPort && remote == proxyPort { return pid }
            }
        }
        return nil
    }
}

/// Turns proxied byte streams into `HTTPExchange`s: parses both directions, pairs requests with responses, attributes
/// them to the process (and agent) behind the connection, reads tool calls, redacts credentials, and hands each
/// finished exchange to `onExchange`.
final class InspectionRecorder: ProxyObserver, @unchecked Sendable {
    private struct Pending { var head: HTTPHead; var body: HTTPBody; var started: Date }

    private final class FlowState {
        let request: HTTPStreamParser
        let response: HTTPStreamParser
        var queue: [Pending] = []
        var owner: Owner?
        let ownerReady = DispatchSemaphore(value: 0)
        init(limit: Int) {
            request = HTTPStreamParser(direction: .request, limit: limit)
            response = HTTPStreamParser(direction: .response, limit: limit)
        }
    }

    struct Owner: Sendable {
        var pid: Int32 = 0
        var bundleID = ""
        var appName = "Unknown app"
        var agent: String?
        var agentName: String?
        var mcpServer: String?
    }

    var bodyLimit = 2 << 20
    var proxyPort: () -> UInt16? = { nil }
    var onExchange: (HTTPExchange) -> Void = { _ in }

    private var flows: [UUID: FlowState] = [:]
    private let lookupQueue = DispatchQueue(label: "flowlight.inspect.owner", qos: .utility)
    private let emitQueue = DispatchQueue(label: "flowlight.inspect.emit", qos: .utility)
    private let processes = ProcessLookup()

    func flowStarted(_ flow: ProxyFlow) {
        let state = FlowState(limit: bodyLimit)
        let response = state.response
        state.request.onHead = { response.requestMethods.append($0.method) }
        state.request.onMessage = { [weak state] head, body in
            state?.queue.append(Pending(head: head, body: body, started: Date()))
        }
        state.response.onMessage = { [weak self, weak state] head, body in
            guard let self, let state, !state.queue.isEmpty else { return }
            let request = state.queue.removeFirst()
            self.emit(flow: flow, state: state, request: request, responseHead: head, responseBody: body, note: nil)
        }
        flows[flow.id] = state
        let port = proxyPort()
        lookupQueue.async { [weak self] in
            state.owner = self?.owner(clientPort: flow.clientPort, proxyPort: port)
            state.ownerReady.signal()
        }
    }

    func flow(_ flow: ProxyFlow, clientSent data: Data) { flows[flow.id]?.request.feed(data) }
    func flow(_ flow: ProxyFlow, serverSent data: Data) { flows[flow.id]?.response.feed(data) }

    func flowEnded(_ flow: ProxyFlow, note: String?) {
        guard let state = flows.removeValue(forKey: flow.id) else { return }
        state.response.finish()
        if let note {
            // Nothing was decrypted; record why, so the user sees which app and host were passed through.
            let head = HTTPHead(startLine: "CONNECT \(flow.host):\(flow.port) HTTP/1.1", headers: [])
            emit(flow: flow, state: state, request: Pending(head: head, body: HTTPBody(), started: flow.started),
                 responseHead: nil, responseBody: HTTPBody(), note: note)
        }
    }

    private func emit(flow: ProxyFlow, state: FlowState, request: Pending, responseHead: HTTPHead?, responseBody: HTTPBody, note: String?) {
        let finished = Date()
        emitQueue.async { [self] in
            if state.owner == nil { _ = state.ownerReady.wait(timeout: .now() + 2); state.ownerReady.signal() }
            let owner = state.owner ?? Owner()
            let calls = LLMToolCallReader.toolCalls(requestBody: request.body.data, responseBody: responseBody.data, host: flow.host)
            let exchange = HTTPExchange(
                id: nil, started: request.started, duration: finished.timeIntervalSince(request.started), scheme: flow.scheme,
                host: flow.host, port: flow.port, method: request.head.method, path: request.head.target, status: responseHead?.status,
                requestHeaders: HeaderRedaction.redact(request.head.headers), requestBody: request.body.data,
                requestSize: request.body.wireSize, requestTruncated: request.body.truncated,
                responseHeaders: HeaderRedaction.redact(responseHead?.headers ?? []), responseBody: responseBody.data,
                responseSize: responseBody.wireSize, responseTruncated: responseBody.truncated,
                contentType: responseHead?.value("Content-Type") ?? "", pid: owner.pid, bundleID: owner.bundleID, appName: owner.appName,
                agent: owner.agent, agentName: owner.agentName, mcpServer: owner.mcpServer, toolCalls: calls, note: note)
            onExchange(exchange)
        }
    }

    private var owners: [UInt16: (owner: Owner, at: Date)] = [:]
    private let ownersLock = NSLock()

    /// The process (and agent) behind a client connection. Cached briefly per source port, because the proxy asks
    /// once to decide whether to decrypt and the recorder asks again to label the exchange.
    func owner(clientPort: UInt16, proxyPort: UInt16?) -> Owner {
        ownersLock.lock()
        if let hit = owners[clientPort], Date().timeIntervalSince(hit.at) < 30 { ownersLock.unlock(); return hit.owner }
        ownersLock.unlock()
        let owner = lookupOwner(clientPort: clientPort, proxyPort: proxyPort)
        ownersLock.lock()
        if owners.count > 2000 { owners.removeAll() }
        owners[clientPort] = (owner, Date())
        ownersLock.unlock()
        return owner
    }

    private func lookupOwner(clientPort: UInt16, proxyPort: UInt16?) -> Owner {
        guard let proxyPort, let pid = SocketOwner.pid(clientPort: clientPort, proxyPort: proxyPort) else { return Owner() }
        let info = processes.info(pid: pid)
        var owner = Owner(pid: pid, bundleID: info.bundleID, appName: info.name)
        let key = FlowKey(pid: pid, bundleID: info.bundleID, appName: info.name, appPath: info.path, remoteIP: "", domain: "",
                          port: 0, transport: .tcp, appProtocol: "")
        if let context = AgentAttributor.shared.agentContext(for: key) {
            owner.agent = context.agentBundleID
            owner.agentName = context.agentName
            owner.mcpServer = context.mcpServer
        } else if let known = AgentCatalog.knownAgent(bundleID: info.bundleID, appName: info.name) {
            owner.agent = info.bundleID
            owner.agentName = known.name
        } else if AgentRegistry.shared.isDiscovered(info.bundleID) {
            owner.agent = info.bundleID
            owner.agentName = AgentRegistry.shared.name(bundleID: info.bundleID, appName: info.name) ?? info.name
        }
        return owner
    }
}
