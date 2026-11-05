import XCTest
@testable import Flowlight

@MainActor
final class InspectNavigationTests: XCTestCase {
    func testAskingForInspectSwitchesScreenAndCarriesTheSubject() {
        let nav = AppNavigation()
        nav.show(.live)
        nav.showInspect(search: "api.anthropic.com")
        XCTAssertEqual(nav.selection, .inspect)
        XCTAssertEqual(nav.inspectRequest?.search, "api.anthropic.com")
    }

    /// Two requests for the same subject have to be distinguishable, or asking twice — because the first
    /// arrival was cleared, or the search was edited since — would look like no change at all and the screen
    /// would ignore it.
    func testTwoRequestsForTheSameThingAreDifferentRequests() {
        let nav = AppNavigation()
        nav.showInspect(search: "claude")
        let first = nav.inspectRequest
        nav.showInspect(search: "claude")
        XCTAssertNotEqual(first, nav.inspectRequest)
        XCTAssertEqual(nav.inspectRequest?.search, "claude")
    }

    /// The sidebar item has to exist for the request to land anywhere, and `SidebarItem` is what the help
    /// anchors and keyboard shortcuts are derived from.
    func testInspectIsAReachableScreen() {
        XCTAssertTrue(SidebarItem.allCases.contains(.inspect))
        XCTAssertEqual(SidebarItem.inspect.section, .investigate)
    }

    func testPackReviewNavigationFocusesManagedPacksInPolicies() {
        let nav = AppNavigation()
        nav.show(.live)

        nav.showPackReviews()

        XCTAssertEqual(nav.selection, .rules)
        XCTAssertEqual(nav.rulesTab, .rules)
        XCTAssertEqual(nav.policyRequest?.destination, .managedPack(nil))
    }

    func testOrdinaryRulesNavigationReturnsToTheRulesTab() {
        let nav = AppNavigation()
        nav.showPackReviews()

        nav.show(.rules)

        XCTAssertEqual(nav.selection, .rules)
        XCTAssertEqual(nav.rulesTab, .rules)
    }

    func testWritingRuleReturnsToTheRulesTab() {
        let nav = AppNavigation()
        nav.showPackReviews()

        nav.writeRule(Rule())

        XCTAssertEqual(nav.selection, .rules)
        XCTAssertEqual(nav.rulesTab, .rules)
        XCTAssertNotNil(nav.ruleRequest)
    }

    func testLegacyRulesTabsRestoreIntoTwoTabPoliciesUI() {
        XCTAssertEqual(RulesTab.rules.rawValue, "rules")
        XCTAssertEqual(RulesTab.restored(from: "rules"), .rules)
        XCTAssertEqual(RulesTab.restored(from: "packs"), .rules)
        XCTAssertTrue(RulesTab.restoresManagedPackFocus(from: "packs"))
        XCTAssertFalse(RulesTab.restoresManagedPackFocus(from: "rules"))
        XCTAssertEqual(RulesTab.restored(from: "activity"), .activity)
        XCTAssertEqual(RulesTab.allCases, [.rules, .activity])
    }

    func testPolicyInventoryIDsAreStableAndNamespaced() {
        let source = "8f183e44-895b-4f05-b221-9d845e772def"
        XCTAssertEqual(PolicyInventoryID.make(.networkRule, sourceID: source), "rule:\(source)")
        XCTAssertEqual(PolicyInventoryID.make(.networkRule, sourceID: source),
                       PolicyInventoryID.make(.networkRule, sourceID: source))
        XCTAssertNotEqual(PolicyInventoryID.make(.networkRule, sourceID: source),
                          PolicyInventoryID.make(.guardrail, sourceID: source))
    }

    func testStoreCapabilitiesOmitEveryInspectionDependentPolicyKind() {
        let capabilities = PolicyInventoryCapabilities(inspectionPolicies: false)
        let items = PolicyInventoryKind.allCases.map { kind in
            PolicyInventoryItem(kind: kind, sourceID: kind.rawValue, title: kind.rawValue, detail: "",
                                isEnabled: true, effect: .effective, reason: nil, destination: .managedPack(nil))
        }
        let visible = items.filter { $0.isVisible(in: capabilities) }.map(\.kind)

        XCTAssertEqual(visible, [.networkRule, .agentAllowlist, .managedPack])
        XCTAssertFalse(visible.contains(.guardrail))
        XCTAssertFalse(visible.contains(.mock))
        XCTAssertFalse(visible.contains(.requestRewrite))
        XCTAssertFalse(visible.contains(.responseTransform))
    }

    func testInventorySeparatesConfiguredStateFromCurrentEffect() throws {
        let rule = Rule(action: .block, destination: "example.com")
        let allowlist = AgentPolicy(agentID: "agent", enabled: true, patterns: ["example.com"], enforce: false)
        let guardrail = Guardrail(agent: "agent", tool: "bash")
        let pack = try XCTUnwrap(BuiltInRulePacks.all.first)
        let retired = RulePackConfiguration(packID: "retired.pack", enabled: true)

        let items = PolicyInventoryBuilder.build(
            rules: [rule], allowlists: ["agent": allowlist], packs: [pack], unavailablePacks: [retired],
            packConfiguration: { RulePackConfiguration(packID: $0, enabled: true) },
            packNeedsReview: { _ in true }, packStatus: .enforcing,
            guardrails: [guardrail], mocks: [], rewrites: [], transforms: [],
            extensionRunning: false, canBlock: true, inspectionEnabled: false, inspectionRunning: false)

        let network = try XCTUnwrap(items.first { $0.kind == .networkRule })
        XCTAssertTrue(network.isEnabled)
        XCTAssertEqual(network.effect, .watchingOnly)
        XCTAssertNotNil(network.reason)

        let agent = try XCTUnwrap(items.first { $0.kind == .agentAllowlist })
        XCTAssertTrue(agent.isEnabled)
        XCTAssertEqual(agent.effect, .reportingOnly)
        XCTAssertNotNil(agent.reason)

        let developer = try XCTUnwrap(items.first { $0.kind == .guardrail })
        XCTAssertTrue(developer.isEnabled)
        XCTAssertEqual(developer.effect, .waiting)
        XCTAssertNotNil(developer.reason)

        let managed = try XCTUnwrap(items.first { $0.sourceID == pack.id })
        XCTAssertTrue(managed.isEnabled)
        XCTAssertEqual(managed.effect, .needsReview)

        let unavailable = try XCTUnwrap(items.first { $0.sourceID == "retired.pack" })
        XCTAssertTrue(unavailable.isEnabled)
        XCTAssertEqual(unavailable.effect, .unavailable)
        XCTAssertNotNil(unavailable.reason)
    }

    func testPackFocusCarriesExactPackIdentity() {
        let nav = AppNavigation()
        nav.showPolicyPack("official.trackers")

        XCTAssertEqual(nav.selection, .rules)
        XCTAssertEqual(nav.rulesTab, .rules)
        XCTAssertEqual(nav.policyRequest?.destination, .managedPack("official.trackers"))
    }

    func testPolicyDeepLinksKeepContextualEditorsAsOwners() {
        let nav = AppNavigation()
        nav.show(.rules)
        nav.showAgentPolicy(agentID: "claude", section: .guardrails)
        XCTAssertEqual(nav.selection, .agents)
        XCTAssertEqual(nav.agentPolicyRequest?.agentID, "claude")
        XCTAssertEqual(nav.agentPolicyRequest?.section, .guardrails)

        nav.showInspectionPolicy(.requestRewrites)
        XCTAssertEqual(nav.selection, .inspect)
        XCTAssertEqual(nav.inspectRequest?.policySection, .requestRewrites)
    }

    func testAgentPolicyDeepLinkIsScopedAndConsumedOnce() {
        let request = AgentPolicyRequest(agentID: "claude", section: .guardrails)
        var state = AgentPolicyDeepLinkState(request: request)

        XCTAssertEqual(state.section(for: "claude"), .guardrails)
        XCTAssertNil(state.section(for: "codex"))
        XCTAssertEqual(AgentDetail.Tab.policyLanding(.guardrails), .guardrails)
        XCTAssertEqual(AgentDetail.Tab.policyLanding(.allowlist), .destinations)

        state.consume()
        XCTAssertNil(state.section(for: "claude"))
    }

    func testUnifiedActivityKeepsGuardrailAndRewriteEffectsDistinct() {
        let exchange = HTTPExchange(
            id: 42, started: Date(timeIntervalSince1970: 100), duration: 0.2, scheme: "https",
            host: "api.example.com", port: 443, method: "POST", path: "/v1/run", status: 200,
            requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
            agent: "agent", agentName: "Agent", mcpServer: nil, toolCalls: [], toolResults: [], mcp: [], llm: nil,
            note: nil, mockRule: nil, guardrail: "Removed shell", requestRewrite: "set X-Test",
            responseTransform: nil)

        let activity = PolicyActivityBuilder.build(ruleEvents: [], packEvents: [], alerts: [], exchanges: [exchange],
                                                   rules: [], guardrails: [], packs: [], mocks: [], rewrites: [],
                                                   transforms: [])

        XCTAssertEqual(Set(activity.map(\.effect)), [.guardrailApplied, .requestRewritten])
        XCTAssertEqual(Set(activity.map(\.id)), ["exchange:42:guardrail", "exchange:42:request-rewrite"])

        let storeActivity = PolicyActivityBuilder.build(
            ruleEvents: [], packEvents: [], alerts: [], exchanges: [exchange], rules: [], guardrails: [],
            packs: [], mocks: [], rewrites: [], transforms: [],
            capabilities: PolicyInventoryCapabilities(inspectionPolicies: false))
        XCTAssertTrue(storeActivity.isEmpty, "Store activity must omit retained Developer-only effects")
    }
}
