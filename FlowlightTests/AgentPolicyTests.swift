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
