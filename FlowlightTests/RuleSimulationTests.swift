import XCTest
@testable import Flowlight

/// Simulation exists so that the first thing you learn about a blocking rule isn't what it broke. That only
/// holds if the number it reports is the number that would actually happen, so these test the cases where a
/// naive "what does this rule match" would give a confidently wrong answer.
final class RuleSimulationTests: XCTestCase {

    private func rule(app: String = "", destination: String = "", action: Rule.Action = .block,
                      enabled: Bool = true) -> Rule {
        var r = Rule()
        r.app = app
        r.destination = destination
        r.action = action
        r.enabled = enabled
        return r
    }

    private func flow(app: String = "claude", name: String = "Claude Code", host: String = "api.example",
                      ip: String = "1.2.3.4", port: UInt16 = 443, connections: Int = 1, bytes: Int64 = 1000,
                      when: Date = Date()) -> RuleSimulation.Flow {
        RuleSimulation.Flow(when: when, agentKey: app, bundleID: app, appName: name, host: host, ip: ip,
                            port: port, bytes: bytes, connections: connections)
    }

    func testItReportsWhatTheRuleWouldRefuse() {
        let result = RuleSimulation.run(candidate: rule(app: "claude", destination: "api.example"),
                                        existing: [], flows: [flow(), flow(host: "other.example")])
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals.first?.host, "api.example")
        XCTAssertEqual(result.flowsConsidered, 2)
    }

    /// The reason this is a delta and not a match count: if an existing rule already refuses the traffic,
    /// adding another that also refuses it changes nothing, and reporting it as a fresh refusal would overstate
    /// the damage of every rule written after the first.
    func testTrafficAlreadyRefusedIsNotCountedAgain() {
        let existing = [rule(app: "claude", destination: "api.example")]
        let result = RuleSimulation.run(candidate: rule(app: "claude"), existing: existing, flows: [flow()])
        XCTAssertTrue(result.refusals.isEmpty, "this traffic was already being refused")
    }

    /// An allow rule written to carve an exception out of a broad block should report what it would *let
    /// through*, which is the same question asked from the other side.
    func testAnAllowRuleReportsWhatItWouldPermit() {
        let existing = [rule(app: "claude")]                       // blocks everything this agent does
        let candidate = rule(app: "claude", destination: "api.example", action: .allow)
        let result = RuleSimulation.run(candidate: candidate, existing: existing, flows: [flow()])
        XCTAssertTrue(result.refusals.isEmpty)
        XCTAssertEqual(result.permits.count, 1)
        XCTAssertEqual(result.permits.first?.host, "api.example")
    }

    /// The use case is a rule you have written and not switched on yet.
    func testADisabledCandidateIsStillSimulated() {
        let candidate = rule(app: "claude", destination: "api.example", enabled: false)
        let result = RuleSimulation.run(candidate: candidate, existing: [], flows: [flow()])
        XCTAssertEqual(result.refusals.count, 1)
    }

    /// Re-simulating a rule that is already saved must compare it against the others, not against itself —
    /// otherwise a saved rule always reports "changes nothing", which is useless and looks like a bug.
    func testASavedRuleIsNotComparedAgainstItself() {
        let saved = rule(app: "claude", destination: "api.example")
        let result = RuleSimulation.run(candidate: saved, existing: [saved], flows: [flow()])
        XCTAssertEqual(result.refusals.count, 1)
    }

    /// Forty refusals to one host is one thing breaking, not forty, so the list groups — while the totals
    /// still count every connection.
    func testRepeatedTrafficToOneDestinationIsOneRow() {
        let flows = (0..<5).map { flow(connections: 2, bytes: 100, when: Date().addingTimeInterval(Double(-$0) * 60)) }
        let result = RuleSimulation.run(candidate: rule(app: "claude"), existing: [], flows: flows)
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.connectionsRefused, 10)
        XCTAssertEqual(result.bytesRefused, 500)
    }

    func testBusiestDestinationComesFirst() {
        let flows = [flow(host: "quiet.example", connections: 1), flow(host: "busy.example", connections: 99)]
        let result = RuleSimulation.run(candidate: rule(app: "claude"), existing: [], flows: flows)
        XCTAssertEqual(result.refusals.first?.host, "busy.example")
    }

    func testItCountsTheAppsAffected() {
        // One destination, two agents reaching it: a rule naming only the destination affects both.
        let flows = [flow(app: "claude", host: "shared.example"), flow(app: "cursor", host: "shared.example")]
        let result = RuleSimulation.run(candidate: rule(destination: "shared.example"), existing: [], flows: flows)
        XCTAssertEqual(result.appsAffected, 2)
    }

    func testAnIncompleteRuleRefusesNothing() {
        let result = RuleSimulation.run(candidate: rule(), existing: [], flows: [flow()])
        XCTAssertTrue(result.isEmpty, "a rule naming neither an app nor a destination is not usable")
    }

    func testEarliestReportsHowFarBackTheEvidenceGoes() {
        let old = Date().addingTimeInterval(-86400)
        let result = RuleSimulation.run(candidate: rule(app: "claude"), existing: [],
                                        flows: [flow(when: old), flow()])
        XCTAssertEqual(result.earliest?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }

    /// Recorded traffic is as named as it will ever be, so a rule naming a destination must judge it rather
    /// than waiting for a hostname that is never coming — which is what a live flow does.
    func testRecordedTrafficIsNeverLeftUndecided() {
        let result = RuleSimulation.run(candidate: rule(app: "claude", destination: "api.example"),
                                        existing: [], flows: [flow(host: "", ip: "9.9.9.9")])
        XCTAssertTrue(result.isEmpty, "an IP that doesn't match the destination should simply not match")
    }
}
