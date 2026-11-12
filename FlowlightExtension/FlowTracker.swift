import Foundation
import Network
import NetworkExtension

/// Per-flow state kept while a flow is alive.
final class FlowState: @unchecked Sendable {
    let id: UUID
    let process: ProcessInfoRecord
    #if APP_STORE
    let localIP: String
    let localPort: UInt16
    let filterGeneration: UInt64
    #endif
    let remoteIP: String
    let remotePort: UInt16
    let transport: TransportProtocol
    let systemHostname: String?
    let started = Date()

    private let lock = NSLock()
    private var firstOutbound: Data?
    private var firstInbound: Data?
    private var sniOrHost: String?
    private var inboundCallbacks = 0
    private var outboundCallbacks = 0
    private(set) var inspectionDone = false

    var lastBytesIn: Int64 = 0
    var lastBytesOut: Int64 = 0
    var counted = false
    var lastActivity = Date()
    /// Set once the block rules have ruled on this flow. Touched only from the data path, which macOS serializes
    /// per flow, so it needs no more protection than `counted` does.
    var judged = false

    let outboundPeek: Int
    let inboundPeek: Int

    #if APP_STORE
    init(id: UUID, process: ProcessInfoRecord, localIP: String, localPort: UInt16, remoteIP: String, remotePort: UInt16,
         transport: TransportProtocol, systemHostname: String?, filterGeneration: UInt64) {
        self.id = id
        self.process = process
        self.localIP = localIP
        self.localPort = localPort
        self.filterGeneration = filterGeneration
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.transport = transport
        self.systemHostname = systemHostname
        self.outboundPeek = 8192
        self.inboundPeek = remotePort == 53 ? 4096 : 512
    }
    #else
    init(id: UUID, process: ProcessInfoRecord, remoteIP: String, remotePort: UInt16,
         transport: TransportProtocol, systemHostname: String?) {
        self.id = id
        self.process = process
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.transport = transport
        self.systemHostname = systemHostname
        self.outboundPeek = 8192          // large enough for post-quantum ClientHellos
        self.inboundPeek = remotePort == 53 ? 4096 : 512
    }
    #endif

    private var isDNS: Bool { remotePort == 53 }
    private var isFTPControl: Bool { remotePort == 21 }

    /// The largest stitched-together opening the tracker will hold. A ClientHello beyond this is pathological,
    /// and the buffer is per open flow.
    private static let maxOpeningBytes = 8192

    func observeOutbound(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        outboundCallbacks += 1
        if firstOutbound == nil {
            firstOutbound = data
            readName()
        } else if isFTPControl, let current = firstOutbound, current.count < 4096 {
            firstOutbound = current + data // keep looking for AUTH TLS
        } else if sniOrHost == nil, let current = firstOutbound,
                  current.count < Self.maxOpeningBytes, nameMayStillArrive {
            // A ClientHello larger than one segment carries its server_name in the second. Without this the
            // later segments were dropped on the floor and the connection was decided as if it had no name —
            // which is how a rule naming a host let that host through.
            firstOutbound = current + data
            readName()
        }
        updateDone()
    }

    /// The destination as the connection's own opening bytes give it: TLS SNI, or an HTTP Host header. Only ever
    /// fills a name in, never clears one, so a re-read of a longer opening can't undo what a shorter one found.
    private func readName() {
        guard sniOrHost == nil, let data = firstOutbound else { return }
        if remotePort == 443 || data.first == 0x16 {
            sniOrHost = TLSSNIParser.serverName(in: data)
        } else {
            sniOrHost = HTTPHostParser.host(in: data)
        }
    }

    func observeInbound(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        inboundCallbacks += 1
        if firstInbound == nil { firstInbound = data }
        if isDNS, let answer = DNSParser.parseResponse(data, tcpFraming: transport == .tcp) {
            DNSCache.shared.record(answer)
        }
        updateDone()
    }

    /// Stop inspecting as soon as we have what classification needs.
    private func updateDone() {
        if isDNS {
            inspectionDone = inboundCallbacks >= 16
        } else if isFTPControl {
            inspectionDone = outboundCallbacks >= 8
        } else {
            // Client-first protocols need outbound bytes; server-first protocols (FTP/SSH/SMTP banners) inbound.
            inspectionDone = (firstOutbound != nil || inboundCallbacks >= 1) && !nameMayStillArrive
        }
        if outboundCallbacks + inboundCallbacks >= 32 { inspectionDone = true }
    }

    /// Whether the destination could still be named. Asked with the lock already held, which is the same order
    /// `domain` takes it in, so the DNS cache is always reached second.
    private var nameMayStillArrive: Bool {
        let named = !(sniOrHost ?? "").isEmpty
            || !(systemHostname ?? "").isEmpty
            || DNSCache.shared.name(for: remoteIP) != nil
        return BlockRules.nameMayStillArrive(port: remotePort, looksLikeTLS: firstOutbound?.first == 0x16,
                                             named: named, outboundCallbacks: outboundCallbacks,
                                             inboundCallbacks: inboundCallbacks)
    }

    /// Domain priority: SNI / Host header, system-provided hostname, passive DNS cache.
    var domain: String {
        lock.lock(); defer { lock.unlock() }
        if let sniOrHost, !sniOrHost.isEmpty { return sniOrHost }
        if let systemHostname, !systemHostname.isEmpty, systemHostname != remoteIP { return systemHostname.lowercased() }
        return DNSCache.shared.name(for: remoteIP) ?? ""
    }

    var appProtocol: String {
        lock.lock(); defer { lock.unlock() }
        return ProtocolClassifier.default.classify(ClassificationInput(
            remotePort: remotePort, transport: transport, firstOutbound: firstOutbound, firstInbound: firstInbound))
    }

    func key() -> FlowKey {
        // A content filter is handed sockets, not interfaces, so the channel has to be read off the address. That
        // is the coarser of the two answers Flowlight can give — see `NetworkChannel.of(address:)` — and where it
        // says peer-to-peer, the sampler would have said which radio.
        let channel = NetworkChannel.of(address: remoteIP)
        let host = channel == .peerToPeer && domain.isEmpty
            ? PeerToPeerService.destination(forProcess: process.name) : domain
        return FlowKey(pid: process.pid, bundleID: process.bundleID, appName: process.name, appPath: process.path,
                       remoteIP: remoteIP, domain: host, port: remotePort, transport: transport,
                       appProtocol: ProtocolCatalog.refine(appProtocol, domain: channel == .peerToPeer ? "" : host),
                       channel: channel)
    }
}

final class FlowTracker: @unchecked Sendable {
    let aggregator = SecondAggregator()
    private let resolver = ProcessResolver()
    private var flows: [UUID: FlowState] = [:]
    private let lock = NSLock()
    #if APP_STORE
    private var activeFilterGeneration: UInt64?

    func filterStarted(generation: UInt64) {
        lock.lock()
        flows.removeAll()
        activeFilterGeneration = generation
        lock.unlock()
    }

    func filterStopped() {
        lock.lock()
        activeFilterGeneration = nil
        flows.removeAll()
        lock.unlock()
    }
    #endif

    /// Counters for the once-a-minute log line. Diagnostics only.
    private(set) var flowsSeen = 0
    private(set) var reportsSeen = 0

    func resetCounters() {
        lock.lock(); flowsSeen = 0; reportsSeen = 0; lock.unlock()
    }

    func begin(_ flow: NEFilterSocketFlow) -> FlowState? {
        lock.lock()
        flowsSeen += 1
        #if APP_STORE
        guard let filterGeneration = activeFilterGeneration else {
            lock.unlock()
            return nil
        }
        #endif
        lock.unlock()
        let transport: TransportProtocol
        switch flow.socketProtocol {
        case IPPROTO_TCP: transport = .tcp
        case IPPROTO_UDP: transport = .udp
        default: return nil
        }
        guard let endpoint = Self.remote(of: flow) else { return nil }
        let process = resolver.resolve(auditToken: flow.sourceAppAuditToken, signingIdentifier: nil)
        #if APP_STORE
        let state = FlowState(
            id: flow.identifier,
            process: process,
            localIP: Self.ip(of: flow.localFlowEndpoint),
            localPort: Self.port(of: flow.localFlowEndpoint),
            remoteIP: endpoint.ip,
            remotePort: endpoint.port,
            transport: transport,
            systemHostname: flow.remoteHostname,
            filterGeneration: filterGeneration
        )
        #else
        let state = FlowState(id: flow.identifier, process: process, remoteIP: endpoint.ip, remotePort: endpoint.port,
                              transport: transport, systemHostname: flow.remoteHostname)
        #endif
        lock.lock()
        #if APP_STORE
        guard activeFilterGeneration == filterGeneration else {
            lock.unlock()
            return nil
        }
        #endif
        flows[flow.identifier] = state
        lock.unlock()
        return state
    }

    func state(for flow: NEFilterFlow) -> FlowState? {
        lock.lock(); defer { lock.unlock() }
        return flows[flow.identifier]
    }

    /// Statistics reports carry cumulative byte counts; convert to deltas and aggregate.
    func account(flow: NEFilterFlow, bytesIn: Int64, bytesOut: Int64, closed: Bool) {
        lock.lock()
        reportsSeen += 1
        guard let state = flows[flow.identifier] else { lock.unlock(); return }
        let deltaIn = max(0, bytesIn - state.lastBytesIn)
        let deltaOut = max(0, bytesOut - state.lastBytesOut)
        state.lastBytesIn = max(state.lastBytesIn, bytesIn)
        state.lastBytesOut = max(state.lastBytesOut, bytesOut)
        state.lastActivity = Date()
        let newFlow = !state.counted
        state.counted = true
        if closed { flows.removeValue(forKey: flow.identifier) }
        lock.unlock()

        aggregator.add(state.key(), FlowCounters(bytesIn: deltaIn, bytesOut: deltaOut, flows: newFlow ? 1 : 0))
    }

    /// Drops state for flows that never reported closing (e.g. UDP sockets that went idle).
    func sweepStale() {
        let cutoff = Date().addingTimeInterval(-15 * 60)
        lock.lock(); defer { lock.unlock() }
        flows = flows.filter { $0.value.lastActivity > cutoff }
    }

    #if APP_STORE
    /// Identity for one live explicit-proxy leg, derived from the audit token macOS attached to that exact flow.
    /// Both ports and loopback destination must match; a stale source-port reuse must never inherit another app.
    func inspectionProxyClient(clientIP: String, clientPort: UInt16, proxyPort: UInt16,
                               filterGeneration: UInt64) -> ProxyClientIdentity? {
        guard let normalizedClientIP = HostCanonicalizer.address(clientIP) else { return nil }
        lock.lock()
        guard activeFilterGeneration == filterGeneration else { lock.unlock(); return nil }
        // Snapshot only exact tuple candidates under the tracker lock. Process ancestry can touch the kernel process
        // table, so doing it for every live flow here can exceed the Store host's 250 ms fail-open timeout.
        let exact = flows.values.filter { state in
            state.filterGeneration == filterGeneration
                && state.transport == .tcp
                && HostCanonicalizer.address(state.localIP) == normalizedClientIP
                && state.localPort == clientPort
                && state.remotePort == proxyPort
                && (state.remoteIP == "127.0.0.1" || state.remoteIP == "::1")
        }
        lock.unlock()
        let candidates = exact.map { state in
            let context = BlockEnforcer.shared.inspectionAgentContext(for: state.process)
            return ProxyClientFlowCandidate(
                localIP: state.localIP,
                localPort: state.localPort,
                remoteIP: state.remoteIP,
                remotePort: state.remotePort,
                isTCP: true,
                identity: ProxyClientIdentity(
                    pid: state.process.pid,
                    bundleID: state.process.bundleID,
                    name: state.process.name,
                    path: state.process.path,
                    agentBundleID: context?.bundleID,
                    agentName: context?.name,
                    // The extension is not given user MCP configuration. Guessing from an executable name would make
                    // server-scoped guardrails apply to ordinary tools, so unknown lineage remains explicitly nil.
                    mcpServer: nil
                ),
                filterGeneration: state.filterGeneration
            )
        }
        // The ancestry walk above deliberately runs unlocked. Revalidate after it: start/stop clears the flow table,
        // but the snapshot retains its old objects and would otherwise still resolve an obsolete identity.
        lock.lock()
        guard activeFilterGeneration == filterGeneration else {
            lock.unlock()
            return nil
        }
        let identity = ProxyClientIdentityResolver.resolve(
            candidates: candidates,
            clientIP: clientIP,
            clientPort: clientPort,
            proxyPort: proxyPort,
            filterGeneration: filterGeneration
        )
        lock.unlock()
        return identity
    }

    private static func ip(of endpoint: Network.NWEndpoint?) -> String {
        guard case .hostPort(let host, _)? = endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _): return HostCanonicalizer.address(name) ?? ""
        @unknown default: return ""
        }
    }

    private static func port(of endpoint: Network.NWEndpoint?) -> UInt16 {
        guard case .hostPort(_, let port)? = endpoint else { return 0 }
        return port.rawValue
    }

    #endif

    private static func remote(of flow: NEFilterSocketFlow) -> (ip: String, port: UInt16)? {
        guard let endpoint = flow.remoteFlowEndpoint, case let .hostPort(host, port) = endpoint else { return nil }
        let ip: String
        switch host {
        case .ipv4(let addr): ip = "\(addr)"
        case .ipv6(let addr): ip = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case .name(let name, _): ip = name
        @unknown default: return nil
        }
        return (ip, port.rawValue)
    }
}
