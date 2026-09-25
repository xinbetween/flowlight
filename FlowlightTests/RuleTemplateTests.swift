import XCTest
@testable import Flowlight

/// The rule library. A template is a promise made in prose and kept in data, so most of what is checked here is
/// that the two halves agree: that a template which says it needs an app does need one, that a template which
/// says it refuses the package registries writes rules that actually refuse them, and that nothing in the library
/// quietly writes a rule the running engine can't carry out without the copy saying so.
///
/// The domain lists get the same treatment as the rules. A blocklist is only as good as the day it was checked,
/// and the failures worth catching mechanically are the ones nobody would spot by reading: an entry already
/// covered by another entry, an entry the store would rewrite on the way in, an entry that is really a whole TLD.
@MainActor
final class RuleTemplateTests: XCTestCase {
    private let session = RuleStore.session

    private func facts(app: String = "com.example.agent", agent: String = "com.example.agent",
                       host: String, ip: String = "93.184.216.34", port: UInt16 = 443) -> FlowFacts {
        FlowFacts(agentKey: agent, bundleID: app, host: host, ip: ip, port: port, hostSettled: true)
    }

    private var subject: RuleTemplate.Subject {
        RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent", destination: "example.com")
    }

    // MARK: The library as a whole

    func testEveryTemplateHasAUniqueIdentifier() {
        let ids = RuleTemplate.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two templates share an id: \(ids.sorted())")
    }

    func testEveryTemplateHasAUniqueTitle() {
        let titles = RuleTemplate.all.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two templates share a title")
    }

    func testEveryTemplateSaysWhatItIsFor() {
        for template in RuleTemplate.all {
            XCTAssertFalse(template.title.isEmpty, template.id)
            XCTAssertGreaterThan(template.summary.count, 40, "\(template.id) has no real description")
        }
    }

    func testEveryCategoryHasSomethingInIt() {
        for category in RuleTemplate.Category.allCases {
            XCTAssertFalse(RuleTemplate.inCategory(category).isEmpty, "\(category.rawValue) is empty")
        }
    }

    func testTheLibraryIsTheSumOfItsCategories() {
        let grouped = RuleTemplate.Category.allCases.flatMap { RuleTemplate.inCategory($0) }
        XCTAssertEqual(Set(grouped.map(\.id)), Set(RuleTemplate.all.map(\.id)))
    }

    // MARK: Every template produces rules the engine will accept

    func testEveryTemplateWritesCompleteRules() {
        for template in RuleTemplate.all {
            let rules = template.rules(for: subject)
            XCTAssertFalse(rules.isEmpty, "\(template.id) wrote nothing even with a full subject")
            for rule in rules {
                XCTAssertTrue(rule.isComplete, "\(template.id) wrote a rule that names nothing: \(rule.title)")
            }
        }
    }

    /// A rule that names neither an app nor a destination would decide every connection on the Mac. `rules(for:)`
    /// filters incomplete rules out rather than handing one over, so an empty result is the only way a template
    /// can fail — never a rule that means more than it says.
    func testNoTemplateCanEverWriteARuleThatDecidesEverything() {
        let subjects = [RuleTemplate.Subject(),
                        RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent"),
                        RuleTemplate.Subject(destination: "example.com"),
                        subject]
        for template in RuleTemplate.all {
            for candidate in subjects {
                for rule in template.rules(for: candidate) {
                    XCTAssertTrue(rule.isComplete, "\(template.id) wrote an unbounded rule")
                }
            }
        }
    }

    func testEveryRuleCarriesAReadableName() {
        for template in RuleTemplate.all {
            for rule in template.rules(for: subject) {
                XCTAssertFalse(rule.name.isEmpty, "\(template.id) left a rule unnamed")
                XCTAssertFalse(rule.name.contains("  "), "\(template.id) has a gap where a name should be")
            }
        }
    }

    func testEveryRuleIsMarkedAsComingFromTheLibrary() {
        for template in RuleTemplate.all {
            for rule in template.rules(for: subject) {
                XCTAssertEqual(rule.origin, .preset, "\(template.id) doesn't say where it came from")
            }
        }
    }

    // MARK: What a template needs

    func testATemplateThatNeedsSomethingWritesNothingWithoutIt() {
        for template in RuleTemplate.all where template.needs != .nothing {
            XCTAssertTrue(template.rules(for: RuleTemplate.Subject()).isEmpty,
                          "\(template.id) wrote rules from an empty subject")
            XCTAssertFalse(template.isSatisfied(by: RuleTemplate.Subject()), template.id)
        }
    }

    func testATemplateThatNeedsAnAppIsNotSatisfiedByADestination() {
        let onlyDestination = RuleTemplate.Subject(destination: "example.com")
        for template in RuleTemplate.all where template.needs == .app || template.needs == .both {
            XCTAssertTrue(template.rules(for: onlyDestination).isEmpty, template.id)
        }
    }

    func testATemplateThatNeedsADestinationIsNotSatisfiedByAnApp() {
        let onlyApp = RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent")
        for template in RuleTemplate.all where template.needs == .destination || template.needs == .both {
            XCTAssertTrue(template.rules(for: onlyApp).isEmpty, template.id)
        }
    }

    func testATemplateThatNeedsNothingWritesRulesFromNothing() {
        for template in RuleTemplate.all where template.needs == .nothing {
            XCTAssertFalse(template.rules().isEmpty, "\(template.id) needs nothing but wrote nothing")
        }
    }

    func testFillingTheBlankNamesTheAppInEveryRule() {
        for template in RuleTemplate.all where template.needs == .app || template.needs == .both {
            for rule in template.rules(for: subject) {
                XCTAssertEqual(rule.app, subject.app, "\(template.id) dropped the app it was given")
            }
        }
    }

    func testScopingToAnAppNarrowsTheWholeMacTemplates() {
        for template in RuleTemplate.all where template.needs == .nothing && template.scopesToApp {
            let wide = template.rules()
            let narrow = template.rules(for: RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent"))
            XCTAssertEqual(wide.count, narrow.count, template.id)
            XCTAssertTrue(wide.allSatisfy { $0.app.isEmpty }, template.id)
            XCTAssertTrue(narrow.allSatisfy { $0.app == "com.example.agent" }, template.id)
        }
    }

    // MARK: What the engine can actually carry out

    /// The one thing the copy must never leave out. A rule that names a method is answered by the HTTPS
    /// inspection proxy and by nothing else — with inspection off it sits in the list watching, which is fine as
    /// long as the template said so before it was switched on.
    func testATemplateThatNeedsHTTPSInspectionSaysSo() {
        for template in RuleTemplate.all where template.engines(for: subject).contains(.request) {
            let copy = template.summary + " " + (template.caveat ?? "")
            XCTAssertTrue(copy.contains("HTTPS inspection"),
                          "\(template.id) writes request-level rules without saying inspection is needed")
        }
    }

    func testARequestLevelRuleIsOnlyEverOneThatNamesAMethodOrAPath() {
        for template in RuleTemplate.all {
            for rule in template.rules(for: subject) where rule.engine == .request {
                XCTAssertTrue(!rule.method.isEmpty || !rule.path.isEmpty, template.id)
            }
        }
    }

    func testTheOnlyRequestLevelTemplateIsTheReadOnlyGitHubOne() {
        let needsInspection = RuleTemplate.all.filter { $0.engines(for: subject).contains(.request) }.map(\.id)
        XCTAssertEqual(needsInspection, ["agent.github-read-only"])
    }

    // MARK: The domain lists

    private var allDestinations: [(template: String, destination: String)] {
        RuleTemplate.all.flatMap { template in
            template.rules(for: subject).filter { !$0.destination.isEmpty && $0.destination != subject.destination }
                .map { (template.id, $0.destination) }
        }
    }

    /// The store normalises a destination on the way in. Anything in the library that doesn't survive that round
    /// trip is a rule that would be saved as something other than what the card showed.
    func testEveryDestinationIsAlreadyNormalised() {
        for entry in allDestinations {
            XCTAssertEqual(RuleStore.cleaned(entry.destination), entry.destination,
                           "\(entry.template) lists \(entry.destination), which the store would rewrite")
        }
    }

    func testNoDestinationIsAWholeTopLevelDomain() {
        for entry in allDestinations {
            XCTAssertGreaterThanOrEqual(entry.destination.split(separator: ".").count, 2,
                                        "\(entry.template) lists a bare label: \(entry.destination)")
        }
    }

    /// A domain carries its subdomains, so listing both `crates.io` and `static.crates.io` writes a rule that can
    /// never decide anything. Harmless, but it makes the card lie about how much it is doing.
    func testNoDestinationIsAlreadyCoveredByAnotherInTheSameTemplate() {
        for template in RuleTemplate.all {
            let destinations = template.rules(for: subject).map(\.destination).filter { !$0.isEmpty }
            for candidate in destinations {
                for other in destinations where other != candidate {
                    XCTAssertFalse(candidate.hasSuffix("." + other),
                                   "\(template.id): \(candidate) is already covered by \(other)")
                }
            }
        }
    }

    /// Everything about a rule except who wrote it and when. Two rules that agree on all of this are one rule and
    /// a mistake; the same destination under two different methods, or the same app in two different windows, is
    /// neither — that is how "read but don't write" and "not at night or at the weekend" are said.
    private func signature(_ rule: Rule) -> String {
        let schedule = rule.schedule
        return [rule.action.rawValue, rule.app, rule.destination, rule.method, rule.path,
                schedule.kind.rawValue, schedule.days.map(String.init).joined(separator: ","),
                "\(schedule.start)", "\(schedule.end)"].joined(separator: "|")
    }

    func testNoTwoRulesInOneTemplateSayTheSameThing() {
        for template in RuleTemplate.all {
            let signatures = template.rules(for: subject).map(signature)
            XCTAssertEqual(Set(signatures).count, signatures.count, "\(template.id) writes the same rule twice")
        }
    }

    /// Two templates that write the same rules are one template with two names, which is the kind of thing a
    /// library accumulates and nobody notices from inside it.
    func testNoTwoTemplatesWriteTheSameRules() {
        var seen: [String: String] = [:]
        for template in RuleTemplate.all {
            let key = template.rules(for: subject).map(signature).sorted().joined(separator: "\n")
            if let other = seen[key] {
                XCTFail("\(template.id) and \(other) write the same rules")
            }
            seen[key] = template.id
        }
    }

    // MARK: Applying from a row

    /// Applying without a look is only allowed where the rule undoes itself. A permanent block that landed on one
    /// click would be exactly the rule nobody could find again.
    func testAnythingAppliedImmediatelyExpiresByItself() {
        for template in RuleTemplate.all where template.appliesImmediately {
            let rules = template.rules(for: subject)
            XCTAssertEqual(rules.count, 1, "\(template.id) applies at once but writes more than one rule")
            XCTAssertNotEqual(rules.first?.schedule.kind, .always,
                              "\(template.id) applies at once and never expires")
        }
    }

    func testMoreThanOneRuleAlwaysGoesThroughTheLibrary() {
        for template in RuleTemplate.all where template.rules(for: subject).count > 1 {
            XCTAssertEqual(template.arrival(for: subject), .list, template.id)
        }
    }

    func testASingleRuleThatDoesNotExpireOpensTheEditor() {
        for template in RuleTemplate.all {
            let rules = template.rules(for: subject)
            guard rules.count == 1, rules[0].schedule.kind == .always else { continue }
            XCTAssertEqual(template.arrival(for: subject), .editor, template.id)
        }
    }

    func testARowThatKnowsNothingIsOfferedNothing() {
        XCTAssertTrue(RuleTemplate.applicable(to: RuleTemplate.Subject()).isEmpty)
    }

    /// The reason a whole-Mac template shows up on a row at all: the row is where someone noticed the category.
    func testADestinationRowIsOfferedTheTemplateThatAlreadyCoversIt() {
        let segment = RuleTemplate.Subject(destination: "api.segment.io")
        let offered = RuleTemplate.applicable(to: segment).map(\.id)
        XCTAssertTrue(offered.contains("telemetry.product-analytics"), offered.description)
        XCTAssertFalse(offered.contains("exfil.paste-sites"), "a paste-site template on an analytics row")
    }

    func testADestinationRowIsNotOfferedTemplatesThatIgnoreIt() {
        let unrelated = RuleTemplate.Subject(destination: "something.invalid")
        for template in RuleTemplate.applicable(to: unrelated) {
            XCTAssertNotEqual(template.needs, .nothing,
                              "\(template.id) was offered to a row it has nothing to say about")
        }
    }

    func testEveryTemplateOfferedToARowCanBeFilledFromIt() {
        for candidate in [RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent"),
                          RuleTemplate.Subject(destination: "example.com"),
                          RuleTemplate.Subject(destination: "api.segment.io"),
                          subject] {
            for template in RuleTemplate.applicable(to: candidate) {
                XCTAssertFalse(template.rules(for: candidate).isEmpty,
                               "\(template.id) was offered to a row it can't be filled from")
            }
        }
    }

    /// A whole-Mac template offered from an app row narrows to that app, which is the whole point. One that
    /// wouldn't is left out rather than quietly widening what was clicked.
    func testAnAppRowIsNotOfferedTemplatesThatWouldIgnoreTheApp() {
        let appOnly = RuleTemplate.Subject(app: "com.example.agent", appName: "Example Agent")
        for template in RuleTemplate.applicable(to: appOnly) where template.needs == .nothing {
            XCTAssertTrue(template.scopesToApp, "\(template.id) was offered from an app row but ignores the app")
        }
    }

    // MARK: What the rules do, once written

    func testNoPackageInstallsRefusesARegistryAndLeavesTheRestAlone() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "agent.no-package-registries" }) else {
            return XCTFail("the package registry template is gone")
        }
        let rules = template.rules(for: subject)
        XCTAssertEqual(RuleBook.decide(facts(host: "registry.npmjs.org"), rules: rules, session: session).verdict,
                       .block)
        XCTAssertEqual(RuleBook.decide(facts(host: "files.pythonhosted.org"), rules: rules, session: session).verdict,
                       .block)
        XCTAssertEqual(RuleBook.decide(facts(host: "api.github.com"), rules: rules, session: session).verdict, .allow)
        // Another app on the same Mac is untouched: the template named one.
        XCTAssertEqual(RuleBook.decide(facts(app: "com.example.other", agent: "com.example.other",
                                             host: "registry.npmjs.org"),
                                       rules: rules, session: session).verdict, .allow)
    }

    func testPasteSitesRefusesGistWithoutRefusingTheRestOfGitHub() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "exfil.paste-sites" }) else {
            return XCTFail("the paste site template is gone")
        }
        let rules = template.rules()
        XCTAssertEqual(RuleBook.decide(facts(host: "gist.github.com"), rules: rules, session: session).verdict, .block)
        XCTAssertEqual(RuleBook.decide(facts(host: "github.com"), rules: rules, session: session).verdict, .allow)
        XCTAssertEqual(RuleBook.decide(facts(host: "api.github.com"), rules: rules, session: session).verdict, .allow)
    }

    /// Two windows, because one can't say both "not at night" and "not at the weekend". The test is the reason
    /// the second rule exists: with only the nightly window, Saturday afternoon is wide open.
    func testWorkingHoursCoversTheNightsAndTheWeekend() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "hours.app-working-hours" }) else {
            return XCTFail("the working hours template is gone")
        }
        let rules = template.rules(for: subject)
        XCTAssertEqual(rules.count, 2)

        func verdict(_ components: DateComponents) -> FlowVerdict {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let moment = calendar.date(from: components)!
            return RuleBook.decide(facts(host: "example.com"), rules: rules, now: moment, session: session).verdict
        }

        // Wednesday 11:00 — inside working hours.
        XCTAssertEqual(verdict(DateComponents(year: 2026, month: 3, day: 4, hour: 11)), .allow)
        // Wednesday 22:00 — the nightly window.
        XCTAssertEqual(verdict(DateComponents(year: 2026, month: 3, day: 4, hour: 22)), .block)
        // Thursday 03:00 — still Wednesday night's window, which crosses midnight.
        XCTAssertEqual(verdict(DateComponents(year: 2026, month: 3, day: 5, hour: 3)), .block)
        // Saturday 14:00 — the middle of the weekend, which the nightly window alone would have let through.
        XCTAssertEqual(verdict(DateComponents(year: 2026, month: 3, day: 7, hour: 14)), .block)
        // Sunday 14:00, the same.
        XCTAssertEqual(verdict(DateComponents(year: 2026, month: 3, day: 8, hour: 14)), .block)
    }

    func testReadOnlyGitHubRefusesWritesAndNeverTouchesTheConnection() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "agent.github-read-only" }) else {
            return XCTFail("the read-only GitHub template is gone")
        }
        let rules = template.rules(for: subject)
        let connection = facts(host: "api.github.com")

        // The flow level skips these entirely: refusing the whole host in a rule's name would be the worst kind
        // of surprise, and it is what would happen if these were written without a method.
        XCTAssertEqual(RuleBook.decide(connection, rules: rules, session: session).verdict, .allow)

        XCTAssertEqual(RuleBook.decideRequest(connection, path: "/repos/x/y", method: "GET",
                                              rules: rules, session: session).verdict, .undecided)
        XCTAssertEqual(RuleBook.decideRequest(connection, path: "/repos/x/y/issues", method: "POST",
                                              rules: rules, session: session).verdict, .block)
        XCTAssertEqual(RuleBook.decideRequest(connection, path: "/repos/x/y", method: "DELETE",
                                              rules: rules, session: session).verdict, .block)
    }

    func testABlockForAnHourIsOverAnHourLater() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "investigate.destination-for-an-hour" }),
              let rule = template.rules(for: subject).first else {
            return XCTFail("the one-hour template is gone")
        }
        let now = Date()
        XCTAssertEqual(RuleBook.decide(facts(host: "example.com"), rules: [rule], now: now, session: session).verdict,
                       .block)
        XCTAssertEqual(RuleBook.decide(facts(host: "example.com"), rules: [rule],
                                       now: now.addingTimeInterval(3601), session: session).verdict, .allow)
    }

    func testASessionBlockIsOverInTheNextRunOfFlowlight() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "investigate.destination-this-session" }),
              let rule = template.rules(for: subject).first else {
            return XCTFail("the session template is gone")
        }
        XCTAssertEqual(RuleBook.decide(facts(host: "example.com"), rules: [rule], session: session).verdict, .block)
        XCTAssertEqual(RuleBook.decide(facts(host: "example.com"), rules: [rule], session: "a-later-run").verdict,
                       .allow)
    }

    /// The narrow investigation rule has to lose to nothing and bite nothing else: it is the one someone reaches
    /// for precisely because they don't want to disturb the rest of the Mac.
    func testBlockingOneAppFromOneDestinationLeavesEveryoneElseAlone() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "investigate.app-and-destination-for-an-hour" }),
              let rule = template.rules(for: subject).first else {
            return XCTFail("the app-and-destination template is gone")
        }
        XCTAssertEqual(RuleBook.decide(facts(host: "example.com"), rules: [rule], session: session).verdict, .block)
        XCTAssertEqual(RuleBook.decide(facts(app: "com.example.other", agent: "com.example.other",
                                             host: "example.com"), rules: [rule], session: session).verdict, .allow)
        XCTAssertEqual(RuleBook.decide(facts(host: "elsewhere.test"), rules: [rule], session: session).verdict, .allow)
    }

    func testNamingAnAgentCoversTheToolsItStarted() {
        guard let template = RuleTemplate.all.first(where: { $0.id == "agent.no-package-registries" }) else {
            return XCTFail("the package registry template is gone")
        }
        let rules = template.rules(for: subject)
        // `curl`, run by the agent: a different process, the same agent key.
        let byATool = facts(app: "/usr/bin/curl", agent: "com.example.agent", host: "pypi.org")
        XCTAssertEqual(RuleBook.decide(byATool, rules: rules, session: session).verdict, .block)
    }
}
