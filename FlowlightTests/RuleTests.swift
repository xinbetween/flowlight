import XCTest
@testable import Flowlight

/// The rule engine, which decides whether a connection happens. Everything here is plain data in and a verdict
/// out, so the whole of it can be checked without a filter, a proxy or a database.
final class RuleTests: XCTestCase {
    private let session = "this-run"

    private func facts(app: String = "com.example.app", agent: String = "com.example.app",
                       host: String = "api.example.com", ip: String = "93.184.216.34",
                       port: UInt16 = 443, settled: Bool = true) -> FlowFacts {
        FlowFacts(agentKey: agent, bundleID: app, host: host, ip: ip, port: port, hostSettled: settled)
    }

    // MARK: Subjects

    func testADestinationAloneIsARule() {
        let rule = Rule(action: .block, destination: "example.com")
        XCTAssertTrue(rule.isComplete)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [rule], session: session).verdict, .block)
    }

    func testAnAppAloneIsARule() {
        let rule = Rule(action: .block, app: "com.example.app")
        XCTAssertEqual(RuleBook.decide(facts(host: "anywhere.test"), rules: [rule], session: session).verdict, .block)
    }

    func testARuleThatNamesNothingDecidesNothing() {
        let rule = Rule(action: .block)
        XCTAssertFalse(rule.isComplete)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [rule], session: session).verdict, .allow)
    }

    func testADomainCarriesItsSubdomains() {
        let rule = Rule(action: .block, destination: "example.com")
        XCTAssertTrue(rule.matches(facts(host: "api.example.com")))
        XCTAssertTrue(rule.matches(facts(host: "example.com")))
        XCTAssertFalse(rule.matches(facts(host: "notexample.com")))
    }

    func testNamingAnAgentCoversTheToolsItStarted() {
        let rule = Rule(action: .block, app: "claude")
        // curl, started by Claude Code: its own bundle id is curl's, its agent key is the agent's.
        XCTAssertTrue(rule.matches(facts(app: "curl", agent: "claude")))
    }

    func testACIDRRangeMatchesByAddress() {
        let rule = Rule(action: .block, destination: "10.0.0.0/8")
        XCTAssertTrue(rule.matches(facts(host: "", ip: "10.3.4.5")))
        XCTAssertFalse(rule.matches(facts(host: "", ip: "11.3.4.5")))
    }

    // MARK: Which rule wins

    func testTheNarrowerExceptionBeatsTheBroaderBlock() {
        let block = Rule(action: .block, destination: "example.com")
        let allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        let decision = RuleBook.decide(facts(), rules: [block, allow], session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertEqual(decision.rule?.id, allow.id)
    }

    func testAnExceptionCannotBeWidenedByAccident() {
        // The exception is broader than the block, so it does not get to overrule it.
        let allow = Rule(action: .allow, destination: "example.com")
        let block = Rule(action: .block, app: "com.example.app", destination: "api.example.com")
        XCTAssertEqual(RuleBook.decide(facts(), rules: [allow, block], session: session).verdict, .block)
    }

    func testEqualReachGoesToTheBlock() {
        let allow = Rule(action: .allow, destination: "example.com")
        let block = Rule(action: .block, destination: "example.com")
        XCTAssertEqual(RuleBook.decide(facts(), rules: [allow, block], session: session).verdict, .block)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [block, allow], session: session).verdict, .block)
    }

    func testAnExactAddressIsNarrowerThanADomain() {
        let block = Rule(action: .block, destination: "example.com")
        let allow = Rule(action: .allow, destination: "93.184.216.34")
        XCTAssertEqual(RuleBook.decide(facts(), rules: [block, allow], session: session).verdict, .allow)
    }

    func testNoRuleMeansNoOpinion() {
        let rule = Rule(action: .block, destination: "elsewhere.test")
        let decision = RuleBook.decide(facts(), rules: [rule], session: session)
        XCTAssertEqual(decision.verdict, .allow)
        XCTAssertNil(decision.rule, "an allow with no rule behind it must not look like an exception")
    }

    // MARK: Waiting for a name

    func testAFlowWithNoHostYetIsUndecided() {
        let rule = Rule(action: .block, destination: "example.com")
        let pending = facts(host: "", settled: false)
        XCTAssertEqual(RuleBook.decide(pending, rules: [rule], session: session).verdict, .undecided)
    }

    func testAFlowThatWillNeverHaveAHostIsJudgedOnItsAddress() {
        let rule = Rule(action: .block, destination: "example.com")
        let settled = facts(host: "", settled: true)
        XCTAssertEqual(RuleBook.decide(settled, rules: [rule], session: session).verdict, .allow)
    }

    // MARK: Schedules

    func testUntilAMomentStopsAtIt() {
        let now = Date()
        let schedule = Rule.Schedule.expiring(in: 60, from: now)
        XCTAssertTrue(schedule.isActive(at: now, session: session))
        XCTAssertFalse(schedule.isActive(at: now.addingTimeInterval(61), session: session))
        XCTAssertTrue(schedule.isExpired(at: now.addingTimeInterval(61), session: session))
    }

    func testASessionRuleIsOverInTheNextRun() {
        let schedule = Rule.Schedule.thisSession(session)
        XCTAssertTrue(schedule.isActive(at: Date(), session: session))
        XCTAssertFalse(schedule.isActive(at: Date(), session: "a-later-run"))
        XCTAssertTrue(schedule.isExpired(at: Date(), session: "a-later-run"))
    }

    private func moment(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 4 January 2026 is a Sunday, so weekday 1 lands on the 4th.
        var parts = DateComponents(year: 2026, month: 1, day: 3 + weekday, hour: hour, minute: minute)
        parts.timeZone = calendar.timeZone
        return calendar.date(from: parts)!
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAWindowIsOpenOnlyInsideItsHours() {
        let schedule = Rule.Schedule(kind: .window, days: [], start: 9 * 60, end: 17 * 60)
        XCTAssertTrue(schedule.isActive(at: moment(weekday: 2, hour: 10), session: session, calendar: utc))
        XCTAssertFalse(schedule.isActive(at: moment(weekday: 2, hour: 8), session: session, calendar: utc))
        XCTAssertFalse(schedule.isActive(at: moment(weekday: 2, hour: 17), session: session, calendar: utc),
                       "the end of a window is not inside it")
    }

    func testAWindowKeepsToItsChosenDays() {
        let weekdays = Rule.Schedule(kind: .window, days: [2, 3, 4, 5, 6], start: 9 * 60, end: 17 * 60)
        XCTAssertTrue(weekdays.isActive(at: moment(weekday: 2, hour: 10), session: session, calendar: utc))
        XCTAssertFalse(weekdays.isActive(at: moment(weekday: 1, hour: 10), session: session, calendar: utc))
    }

    func testAWindowThatCrossesMidnightBelongsToTheDayItOpened() {
        // Monday evening through Tuesday morning: chosen day is Monday (weekday 2) alone.
        let night = Rule.Schedule(kind: .window, days: [2], start: 22 * 60, end: 6 * 60)
        XCTAssertTrue(night.isActive(at: moment(weekday: 2, hour: 23), session: session, calendar: utc))
        XCTAssertTrue(night.isActive(at: moment(weekday: 3, hour: 2), session: session, calendar: utc),
                      "the small hours are still Monday night's window")
        XCTAssertFalse(night.isActive(at: moment(weekday: 3, hour: 23), session: session, calendar: utc))
        XCTAssertFalse(night.isActive(at: moment(weekday: 2, hour: 12), session: session, calendar: utc))
    }

    func testAWindowIsNeverExpired() {
        let schedule = Rule.Schedule(kind: .window, days: [], start: 9 * 60, end: 17 * 60)
        XCTAssertFalse(schedule.isExpired(at: moment(weekday: 2, hour: 3), session: session),
                       "a closed window comes back tomorrow")
    }

    func testAScheduledRuleOutsideItsHoursDecidesNothing() {
        var rule = Rule(action: .block, destination: "example.com")
        rule.schedule = Rule.Schedule(kind: .window, days: [], start: 9 * 60, end: 17 * 60)
        let asleep = moment(weekday: 2, hour: 3)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [rule], now: asleep, session: session).verdict, .allow)
    }

    // MARK: The escape hatch

    func testPausingStandsEveryRuleDown() {
        let rule = Rule(action: .block, destination: "example.com")
        let now = Date()
        let decision = RuleBook.decide(facts(), rules: [rule], now: now, session: session,
                                       pausedUntil: now.addingTimeInterval(600))
        XCTAssertEqual(decision.verdict, .undecided, "a paused rule has no opinion, rather than an opinion of allow")
        XCTAssertNil(decision.rule)
    }

    func testAPauseThatHasRunOutIsOver() {
        let rule = Rule(action: .block, destination: "example.com")
        let now = Date()
        XCTAssertEqual(RuleBook.decide(facts(), rules: [rule], now: now, session: session,
                                       pausedUntil: now.addingTimeInterval(-1)).verdict, .block)
    }

    // MARK: One-off allowances

    func testAnAllowOnceIsSpentAfterOneUse() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let block = Rule(action: .block, destination: "example.com")
        XCTAssertEqual(RuleBook.decide(facts(), rules: [block, allow], session: session).verdict, .allow)
        allow.hits = 1
        XCTAssertFalse(allow.isUsable)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [block, allow], session: session).verdict, .block)
    }

    // MARK: Which engine can carry a rule out

    func testAPathMakesItTheProxysJob() {
        XCTAssertEqual(Rule(action: .block, destination: "example.com").engine, .flow)
        var rule = Rule(action: .block, destination: "example.com")
        rule.path = "/v1/*"
        XCTAssertEqual(rule.engine, .request)
    }

    func testAPathRuleIsNeverAppliedToAWholeConnection() {
        var rule = Rule(action: .block, destination: "example.com")
        rule.path = "/v1/admin"
        XCTAssertEqual(RuleBook.decide(facts(), rules: [rule], session: session).verdict, .allow,
                       "refusing the whole host in a path rule's name would block far more than was asked")
    }

    func testARequestRuleMatchesItsPathAndMethod() {
        var rule = Rule(action: .block, destination: "example.com")
        rule.path = "/v1/*"
        rule.method = "POST"
        let hit = RuleBook.decideRequest(facts(), path: "/v1/messages", method: "POST", rules: [rule], session: session)
        XCTAssertEqual(hit.verdict, .block)
        XCTAssertEqual(RuleBook.decideRequest(facts(), path: "/v1/messages", method: "GET", rules: [rule], session: session).verdict,
                       .undecided)
        XCTAssertEqual(RuleBook.decideRequest(facts(), path: "/v2/messages", method: "POST", rules: [rule], session: session).verdict,
                       .undecided)
    }

    func testARuleSaysSoWhenItsEngineIsntThere() {
        var request = Rule(action: .block, destination: "example.com")
        request.path = "/v1/*"
        let flow = Rule(action: .block, destination: "example.com")
        XCTAssertEqual(RuleBook.unenforceable([flow, request], extensionRunning: false, inspecting: true).map(\.id), [flow.id])
        XCTAssertEqual(RuleBook.unenforceable([flow, request], extensionRunning: true, inspecting: false).map(\.id), [request.id])
        XCTAssertTrue(RuleBook.unenforceable([flow, request], extensionRunning: true, inspecting: true).isEmpty)
        XCTAssertNotNil(flow.limitation(extensionRunning: false, inspecting: true))
        XCTAssertNil(flow.limitation(extensionRunning: true, inspecting: false))
    }

    // MARK: Storing them

    func testARuleSurvivesARoundTrip() throws {
        var rule = Rule(action: .block, app: "claude", destination: "example.com")
        rule.schedule = Rule.Schedule(kind: .window, days: [2, 3], start: 60, end: 120)
        rule.hits = 4
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded, rule)
    }

    func testARefusalCarriesAReadableAnswer() {
        var rule = Rule(action: .block, destination: "example.com")
        rule.path = "/v1/*"
        rule.status = 403
        let text = String(decoding: rule.asRefusal().responseBytes(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403 Forbidden"))
        XCTAssertTrue(text.contains("X-Flowlight-Blocked:"), "a refusal must not call itself a mock")
        XCTAssertTrue(text.contains("blocked by Flowlight"))
    }

    func testARefusalForAnAppWithNoDestinationUsesTheHostItArrivedOn() {
        var rule = Rule(action: .block, app: "claude")
        rule.path = "/v1/*"
        XCTAssertEqual(rule.asRefusal(host: "api.anthropic.com").host, "api.anthropic.com")
    }
}
