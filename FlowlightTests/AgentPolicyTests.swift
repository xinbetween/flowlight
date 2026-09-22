import XCTest
@testable import Flowlight

final class AgentPolicyTests: XCTestCase {
    func testMatching() {
        XCTAssertTrue(AgentPolicy.matches("github.com", host: "api.github.com", ip: "1.1.1.1"))
        XCTAssertTrue(AgentPolicy.matches("github.com", host: "github.com", ip: "1.1.1.1"))
        XCTAssertFalse(AgentPolicy.matches("github.com", host: "evilgithub.com", ip: "1.1.1.1"), "label boundaries")
        XCTAssertFalse(AgentPolicy.matches("github.com", host: "", ip: "1.1.1.1"), "hostless traffic needs an IP rule")
        XCTAssertTrue(AgentPolicy.matches("140.82.112.0/20", host: "", ip: "140.82.121.4"))
        XCTAssertFalse(AgentPolicy.matches("140.82.112.0/20", host: "", ip: "140.82.128.1"))
        XCTAssertTrue(AgentPolicy.matches("2606:50c0::/32", host: "", ip: "2606:50c0:8000::153"))
        XCTAssertTrue(AgentPolicy.matches("203.0.113.9", host: "", ip: "203.0.113.9"))
    }

    func testNormalizeInput() {
        XCTAssertEqual(AgentPolicy.normalize(" https://API.GitHub.com:443/repos "), "api.github.com")
        XCTAssertEqual(AgentPolicy.normalize("*.npmjs.org"), "npmjs.org")
        XCTAssertEqual(AgentPolicy.normalize("10.0.0.0/8"), "10.0.0.0/8")
        XCTAssertEqual(AgentPolicy.normalize("2606:50c0::153"), "2606:50c0::153")
        XCTAssertNil(AgentPolicy.normalize("localhost"))
        XCTAssertNil(AgentPolicy.normalize(""))
    }

    func testAllowsProvidersAndLocalNetwork() {
        var policy = AgentPolicy(agentID: "claude", patterns: ["github.com", "npmjs.org"])
        XCTAssertTrue(policy.allows(host: "api.anthropic.com", ip: "160.79.104.10", isAIProvider: true))
        XCTAssertTrue(policy.allows(host: "", ip: "192.168.1.20", isAIProvider: false), "local network is always allowed")
        XCTAssertTrue(policy.allows(host: "registry.npmjs.org", ip: "104.16.1.1", isAIProvider: false))
        XCTAssertFalse(policy.allows(host: "paste.example", ip: "203.0.113.7", isAIProvider: false))
        policy.allowAIProviders = false
        XCTAssertFalse(policy.allows(host: "api.anthropic.com", ip: "160.79.104.10", isAIProvider: true))
    }

    func testViolationsAlertOncePerDestination() throws {
        final class NoActivity: ActivitySnapshotting, @unchecked Sendable { func idleDuration(bundleID: String) -> TimeInterval? { nil } }
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("violation-\(UUID()).sqlite"))
        try db.savePolicy(AgentPolicy(agentID: "claude", patterns: ["github.com", "npmjs.org"]))
        let engine = AnomalyEngine(db: db, activity: NoActivity())
        engine.settings = { AnomalySettings() }
        var fired: [AlertRecord] = []
        engine.onAlert = { fired += $0 }
        func key(_ app: String, _ host: String, ip: String = "203.0.113.7", parent: Bool = false) -> FlowKey {
            var k = FlowKey(pid: 1, bundleID: app, appName: app, appPath: "", remoteIP: ip, domain: host, port: 443, transport: .tcp, appProtocol: "https")
            if parent { k.parentAgent = "claude"; k.parentAgentName = "Claude Code" }
            return k
        }
        let c = FlowCounters(bytesIn: 1, bytesOut: 900, flows: 1)
        try engine.observe([TrafficBatch(timestamp: 100, records: [
            TrafficRecord(key: key("claude", "api.anthropic.com", ip: "160.79.104.10"), counters: c),   // AI provider: allowed
            TrafficRecord(key: key("claude", "api.github.com"), counters: c),                            // listed
            TrafficRecord(key: key("curl", "registry.npmjs.org", parent: true), counters: c),             // listed, via a tool
            TrafficRecord(key: key("curl", "paste.example", parent: true), counters: c),                  // not listed
            TrafficRecord(key: key("curl", "cdn.paste.example", parent: true), counters: c),              // same registrable domain
        ])])
        let violations = fired.filter { $0.kind == AnomalyEngine.Kind.allowlistViolation.rawValue }
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.bundleID, "claude")
        XCTAssertTrue(violations.first?.detail.contains("Claude Code › curl contacted paste.example") == true, violations.first?.detail ?? "")
        // Agents without a policy aren't affected.
        try engine.observe([TrafficBatch(timestamp: 101, records: [TrafficRecord(key: key("codex", "paste.example"), counters: c)])])
        XCTAssertEqual(fired.filter { $0.kind == AnomalyEngine.Kind.allowlistViolation.rawValue }.count, 1)
    }

    func testPoliciesPersist() throws {
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID()).sqlite"))
        let policy = AgentPolicy(agentID: "claude", patterns: ["github.com"])
        try db.savePolicy(policy)
        var updated = policy
        updated.patterns.append("npmjs.org")
        try db.savePolicy(updated)
        XCTAssertEqual(try db.loadPolicies(), ["claude": updated])
    }
}
