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

    // MARK: The name that arrives in the second segment

    func testAClientHelloSplitAcrossSegmentsOnlyNamesItselfOnceItIsWholeAgain() {
        // The shape that caused this: a ClientHello around 2 KB, where server_name sits after a key_share too
        // big for one TCP segment. Reading only the first segment finds nothing — which used to be read as
        // "this connection has no name" rather than "not yet".
        let hello = clientHello(host: "www.google-analytics.com", paddingBefore: 1600)
        XCTAssertGreaterThan(hello.count, 1460, "the point of this test is a hello that doesn't fit one segment")

        let firstSegment = hello.prefix(1460)
        XCTAssertNil(TLSSNIParser.serverName(in: firstSegment), "the name isn't in the first segment")
        XCTAssertEqual(TLSSNIParser.serverName(in: hello), "www.google-analytics.com")
    }

    func testAHelloThatFitsOneSegmentIsStillReadStraightAway() {
        let hello = clientHello(host: "api.github.com", paddingBefore: 0)
        XCTAssertEqual(TLSSNIParser.serverName(in: hello), "api.github.com")
    }

    /// A ClientHello with `paddingBefore` bytes of some other extension ahead of server_name.
    ///
    /// Written as one `append` per field rather than as concatenated array literals: the chained version was a
    /// single expression the Swift type checker gave up on, which fails the build rather than the test.
    private func clientHello(host: String, paddingBefore: Int) -> Data {
        let name: [UInt8] = Array(host.utf8)

        var extensions: [UInt8] = []
        if paddingBefore > 0 {
            extensions.append(contentsOf: u16(0x0033))
            extensions.append(contentsOf: u16(paddingBefore))
            extensions.append(contentsOf: [UInt8](repeating: 0, count: paddingBefore))
        }
        extensions.append(contentsOf: u16(0x0000))          // server_name
        extensions.append(contentsOf: u16(name.count + 5))  // extension length
        extensions.append(contentsOf: u16(name.count + 3))  // name list length
        extensions.append(0)                                // host_name
        extensions.append(contentsOf: u16(name.count))
        extensions.append(contentsOf: name)

        var body: [UInt8] = [0x03, 0x03]
        body.append(contentsOf: [UInt8](repeating: 0xAB, count: 32))   // random
        body.append(0)                                                 // no session id
        body.append(contentsOf: u16(2))
        body.append(contentsOf: [0x13, 0x01] as [UInt8])               // one cipher suite
        body.append(contentsOf: [1, 0] as [UInt8])                     // one compression method
        body.append(contentsOf: u16(extensions.count))
        body.append(contentsOf: extensions)

        var handshake: [UInt8] = [0x01]
        handshake.append(contentsOf: u24(body.count))
        handshake.append(contentsOf: body)

        var record: [UInt8] = [0x16, 0x03, 0x01]
        record.append(contentsOf: u16(handshake.count))
        record.append(contentsOf: handshake)
        return Data(record)
    }

    private func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func u24(_ v: Int) -> [UInt8] { [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    private func facts(host: String, settled: Bool = true) -> FlowFacts {
        FlowFacts(agentKey: "com.google.Chrome.helper", bundleID: "com.google.Chrome.helper",
                  host: host, ip: "2607:f8b0:4002:c10::64", port: 443, hostSettled: settled)
    }
}
