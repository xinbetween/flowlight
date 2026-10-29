import XCTest
@testable import Flowlight

/// The rule engine, which decides whether a connection happens. Everything here is plain data in and a verdict
/// out, so the whole of it can be checked without a filter, a proxy or a database.
@MainActor
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

    func testAnExactHostDoesNotCarryItsSubdomains() {
        let rule = Rule(action: .block, destination: "api.example.com", destinationMatch: .exact)
        XCTAssertTrue(rule.matches(facts(host: "API.EXAMPLE.COM.")))
        XCTAssertFalse(rule.matches(facts(host: "child.api.example.com")))
        XCTAssertFalse(rule.matches(facts(host: "example.com")))
    }

    func testAnExactAllowBeatsABroaderSuffixBlock() {
        let block = Rule(action: .block, destination: "example.com")
        let allow = Rule(action: .allow, destination: "api.example.com", destinationMatch: .exact)
        XCTAssertEqual(RuleBook.decide(facts(), rules: [block, allow], session: session).verdict, .allow)
    }

    func testLegacyProductAnalyticsPresetRuleStopsBlockingTheProduct() throws {
        let json = Data(#"{"action":"block","destination":"mixpanel.com","origin":"preset","name":"no product analytics"}"#.utf8)
        var legacy = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(legacy.presetID, "telemetry.product-analytics")
        XCTAssertFalse(legacy.matches(facts(host: "mixpanel.com")))
        XCTAssertFalse(legacy.matches(facts(host: "app.mixpanel.com")))
        XCTAssertTrue(legacy.matches(facts(host: "api.mixpanel.com")))
        XCTAssertFalse(legacy.matches(facts(host: "child.api.mixpanel.com")))
        legacy.name = "My analytics policy"
        XCTAssertFalse(legacy.matches(facts(host: "app.mixpanel.com")), "renaming must not restore the broad block")
        XCTAssertTrue(legacy.matches(facts(host: "api.mixpanel.com")))
    }

    func testLegacyAppScopedProductAnalyticsRuleKeepsItsScope() throws {
        let json = Data(#"{"action":"block","app":"com.example.app","destination":"amplitude.com","origin":"preset","name":"Example: no product analytics"}"#.utf8)
        let legacy = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertTrue(legacy.matches(facts(host: "api2.amplitude.com")))
        XCTAssertFalse(legacy.matches(facts(app: "com.example.other", agent: "com.example.other",
                                            host: "api2.amplitude.com")))
    }

    func testTypedAndRenamedBroadRulesKeepTheirAuthoredMeaning() {
        let typed = Rule(action: .block, destination: "mixpanel.com")
        let renamed = Rule(action: .block, destination: "mixpanel.com", origin: .preset, name: "My block")
        XCTAssertTrue(typed.matches(facts(host: "app.mixpanel.com")))
        XCTAssertTrue(renamed.matches(facts(host: "app.mixpanel.com")))
    }

    func testLegacySharedProductRuleWithNoSafeCollectorIsRetired() throws {
        let json = Data(#"{"action":"block","destination":"segment.com","origin":"preset","name":"no product analytics"}"#.utf8)
        let legacy = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertFalse(legacy.matches(facts(host: "segment.com")))
        XCTAssertFalse(legacy.matches(facts(host: "app.segment.com")))
    }

    func testEveryLegacyProductAnalyticsMappingLeavesTheBroadProductDomainReachable() {
        for (domain, collectors) in Rule.legacyProductAnalyticsReplacements {
            let legacy = Rule(action: .block, destination: domain, origin: .preset,
                              presetID: "telemetry.product-analytics", name: "no product analytics")
            XCTAssertFalse(legacy.matches(facts(host: domain)), domain)
            XCTAssertFalse(legacy.matches(facts(host: "app.\(domain)")), domain)
            for collector in collectors {
                XCTAssertTrue(legacy.matches(facts(host: collector)), "\(domain) must retain \(collector)")
                XCTAssertFalse(legacy.matches(facts(host: "child.\(collector)")),
                               "legacy collector \(collector) must be exact")
            }
        }
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

    func testLiveProxyConsumesFiniteHitRulesExactlyOnce() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let block = Rule(action: .block, destination: "example.com")
        let live = LiveRules()
        live.replace([block, allow], pausedUntil: nil)

        let first = live.flowDecision(facts())
        XCTAssertEqual(first.decision.rule?.id, allow.id)
        XCTAssertEqual(first.decision.verdict, .allow)
        XCTAssertNil(first.externalClaim)

        let second = live.flowDecision(facts())
        XCTAssertEqual(second.decision.rule?.id, block.id)
        XCTAssertEqual(second.decision.verdict, .block)
    }

    func testLiveProxyCanPreviewAndReconcileAnExtensionClaim() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let block = Rule(action: .block, destination: "example.com")
        let live = LiveRules()
        live.replace([block, allow], pausedUntil: nil, generation: 7)
        _ = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [block, allow], generation: 7, session: RuleStore.session)
        )

        let preview = live.flowDecision(facts())
        XCTAssertEqual(preview.decision.rule?.id, allow.id)
        XCTAssertEqual(preview.externalClaim, RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 7))
        live.markBoundedRuleClaimed(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 7))
        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, block.id)

        live.replace([block, allow], pausedUntil: nil, generation: 8)
        live.markBoundedRuleSpent(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 8))
        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, block.id)
    }

    func testOrdinaryPublicationCannotReopenAConsumedFiniteRule() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 2
        let block = Rule(action: .block, destination: "example.com")
        let live = LiveRules()
        live.replace([block, allow], pausedUntil: nil, generation: 1)

        live.markBoundedRuleClaimed(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 1))
        live.markBoundedRuleClaimed(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 1))
        live.replace([block, allow], pausedUntil: nil, generation: 2)

        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, block.id)
    }

    func testExplicitResetMayLowerALiveFiniteRuleCount() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let block = Rule(action: .block, destination: "example.com")
        let live = LiveRules()
        live.replace([block, allow], pausedUntil: nil, generation: 1)
        live.markBoundedRuleClaimed(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 1))

        live.replace([block, allow], pausedUntil: nil, generation: 2, resetHitCounts: [allow.id])

        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, allow.id)
    }

    func testStaleClaimRepliesDoNotUndoAnExplicitReset() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let live = LiveRules()
        live.replace([allow], pausedUntil: nil, generation: 4)
        _ = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [allow], generation: 4, session: RuleStore.session)
        )
        let stale = try! XCTUnwrap(live.flowDecision(facts()).externalClaim)

        live.replace([allow], pausedUntil: nil, generation: 5, resetHitCounts: [allow.id])
        live.markBoundedRuleClaimed(stale)
        live.markBoundedRuleSpent(stale)

        XCTAssertEqual(live.flowDecision(facts()).externalClaim,
                       RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 5))
    }

    func testExtensionClaimSurvivesAnUnrelatedRuleEdit() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let unrelated = Rule(action: .block, destination: "other.example.com")
        let set = RuleSet(rules: [allow, unrelated], generation: 5, session: RuleStore.session,
                          ruleInvalidatedAt: [allow.id: 1, unrelated.id: 5])

        XCTAssertTrue(
            set.accepts(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 1))
        )
    }

    func testExtensionClaimDoesNotSurviveSameRuleInvalidation() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let set = RuleSet(rules: [allow], generation: 5, session: RuleStore.session,
                          ruleInvalidatedAt: [allow.id: 5])

        XCTAssertFalse(
            set.accepts(RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 4))
        )
    }

    func testClaimReplySurvivesAnUnrelatedRuleEdit() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let unrelated = Rule(action: .block, destination: "other.example.com")
        let live = LiveRules()
        live.replace([allow, unrelated], pausedUntil: nil, generation: 4)
        _ = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [allow, unrelated], generation: 4, session: RuleStore.session)
        )
        let claim = try! XCTUnwrap(live.flowDecision(facts()).externalClaim)

        var edited = unrelated
        edited.name = "Edited"
        live.replace(
            [allow, edited],
            pausedUntil: nil,
            generation: 5,
            ruleInvalidatedAt: [unrelated.id: 5]
        )
        live.markBoundedRuleClaimed(claim)

        XCTAssertNil(live.flowDecision(facts()).externalClaim)
    }

    @MainActor
    func testStaleRuleEventDoesNotUndoAnExplicitReset() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let live = LiveRules()
        let store = RuleStore()
        store.save(allow)
        let staleGeneration = store.ruleSet.generation
        store.resetHits(allow)

        store.record([
            RuleEvent(
                at: 1_700_000_000,
                ruleID: allow.id,
                ruleSession: RuleStore.session,
                ruleGeneration: staleGeneration,
                action: .allow,
                engine: .flow,
                agentKey: "com.example.app",
                agentName: "Example",
                appName: "Example",
                bundleID: "com.example.app",
                host: "api.example.com",
                ip: "",
                port: 443
            ),
        ])
        live.replace(store.rules, pausedUntil: nil, generation: store.ruleSet.generation)

        XCTAssertEqual(store.rules.first?.hits, 0)
        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, allow.id)
    }

    func testStaleRuleEventIsNotPersistedAfterReset() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-stale-event-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        store.save(allow)
        let staleGeneration = store.ruleSet.generation
        store.resetHits(allow)

        store.record([
            RuleEvent(
                at: 1_700_000_000,
                ruleID: allow.id,
                ruleSession: RuleStore.session,
                ruleGeneration: staleGeneration,
                action: .allow,
                engine: .flow,
                agentKey: "com.example.app",
                agentName: "Example",
                appName: "Example",
                bundleID: "com.example.app",
                host: "api.example.com",
                ip: "",
                port: 443
            ),
        ])
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(try db.sync { try $0.ruleEvents(limit: 10).isEmpty })
        XCTAssertTrue(store.events.isEmpty)
    }

    @MainActor
    func testRuleEventSurvivesAnUnrelatedRuleEdit() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        var unrelated = Rule(action: .block, destination: "other.example.com")
        let store = RuleStore()
        store.save(allow)
        let claimGeneration = store.ruleSet.generation
        store.save(unrelated)
        unrelated.name = "Edited"
        store.save(unrelated)

        store.record([
            RuleEvent(
                at: 1_700_000_000,
                ruleID: allow.id,
                ruleSession: RuleStore.session,
                ruleGeneration: claimGeneration,
                action: .allow,
                engine: .flow,
                agentKey: "com.example.app",
                agentName: "Example",
                appName: "Example",
                bundleID: "com.example.app",
                host: "api.example.com",
                ip: "",
                port: 443
            ),
        ])

        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
    }

    func testPublishedRuleEventsClearAfterDurableDeletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-events-published-clear-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }
        let rule = Rule(action: .block, destination: "example.com")
        store.save(rule)
        store.record([
            RuleEvent(
                at: 1_700_000_000,
                ruleID: rule.id,
                action: .block,
                engine: .flow,
                agentKey: "com.example.app",
                agentName: "Example",
                appName: "Example",
                bundleID: "com.example.app",
                host: "example.com",
                ip: "",
                port: 443
            ),
        ])
        try await waitUntil { !store.events.isEmpty }
        XCTAssertEqual(store.events.count, 1)

        try await db.asyncResult { try $0.clearAll() }
        store.clearPublishedEventsAfterDurableDeletion()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(try db.sync { try $0.ruleEvents(limit: 10).isEmpty })
    }

    func testAcceptedBoundedClaimPersistsCountAndEventBeforeCompletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-accepted-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }

        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        store.save(allow)
        let claim = RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: store.ruleSet.generation)
        let event = RuleEvent(
            at: 1_700_000_000,
            ruleID: allow.id,
            ruleSession: claim.session,
            ruleGeneration: claim.generation,
            action: .allow,
            engine: .flow,
            agentKey: "com.example.app",
            agentName: "Example",
            appName: "Example",
            bundleID: "com.example.app",
            host: "api.example.com",
            ip: "",
            port: 443
        )
        let completed = expectation(description: "accepted claim committed")

        store.recordBoundedClaim(claim, event: event) { persisted in
            XCTAssertTrue(persisted)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)

        let loaded = try db.sync { try $0.loadRules() }
        XCTAssertEqual(loaded.first(where: { $0.id == allow.id })?.hits, 1)
        XCTAssertEqual(try db.sync { try $0.ruleEvents(ruleID: allow.id).count }, 1)
        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
        XCTAssertNil(store.live.flowDecision(facts()).externalClaim)
    }

    func testAcceptedBoundedClaimFailsOpenWhenDurableStorageIsUnavailable() async {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let store = RuleStore()
        store.save(allow)
        let claim = RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: store.ruleSet.generation)
        let event = RuleEvent(
            at: 1_700_000_000,
            ruleID: allow.id,
            ruleSession: claim.session,
            ruleGeneration: claim.generation,
            action: .allow,
            engine: .flow,
            agentKey: "com.example.app",
            agentName: "Example",
            appName: "Example",
            bundleID: "com.example.app",
            host: "api.example.com",
            ip: "",
            port: 443
        )
        let completed = expectation(description: "accepted claim failed open")

        store.recordBoundedClaim(claim, event: event) { persisted in
            XCTAssertFalse(persisted)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
        XCTAssertNil(store.live.flowDecision(facts()).externalClaim)
    }

    func testUncertainClaimFailsOpenWhenDurableStorageIsUnavailable() async {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let store = RuleStore()
        store.save(allow)
        let claim = RuleClaim(
            ruleID: allow.id,
            session: RuleStore.session,
            generation: store.ruleSet.generation
        )
        let completed = expectation(description: "retirement completed")

        store.retireBoundedClaim(claim) { result in
            XCTAssertFalse(result)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
        XCTAssertNil(store.live.flowDecision(facts()).externalClaim)
    }

    func testUncertainClaimIsPersistedSpentBeforeCompletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-uncertain-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }

        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        store.save(allow)
        let claim = RuleClaim(
            ruleID: allow.id,
            session: RuleStore.session,
            generation: store.ruleSet.generation
        )
        let persisted = expectation(description: "uncertain claim persisted")

        store.retireBoundedClaim(claim) { saved in
            XCTAssertTrue(saved)
            persisted.fulfill()
        }
        await fulfillment(of: [persisted], timeout: 2)

        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
        let loaded = try db.sync { try $0.loadRules() }
        XCTAssertEqual(loaded.first(where: { $0.id == allow.id })?.hits, 1)
    }

    func testUncertainClaimSurvivesAnUnrelatedEditAndPersistsSpent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-unrelated-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }

        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        var unrelated = Rule(action: .block, destination: "other.example.com")
        store.save(allow)
        let claim = RuleClaim(
            ruleID: allow.id,
            session: RuleStore.session,
            generation: store.ruleSet.generation
        )
        store.save(unrelated)
        unrelated.name = "Edited"
        store.save(unrelated)
        let persisted = expectation(description: "claim persisted across unrelated edit")

        store.retireBoundedClaim(claim) { saved in
            XCTAssertTrue(saved)
            persisted.fulfill()
        }
        await fulfillment(of: [persisted], timeout: 2)

        XCTAssertEqual(store.rules.first(where: { $0.id == allow.id })?.hits, 1)
        let loaded = try db.sync { try $0.loadRules() }
        XCTAssertEqual(loaded.first(where: { $0.id == allow.id })?.hits, 1)
    }

    func testExternalAuthorityReceivesLocallyConsumedHitsAtHandoff() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 2
        let live = LiveRules()
        live.replace([allow], pausedUntil: nil, generation: 12)
        XCTAssertEqual(live.flowDecision(facts()).decision.rule?.id, allow.id)

        let transferred = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [allow], generation: 12, session: RuleStore.session)
        )

        XCTAssertEqual(transferred.rules.first?.hits, 1)
        XCTAssertEqual(live.flowDecision(facts()).externalClaim,
                       RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 12))
    }

    func testExternalAuthorityRemainsStickyAcrossSourceFallback() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let live = LiveRules()
        live.replace([allow], pausedUntil: nil, generation: 12)
        _ = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [allow], generation: 12, session: RuleStore.session)
        )

        let afterFallback = live.flowDecision(facts())

        XCTAssertEqual(afterFallback.externalClaim,
                       RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 12))
        XCTAssertEqual(live.flowDecision(facts()).externalClaim,
                       afterFallback.externalClaim,
                       "fallback must fail open through unavailable claims, not resume a second counter")
    }

    func testRuleClaimRoundTripKeepsSessionIdentity() throws {
        let claim = RuleClaim(
            ruleID: UUID(),
            session: "new-app-process",
            generation: 1
        )

        let decoded = try JSONDecoder().decode(
            RuleClaim.self,
            from: JSONEncoder().encode(claim)
        )

        XCTAssertEqual(decoded, claim)
        XCTAssertNotEqual(
            decoded,
            RuleClaim(
                ruleID: claim.ruleID,
                session: "old-app-process",
                generation: claim.generation
            )
        )
    }

    func testExternalAuthorityOwnsFiniteRuleDuringSynchronization() {
        var allow = Rule(action: .allow, app: "com.example.app", destination: "api.example.com")
        allow.maxHits = 1
        let live = LiveRules()
        live.replace([allow], pausedUntil: nil, generation: 12)
        _ = live.beginExternalClaimAuthority(
            with: RuleSet(rules: [allow], generation: 12, session: RuleStore.session)
        )

        let first = live.flowDecision(facts())
        let second = live.flowDecision(facts())

        XCTAssertEqual(first.externalClaim, RuleClaim(ruleID: allow.id, session: RuleStore.session, generation: 12))
        XCTAssertEqual(second.externalClaim, first.externalClaim)
        XCTAssertEqual(second.decision.rule?.id, allow.id,
                       "the proxy must not spend independently while the extension owns the counter")
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition did not become true")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        var rule = Rule(action: .block, app: "claude", destination: "example.com", destinationMatch: .exact)
        rule.schedule = Rule.Schedule(kind: .window, days: [2, 3], start: 60, end: 120)
        rule.hits = 4
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(decoded, rule)
    }

    func testARuleStoredBeforeExactMatchingDefaultsToSuffix() throws {
        let json = Data(#"{"destination":"example.com","action":"block"}"#.utf8)
        let decoded = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(decoded.destinationMatch, .suffix)
        XCTAssertTrue(decoded.matches(facts(host: "api.example.com")))
    }

    func testSavingAWildcardDestinationSelectsSuffixMatching() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-wildcard-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RuleStore()
        store.attach(db: db)
        try await waitUntil { !store.rules.isEmpty || store.ruleSet.generation > 0 }
        let rule = Rule(action: .block, destination: "*.example.com", destinationMatch: .exact)

        store.save(rule)

        let saved = try XCTUnwrap(store.rules.first(where: { $0.id == rule.id }))
        XCTAssertEqual(saved.destination, "example.com")
        XCTAssertEqual(saved.destinationMatch, .suffix)
        XCTAssertTrue(saved.matches(facts(host: "api.example.com")))
    }

    func testRuleSetTransportPreservesExactMatching() throws {
        let set = RuleSet(rules: [Rule(action: .block, destination: "api.example.com", destinationMatch: .exact)])
        let decoded = try XCTUnwrap(BlockCoding.decode(RuleSet.self, from: BlockCoding.encode(set)))
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded.rules.first?.destinationMatch, .exact)
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
