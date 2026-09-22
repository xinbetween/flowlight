import Darwin
import Foundation

/// "Claude Code may talk to GitHub and npm, nothing else." An allowlist for one agent (its tools and MCP
/// servers included). Flowlight observes rather than blocks, so a violation raises an alert.
struct AgentPolicy: Codable, Equatable, Sendable {
    var agentID: String
    var enabled: Bool = true
    /// The agent's own model providers are allowed without listing them.
    var allowAIProviders: Bool = true
    /// Domains (subdomains included), IP addresses and CIDR ranges.
    var patterns: [String] = []

    struct Preset: Identifiable, Sendable {
        var name: String
        var patterns: [String]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "GitHub", patterns: ["github.com", "githubusercontent.com", "githubassets.com", "ghcr.io"]),
        Preset(name: "npm", patterns: ["npmjs.org", "npmjs.com", "yarnpkg.com"]),
        Preset(name: "PyPI", patterns: ["pypi.org", "pythonhosted.org"]),
        Preset(name: "Homebrew", patterns: ["brew.sh", "ghcr.io"]),
        Preset(name: "Docker Hub", patterns: ["docker.io", "docker.com"]),
        Preset(name: "Rust crates", patterns: ["crates.io", "rust-lang.org"]),
        Preset(name: "Go modules", patterns: ["golang.org", "proxy.golang.org", "sum.golang.org"]),
        Preset(name: "Apple", patterns: ["apple.com", "icloud.com", "mzstatic.com"]),
    ]

    /// Whether this destination is allowed. Local-network traffic always is.
    func allows(host: String, ip: String, isAIProvider: Bool) -> Bool {
        if IPOwnerLookup.isLocalNetwork(ip) { return true }
        if isAIProvider && allowAIProviders { return true }
        return patterns.contains { Self.matches($0, host: host, ip: ip) }
    }

    static func matches(_ pattern: String, host: String, ip: String) -> Bool {
        let p = pattern.lowercased()
        if p.contains("/") { return cidrContains(p, ip) }
        if isIPAddress(p) { return p == ip.lowercased() }
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        return h == p || h.hasSuffix("." + p)
    }

    /// Cleans user input: "https://api.GitHub.com:443/x" → "api.github.com", "*.npmjs.org" → "npmjs.org".
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        if s.hasPrefix(".") { s = String(s.dropFirst()) }
        if !s.contains("/") || !isCIDR(s) { s = s.split(separator: "/").first.map(String.init) ?? s }
        if !isIPAddress(s), !isCIDR(s), let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }   // host:port
        guard !s.isEmpty, s.count <= 253, isIPAddress(s) || isCIDR(s) || s.contains(".") else { return nil }
        return s
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        return parts.count == 2 && isIPAddress(String(parts[0])) && Int(parts[1]) != nil
    }

    static func cidrContains(_ cidr: String, _ ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), let net = bytes(String(parts[0])), let addr = bytes(ip),
              net.count == addr.count, bits >= 0, bits <= net.count * 8 else { return false }
        for i in 0..<net.count {
            let remaining = bits - i * 8
            if remaining <= 0 { break }
            let mask: UInt8 = remaining >= 8 ? 0xFF : UInt8(0xFF << (8 - remaining) & 0xFF)
            if net[i] & mask != addr[i] & mask { return false }
        }
        return true
    }

    private static func bytes(_ ip: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
