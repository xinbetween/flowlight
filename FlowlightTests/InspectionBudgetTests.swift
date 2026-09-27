import XCTest
@testable import Flowlight

/// The budget is the only thing standing between "inspection is on" and a database full of other people's
/// credentials, so each limit is tested for the case it exists to stop rather than for the happy path.
final class InspectionBudgetTests: XCTestCase {

    private func headers(_ pairs: [(String, String)]) -> [HTTPHeader] {
        pairs.map { HTTPHeader(name: $0.0, value: $0.1) }
    }

    private func value(_ result: [HTTPHeader], _ name: String) -> String? {
        result.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: The allowlist

    func testAllowlistKeepsOnlyWhatItNames() {
        var budget = InspectionBudget()
        budget.headerPolicy = .allowlist
        budget.allowedHeaders = ["content-type"]
        let result = HeaderRedaction.redact(headers([
            ("Content-Type", "application/json"),
            ("X-Unusual-Vendor-Thing", "hunter2"),
        ]), budget: budget)

        XCTAssertEqual(value(result, "Content-Type"), "application/json")
        XCTAssertEqual(value(result, "X-Unusual-Vendor-Thing")?.contains("hunter2"), false,
                       "a header nobody allowed was stored in full")
    }

    /// The whole reason the allowlist exists: the denylist can only hide what somebody thought of, and a
    /// credential under an unfamiliar name went straight to disk.
    func testAllowlistHidesACredentialTheDenylistWouldMiss() {
        let invented = headers([("X-Acme-Entitlement", "super-secret-value")])

        var denylist = InspectionBudget()
        denylist.headerPolicy = .redactSecrets
        XCTAssertEqual(value(HeaderRedaction.redact(invented, budget: denylist), "X-Acme-Entitlement"),
                       "super-secret-value", "precondition: the denylist does not recognise this name")

        var allowlist = InspectionBudget()
        allowlist.headerPolicy = .allowlist
        XCTAssertEqual(value(HeaderRedaction.redact(invented, budget: allowlist), "X-Acme-Entitlement")?
                        .contains("super-secret-value"), false)
    }

    func testNamesSurviveEveryPolicySoTheRequestStillReads() {
        for policy in InspectionBudget.HeaderPolicy.allCases {
            var budget = InspectionBudget()
            budget.headerPolicy = policy
            budget.allowedHeaders = []
            let result = HeaderRedaction.redact(headers([("X-Thing", "value")]), budget: budget)
            XCTAssertEqual(result.count, 1, "\(policy) dropped a header instead of its value")
            XCTAssertNotNil(value(result, "X-Thing"))
        }
    }

    /// A withheld value still says how long it was: a shorter request than the one that happened would be a
    /// quieter lie than showing the secret.
    func testAWithheldValueStillReportsItsLength() {
        var budget = InspectionBudget()
        budget.headerPolicy = .none
        let result = HeaderRedaction.redact(headers([("X-Thing", "123456")]), budget: budget)
        XCTAssertEqual(value(result, "X-Thing")?.contains("6"), true)
    }

    func testKeepNothingKeepsNotEvenTheAuthorizationScheme() {
        var budget = InspectionBudget()
        budget.headerPolicy = .none
        let result = HeaderRedaction.redact(headers([("Authorization", "Bearer abc123")]), budget: budget)
        XCTAssertEqual(value(result, "Authorization")?.contains("Bearer"), false,
                       "a scheme is a header value, and this policy keeps none")
        XCTAssertEqual(value(result, "Authorization")?.contains("abc123"), false)
    }

    func testTheDenylistStillShowsTheSchemeSoTheCredentialKindIsVisible() {
        var budget = InspectionBudget()
        budget.headerPolicy = .redactSecrets
        let result = HeaderRedaction.redact(headers([("Authorization", "Bearer abc123")]), budget: budget)
        XCTAssertEqual(value(result, "Authorization")?.hasPrefix("Bearer"), true)
        XCTAssertEqual(value(result, "Authorization")?.contains("abc123"), false)
    }

    // MARK: Patterns of your own

    func testAnAddedWordRedactsAVendorSpellingNothingKnows() {
        var budget = InspectionBudget()
        budget.headerPolicy = .redactSecrets
        budget.extraSecretWords = ["entitlement"]
        let result = HeaderRedaction.redact(headers([("X-Acme-Entitlement", "secret")]), budget: budget)
        XCTAssertEqual(value(result, "X-Acme-Entitlement")?.contains("secret"), false)
    }

    /// The user's word beats the built-in exception list: they know their own headers, and `notSecret` was
    /// written without them in mind.
    func testAnAddedWordBeatsTheBuiltInException() {
        XCTAssertTrue(HeaderRedaction.notSecret.contains("x-request-id"), "precondition")
        XCTAssertFalse(HeaderRedaction.isSecret("x-request-id"))
        XCTAssertTrue(HeaderRedaction.isSecret("x-request-id", extraWords: ["request-id"]))
    }

    func testTheDefaultAllowlistCarriesNothingTheDenylistCallsASecret() {
        for name in InspectionBudget.defaultAllowedHeaders {
            XCTAssertFalse(HeaderRedaction.isSecret(name),
                           "\(name) is allowed by default but looks like a credential")
        }
    }

    /// A Referer can carry a token in its query string, which is how a secret reaches a place nobody was
    /// watching for one.
    func testRefererIsNotAllowedByDefault() {
        XCTAssertFalse(InspectionBudget.defaultAllowedHeaders.contains("referer"))
    }

    // MARK: Persistence

    func testSettingsSurviveARelaunch() throws {
        let defaults = UserDefaults(suiteName: "flowlight.budget.tests.\(UUID().uuidString)")!
        var budget = InspectionBudget()
        budget.headerPolicy = .none
        budget.allowedHeaders = ["content-type"]
        budget.extraSecretWords = ["licence"]
        budget.dailyBodyBytesPerApp = 25_000_000
        budget.retentionDays = 7
        budget.sessionMinutes = 120
        budget.save(defaults)

        XCTAssertEqual(InspectionBudget.load(defaults), budget)
    }

    /// "Allow nothing" is a decision, and the absence of the key is what means "use the defaults" — otherwise
    /// the strictest setting would quietly reset itself on the next launch.
    func testAnEmptyAllowlistIsNotMistakenForUnset() {
        let defaults = UserDefaults(suiteName: "flowlight.budget.tests.\(UUID().uuidString)")!
        var budget = InspectionBudget()
        budget.allowedHeaders = []
        budget.save(defaults)
        XCTAssertEqual(InspectionBudget.load(defaults).allowedHeaders, [])
    }

    func testAnUnsetStoreFallsBackToTheDefaults() {
        let defaults = UserDefaults(suiteName: "flowlight.budget.tests.\(UUID().uuidString)")!
        XCTAssertEqual(InspectionBudget.load(defaults).allowedHeaders, InspectionBudget.defaultAllowedHeaders)
    }

    func testRetentionNeverLoadsAsZeroDays() {
        let defaults = UserDefaults(suiteName: "flowlight.budget.tests.\(UUID().uuidString)")!
        defaults.set(0, forKey: InspectionBudget.Keys.retentionDays)
        XCTAssertGreaterThanOrEqual(InspectionBudget.load(defaults).retentionDays, 1,
                                    "zero days would prune everything the moment it was recorded")
    }

    // MARK: What the screen says

    /// The sentence this replaces was hardcoded, and went on saying "3 days" after the period became a setting.
    func testTheSummaryFollowsTheSettings() {
        var budget = InspectionBudget()
        budget.retentionDays = 7
        budget.headerPolicy = .none
        budget.dailyBodyBytesPerApp = 10_000_000
        budget.sessionMinutes = 90
        let summary = budget.summary

        XCTAssertTrue(summary.contains("7"), summary)
        XCTAssertFalse(summary.contains("3 days"), summary)
        XCTAssertTrue(summary.localizedCaseInsensitiveContains("no header values"), summary)
        XCTAssertTrue(summary.contains("90") || summary.localizedCaseInsensitiveContains("hour"), summary)
    }

    /// It said credential headers are "never stored". Their length is stored, and the match is a guess — the
    /// wording has to stop promising more than either of those.
    func testTheSummaryDoesNotPromiseHeadersAreNeverStored() {
        var budget = InspectionBudget()
        budget.headerPolicy = .redactSecrets
        XCTAssertFalse(budget.summary.localizedCaseInsensitiveContains("never stored"), budget.summary)
    }

    func testDurationReadsAsAPeriodSomebodyChose() {
        XCTAssertEqual(InspectionBudget.duration(minutes: 30), "30 minutes")
        XCTAssertEqual(InspectionBudget.duration(minutes: 60), "1 hour")
        XCTAssertEqual(InspectionBudget.duration(minutes: 90), "1 hour 30 minutes")
        XCTAssertEqual(InspectionBudget.duration(minutes: 480), "8 hours")
    }

    /// A session that runs until someone remembers is the failure this feature exists for, so the shipped
    /// default has to be a bounded one.
    func testInspectionExpiresByDefault() {
        XCTAssertGreaterThan(InspectionBudget().sessionMinutes, 0)
    }

    func testTheSaferHeaderPolicyIsTheDefault() {
        XCTAssertEqual(InspectionBudget().headerPolicy, .allowlist)
    }
}
