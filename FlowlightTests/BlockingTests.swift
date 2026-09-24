import XCTest
@testable import Flowlight

/// The rules that decide whether a connection is refused. They are plain functions on plain data, so the whole
/// decision can be checked here rather than on a Mac with the filter installed.
final class BlockingTests: XCTestCase {
    private func facts(host: String = "paste.example", ip: String = "203.0.113.7", port: UInt16 = 443,
                       bundleID: String = "claude", settled: Bool = true) -> FlowFacts {
        FlowFacts(agentKey: "claude", bundleID: bundleID, host: host, ip: ip, port: port, hostSettled: settled)
    }

    private func policy(enforce: Bool = true, enabled: Bool = true, patterns: [String] = ["github.com", "npmjs.org"]) -> AgentPolicy {
        AgentPolicy(agentID: "claude", enabled: enabled, allowAIProviders: true, patterns: patterns, enforce: enforce)
    }

    func testOnlyEnforcingPoliciesBlock() {
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: policy()), .block)
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: policy(enforce: false)), .allow,
                       "an allowlist that only reports must never refuse anything")
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: policy(enabled: false)), .allow)
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: nil), .allow, "an agent with no allowlist")
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "api.github.com"), policy: policy()), .allow)
    }

    func testStoredPolicyWithoutTheFlagDoesNotBlock() throws {
        // What an allowlist saved by an earlier version looks like on disk.
        let json = Data(#"{"agentID":"claude","enabled":true,"allowAIProviders":true,"patterns":["github.com"]}"#.utf8)
        let policy = try JSONDecoder().decode(AgentPolicy.self, from: json)
        XCTAssertFalse(policy.enforce)
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: policy), .allow)
    }

    func testTheMachineIsNeverBroken() {
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", ip: "192.168.1.30"), policy: policy()), .allow,
                       "the local network")
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", ip: "127.0.0.1", port: 8877), policy: policy()), .allow,
                       "Flowlight's own inspection proxy")
        XCTAssertEqual(BlockRules.verdict(for: facts(bundleID: "com.flowlight.app"), policy: policy()), .allow,
                       "Flowlight's own traffic")
        XCTAssertEqual(BlockRules.verdict(for: facts(bundleID: "com.apple.nsurlsessiond"), policy: policy()), .allow)
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "gateway.icloud.com"), policy: policy()), .allow,
                       "Apple services")
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", ip: "1.1.1.1", port: 53), policy: policy()), .allow,
                       "refusing DNS breaks name resolution for whatever asked next")
    }

    func testAIProvidersFollowThePolicy() {
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "api.anthropic.com", ip: "160.79.104.10"), policy: policy()), .allow)
        var strict = policy()
        strict.allowAIProviders = false
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "api.anthropic.com", ip: "160.79.104.10"), policy: strict), .block)
    }

    func testAnUnknownHostnameWaitsAndThenIsJudgedOnItsIP() {
        // TLS SNI arrives in the first outbound bytes, so a nameless flow that might still name itself waits.
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", settled: false), policy: policy()), .undecided)
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", settled: true), policy: policy()), .block)
        let byIP = policy(patterns: ["203.0.113.0/24"])
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "", settled: true), policy: byIP), .allow)
    }

    /// Nothing is refused while the app isn't there to record it, and a moment's XPC hiccup doesn't flip the rule.
    func testEnforcementLapsesWhenTheAppIsGone() {
        XCTAssertTrue(BlockRules.inForce(appConnected: true, sinceDisconnect: nil))
        XCTAssertTrue(BlockRules.inForce(appConnected: false, sinceDisconnect: 2), "reconnecting")
        XCTAssertFalse(BlockRules.inForce(appConnected: false, sinceDisconnect: 30), "the app has quit")
        XCTAssertFalse(BlockRules.inForce(appConnected: false, sinceDisconnect: nil), "never connected")
        XCTAssertEqual(BlockRules.verdict(for: facts(), policy: policy(), inForce: false), .allow)
    }

    func testABlockedConnectionBecomesAnAlertThatCanBeUndone() throws {
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("blocked-\(UUID()).sqlite"))
        let event = BlockEvent(at: 1000, agentKey: "claude", agentName: "Claude Code", appName: "curl",
                               host: "cdn.paste.example", ip: "203.0.113.7", port: 443)
        let alert = try db.addAlert(kind: AnomalyEngine.Kind.blockedConnection.rawValue, bundleID: event.agentKey,
                                    appName: event.agentName, detail: "Blocked it", severity: 3,
                                    allowPattern: AnomalyEngine.registrableDomain(event.destination))
        XCTAssertEqual(alert.allowPattern, "paste.example")
        XCTAssertEqual(try db.alerts().first?.allowPattern, "paste.example", "the offer survives a round trip")
        XCTAssertEqual(try db.alerts().first?.kind, "Connection blocked")
    }

    func testEnforcementTravelsAsPolicies() {
        let list = [policy(), policy(enforce: false)]
        let decoded = BlockCoding.decode([AgentPolicy].self, from: BlockCoding.encode(list))
        XCTAssertEqual(decoded, list)
        let events = [BlockEvent(at: 1, agentKey: "claude", agentName: "Claude Code", appName: "curl",
                                 host: "", ip: "203.0.113.7", port: 8443)]
        XCTAssertEqual(BlockCoding.decode([BlockEvent].self, from: BlockCoding.encode(events)), events)
        XCTAssertEqual(events[0].destination, "203.0.113.7", "a nameless destination is named by its address")
    }
}
