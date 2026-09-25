import XCTest
@testable import Flowlight

/// When a flow may be judged, and what the rules then say about it.
///
/// The bug these were written for: a rule naming a host let the host through. The rule was right and the engine
/// was right — the flow was judged on its first outbound bytes, before TLS SNI or passive DNS had named the
/// destination, and a flow is judged once.
final class FlowJudgementTests: XCTestCase {

    func testAFlowWithNoNameYetIsNotJudgedOnItsFirstBytes() {
        XCTAssertTrue(BlockRules.nameMayStillArrive(port: 443, looksLikeTLS: true, named: false,
                                                    outboundCallbacks: 1, inboundCallbacks: 0))
    }

    func testAFlowThatHasNamedItselfIsJudgedStraightAway() {
        XCTAssertFalse(BlockRules.nameMayStillArrive(port: 443, looksLikeTLS: true, named: true,
                                                     outboundCallbacks: 1, inboundCallbacks: 0))
    }

    func testTheWaitIsBoundedSoAConnectionToABareAddressStillGetsJudged() {
        // Nothing here will ever produce a hostname. Holding it unjudged means peeking at every byte for nothing.
        XCTAssertFalse(BlockRules.nameMayStillArrive(port: 443, looksLikeTLS: true, named: false,
                                                     outboundCallbacks: 4, inboundCallbacks: 0))
        XCTAssertFalse(BlockRules.nameMayStillArrive(port: 443, looksLikeTLS: true, named: false,
                                                     outboundCallbacks: 2, inboundCallbacks: 6))
    }

    func testAPortThatNeverCarriesAHostnameIsJudgedAtOnce() {
        XCTAssertFalse(BlockRules.nameMayStillArrive(port: 22, looksLikeTLS: false, named: false,
                                                     outboundCallbacks: 1, inboundCallbacks: 0))
    }

    func testTLSOnAnUnusualPortStillGetsTheWait() {
        XCTAssertTrue(BlockRules.nameMayStillArrive(port: 8443, looksLikeTLS: true, named: false,
                                                    outboundCallbacks: 1, inboundCallbacks: 0))
    }

    // MARK: What the rules then say

    func testARuleNamingAHostBlocksItOnceTheNameIsKnown() {
        let rule = Rule(action: .block, app: "", destination: "google-analytics.com", origin: .preset)
        let decision = RuleBook.decide(facts(host: "www.google-analytics.com"), rules: [rule])
        XCTAssertEqual(decision.verdict, .block)
        XCTAssertEqual(decision.rule?.destination, "google-analytics.com")
    }

    func testTheSameRuleWaitsRatherThanAllowingWhileTheNameIsUnknown() {
        // This is the whole fix: undecided, not allow. An allow here is permanent.
        let rule = Rule(action: .block, app: "", destination: "google-analytics.com", origin: .preset)
        let decision = RuleBook.decide(facts(host: "", settled: false), rules: [rule])
        XCTAssertEqual(decision.verdict, .undecided)
    }

    func testAnUnnamedFlowIsAllowedOnceItCanNoLongerBeNamed() {
        let rule = Rule(action: .block, app: "", destination: "google-analytics.com", origin: .preset)
        XCTAssertEqual(RuleBook.decide(facts(host: "", settled: true), rules: [rule]).verdict, .allow)
    }

    private func facts(host: String, settled: Bool = true) -> FlowFacts {
        FlowFacts(agentKey: "com.google.Chrome.helper", bundleID: "com.google.Chrome.helper",
                  host: host, ip: "2607:f8b0:4002:c10::64", port: 443, hostSettled: settled)
    }
}
