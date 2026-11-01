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
        XCTAssertEqual(BlockRules.verdict(for: facts(bundleID: "com.apple.Safari"), policy: policy()), .block,
                       "user-facing Apple apps are not a blanket safety exemption")
        XCTAssertEqual(BlockRules.verdict(for: facts(host: "advertising.apple.com"), policy: policy()), .block,
                       "audited Apple advertising hosts remain blockable")
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

    func testRepeatedReportingFailuresCannotExtendFailOpenGrace() {
        var state = EnforcementConnectionState()
        let connectedAt = Date(timeIntervalSince1970: 1_000)
        state.update(connected: true, now: connectedAt)
        state.update(connected: false, now: connectedAt.addingTimeInterval(1))

        for second in 2...10 {
            state.update(connected: false, now: connectedAt.addingTimeInterval(TimeInterval(second)))
        }

        XCTAssertFalse(
            state.isInForce(now: connectedAt.addingTimeInterval(7)),
            "retries must not restart the five-second fail-open grace"
        )
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

    func testDurableQueueRemovesOnlyTheAcknowledgedEventIDs() {
        struct Event: Equatable { var id: UUID }
        let first = Event(id: UUID())
        let second = Event(id: UUID())
        let arrivedWhileSending = Event(id: UUID())
        var queue = DurableEventQueue<Event>()
        queue.append(first)
        queue.append(second)
        let delivery = try! XCTUnwrap(queue.begin(clientGeneration: 1, limit: 500, id: \.id))
        XCTAssertNil(queue.begin(clientGeneration: 1, limit: 500, id: \.id),
                     "one in-flight token must produce exactly one XPC send")

        queue.append(arrivedWhileSending)
        XCTAssertTrue(queue.complete(token: delivery.token, clientGeneration: 1, committed: true, id: \.id))
        XCTAssertEqual(queue.pending, [arrivedWhileSending])
    }

    func testDurableQueueIgnoresAReplyFromASupersededClient() {
        struct Event: Equatable { var id: UUID }
        let first = Event(id: UUID())
        let second = Event(id: UUID())
        var queue = DurableEventQueue<Event>()
        queue.append(first)
        let stale = try! XCTUnwrap(queue.begin(clientGeneration: 1, limit: 500, id: \.id))
        queue.resetDelivery()
        queue.append(second)
        let current = try! XCTUnwrap(queue.begin(clientGeneration: 2, limit: 500, id: \.id))

        XCTAssertFalse(queue.complete(token: stale.token, clientGeneration: 1, committed: true, id: \.id))
        XCTAssertEqual(queue.pending, [first, second])
        XCTAssertTrue(queue.complete(token: current.token, clientGeneration: 2, committed: true, id: \.id))
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testDurableQueueRetriesTheSameEventsAfterFailure() {
        struct Event: Equatable { var id: UUID }
        let event = Event(id: UUID())
        var queue = DurableEventQueue<Event>()
        queue.append(event)
        let first = try! XCTUnwrap(queue.begin(clientGeneration: 1, limit: 500, id: \.id))

        XCTAssertTrue(queue.complete(token: first.token, clientGeneration: 1, committed: false, id: \.id))
        let retry = try! XCTUnwrap(queue.begin(clientGeneration: 1, limit: 500, id: \.id))
        XCTAssertEqual(retry.events, [event])
        XCTAssertEqual(queue.pending, [event])
    }

    func testDurableHealthRequiresEveryPendingChannelToCommit() {
        enum Channel { case blocks, decisions, packs }
        var health = DurableDeliveryHealth<Channel>()

        XCTAssertTrue(health.isHealthy)
        health.begin(.blocks)
        health.begin(.decisions)
        XCTAssertFalse(health.isHealthy)
        health.succeeded(.blocks)
        XCTAssertFalse(health.isHealthy)
        health.failed(.decisions)
        XCTAssertFalse(health.isHealthy)
        health.succeeded(.decisions)
        XCTAssertTrue(health.isHealthy)
        health.begin(.packs)
        health.reset()
        XCTAssertTrue(health.isHealthy)
    }

    func testDurableQueueDoesNotEvictUncommittedEvidence() {
        struct Event { var id: UUID }
        var queue = DurableEventQueue<Event>()
        for _ in 0..<501 { queue.append(Event(id: UUID())) }
        XCTAssertEqual(queue.pending.count, 501)
    }

    func testMalformedDurablePayloadsAreNotAcknowledged() {
        let source = ExtensionTrafficSource()
        let blockReply = expectation(description: "block reply")
        source.blockedDurably(payload: Data([0x01, 0x02, 0x03])) { committed in
            XCTAssertFalse(committed)
            blockReply.fulfill()
        }
        let decisionReply = expectation(description: "decision reply")
        source.ruleDecisionsDurably(payload: Data([0x01, 0x02, 0x03])) { committed in
            XCTAssertFalse(committed)
            decisionReply.fulfill()
        }
        wait(for: [blockReply, decisionReply], timeout: 1)
    }

    func testEnforcementTravelsAsPolicies() throws {
        let list = [policy(), policy(enforce: false)]
        let decoded = BlockCoding.decode([AgentPolicy].self, from: BlockCoding.encode(list))
        XCTAssertEqual(decoded, list)
        let events = [BlockEvent(at: 1, agentKey: "claude", agentName: "Claude Code", appName: "curl", bundleID: "curl",
                                 host: "", ip: "203.0.113.7", port: 8443)]
        XCTAssertEqual(BlockCoding.decode([BlockEvent].self, from: BlockCoding.encode(events)), events)
        XCTAssertEqual(events[0].destination, "203.0.113.7", "a nameless destination is named by its address")

        let legacy = try PropertyListSerialization.data(
            fromPropertyList: [["at": 2, "agentKey": "claude", "agentName": "Claude Code", "appName": "curl",
                                "host": "legacy.example", "ip": "", "port": 443]],
            format: .binary,
            options: 0
        )
        XCTAssertNil(BlockCoding.decode([BlockEvent].self, from: legacy)?.first?.bundleID,
                     "new apps continue to accept events from an older extension")
    }
}
