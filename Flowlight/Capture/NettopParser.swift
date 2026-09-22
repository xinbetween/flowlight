import Foundation

/// Parses `nettop -x -n -J bytes_in,bytes_out` output. Each sample starts with a
/// `,bytes_in,bytes_out,` header; counters are cumulative per socket, so we emit deltas.
///
/// Limitations vs. the Network Extension: no SNI/DNS enrichment (reverse DNS only), sockets
/// that open and close between samples are missed, and protocols come from port heuristics.
final class NettopParser {
    struct Socket: Hashable {
        var pid: Int32
        var descriptor: String
    }

    struct Connection {
        var transport: TransportProtocol
        var remoteIP: String
        var remotePort: UInt16
        var localPort: UInt16
    }

    struct Delta {
        var pid: Int32
        var processName: String
        var connection: Connection
        var counters: FlowCounters
    }

    private var previous: [Socket: (Int64, Int64)] = [:]
    private var current: [Socket: (Int64, Int64)] = [:]
    private var pendingDeltas: [Delta] = []
    private var currentPid: Int32 = -1
    private var processNames: [Int32: String] = [:]
    private var buffer = ""

    /// Feed raw output; returns deltas for every completed sample.
    func feed(_ chunk: String) -> [[Delta]] {
        buffer += chunk
        var completed: [[Delta]] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let sample = consume(line: line) { completed.append(sample) }
        }
        return completed
    }

    private func consume(line: String) -> [Delta]? {
        if line.hasPrefix(",") { return finishSample() } // header: new sample begins
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }
        let name = fields[0]

        if let transport = Self.transport(of: name) {
            guard currentPid >= 0, Self.parseConnection(String(name.dropFirst(5)), transport: transport) != nil else { return nil }
            let bytesIn = Int64(fields[1]) ?? 0
            let bytesOut = Int64(fields[2]) ?? 0
            let socket = Socket(pid: currentPid, descriptor: name)
            // Duplicate descriptors (e.g. several unconnected UDP sockets) are summed.
            let existing = current[socket] ?? (0, 0)
            current[socket] = (existing.0 + bytesIn, existing.1 + bytesOut)
        } else if let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) {
            currentPid = pid
            processNames[pid] = String(name[..<dot])
        }
        return nil
    }

    /// Feeds one complete `nettop -L 1` run and returns its deltas (empty for the baseline sample).
    func feedSample(_ output: String) -> [Delta] {
        feed(output + "\n,bytes_in,bytes_out,\n").flatMap { $0 }
    }

    private func finishSample() -> [Delta]? {
        // Back-to-back headers (e.g. one-shot runs) must not wipe the baseline.
        guard !current.isEmpty else { currentPid = -1; return nil }
        defer {
            previous = current
            current = [:]
            currentPid = -1
        }
        // The first sample is only a baseline: its counters include history from before we started.
        guard !previous.isEmpty else { return nil }
        var deltas: [Delta] = []
        for (socket, value) in current {
            guard let transport = Self.transport(of: socket.descriptor),
                  let conn = Self.parseConnection(String(socket.descriptor.dropFirst(5)), transport: transport) else { continue }
            let old = previous[socket]
            var dIn = value.0 - (old?.0 ?? 0)
            var dOut = value.1 - (old?.1 ?? 0)
            if dIn < 0 || dOut < 0 { dIn = value.0; dOut = value.1 } // socket was replaced
            let counters = FlowCounters(bytesIn: max(0, dIn), bytesOut: max(0, dOut), flows: old == nil ? 1 : 0)
            guard !counters.isEmpty else { continue }
            deltas.append(Delta(pid: socket.pid, processName: processNames[socket.pid] ?? "", connection: conn, counters: counters))
        }
        return deltas
    }

    static func transport(of name: String) -> TransportProtocol? {
        if name.hasPrefix("tcp4 ") || name.hasPrefix("tcp6 ") { return .tcp }
        if name.hasPrefix("udp4 ") || name.hasPrefix("udp6 ") { return .udp }
        return nil
    }

    /// `192.168.1.2:49538<->17.57.144.26:5223`, `fe80::1%en0.1024<->fe80::2%en0.443`, `*:5353<->*:*`
    static func parseConnection(_ text: String, transport: TransportProtocol) -> Connection? {
        let parts = text.components(separatedBy: "<->")
        guard parts.count == 2 else { return nil }
        let local = splitEndpoint(parts[0])
        let remote = splitEndpoint(parts[1])
        if remote.host == "*" {
            // Listening TCP sockets carry no traffic; unconnected UDP sockets do (e.g. mDNSResponder).
            guard transport == .udp, let localPort = local.port else { return nil }
            return Connection(transport: transport, remoteIP: "*", remotePort: localPort, localPort: localPort)
        }
        guard let port = remote.port else { return nil }
        let host = remote.host.components(separatedBy: "%").first ?? remote.host
        return Connection(transport: transport, remoteIP: host, remotePort: port, localPort: local.port ?? 0)
    }

    private static func splitEndpoint(_ s: String) -> (host: String, port: UInt16?) {
        // IPv6 uses '.' before the port, IPv4 ':'. Pick whichever separator comes last.
        let separator: Character = s.hasPrefix("*.") || s.filter({ $0 == ":" }).count > 1 ? "." : ":"
        guard let idx = s.lastIndex(of: separator) else { return (s, nil) }
        return (String(s[..<idx]), UInt16(s[s.index(after: idx)...]))
    }
}
