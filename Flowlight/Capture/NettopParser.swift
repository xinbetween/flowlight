import Foundation

/// Parses `nettop -x -n -J interface,bytes_in,bytes_out` output. Each sample starts with a header naming its
/// columns; counters are cumulative per socket, so we emit deltas.
///
/// Columns are read from that header rather than counted off by position. nettop's own man page says the ordering
/// of `-J` "may change in future revisions", and a silent shift by one would turn every byte count into an
/// interface name.
///
/// Limitations vs. the Network Extension: no SNI/DNS enrichment (reverse DNS only), sockets
/// that open and close between samples are missed, and protocols come from port heuristics.
final class NettopParser {
    struct Socket: Hashable {
        var pid: Int32
        var descriptor: String
        /// Part of the key, not an attribute: the same socket descriptor appears once per interface it is bound
        /// to. A process doing Bonjour discovery shows `udp6 *.5353<->*.*` on `en0`, `llw0` and `awdl0` at once,
        /// and those are three different things that happened.
        var interface: String = ""
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
        /// The interface the socket was bound to, empty when nettop didn't say.
        var interface: String = ""
        var channel: NetworkChannel { NetworkChannel.of(interface: interface) }
    }

    private var previous: [Socket: (Int64, Int64)] = [:]
    private var current: [Socket: (Int64, Int64)] = [:]
    private var pendingDeltas: [Delta] = []
    private var currentPid: Int32 = -1
    private var processNames: [Int32: String] = [:]
    private var buffer = ""
    /// Column name → position in a split data line. Read from each sample's header; the defaults match the
    /// columns this parser asks for, so a header that never arrives still reads correctly.
    private var columns: [String: Int] = ["interface": 1, "bytes_in": 2, "bytes_out": 3]

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
        if line.hasPrefix(",") {
            let sample = finishSample()   // a header means the previous sample is over
            readHeader(line)
            return sample
        }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }
        let name = fields[0]

        if let transport = Self.transport(of: name) {
            guard currentPid >= 0, Self.parseConnection(String(name.dropFirst(5)), transport: transport) != nil else { return nil }
            let bytesIn = Int64(column("bytes_in", in: fields) ?? "") ?? 0
            let bytesOut = Int64(column("bytes_out", in: fields) ?? "") ?? 0
            let socket = Socket(pid: currentPid, descriptor: name, interface: column("interface", in: fields) ?? "")
            // Duplicate descriptors (e.g. several unconnected UDP sockets) are summed.
            let existing = current[socket] ?? (0, 0)
            current[socket] = (existing.0 + bytesIn, existing.1 + bytesOut)
        } else if let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) {
            currentPid = pid
            processNames[pid] = String(name[..<dot])
        }
        return nil
    }

    /// `,interface,bytes_in,bytes_out,` — the names line up with the positions of a data line, because both start
    /// with the field that holds the process or socket name.
    private func readHeader(_ line: String) {
        let names = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var found: [String: Int] = [:]
        for (index, name) in names.enumerated() where !name.isEmpty { found[name] = index }
        guard found["bytes_in"] != nil, found["bytes_out"] != nil else { return }   // not a header we can read
        columns = found
    }

    private func column(_ name: String, in fields: [String]) -> String? {
        guard let index = columns[name], fields.indices.contains(index) else { return nil }
        return fields[index]
    }

    /// Feeds one complete `nettop -L 1` run and returns its deltas (empty for the baseline sample).
    ///
    /// The trailing line is a sentinel that closes the sample, not a real header: `readHeader` ignores it, so the
    /// column map the run's own header established is kept.
    func feedSample(_ output: String) -> [Delta] {
        feed(output + "\n,\n").flatMap { $0 }
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
            deltas.append(Delta(pid: socket.pid, processName: processNames[socket.pid] ?? "", connection: conn,
                                counters: counters, interface: socket.interface))
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
