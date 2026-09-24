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
    /// Tool results first seen in this exchange: sent back to the model, or returned by an MCP server.
    var toolResults: [ToolResult] = []
    /// JSON-RPC calls to an MCP server over HTTP.
    var mcp: [MCPActivity] = []
    /// What an LLM API call declared: tools, provider-side MCP servers, model, tokens.
    var llm: LLMFacts?
    /// Set when there's no exchange to show, e.g. the app rejected Flowlight's certificate.
    var note: String?
    /// The mock rule that answered this request, when Flowlight replied instead of the server. Its own field
    /// rather than a `note`: a note means "nothing was inspected", and a mocked exchange is fully inspected — it
    /// just didn't come from the host it names, which anyone reading a recorded session has to be able to tell.
    var mockRule: String?
    /// What a guardrail took out of this request before it left. Its own field for the same reason: the exchange
    /// is real and was really sent, but it is not quite what the agent wrote, and that has to be readable.
    var guardrail: String?

    var url: String {
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)\(defaultPort ? "" : ":\(port)")\(path)"
    }
}

extension HTTPExchange {
    /// The tool or MCP server that made the request for an agent ("curl", "github MCP"), or nil when the agent itself did.
    var via: String? {
        guard let agent, agent != bundleID, !appName.isEmpty else { return nil }
        return mcpServer.map { "\($0) MCP" } ?? appName
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Which process owns a TCP connection to the proxy, found from the client's source port.
enum SocketOwner {
    /// The pid with a TCP socket whose local port is `clientPort` and remote port is `proxyPort`. Scans the current
    /// user's processes with libproc; typically a few milliseconds.
    /// True when the connection comes from this process, i.e. the proxy is being asked to proxy itself.
    static func isOwnConnection(clientPort: UInt16, proxyPort: UInt16) -> Bool {
        owns(pid: getpid(), clientPort: clientPort, proxyPort: proxyPort)
    }

    static func pid(clientPort: UInt16, proxyPort: UInt16) -> Int32? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        return pids.prefix(Int(max(0, filled))).first { pid in
            pid > 0 && pid != me && owns(pid: pid, clientPort: clientPort, proxyPort: proxyPort)
        }
    }

    private static func owns(pid: Int32, clientPort: UInt16, proxyPort: UInt16) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let n = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: n)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            if local == clientPort && remote == proxyPort { return true }
        }
        return false
    }
}

/// Turns proxied byte streams into `HTTPExchange`s: parses both directions, pairs requests with responses, attributes
/// them to the process (and agent) behind the connection, reads tool calls, redacts credentials, and hands each
/// finished exchange to `onExchange`.
final class InspectionRecorder: ProxyObserver, @unchecked Sendable {
    private struct Pending { var head: HTTPHead; var body: HTTPBody; var started: Date; var mock: String?; var guardrail: String? }

    private final class FlowState {
        let request: HTTPStreamParser
        let response: HTTPStreamParser
        var queue: [Pending] = []
        /// Set by the proxy just before the bytes that complete a request it answers itself.
        var nextMock: String?
        var nextGuardrail: String?
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
        var appPath = ""
        var agent: String?
        var agentName: String?
        var mcpServer: String?
    }

    /// Bodies are parsed up to this size (agents resend whole conversations, so LLM requests get large)…
    var parseLimit = 16 << 20
    /// …and stored up to this size.
    var storeLimit = 2 << 20
    var proxyPort: () -> UInt16? = { nil }
    var onExchange: (HTTPExchange) -> Void = { _ in }

    private var flows: [UUID: FlowState] = [:]
    private let lookupQueue = DispatchQueue(label: "flowlight.inspect.owner", qos: .utility)
    private let emitQueue = DispatchQueue(label: "flowlight.inspect.emit", qos: .utility)
    private let processes = ProcessLookup()

    func flowStarted(_ flow: ProxyFlow) {
        let state = FlowState(limit: parseLimit)
        let response = state.response
        state.request.onHead = { response.requestMethods.append($0.method) }
        state.request.onMessage = { [weak state] head, body in
            state?.queue.append(Pending(head: head, body: body, started: Date(), mock: state?.nextMock,
                                        guardrail: state?.nextGuardrail))
            state?.nextMock = nil
            state?.nextGuardrail = nil
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

    func flow(_ flow: ProxyFlow, connectedTo remoteIP: String) {
        guard let state = flows[flow.id] else { return }
        lookupQueue.async {
            // The lookup queue is serial, so the owner for this flow is already known.
            if let owner = state.owner, owner.pid > 0 {
                ProxyAttribution.shared.record(host: flow.host, ip: remoteIP, owner: owner)
            }
        }
    }

    func flow(_ flow: ProxyFlow, clientSent data: Data) { flows[flow.id]?.request.feed(data) }
    func flow(_ flow: ProxyFlow, serverSent data: Data) { flows[flow.id]?.response.feed(data) }
    func flow(_ flow: ProxyFlow, mockedBy rule: String) { flows[flow.id]?.nextMock = rule }
    func flow(_ flow: ProxyFlow, guardedBy note: String) { flows[flow.id]?.nextGuardrail = note }

    func flowEnded(_ flow: ProxyFlow, note: String?) {
        guard let state = flows.removeValue(forKey: flow.id) else { return }
        state.response.finish()
        if let note {
            // Nothing was decrypted; record why, so the user sees which app and host were passed through.
            let head = HTTPHead(startLine: "CONNECT \(flow.host):\(flow.port) HTTP/1.1", headers: [])
            emit(flow: flow, state: state,
                 request: Pending(head: head, body: HTTPBody(), started: flow.started, mock: nil, guardrail: nil),
                 responseHead: nil, responseBody: HTTPBody(), note: note)
        }
    }

    private func emit(flow: ProxyFlow, state: FlowState, request: Pending, responseHead: HTTPHead?, responseBody: HTTPBody, note: String?) {
        let finished = Date()
        emitQueue.async { [self] in
            if state.owner == nil { _ = state.ownerReady.wait(timeout: .now() + 2); state.ownerReady.signal() }
            let owner = state.owner ?? Owner()
            var calls = LLMToolCallReader.responseCalls(responseBody.data)
            var results = newResults(ToolResultReader.results(inRequest: request.body.data) + ToolResultReader.results(inResponse: responseBody.data))
            let endpoint = flow.host + (request.head.target.split(separator: "?").first.map(String.init) ?? "")
            let mcp = ToolResultReader.mcpActivity(request: request.body.data, response: responseBody.data, host: flow.host,
                                                   path: request.head.target, knownName: mcpNames[endpoint])
            for activity in mcp {
                if activity.method == "initialize", activity.server != flow.host { mcpNames[endpoint] = activity.server }
                guard activity.method == "tools/call", let tool = activity.tool else { continue }
                // A direct MCP tool call carries its own result; pair them with a shared id.
                let id = "mcp-\(UUID().uuidString)"
                calls.append(ToolCall(source: .mcp, callID: id, name: tool, mcpServer: activity.server, input: activity.summary ?? "",
                                      summary: activity.summary))
                results.append(ToolResult(callID: id, isError: activity.isError, output: activity.output ?? "",
                                          outputSize: activity.output?.count ?? 0))
            }
            let llm = LLMFactsReader.facts(request: request.body.data, response: responseBody.data, host: flow.host)
            let (requestBody, requestCut) = clip(request.body)
            let (responseData, responseCut) = clip(responseBody)
            let exchange = HTTPExchange(
                id: nil, started: request.started, duration: finished.timeIntervalSince(request.started), scheme: flow.scheme,
                host: flow.host, port: flow.port, method: request.head.method, path: request.head.target, status: responseHead?.status,
                requestHeaders: HeaderRedaction.redact(request.head.headers), requestBody: requestBody,
                requestSize: request.body.wireSize, requestTruncated: requestCut,
                responseHeaders: HeaderRedaction.redact(responseHead?.headers ?? []), responseBody: responseData,
                responseSize: responseBody.wireSize, responseTruncated: responseCut,
                contentType: responseHead?.value("Content-Type") ?? "", pid: owner.pid, bundleID: owner.bundleID, appName: owner.appName,
                agent: owner.agent, agentName: owner.agentName, mcpServer: owner.mcpServer, toolCalls: calls,
                toolResults: results, mcp: mcp, llm: llm, note: note, mockRule: request.mock, guardrail: request.guardrail)
            onExchange(exchange)
        }
    }

    /// MCP endpoint (host + path) → the server's name from its `initialize` response. Used on the emit queue only.
    private var mcpNames: [String: String] = [:]
    /// Tool result ids already recorded. Agents resend the whole conversation each turn; keep each result once.
    private var seenResults: Set<String> = []

    private func newResults(_ results: [ToolResult]) -> [ToolResult] {
        if seenResults.count > 100_000 { seenResults.removeAll() }
        return results.filter { seenResults.insert($0.callID).inserted }
    }

    private func clip(_ body: HTTPBody) -> (Data, Bool) {
        body.data.count > storeLimit ? (body.data.prefix(storeLimit), true) : (body.data, body.truncated)
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
        var owner = Owner(pid: pid, bundleID: info.bundleID, appName: info.name, appPath: info.path)
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

/// Gives traffic that went through the inspection proxy back to the app that made it.
///
/// The capture engine sees the proxy's upstream connections as Flowlight's own, and the hop from the app to the proxy
/// as loopback traffic. `rewrite` relabels the first with the app (and agent) behind each proxied host, and drops the
/// second so nothing is counted twice.
final class ProxyAttribution: @unchecked Sendable {
    static let shared = ProxyAttribution()
    private let lock = NSLock()
    private var byHost: [String: (owner: InspectionRecorder.Owner, at: Date)] = [:]
    private var byIP: [String: (owner: InspectionRecorder.Owner, at: Date)] = [:]
    private let selfPID = getpid()
    var proxyPort: UInt16?
    /// A local collector Flowlight exports to, if one is configured. Its traffic is Flowlight's own and on
    /// loopback, so the rule below would drop it — and then the app would be sending data off to a collector
    /// while showing nothing, which is exactly the behaviour it exists to catch someone else doing.
    var exportPort: UInt16?

    func record(host: String, ip: String, owner: InspectionRecorder.Owner) {
        lock.lock(); defer { lock.unlock() }
        if byHost.count > 5000 { byHost.removeAll(); byIP.removeAll() }
        byHost[host.lowercased()] = (owner, Date())
        byIP[ip] = (owner, Date())
    }

    func rewrite(_ batches: [TrafficBatch]) -> [TrafficBatch] {
        guard let proxyPort else { return batches }
        return batches.map { batch in
            var batch = batch
            batch.records = batch.records.compactMap { record in
                var record = record
                let k = record.key
                let loopback = k.remoteIP.hasPrefix("127.") || k.remoteIP == "::1"
                // Flowlight talking to a local collector is real traffic worth showing, not a proxy leg.
                if loopback, k.pid == selfPID, let exportPort, k.port == exportPort { return record }
                // App → proxy, and the proxy's internal loopback legs: already counted on the upstream side.
                if loopback && (k.port == proxyPort || k.pid == selfPID) { return nil }
                guard k.pid == selfPID, let owner = owner(domain: k.domain, ip: k.remoteIP) else { return record }
                record.key.pid = owner.pid
                record.key.bundleID = owner.bundleID
                record.key.appName = owner.appName
                record.key.appPath = owner.appPath
                if let agent = owner.agent, agent != owner.bundleID {
                    record.key.parentAgent = agent
                    record.key.parentAgentName = owner.agentName
                    record.key.mcpServer = owner.mcpServer
                }
                return record
            }
            return batch
        }
    }

    private func owner(domain: String, ip: String) -> InspectionRecorder.Owner? {
        lock.lock(); defer { lock.unlock() }
        let fresh = { (entry: (owner: InspectionRecorder.Owner, at: Date)?) in
            entry.flatMap { Date().timeIntervalSince($0.at) < 3600 ? $0.owner : nil }
        }
        return fresh(byIP[ip]) ?? (domain.isEmpty ? nil : fresh(byHost[domain.lowercased()]))
    }
}
