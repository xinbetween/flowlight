import Foundation
import Network
import NetworkExtension

/// Per-flow state kept while a flow is alive.
final class FlowState: @unchecked Sendable {
    let id: UUID
    let process: ProcessInfoRecord
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

    let outboundPeek: Int
    let inboundPeek: Int

    init(id: UUID, process: ProcessInfoRecord, remoteIP: String, remotePort: UInt16, transport: TransportProtocol, systemHostname: String?) {
        self.id = id
        self.process = process
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.transport = transport
        self.systemHostname = systemHostname
        self.outboundPeek = 8192          // large enough for post-quantum ClientHellos
        self.inboundPeek = remotePort == 53 ? 4096 : 512
    }

    private var isDNS: Bool { remotePort == 53 }
    private var isFTPControl: Bool { remotePort == 21 }

    func observeOutbound(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        outboundCallbacks += 1
        if firstOutbound == nil {
            firstOutbound = data
            if remotePort == 443 || data.first == 0x16 {
                sniOrHost = TLSSNIParser.serverName(in: data)
            } else if sniOrHost == nil {
                sniOrHost = HTTPHostParser.host(in: data)
            }
        } else if isFTPControl, let current = firstOutbound, current.count < 4096 {
            firstOutbound = current + data // keep looking for AUTH TLS
        }
        updateDone()
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
            inspectionDone = firstOutbound != nil || inboundCallbacks >= 1
        }
        if outboundCallbacks + inboundCallbacks >= 32 { inspectionDone = true }
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
        let host = domain
        return FlowKey(pid: process.pid, bundleID: process.bundleID, appName: process.name, appPath: process.path,
                       remoteIP: remoteIP, domain: host, port: remotePort, transport: transport,
                       appProtocol: ProtocolCatalog.refine(appProtocol, domain: host))
    }
}

final class FlowTracker: @unchecked Sendable {
    let aggregator = SecondAggregator()
    private let resolver = ProcessResolver()
    private var flows: [UUID: FlowState] = [:]
    private let lock = NSLock()

    func begin(_ flow: NEFilterSocketFlow) -> FlowState? {
        let transport: TransportProtocol
        switch flow.socketProtocol {
        case IPPROTO_TCP: transport = .tcp
        case IPPROTO_UDP: transport = .udp
        default: return nil
        }
        guard let endpoint = Self.remote(of: flow) else { return nil }
        let process = resolver.resolve(auditToken: flow.sourceAppAuditToken, signingIdentifier: nil)
        let state = FlowState(id: flow.identifier, process: process, remoteIP: endpoint.ip, remotePort: endpoint.port,
                              transport: transport, systemHostname: flow.remoteHostname)
        lock.lock(); flows[flow.identifier] = state; lock.unlock()
        return state
    }

    func state(for flow: NEFilterFlow) -> FlowState? {
        lock.lock(); defer { lock.unlock() }
        return flows[flow.identifier]
    }

    /// Statistics reports carry cumulative byte counts; convert to deltas and aggregate.
    func account(flow: NEFilterFlow, bytesIn: Int64, bytesOut: Int64, closed: Bool) {
        lock.lock()
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
