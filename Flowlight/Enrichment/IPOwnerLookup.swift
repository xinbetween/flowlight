import Darwin
import Foundation
import dnssd

/// Who operates an IP address (its autonomous system), for traffic with no known hostname.
struct IPOwner: Sendable, Equatable {
    var asn: Int
    var name: String

    /// "Anthropic, PBC" from "ANTHROPIC - Anthropic, PBC, US"; falls back to the AS handle.
    static func displayName(fromASDescription description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        var handle = ""
        var text = trimmed
        if let dash = trimmed.range(of: " - ") {
            handle = String(trimmed[..<dash.lowerBound])
            text = String(trimmed[dash.upperBound...])
        }
        // Trailing ", US" country code.
        if let comma = text.range(of: ", ", options: .backwards), text[comma.upperBound...].count == 2 {
            text = String(text[..<comma.lowerBound])
        }
        // Some registries put a street address where the organization belongs; use the AS handle then.
        let addressWords = ["building", "avenue", "road", "street", "floor", "tower", "district", "no."]
        if !handle.isEmpty, addressWords.contains(where: { text.lowercased().contains($0) }),
           let first = handle.split(separator: "-").first {
            return first.capitalized
        }
        return text.isEmpty ? trimmed : text
    }

    static let localNetwork = IPOwner(asn: 0, name: "Local network")
}

/// Resolves IP → AS owner with Team Cymru's DNS interface (origin.asn.cymru.com / asn.cymru.com).
/// Results are cached in memory and persisted by the caller. Private/local ranges never leave the Mac.
final class IPOwnerLookup: @unchecked Sendable {
    static let shared = IPOwnerLookup()

    private var owners: [String: IPOwner] = [:]
    private var asNames: [Int: String] = [:]
    private var pending: Set<String> = []
    private var failed: [String: Date] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "flowlight.asn", qos: .utility, attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 4)

    /// Called with each newly resolved owner (for persistence).
    var onResolved: (String, IPOwner) -> Void = { _, _ in }
    var isEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: AnomalySettings.Keys.ownerLookup) }

    func preload(_ entries: [String: IPOwner]) {
        lock.lock(); defer { lock.unlock() }
        owners.merge(entries) { current, _ in current }
    }

    func cached(_ ip: String) -> IPOwner? {
        if Self.isLocalNetwork(ip) { return .localNetwork }
        lock.lock(); defer { lock.unlock() }
        return owners[ip]
    }

    /// Returns the cached owner, scheduling a lookup if unknown.
    @discardableResult
    func owner(for ip: String) -> IPOwner? {
        if let hit = cached(ip) { return hit }
        // Special-purpose ranges are never sent to the lookup service.
        guard isEnabled(), !ip.isEmpty, ip != "(unconnected)", ip != "*", !Self.isPrivate(ip) else { return nil }
        lock.lock()
        if let failedAt = failed[ip], Date().timeIntervalSince(failedAt) < 3600 { lock.unlock(); return nil }
        let isNew = pending.insert(ip).inserted
        lock.unlock()
        if isNew { queue.async { self.resolve(ip) } }
        return nil
    }

    private func resolve(_ ip: String) {
        limiter.wait(); defer { limiter.signal() }
        // A queued lookup may start after the user has turned this feature off.
        guard isEnabled() else {
            lock.lock(); pending.remove(ip); lock.unlock()
            return
        }
        var result: IPOwner?
        if let originName = Self.originQueryName(ip),
           let origin = Self.txt(originName)?.first,
           let asn = origin.split(separator: "|").first.flatMap({ Int($0.split(separator: " ").first?.trimmingCharacters(in: .whitespaces) ?? "") }) {
            lock.lock(); let knownName = asNames[asn]; lock.unlock()
            var name = knownName
            if name == nil, let description = Self.txt("AS\(asn).asn.cymru.com")?.first?.split(separator: "|").last {
                name = IPOwner.displayName(fromASDescription: String(description))
                lock.lock(); asNames[asn] = name; lock.unlock()
            }
            result = IPOwner(asn: asn, name: name ?? "AS\(asn)")
        }
        lock.lock()
        pending.remove(ip)
        if let result { owners[ip] = result } else { failed[ip] = Date() }
        lock.unlock()
        if let result { onResolved(ip, result) }
    }

    /// `1.2.3.4` → `4.3.2.1.origin.asn.cymru.com`; IPv6 uses reversed nibbles under origin6.
    static func originQueryName(_ ip: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            return ip.split(separator: ".").reversed().joined(separator: ".") + ".origin.asn.cymru.com"
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        let nibbles = bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 0x0F, radix: 16)] }
        return nibbles.reversed().joined(separator: ".") + ".origin6.asn.cymru.com"
    }

    /// Traffic that stays on this Mac or the local network (loopback, RFC 1918, link-local, ULA).
    /// Narrower than `isPrivate`: reserved-but-routable-looking ranges still count as leaving the Mac.
    static func isLocalNetwork(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let o = withUnsafeBytes(of: &v4) { Array($0) }
            return o[0] == 10 || o[0] == 127 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
                || (o[0] == 169 && o[1] == 254) || o[0] >= 224
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return ip == "(unconnected)" || ip == "*" }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        return (b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1) || (b[0] & 0xfe) == 0xfc
            || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || b[0] == 0xff
    }

    static func isPrivate(_ ip: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let octets = withUnsafeBytes(of: &v4) { Array($0) }
            let a = octets[0], b = octets[1]
            return a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b))
                || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b))
                || (a == 192 && (b == 0 || b == 168))
                || (a == 192 && b == 88 && octets[2] == 99)
                || (a == 198 && (b == 18 || b == 19))
                || (a == 198 && b == 51 && octets[2] == 100)
                || (a == 203 && b == 0 && octets[2] == 113)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, ip, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        return bytes.allSatisfy { $0 == 0 } // unspecified
            || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1) // loopback
            || bytes[0] == 0xff // multicast
            || (bytes[0] & 0xfe) == 0xfc // unique local
            || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) // link local
            || (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) // documentation
            || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                && Self.isPrivate(bytes[12...15].map(String.init).joined(separator: "."))) // mapped IPv4
    }

    /// Synchronous TXT query through the system resolver, with a timeout.
    static func txt(_ name: String, timeout: TimeInterval = 3) -> [String]? {
        final class Box { var records: [String] = []; var done = false }
        let box = Box()
        var ref: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
            let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
            if error == kDNSServiceErr_NoError, let data {
                let bytes = UnsafeRawBufferPointer(start: data, count: Int(length))
                var text = ""
                var i = 0
                while i < bytes.count {
                    let len = Int(bytes[i])
                    text += String(decoding: bytes[(i + 1)..<min(bytes.count, i + 1 + len)], as: UTF8.self)
                    i += 1 + len
                }
                box.records.append(text)
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.done = true }
        }
        let context = Unmanaged.passUnretained(box).toOpaque()
        guard DNSServiceQueryRecord(&ref, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                    callback, context) == kDNSServiceErr_NoError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0 else { break }
            guard DNSServiceProcessResult(ref) == kDNSServiceErr_NoError else { break }
        }
        return box.records.isEmpty ? nil : box.records
    }
}
