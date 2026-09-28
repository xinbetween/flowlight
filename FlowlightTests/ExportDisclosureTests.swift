import XCTest
@testable import Flowlight

/// The disclosure is only worth having if approving one thing cannot authorise a different thing. These test
/// that property from the directions someone would actually get there: changing where it goes, changing what
/// goes, changing how it is protected in transit, and switching off and on again.
final class ExportDisclosureTests: XCTestCase {

    private func config(endpoint: String = "https://collector.example/v1",
                        mode: ExportMode = .otlp,
                        rollups: Bool = true, alerts: Bool = true, hostName: Bool = true) -> ExportConfiguration {
        var c = ExportConfiguration()
        c.endpoint = endpoint
        c.mode = mode
        c.includeRollups = rollups
        c.includeAlerts = alerts
        c.includeHostName = hostName
        return c
    }

    private func build(_ c: ExportConfiguration, headers: [String: String] = [:]) -> ExportDisclosure {
        ExportDisclosure.build(configuration: c, headers: headers)!
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "flowlight.disclosure.tests.\(UUID().uuidString)")!
    }

    // MARK: Consent is tied to what was disclosed

    func testApprovingOneEndpointDoesNotApproveAnother() {
        let d = defaults()
        ExportDisclosure.approve(build(config()), defaults: d)
        let elsewhere = build(config(endpoint: "https://somewhere-else.example/v1"))
        XCTAssertFalse(ExportDisclosure.isApproved(elsewhere, defaults: d),
                       "consent for one collector must not travel to another")
    }

    /// The case the whole design exists for: approving a TLS endpoint must not authorise the same fields going
    /// to the same host in the clear.
    func testApprovingHTTPSDoesNotApproveCleartext() {
        let d = defaults()
        ExportDisclosure.approve(build(config(endpoint: "https://collector.example/v1")), defaults: d)
        let cleartext = build(config(endpoint: "http://collector.example/v1"))
        XCTAssertFalse(ExportDisclosure.isApproved(cleartext, defaults: d))
    }

    func testApprovingFewerFieldsDoesNotApproveMore() {
        let d = defaults()
        ExportDisclosure.approve(build(config(alerts: false)), defaults: d)
        XCTAssertFalse(ExportDisclosure.isApproved(build(config(alerts: true)), defaults: d))
    }

    func testTurningOnTheHostNameNeedsApprovingAgain() {
        let d = defaults()
        ExportDisclosure.approve(build(config(hostName: false)), defaults: d)
        XCTAssertFalse(ExportDisclosure.isApproved(build(config(hostName: true)), defaults: d),
                       "naming the machine is exactly the kind of change someone would want to be asked about")
    }

    /// A header is credentials or routing added to the request; adding one changes what is sent.
    func testAddingAHeaderNeedsApprovingAgain() {
        let d = defaults()
        ExportDisclosure.approve(build(config()), defaults: d)
        XCTAssertFalse(ExportDisclosure.isApproved(build(config(), headers: ["X-Team": "blue"]), defaults: d))
    }

    /// The value is in the Keychain and the disclosure never shows it, so rotating a token is not a change to
    /// what leaves — asking again would train people to click through.
    func testChangingAHeaderValueDoesNotNeedApprovingAgain() {
        let d = defaults()
        ExportDisclosure.approve(build(config(), headers: ["Authorization": "Bearer old"]), defaults: d)
        XCTAssertTrue(ExportDisclosure.isApproved(build(config(), headers: ["Authorization": "Bearer new"]), defaults: d))
    }

    func testApprovingIsStableAcrossRebuilds() {
        let d = defaults()
        ExportDisclosure.approve(build(config()), defaults: d)
        XCTAssertTrue(ExportDisclosure.isApproved(build(config()), defaults: d),
                      "the same settings must not ask again on every launch")
    }

    func testNothingIsApprovedToBeginWith() {
        XCTAssertFalse(ExportDisclosure.isApproved(build(config()), defaults: defaults()))
    }

    func testSwitchingOffWithdrawsApproval() {
        let d = defaults()
        ExportDisclosure.approve(build(config()), defaults: d)
        ExportDisclosure.withdraw(defaults: d)
        XCTAssertFalse(ExportDisclosure.isApproved(build(config()), defaults: d),
                       "turning export on again is a fresh decision")
    }

    func testNoEndpointCannotBeApproved() {
        XCTAssertNil(ExportDisclosure.build(configuration: config(endpoint: ""), headers: [:]))
        XCTAssertFalse(ExportDisclosure.isApproved(nil, defaults: defaults()))
    }

    // MARK: What it says

    func testItNamesTheFieldsThatWillTravelNotEveryFieldThatCould() {
        let everything = build(config()).fieldCount
        let alertsOnly = build(config(rollups: false)).fieldCount
        XCTAssertLessThan(alertsOnly, everything)
        XCTAssertLessThanOrEqual(everything, ExportField.allCases.count)
    }

    /// The counters leave the Mac under OTLP too — they ride inside the data points instead of being named
    /// attributes. A list that dropped them would be describing JSON shape rather than exposure.
    func testCountersAreDisclosedInBothFormats() {
        for mode in ExportMode.allCases {
            let keys = build(config(mode: mode)).items.map(\.key)
            XCTAssertTrue(keys.contains(ExportField.bytesSent.rawValue), "\(mode) omitted the byte counts")
            XCTAssertTrue(keys.contains(ExportField.flows.rawValue), "\(mode) omitted the flow counts")
        }
    }

    func testEveryDisclosedFieldExplainsItself() {
        for item in build(config()).items {
            XCTAssertFalse(item.what.isEmpty, "\(item.key) is disclosed with no explanation")
        }
    }

    func testTheThreeResourceFieldsAreMarkedAsSentOncePerRequest() {
        let items = build(config()).items
        let perRequest = Set(items.filter(\.perRequest).map(\.key))
        XCTAssertEqual(perRequest, [ExportField.serviceName.rawValue, ExportField.serviceVersion.rawValue,
                                    ExportField.hostName.rawValue])
    }

    func testCleartextIsReportedAsSuch() {
        XCTAssertFalse(build(config(endpoint: "http://collector.example/v1")).encrypted)
        XCTAssertTrue(build(config(endpoint: "https://collector.example/v1")).encrypted)
    }

    /// Header names are disclosed so you know what is attached; values are not, because a screen that printed a
    /// token to prove it was being sent would be the thing it warns about.
    func testHeaderNamesAreDisclosedAndValuesAreNot() {
        let d = build(config(), headers: ["Authorization": "Bearer sk-secret-value"])
        XCTAssertEqual(d.headerNames, ["Authorization"])
        XCTAssertFalse("\(d)".contains("sk-secret-value"))
    }

    func testTheSummaryNamesTheHostAndTheFieldCount() {
        let d = build(config())
        XCTAssertTrue(d.summary.contains("collector.example"), d.summary)
        XCTAssertTrue(d.summary.contains("\(d.fieldCount)"), d.summary)
    }
}
