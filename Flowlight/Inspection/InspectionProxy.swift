import Foundation
import Network
import Security

/// One proxied connection, as seen by observers.
final class ProxyFlow: @unchecked Sendable {
    let id = UUID()
    let host: String
    let port: Int
    /// Source port of the client's connection to the proxy, used to find the process that opened it.
    let clientPort: UInt16
    let started = Date()
    /// True when TLS was terminated and the plaintext is visible; false for tunnels passed through untouched.
    let inspected: Bool
    let scheme: String

    init(host: String, port: Int, clientPort: UInt16, inspected: Bool, scheme: String) {
        self.host = host; self.port = port; self.clientPort = clientPort; self.inspected = inspected; self.scheme = scheme
    }
}

/// Receives plaintext from inspected flows. Calls arrive on the proxy's queue, in order per flow.
protocol ProxyObserver: AnyObject {
    func flowStarted(_ flow: ProxyFlow)
    func flow(_ flow: ProxyFlow, clientSent data: Data)
    func flow(_ flow: ProxyFlow, serverSent data: Data)
    func flowEnded(_ flow: ProxyFlow, note: String?)
    /// The proxy's own connection to the destination is up, to this address.
    func flow(_ flow: ProxyFlow, connectedTo remoteIP: String)
    /// The request whose bytes come next was answered by Flowlight itself, not by the server.
    func flow(_ flow: ProxyFlow, mockedBy rule: String)
}

/// A local HTTP proxy on 127.0.0.1 that can decrypt HTTPS for inspection.
///
/// Clients send `CONNECT host:443`. For hosts Flowlight may inspect, the proxy answers the TLS handshake itself with a
/// certificate from the local CA (see `CertificateAuthority`), opens its own verified TLS connection to the real server,
/// and relays the plaintext between them while observers watch it. Anything else, including hosts on the never-inspect
/// list and apps that reject the certificate (pinning), is tunnelled byte for byte without decryption.
///
/// Network.framework can't start TLS on a connection that's already open, so after `CONNECT` the client's bytes are
/// piped into a loopback TLS listener that holds the certificate for that host.
final class InspectionProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flowlight.inspect.proxy")
    private let ca: CertificateAuthority
    private var listener: NWListener?
    private var hostListeners: [String: HostListener] = [:]
    /// Bridge source port → the flow it carries, so the TLS listener can match an accepted connection to its target.
    private var pending: [UInt16: ProxyFlow] = [:]
    /// Hosts whose clients rejected our certificate recently; tunnelled without inspection until the date passes.
    private var pinned: [String: Date] = [:]

    weak var observer: ProxyObserver?
    /// Decides whether to decrypt a CONNECT to `host` from the client at `clientPort`. May answer asynchronously
    /// (it can look up the owning process); the proxy continues on its own queue.
    var shouldInspect: (_ host: String, _ clientPort: UInt16, _ answer: @escaping (Bool) -> Void) -> Void = { _, _, answer in answer(true) }
    /// The enabled mock rules that could answer for a host. Asked once per inspected flow, before any framing.
    var mockRules: (_ host: String, _ clientPort: UInt16) -> [MockRule] = { _, _ in [] }
    /// Called with every request Flowlight answered itself, and the flow it arrived on. A rule refusing a request
    /// has to be recordable as a refusal, not only as an exchange with an odd status.
    var onAnswered: (_ rule: MockRule, _ flow: ProxyFlow, _ head: ProxyRequestHead?) -> Void = { _, _, _ in }
    /// Served at http://127.0.0.1:<port>/proxy.pac.
    var pacScript: () -> String = { "function FindProxyForURL(url, host) { return \"DIRECT\"; }" }
    var onStateChange: (String?) -> Void = { _ in }

    private(set) var port: UInt16?

    init(ca: CertificateAuthority = .shared) { self.ca = ca }

    // MARK: Lifecycle

    func start(port requested: UInt16) {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requested) ?? .any)
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = listener.port?.rawValue; self.onStateChange(nil)
                    case .failed(let error): self.onStateChange("The inspection proxy stopped: \(error.localizedDescription)"); self.stop()
                    default: break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                onStateChange("Couldn't start the inspection proxy: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil; port = nil
            hostListeners.values.forEach { $0.listener.cancel() }
            hostListeners.removeAll(); pending.removeAll()
            onStateChange(nil)
        }
    }

    // MARK: Client side

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readHead(client, buffer: Data()) { [weak self] head, rest in
            guard let self, let head else { client.cancel(); return }
            self.route(client, head: head, rest: rest)
        }
    }

    /// Reads until the end of an HTTP request head (at most 64 KB).
    private func readHead(_ conn: NWConnection, buffer: Data, done: @escaping (ProxyRequestHead?, Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = ProxyRequestHead.parse(buffer[..<end.upperBound])
                done(head, Data(buffer[end.upperBound...]))
            } else if complete || error != nil || buffer.count > 65536 {
                done(nil, Data())
            } else {
                self.readHead(conn, buffer: buffer, done: done)
            }
        }
    }

    private func route(_ client: NWConnection, head: ProxyRequestHead, rest: Data) {
        let clientPort = Self.remotePort(client)
        // Never proxy our own connections (a system proxy pointing at Flowlight would otherwise loop).
        if !head.target.hasPrefix("/"), let port, SocketOwner.isOwnConnection(clientPort: clientPort, proxyPort: port) {
            respond(client, status: "508 Loop Detected")
            return
        }
        if head.method == "CONNECT" {
            guard let (host, port) = head.authority else { respond(client, status: "400 Bad Request"); return }
            let notPinned = pinned[host].map { $0 < Date() } ?? true
            let proceed: (Bool) -> Void = { [weak self] inspect in
                self?.queue.async {
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { error in
                        guard let self, error == nil else { client.cancel(); return }
                        if inspect && notPinned {
                            self.bridge(client, host: host, port: port, clientPort: clientPort, early: rest)
                        } else {
                            self.tunnel(client, host: host, port: port, clientPort: clientPort, early: rest)
                        }
                    })
                }
            }
            if notPinned { shouldInspect(host, clientPort, proceed) } else { proceed(false) }
        } else if head.target.hasPrefix("/") {
            if head.target.hasPrefix("/proxy.pac") {
                let body = Data(pacScript().utf8)
                respond(client, status: "200 OK", headers: ["Content-Type": "application/x-ns-proxy-autoconfig"], body: body)
            } else {
                respond(client, status: "404 Not Found")
            }
        } else if let url = URL(string: head.target), url.scheme == "http", let host = url.host {
            // Plain HTTP through the proxy: forward it and watch it like an inspected flow.
            let port = url.port ?? 80
            let flow = ProxyFlow(host: host, port: port, clientPort: clientPort, inspected: true, scheme: "http")
            var request = head.originForm()
            request.append(rest)
            let upstream = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(clamping: port)), using: Self.direct(.tcp))
            relay(client: client, upstream: upstream, flow: flow, firstClientBytes: request)
        } else {
            respond(client, status: "400 Bad Request")
        }
    }

    private func respond(_ client: NWConnection, status: String, headers: [String: String] = [:], body: Data = Data()) {
        var text = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        var data = Data((text + "\r\n").utf8)
        data.append(body)
        client.send(content: data, completion: .contentProcessed { _ in client.cancel() })
    }

    // MARK: Pass-through

    private func tunnel(_ client: NWConnection, host: String, port: Int, clientPort: UInt16, early: Data) {
        let flow = ProxyFlow(host: host, port: port, clientPort: clientPort, inspected: false, scheme: "https")
        let upstream = NWConnection(host: .init(host), port: .init(integerLiteral: UInt16(clamping: port)), using: Self.direct(.tcp))
        observer?.flowStarted(flow)
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let ip = Self.remoteIP(upstream) { self?.observer?.flow(flow, connectedTo: ip) }
                if !early.isEmpty { upstream.send(content: early, completion: .idempotent) }
                var ended = false
                let finish = {
                    guard !ended else { return }
                    ended = true
                    self?.observer?.flowEnded(flow, note: nil)
                    client.cancel(); upstream.cancel()
                }
                self?.pump(client, into: upstream, tap: nil, closed: finish)
                self?.pump(upstream, into: client, tap: nil, closed: finish)
            case .failed, .cancelled:
                client.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    // MARK: Decrypting bridge

    private func bridge(_ client: NWConnection, host: String, port: Int, clientPort: UInt16, early: Data) {
        hostListener(for: host) { [weak self] listenerPort in
            guard let self else { return }
            guard let listenerPort else {
                // No certificate for this host; don't break the app, tunnel instead.
                self.tunnel(client, host: host, port: port, clientPort: clientPort, early: early)
                return
            }
            let bridge = NWConnection(host: "127.0.0.1", port: .init(integerLiteral: listenerPort), using: Self.direct(.tcp))
            let flow = ProxyFlow(host: host, port: port, clientPort: clientPort, inspected: true, scheme: "https")
            bridge.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let local = Self.localPort(bridge) { self.pending[local] = flow }
                    if !early.isEmpty { bridge.send(content: early, completion: .idempotent) }
                    let finish = { client.cancel(); bridge.cancel() }
                    self.pump(client, into: bridge, tap: nil, closed: finish)
                    self.pump(bridge, into: client, tap: nil, closed: finish)
                case .failed, .cancelled:
                    client.cancel()
                default: break
                }
            }
            bridge.start(queue: self.queue)
        }
    }

    private final class HostListener {
        let listener: NWListener
        var port: UInt16?
        var waiting: [(UInt16?) -> Void] = []
        init(_ listener: NWListener) { self.listener = listener }
    }

    /// A loopback TLS listener presenting the certificate for `host`, created on first use.
    private func hostListener(for host: String, ready: @escaping (UInt16?) -> Void) {
        if let existing = hostListeners[host] {
            if let port = existing.port { ready(port) } else { existing.waiting.append(ready) }
            return
        }
        let identity: SecIdentity
        do { identity = try ca.identity(for: host) } catch { ready(nil); return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        // HTTP/1.1 only, so the plaintext can be read as text.
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls, tcp: .init())
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { ready(nil); return }
        let entry = HostListener(listener)
        entry.waiting.append(ready)
        hostListeners[host] = entry
        listener.newConnectionHandler = { [weak self] inner in self?.acceptDecrypted(inner, host: host) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                entry.port = listener.port?.rawValue
                entry.waiting.forEach { $0(entry.port) }; entry.waiting.removeAll()
            case .failed:
                entry.waiting.forEach { $0(nil) }; entry.waiting.removeAll()
                self?.hostListeners[host] = nil
            default: break
            }
        }
        listener.start(queue: queue)
    }

    /// The client finished (or failed) its TLS handshake with our certificate.
    private func acceptDecrypted(_ inner: NWConnection, host: String) {
        let key = Self.remotePort(inner)
        inner.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let flow = self.pending.removeValue(forKey: key) else { inner.cancel(); return }
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, flow.host)
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                let upstream = NWConnection(host: .init(flow.host), port: .init(integerLiteral: UInt16(clamping: flow.port)),
                                            using: Self.direct(NWParameters(tls: tls, tcp: .init())))
                self.relay(client: inner, upstream: upstream, flow: flow, firstClientBytes: nil)
            case .failed(let error):
                // Most often the app pins its certificates or doesn't trust the Flowlight CA. Stop decrypting this
                // host for an hour so the app keeps working.
                if let flow = self.pending.removeValue(forKey: key) {
                    self.pinned[host] = Date().addingTimeInterval(3600)
                    self.observer?.flowStarted(flow)
                    self.observer?.flowEnded(flow, note: "The app rejected Flowlight's certificate (\(error.localizedDescription)). This host is passed through without inspection for an hour.")
                }
                inner.cancel()
            default: break
            }
        }
        inner.start(queue: queue)
    }

    // MARK: Relay

    private func relay(client: NWConnection, upstream: NWConnection, flow: ProxyFlow, firstClientBytes: Data?) {
        observer?.flowStarted(flow)
        // Read once per flow: a host no enabled rule names gets the plain relay, with its requests never framed.
        let mocks = mockRules(flow.host, flow.clientPort)
        let gate = mocks.isEmpty ? nil : MockGate(host: flow.host, rules: mocks)
        let fromClient: (Data) -> Data = { [weak self] data in
            guard let self else { return data }
            guard let gate else { self.observer?.flow(flow, clientSent: data); return data }
            return self.apply(gate.clientSent(data), flow: flow, client: client)
        }
        var ended = false
        let finish: (String?) -> Void = { [weak self] note in
            guard !ended else { return }
            ended = true
            self?.observer?.flowEnded(flow, note: note)
            client.cancel(); upstream.cancel()
        }
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let ip = Self.remoteIP(upstream) { self.observer?.flow(flow, connectedTo: ip) }
                if let first = firstClientBytes, !first.isEmpty {
                    let onward = fromClient(first)
                    if !onward.isEmpty { upstream.send(content: onward, completion: .idempotent) }
                }
                self.pump(client, into: upstream, tap: fromClient) { finish(nil) }
                self.pump(upstream, into: client, tap: { self.observer?.flow(flow, serverSent: $0); return $0 }) { finish(nil) }
            case .failed(let error):
                finish("Couldn't reach \(flow.host): \(error.localizedDescription)")
            case .waiting(let error):
                finish("Couldn't reach \(flow.host): \(error.localizedDescription)")
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    // MARK: Mock responses

    /// Performs what the gate decided, and returns the bytes that still go upstream.
    private func apply(_ actions: [MockGate.Action], flow: ProxyFlow, client: NWConnection) -> Data {
        var onward = Data()
        for action in actions {
            switch action {
            case .forward(let bytes):
                observer?.flow(flow, clientSent: bytes)
                onward.append(bytes)
            case .hold(let bytes):
                // Recorded like any other request byte: what the agent sent is exactly what it would have sent.
                observer?.flow(flow, clientSent: bytes)
            case .answer(let rule, let bytes, let head):
                // Mark before the bytes that complete the request, so the recorder can label the exchange it is
                // about to parse rather than having to match it up afterwards.
                observer?.flow(flow, mockedBy: rule.title)
                observer?.flow(flow, clientSent: bytes)
                onAnswered(rule, flow, head)
                answer(rule, to: client, flow: flow)
            }
        }
        return onward
    }

    /// Writes a rule's canned response to the client, after its delay. The observer sees it as if the server had
    /// sent it, which is what puts a mocked exchange in Inspect beside the real ones.
    private func answer(_ rule: MockRule, to client: NWConnection, flow: ProxyFlow) {
        let bytes = rule.responseBytes()
        let send = { [weak self] in
            self?.observer?.flow(flow, serverSent: bytes)
            client.send(content: bytes, completion: .idempotent)
        }
        if rule.delay > 0 {
            queue.asyncAfter(deadline: .now() + rule.delay, execute: send)
        } else {
            send()
        }
    }

    // MARK: Copying

    /// Copies bytes from `source` to `destination` until `source` closes, waiting for each write before reading more.
    /// `tap` sees every byte and returns what carries on to `destination` — all of it, except for a request that a
    /// mock rule answered, which is recorded but never relayed.
    private func pump(_ source: NWConnection, into destination: NWConnection, tap: ((Data) -> Data)?, closed: @escaping () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                let onward = tap.map { $0(data) } ?? data
                guard !onward.isEmpty else {
                    // Everything in this read was answered locally; there's nothing to write upstream.
                    if complete || error != nil {
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                        closed()
                    } else {
                        self?.pump(source, into: destination, tap: tap, closed: closed)
                    }
                    return
                }
                destination.send(content: onward, completion: .contentProcessed { sendError in
                    if sendError != nil { closed(); return }
                    if complete || error != nil {
                        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                        closed()
                    } else {
                        self?.pump(source, into: destination, tap: tap, closed: closed)
                    }
                })
            } else if complete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                closed()
            } else {
                self?.pump(source, into: destination, tap: tap, closed: closed)
            }
        }
    }

    // MARK: Endpoints

    static func remotePort(_ conn: NWConnection) -> UInt16 {
        if case .hostPort(_, let port) = conn.endpoint { return port.rawValue }
        return 0
    }

    /// The proxy's own connections must never go through a proxy. With Flowlight set as the system proxy, macOS would
    /// otherwise route them back into Flowlight, looping each request through itself dozens of times.
    static func direct(_ parameters: NWParameters) -> NWParameters {
        let copy = parameters.copy()
        copy.preferNoProxies = true
        return copy
    }

    static func remoteIP(_ conn: NWConnection) -> String? {
        guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first
        default: return nil
        }
    }

    static func localPort(_ conn: NWConnection) -> UInt16? {
        if case .hostPort(_, let port)? = conn.currentPath?.localEndpoint { return port.rawValue }
        return nil
    }
}

/// The request line and headers a client sends to the proxy.
struct ProxyRequestHead: Equatable {
    var method: String
    var target: String
    var version: String
    var headers: [(String, String)]

    static func == (a: Self, b: Self) -> Bool {
        a.method == b.method && a.target == b.target && a.version == b.version
            && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    static func parse<D: DataProtocol>(_ bytes: D) -> ProxyRequestHead? {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return ProxyRequestHead(method: String(parts[0]).uppercased(), target: String(parts[1]), version: String(parts[2]), headers: headers)
    }

    /// `host:port` from a CONNECT target, including bracketed IPv6.
    var authority: (String, Int)? {
        var host = target, port = 443
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            host = String(target[target.index(after: target.startIndex)..<close])
            let after = target[target.index(after: close)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { port = p }
        } else if let colon = target.lastIndex(of: ":"), let p = Int(target[target.index(after: colon)...]) {
            host = String(target[..<colon]); port = p
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return (host.lowercased(), port)
    }

    /// The request rewritten for the origin server: `GET /path` instead of `GET http://host/path`, minus proxy headers.
    func originForm() -> Data {
        var path = target
        if let url = URLComponents(string: target) {
            path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        var text = "\(method) \(path) \(version)\r\n"
        for (name, value) in headers where !name.lowercased().hasPrefix("proxy-") {
            text += "\(name): \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }
}
