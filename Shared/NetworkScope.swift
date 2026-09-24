import Darwin
import Foundation

/// Where an address sits. It lives in `Shared` because the filter extension has to answer the same question the
/// app does — and has to answer it before refusing a connection.
enum NetworkScope {
    /// Traffic that stays on this Mac or the local network (loopback, RFC 1918, link-local, ULA).
    /// Narrower than `IPOwnerLookup.isPrivate`: reserved-but-routable-looking ranges still count as leaving the Mac.
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
}
