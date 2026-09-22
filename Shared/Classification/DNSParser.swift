import Foundation

/// Minimal DNS response parser used to build a passive IP → name cache from UDP/53 traffic.
enum DNSParser {
    struct Answer: Equatable {
        var queriedName: String
        var addresses: [String]
        var ttl: UInt32
    }

    /// Parses a DNS response. Pass `tcpFraming: true` for DNS over TCP (2-byte length prefix).
    static func parseResponse(_ data: Data, tcpFraming: Bool = false) -> Answer? {
        var b = [UInt8](data)
        if tcpFraming {
            guard b.count > 2 else { return nil }
            b.removeFirst(2)
        }
        guard b.count >= 12 else { return nil }
        let flags = UInt16(b[2]) << 8 | UInt16(b[3])
        guard flags & 0x8000 != 0 else { return nil } // QR bit: response
        let qdCount = Int(b[4]) << 8 | Int(b[5])
        let anCount = Int(b[6]) << 8 | Int(b[7])
        guard qdCount >= 1 else { return nil }

        var i = 12
        guard let qname = readName(b, &i) else { return nil }
        i += 4 // qtype + qclass
        for _ in 1..<max(qdCount, 1) { // skip extra questions (rare)
            guard readName(b, &i) != nil else { return nil }
            i += 4
        }

        var addresses: [String] = []
        var minTTL = UInt32.max
        for _ in 0..<anCount {
            guard readName(b, &i) != nil, i + 10 <= b.count else { break }
            let type = Int(b[i]) << 8 | Int(b[i + 1])
            let ttl = UInt32(b[i + 4]) << 24 | UInt32(b[i + 5]) << 16 | UInt32(b[i + 6]) << 8 | UInt32(b[i + 7])
            let rdLength = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + rdLength <= b.count else { break }
            let rdata = Array(b[i..<(i + rdLength)])
            if type == 1, rdLength == 4 {
                addresses.append(rdata.map(String.init).joined(separator: "."))
                minTTL = min(minTTL, ttl)
            } else if type == 28, rdLength == 16 {
                addresses.append(formatIPv6(rdata))
                minTTL = min(minTTL, ttl)
            }
            i += rdLength
        }
        guard !addresses.isEmpty else { return nil }
        return Answer(queriedName: qname.lowercased(), addresses: addresses, ttl: minTTL)
    }

    private static func readName(_ b: [UInt8], _ i: inout Int) -> String? {
        var labels: [String] = []
        var pos = i
        var jumped = false
        var hops = 0
        while pos < b.count {
            let len = Int(b[pos])
            if len == 0 {
                pos += 1
                if !jumped { i = pos }
                return labels.joined(separator: ".")
            }
            if len & 0xC0 == 0xC0 { // compression pointer
                guard pos + 1 < b.count, hops < 16 else { return nil }
                let target = (len & 0x3F) << 8 | Int(b[pos + 1])
                if !jumped { i = pos + 2 }
                jumped = true
                hops += 1
                pos = target
                continue
            }
            guard pos + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(pos + 1)...(pos + len)], as: UTF8.self))
            pos += 1 + len
        }
        return nil
    }

    static func formatIPv6(_ bytes: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { raw in
            for (idx, byte) in bytes.prefix(16).enumerated() { raw[idx] = byte }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

/// Thread-safe passive hostname cache: IP → name, learned from DNS answers and TLS SNI.
/// SNI wins over DNS because it names the host the client actually asked for on that connection.
final class DNSCache: @unchecked Sendable {
    static let shared = DNSCache()
    private var entries: [String: (name: String, expires: Date)] = [:]
    private var sniEntries: [String: (name: String, expires: Date)] = [:]
    private let lock = NSLock()
    private let maxEntries = 50_000
    private(set) var learnedCount = 0

    func record(_ answer: DNSParser.Answer) {
        // Keep entries well past TTL: connections often outlive the record.
        let expires = Date().addingTimeInterval(max(TimeInterval(answer.ttl), 3600) * 4)
        lock.lock(); defer { lock.unlock() }
        trimIfNeeded(&entries)
        for ip in answer.addresses {
            if entries[ip] == nil { learnedCount += 1 }
            entries[ip] = (answer.queriedName, expires)
        }
    }

    func recordSNI(ip: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        trimIfNeeded(&sniEntries)
        if sniEntries[ip] == nil && entries[ip] == nil { learnedCount += 1 }
        sniEntries[ip] = (name, Date().addingTimeInterval(24 * 3600))
    }

    func name(for ip: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let sni = sniEntries[ip], sni.expires > now { return sni.name }
        guard let entry = entries[ip], entry.expires > now else { return nil }
        return entry.name
    }

    private func trimIfNeeded(_ dict: inout [String: (name: String, expires: Date)]) {
        guard dict.count > maxEntries else { return }
        let now = Date()
        dict = dict.filter { $0.value.expires > now }
    }
}
