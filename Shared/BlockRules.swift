import Foundation

/// One flow, reduced to what a block decision needs. No NEFilter types, so the rules below are plain functions
/// that can be tested the way `AgentPolicy.matches` is.
struct FlowFacts: Sendable, Equatable {
    /// The agent this flow belongs to: the process itself, or the agent that started it.
    var agentKey: String
    /// The process that opened the connection — the agent, a tool it ran, or an MCP server.
    var bundleID: String
    /// Empty until TLS SNI, a Host header, the system hostname or passive DNS names the destination.
    var host: String
    var ip: String
    var port: UInt16
    /// True once this flow can no longer reveal a hostname, so it has to be judged on its IP alone.
    var hostSettled: Bool
}

enum FlowVerdict: Equatable, Sendable {
    case allow
    /// Refuse the connection, and tell the app so it can be recorded.
    case block
    /// Not yet: the hostname may still arrive in the bytes that follow.
    case undecided
}

/// Whether a flow is refused. Everything here errs towards letting traffic through: a monitor that breaks the
/// machine it watches is worse than one that missed a connection, and a missed connection still raises an alert.
enum BlockRules {
    /// Never refused whatever an allowlist says. Apple's own services carry the Mac's account, push and software
    /// update traffic, and many of them pin certificates, so a refusal there looks like a broken Mac rather than a
    /// blocked agent.
    static let alwaysAllowedHosts = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "mzstatic.com", "cdn-apple.com",
        "apple-dns.net", "aaplimg.com",
    ]

    /// Enforcement only stands while the host app is connected to hear about it, plus a few seconds of grace.
    ///
    /// Two reasons. A refusal nobody can see is worse than no refusal at all, and the app is the only place it can
    /// be recorded; and "allow this from now on" lives in the app too, so with the app gone a blocked agent would
    /// have no way out. The grace period is there because XPC reconnects on its own — flipping enforcement on and
    /// off at every hiccup is worse than either state. When in doubt this lapses towards allowing traffic.
    static let disconnectGrace: TimeInterval = 5

    static func inForce(appConnected: Bool, sinceDisconnect: TimeInterval?, grace: TimeInterval = disconnectGrace) -> Bool {
        if appConnected { return true }
        guard let sinceDisconnect else { return false }   // never connected: nothing to report to
        return sinceDisconnect < grace
    }

    static func verdict(for facts: FlowFacts, policy: AgentPolicy?, inForce: Bool = true) -> FlowVerdict {
        guard inForce, let policy, policy.enabled, policy.enforce else { return .allow }
        if isExempt(facts) { return .allow }
        // The hostname usually isn't known when a flow starts: TLS SNI arrives in the first outbound bytes. Wait
        // for it rather than judging a named destination as if it were a bare IP.
        guard facts.hostSettled || !facts.host.isEmpty else { return .undecided }
        let provider = AgentCatalog.provider(domain: facts.host) != nil
        return policy.allows(host: facts.host, ip: facts.ip, isAIProvider: provider) ? .allow : .block
    }

    /// Traffic that is never refused, before the allowlist is even consulted.
    static func isExempt(_ facts: FlowFacts) -> Bool {
        if NetworkScope.isLocalNetwork(facts.ip) { return true }
        // Flowlight's own traffic, including anything relayed by its HTTPS inspection proxy.
        if facts.bundleID == FlowlightConstants.hostBundleIdentifier
            || facts.bundleID == FlowlightConstants.extensionBundleIdentifier { return true }
        if facts.bundleID.hasPrefix("com.apple.") { return true }
        // Refusing DNS wouldn't stop the agent, it would break name resolution for whatever asked next.
        if facts.port == 53 || facts.port == 853 { return true }
        return alwaysAllowedHosts.contains { AgentPolicy.matches($0, host: facts.host, ip: facts.ip) }
    }
}

/// One refused connection, on its way to the app to be recorded. Blocking invisibly would be worse than not
/// blocking at all, so this travels with the verdict rather than being a log line in the extension.
struct BlockEvent: Codable, Sendable, Equatable {
    var at: Int64
    var agentKey: String
    var agentName: String
    /// The process that opened the connection, which may be a tool the agent ran rather than the agent itself.
    var appName: String
    var host: String
    var ip: String
    var port: UInt16

    /// Where the alert points, and what "Allow from now on" would add to the allowlist.
    var destination: String { host.isEmpty ? ip : host }
}

/// Binary plists both ways, like `TrafficCoding`. Both sides of this ship together, so the payloads are just the
/// shared structs.
enum BlockCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? PropertyListDecoder().decode(type, from: data)
    }
}
