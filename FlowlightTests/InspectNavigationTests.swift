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

    func testPrimaryPolicySectionExpansionUsesStablePersistedKeys() {
        XCTAssertEqual(PolicySectionExpansion.networkRulesKey,
                       "policies.sections.network-rules.expanded")
        XCTAssertEqual(PolicySectionExpansion.agentAllowlistsKey,
                       "policies.sections.agent-allowlists.expanded")
        XCTAssertEqual(PolicySectionExpansion.managedPacksKey,
                       "policies.sections.managed-packs.expanded")
        XCTAssertEqual(PolicySectionExpansion.catalogDetailsKey,
                       "policies.sections.managed-packs.catalog-details.expanded")
        XCTAssertTrue(PolicySectionExpansion.isCollapsible(.networkRule))
        XCTAssertTrue(PolicySectionExpansion.isCollapsible(.agentAllowlist))
        XCTAssertTrue(PolicySectionExpansion.isCollapsible(.managedPack))
        XCTAssertFalse(PolicySectionExpansion.isCollapsible(.guardrail))
    }

    func testCollapsedPolicySummarySeparatesConfiguredIntentFromCurrentEffect() {
        let items = [
            PolicyInventoryItem(kind: .networkRule, sourceID: "effective", title: "", detail: "",
                                isEnabled: true, effect: .effective, reason: nil, destination: .managedPack(nil)),
            PolicyInventoryItem(kind: .networkRule, sourceID: "waiting", title: "", detail: "",
                                isEnabled: true, effect: .waiting, reason: nil, destination: .managedPack(nil)),
            PolicyInventoryItem(kind: .networkRule, sourceID: "off", title: "", detail: "",
                                isEnabled: false, effect: .off, reason: nil, destination: .managedPack(nil)),
        ]

        let summary = PolicySectionSummary(items: items)
        XCTAssertEqual(summary.enabled, 2)
        XCTAssertEqual(summary.effective, 1)
        XCTAssertEqual(summary.reportingOnly, 0)
        XCTAssertEqual(summary.waiting, 1)
        XCTAssertEqual(summary.needsReview, 0)
    }

    func testCollapsedPolicySummaryKeepsAllowlistAndPackActionStateVisible() {
        let items = [
            PolicyInventoryItem(kind: .agentAllowlist, sourceID: "enforcing", title: "", detail: "",
                                isEnabled: true, effect: .effective, reason: nil, destination: .managedPack(nil)),
            PolicyInventoryItem(kind: .agentAllowlist, sourceID: "reporting", title: "", detail: "",
                                isEnabled: true, effect: .reportingOnly, reason: nil, destination: .managedPack(nil)),
            PolicyInventoryItem(kind: .managedPack, sourceID: "review", title: "", detail: "",
                                isEnabled: true, effect: .needsReview, reason: nil, destination: .managedPack(nil)),
            PolicyInventoryItem(kind: .managedPack, sourceID: "removed", title: "", detail: "",
                                isEnabled: true, effect: .unavailable, reason: nil, destination: .managedPack(nil)),
        ]

        let summary = PolicySectionSummary(items: items)
        XCTAssertEqual(summary.enabled, 4)
        XCTAssertEqual(summary.effective, 2)
        XCTAssertEqual(summary.reportingOnly, 1)
        XCTAssertEqual(summary.waiting, 0)
        XCTAssertEqual(summary.needsReview, 2)
    }

    func testManagedPackFocusWaitsForDefinitionsAndKeepsExactIdentity() throws {
        let sectionRequest = PolicyRequest(destination: .managedPack(nil))
        let sectionFocus = try XCTUnwrap(ManagedPackFocusRequest(sectionRequest))
        XCTAssertFalse(sectionFocus.isReady(availablePackIDs: [], catalogReady: false))
        XCTAssertTrue(sectionFocus.isReady(availablePackIDs: ["official.trackers"], catalogReady: true))
        XCTAssertEqual(sectionFocus.targetID, PolicySectionExpansion.managedPacksAnchor)

        let packRequest = PolicyRequest(destination: .managedPack("official.trackers"))
        let packFocus = try XCTUnwrap(ManagedPackFocusRequest(packRequest))
        XCTAssertEqual(packFocus.resolution(availablePackIDs: ["official.trackers"], catalogReady: false), .waiting)
        XCTAssertEqual(packFocus.resolution(availablePackIDs: ["official.telemetry"], catalogReady: true), .missing)
        XCTAssertEqual(packFocus.resolution(availablePackIDs: ["official.trackers"], catalogReady: true), .found)
        XCTAssertFalse(packFocus.isReady(availablePackIDs: [], catalogReady: false))
        XCTAssertFalse(packFocus.isReady(availablePackIDs: ["official.telemetry"], catalogReady: true))
        XCTAssertTrue(packFocus.isReady(availablePackIDs: ["official.trackers"], catalogReady: true))
        XCTAssertEqual(packFocus.navigationID, packRequest.id)
        XCTAssertEqual(packFocus.targetID, "pack:official.trackers")

        XCTAssertNil(ManagedPackFocusRequest(PolicyRequest(destination: .allowlist("agent"))))
    }

    func testCapabilitiesWithoutInspectionHideEveryInspectionPolicyKind() {
        let capabilities = PolicyInventoryCapabilities(
            inspectionPolicies: false,
            responseTransforms: false
        )
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

    func testStoreLikeCapabilitiesKeepInspectionPoliciesWithoutResponseTransforms() {
        let capabilities = PolicyInventoryCapabilities(
            inspectionPolicies: true,
            responseTransforms: false
        )
        let items = PolicyInventoryKind.allCases.map { kind in
            PolicyInventoryItem(kind: kind, sourceID: kind.rawValue, title: kind.rawValue, detail: "",
                                isEnabled: true, effect: .effective, reason: nil, destination: .managedPack(nil))
        }
        let visible = items.filter { $0.isVisible(in: capabilities) }.map(\.kind)

        XCTAssertEqual(visible, [
            .networkRule, .agentAllowlist, .managedPack, .guardrail, .mock, .requestRewrite
        ])
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

    func testRequestAndInspectionPoliciesRemainEffectiveForPlainHTTPWithoutCertificateTrust() throws {
        var requestRule = Rule(action: .block, destination: "plain.example")
        requestRule.path = "/v1/*"
        let mock = MockRule(host: "plain.example")
        let rewrite = RewriteRule(host: "plain.example", headers: [HeaderEdit(name: "X-Test", value: "yes")])
        let guardrail = Guardrail(agent: "agent", tool: "bash")
        let items = PolicyInventoryBuilder.build(
            rules: [requestRule], allowlists: [:], packs: [], packConfiguration: { RulePackConfiguration(packID: $0) },
            guardrails: [guardrail], mocks: [mock], rewrites: [rewrite], transforms: [],
            inspectionEnabled: true, inspectionRunning: true, inspectionTrusted: false,
            inspectionAttributionReady: true
        )

        for kind in [PolicyInventoryKind.networkRule, .guardrail, .mock, .requestRewrite] {
            let item = try XCTUnwrap(items.first { $0.kind == kind })
            XCTAssertEqual(item.effect, .httpOnly)
            XCTAssertTrue(item.effect.isEffective)
            XCTAssertTrue(item.reason?.contains("plain HTTP") == true)
        }
    }

    func testAppScopedPoliciesWaitForTrustedAttributionWhileGlobalGuardrailsDoNot() throws {
        var requestRule = Rule(action: .block, app: "com.example.agent", destination: "plain.example")
        requestRule.path = "/v1/*"
        let flowRule = Rule(action: .block, app: "com.example.agent", destination: "blocked.example")
        let allowlist = AgentPolicy(agentID: "com.example.agent", enabled: true,
                                    patterns: ["allowed.example"], enforce: true)
        let pack = try XCTUnwrap(BuiltInRulePacks.all.first)
        let scopedGuardrail = Guardrail(agent: "com.example.agent", tool: "bash")
        let globalGuardrail = Guardrail(tool: "bash")
        let items = PolicyInventoryBuilder.build(
            rules: [requestRule, flowRule], allowlists: ["com.example.agent": allowlist], packs: [pack],
            packConfiguration: { packID in
                var configuration = RulePackConfiguration(packID: packID, enabled: true)
                configuration.scope = .selectedApps
                configuration.apps = ["com.example.agent"]
                return configuration
            },
            packStatus: .enforcing, guardrails: [scopedGuardrail, globalGuardrail], mocks: [], rewrites: [],
            transforms: [], extensionRunning: true, canBlock: true, inspectionEnabled: true,
            inspectionRunning: true, inspectionTrusted: false, inspectionAttributionReady: false
        )

        for sourceID in [requestRule.id.uuidString.lowercased(), flowRule.id.uuidString.lowercased(),
                         "com.example.agent", pack.id, scopedGuardrail.id.uuidString.lowercased()] {
            let item = try XCTUnwrap(items.first { $0.sourceID == sourceID })
            XCTAssertEqual(item.effect, .waiting, sourceID)
            XCTAssertTrue(item.reason?.contains("trusted app attribution is unavailable") == true, sourceID)
        }
        let global = try XCTUnwrap(items.first { $0.sourceID == globalGuardrail.id.uuidString.lowercased() })
        XCTAssertEqual(global.effect, .httpOnly)
        XCTAssertTrue(global.reason?.contains("plain HTTP") == true)
    }

    func testHTTPOnlyGuardrailStillWaitsForTrustedAttribution() throws {
        let guardrail = Guardrail(agent: "agent", tool: "bash")
        let items = PolicyInventoryBuilder.build(
            rules: [], allowlists: [:], packs: [], packConfiguration: { RulePackConfiguration(packID: $0) },
            guardrails: [guardrail], mocks: [], rewrites: [], transforms: [],
            inspectionEnabled: true, inspectionRunning: true, inspectionTrusted: false,
            inspectionAttributionReady: false
        )

        let item = try XCTUnwrap(items.first { $0.kind == .guardrail })
        XCTAssertEqual(item.effect, .waiting)
        XCTAssertTrue(item.reason?.contains("trusted app attribution is unavailable") == true)
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
        let guardrailID = UUID()
        nav.show(.rules)
        nav.showAgentPolicy(agentID: "claude", section: .guardrails, guardrailID: guardrailID)
        XCTAssertEqual(nav.selection, .agents)
        XCTAssertEqual(nav.agentPolicyRequest?.agentID, "claude")
        XCTAssertEqual(nav.agentPolicyRequest?.section, .guardrails)
        XCTAssertEqual(nav.agentPolicyRequest?.guardrailID, guardrailID)

        let rewriteID = UUID()
        nav.showInspectionPolicy(.requestRewrites, policyID: rewriteID)
        XCTAssertEqual(nav.selection, .inspect)
        XCTAssertEqual(nav.inspectRequest?.policySection, .requestRewrites)
        XCTAssertEqual(nav.inspectRequest?.policyID, rewriteID)
    }

    func testAgentPolicyDeepLinkIsScopedAndConsumedOnce() {
        let guardrailID = UUID()
        let request = AgentPolicyRequest(agentID: "claude", section: .guardrails, guardrailID: guardrailID)
        var state = AgentPolicyDeepLinkState(request: request)

        XCTAssertEqual(state.section(for: "claude"), .guardrails)
        XCTAssertEqual(state.section(for: ["claude-code", "Claude Code"]), .guardrails)
        XCTAssertEqual(state.guardrailID(for: ["claude-code", "Claude Code"]), guardrailID)
        XCTAssertNil(state.section(for: ["CLAUDE"]), "ambiguous case-folded identities must not pick a product")
        XCTAssertNil(state.section(for: ["codex", "com.example.Codex"]))
        XCTAssertNil(state.guardrailID(for: ["codex", "com.example.Codex"]))
        XCTAssertEqual(AgentDetail.Tab.policyLanding(.guardrails), .guardrails)
        XCTAssertEqual(AgentDetail.Tab.policyLanding(.allowlist), .destinations)

        state.consume()
        XCTAssertNil(state.section(for: "claude"))
        XCTAssertNil(state.guardrailID(for: ["claude"]))
    }

    func testUnifiedActivityUsesStableInspectionPolicyIdentities() throws {
        let guardrailID = UUID()
        let rewriteID = UUID()
        let transformID = UUID()
        let guardrail = try XCTUnwrap(InspectionPolicyReference.encode([
            .init(id: guardrailID, title: "Shell guardrail"),
        ]))
        let rewrite = try XCTUnwrap(InspectionPolicyReference.encode([
            .init(id: rewriteID, title: "Scrub request"),
        ]))
        let transform = try XCTUnwrap(InspectionPolicyReference.encode([
            .init(id: transformID, title: "Shape response"),
        ]))
        let exchange = HTTPExchange(
            id: 43, started: Date(timeIntervalSince1970: 100), duration: 0.2, scheme: "https",
            host: "api.example.com", port: 443, method: "POST", path: "/v1/run", status: 200,
            requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
            agent: "agent", agentName: "Agent", mcpServer: nil, toolCalls: [], toolResults: [], mcp: [], llm: nil,
            note: nil, mockRule: nil, guardrail: guardrail, requestRewrite: rewrite,
            responseTransform: transform)

        let activity = PolicyActivityBuilder.build(ruleEvents: [], packEvents: [], alerts: [], exchanges: [exchange],
                                                   rules: [],
                                                   guardrails: [Guardrail(id: guardrailID, tool: "bash",
                                                                          name: "Renamed guardrail")],
                                                   packs: [], mocks: [],
                                                   rewrites: [RewriteRule(id: rewriteID, name: "Renamed rewrite")],
                                                   transforms: [ResponseTransformRule(id: transformID,
                                                                                      name: "Renamed transform")])

        XCTAssertEqual(Set(activity.compactMap(\.policyID)), [
            PolicyInventoryID.make(.guardrail, sourceID: guardrailID.uuidString.lowercased()),
            PolicyInventoryID.make(.requestRewrite, sourceID: rewriteID.uuidString.lowercased()),
            PolicyInventoryID.make(.responseTransform, sourceID: transformID.uuidString.lowercased()),
        ])
        XCTAssertEqual(Set(activity.map(\.title)), ["Shell guardrail", "Scrub request", "Shape response"])
        XCTAssertEqual(InspectionPolicyReference.display(transform), "Shape response")
    }

    func testDeletedInspectionPolicyActivityKeepsHistoryWithoutNavigation() throws {
        let guardrailID = UUID()
        let reference = try XCTUnwrap(InspectionPolicyReference.encode([
            .init(id: guardrailID, title: "Deleted shell guardrail"),
        ]))
        let exchange = HTTPExchange(
            id: 44, started: Date(timeIntervalSince1970: 100), duration: 0.2, scheme: "https",
            host: "api.example.com", port: 443, method: "POST", path: "/v1/run", status: 200,
            requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
            agent: "agent", agentName: "Agent", mcpServer: nil, toolCalls: [], toolResults: [], mcp: [], llm: nil,
            note: nil, mockRule: nil, guardrail: reference, requestRewrite: nil,
            responseTransform: nil)

        let activity = PolicyActivityBuilder.build(ruleEvents: [], packEvents: [], alerts: [], exchanges: [exchange],
                                                   rules: [], guardrails: [], packs: [], mocks: [], rewrites: [],
                                                   transforms: [])

        XCTAssertEqual(activity.first?.title, "Deleted shell guardrail")
        XCTAssertNil(activity.first?.policyID)
    }

    func testMockActivityKeepsStableAndUncorrelatedLegacyHistory() throws {
        let mockID = UUID()
        let stableReference = try XCTUnwrap(InspectionPolicyReference.encode([
            .init(id: mockID, title: "Original mock title"),
        ]))
        func exchange(id: Int64, mockRule: String, offset: TimeInterval = 0) -> HTTPExchange {
            HTTPExchange(
                id: id, started: Date(timeIntervalSince1970: 100 + offset), duration: 0.2, scheme: "https",
                host: "api.example.com", port: 443, method: "POST", path: "/v1/run", status: 500,
                requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
                responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
                contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
                agent: "agent", agentName: "Agent", mcpServer: nil, toolCalls: [], toolResults: [], mcp: [], llm: nil,
                note: nil, mockRule: mockRule, guardrail: nil, requestRewrite: nil, responseTransform: nil)
        }

        let current = PolicyActivityBuilder.build(
            ruleEvents: [], packEvents: [], alerts: [], exchanges: [exchange(id: 45, mockRule: stableReference)],
            rules: [], guardrails: [], packs: [],
            mocks: [MockRule(id: mockID, name: "Renamed mock")], rewrites: [], transforms: [])
        XCTAssertEqual(current.first?.title, "Original mock title")
        XCTAssertEqual(current.first?.policyID,
                       PolicyInventoryID.make(.mock, sourceID: mockID.uuidString.lowercased()))

        let deleted = PolicyActivityBuilder.build(
            ruleEvents: [], packEvents: [], alerts: [],
            exchanges: [exchange(id: 46, mockRule: stableReference),
                        exchange(id: 47, mockRule: "Legacy deleted mock", offset: 10)],
            rules: [], guardrails: [], packs: [], mocks: [], rewrites: [], transforms: [])
        XCTAssertEqual(Set(deleted.map(\.title)), ["Original mock title", "Legacy deleted mock"])
        XCTAssertTrue(deleted.allSatisfy { $0.policyID == nil })
    }

    func testAllowlistActivityUsesThePersistedPolicyIdentity() throws {
        let policy = AgentPolicy(agentID: "claude", patterns: ["api.example"])
        let alert = AlertRecord(
            id: 49,
            timestamp: Date(timeIntervalSince1970: 100),
            kind: AnomalyEngine.Kind.allowlistViolation.rawValue,
            bundleID: "claude-code",
            appName: "Claude Code",
            detail: "Claude Code contacted uploads.example",
            severity: 2,
            state: .new
        )

        let activity = PolicyActivityBuilder.build(
            ruleEvents: [], packEvents: [], alerts: [alert], exchanges: [], rules: [],
            guardrails: [], packs: [], mocks: [], rewrites: [], transforms: [], policies: [policy]
        )

        XCTAssertEqual(
            try XCTUnwrap(activity.first).policyID,
            PolicyInventoryID.make(.agentAllowlist, sourceID: "claude")
        )
    }

    func testLegacyRefusalAnswerDoesNotAppearAsMockActivity() {
        let exchange = HTTPExchange(
            id: 48, started: Date(timeIntervalSince1970: 100), duration: 0.2, scheme: "https",
            host: "api.example.com", port: 443, method: "POST", path: "/v1/run", status: 200,
            requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
            agent: "agent", agentName: "Agent", mcpServer: nil, toolCalls: [], toolResults: [], mcp: [], llm: nil,
            note: nil, mockRule: "Flowlight blocked this request", guardrail: nil,
            requestRewrite: nil, responseTransform: nil)
        let event = RuleEventRecord(
            id: 8, timestamp: exchange.started, ruleID: UUID(), action: .block, engine: .guardrail,
            bundleID: "agent", appName: "Agent", agentKey: "agent", agentName: "Agent",
            host: exchange.host, ip: "", port: 443, path: "shell", method: exchange.method)

        let activity = PolicyActivityBuilder.build(
            ruleEvents: [event], packEvents: [], alerts: [], exchanges: [exchange], rules: [],
            guardrails: [], packs: [], mocks: [], rewrites: [], transforms: [])

        XCTAssertEqual(activity.count, 1)
        XCTAssertEqual(activity.first?.kind, .guardrail)
    }

    func testDeletedGuardrailEventRetainsItsKind() {
        let event = RuleEventRecord(
            id: 7, timestamp: Date(timeIntervalSince1970: 100), ruleID: UUID(), action: .block,
            engine: .guardrail, bundleID: "agent", appName: "Agent", agentKey: "agent", agentName: "Agent",
            host: "api.example.com", ip: "", port: 443, path: "shell", method: "POST"
        )

        let activity = PolicyActivityBuilder.build(ruleEvents: [event], packEvents: [], alerts: [], exchanges: [],
                                                   rules: [], guardrails: [], packs: [], mocks: [], rewrites: [],
                                                   transforms: [])

        XCTAssertEqual(activity.first?.kind, .guardrail)
        XCTAssertEqual(activity.first?.effect, .guardrailApplied)
    }

    func testUnifiedActivityPreservesOrdinaryAndPackSourceEvidence() throws {
        let rule = Rule(action: .block, app: "com.example.browser", destination: "blocked.example")
        let ruleEvent = RuleEventRecord(
            id: 50, timestamp: Date(timeIntervalSince1970: 100), ruleID: rule.id,
            action: .block, engine: .flow, bundleID: "com.example.browser", appName: "Browser",
            agentKey: "agent", agentName: "Agent", host: "blocked.example", ip: "", port: 443,
            path: "", method: ""
        )
        let packEvent = RulePackEventRecord(
            id: 51, bucket: Date(timeIntervalSince1970: 120), packID: "official.privacy",
            packVersion: "3", entryID: 7, category: .tracking, match: .suffix, action: .block,
            count: 4, firstAt: Date(timeIntervalSince1970: 120), lastAt: Date(timeIntervalSince1970: 125),
            bundleID: "com.example.browser", appName: "Browser", agentKey: "", agentName: "",
            host: "cdn.blocked.example", matchedHost: "blocked.example", port: 443
        )

        let activity = PolicyActivityBuilder.build(
            ruleEvents: [ruleEvent], packEvents: [packEvent], alerts: [], exchanges: [], rules: [rule],
            guardrails: [], packs: [], mocks: [], rewrites: [], transforms: []
        )

        XCTAssertTrue(activity.contains { $0.source == .rule(ruleEvent) })
        XCTAssertTrue(activity.contains { $0.source == .managedPack(packEvent) })
    }

    func testPackActivityActionsKeepExactAppMatchAndDestination() {
        let event = RulePackEventRecord(
            id: 52, bucket: Date(timeIntervalSince1970: 120), packID: "official.privacy",
            packVersion: "3", entryID: 7, category: .tracking, match: .exact, action: .block,
            count: 1, firstAt: Date(timeIntervalSince1970: 120), lastAt: Date(timeIntervalSince1970: 120),
            bundleID: "com.example.browser", appName: "Browser", agentKey: "", agentName: "",
            host: "www.blocked.example", matchedHost: "blocked.example", port: 443
        )

        let exception = RulePackActivityAction.exception(for: event)
        XCTAssertEqual(exception.packID, event.packID)
        XCTAssertEqual(exception.app, event.bundleID)
        XCTAssertEqual(exception.host, event.matchedHost)
        XCTAssertEqual(exception.match, event.match)

        let rule = RulePackActivityAction.normalAllowRule(for: event)
        XCTAssertEqual(rule.action, .allow)
        XCTAssertEqual(rule.app, event.bundleID)
        XCTAssertEqual(rule.destination, event.matchedHost)
        XCTAssertEqual(rule.destinationMatch, .exact)

        var suffixEvent = event
        suffixEvent.match = .suffix
        XCTAssertEqual(RulePackActivityAction.normalAllowRule(for: suffixEvent).destinationMatch, .suffix)
    }

    func testNetworkRuleGroupingSeparatesActiveFromDisabledExpiredAndSpent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = "test-session"
        let active = Rule(name: "active")
        var disabled = Rule(name: "disabled")
        disabled.enabled = false
        var expired = Rule(name: "expired")
        expired.schedule = .expiring(in: -1, from: now)
        var spent = Rule(name: "spent")
        spent.maxHits = 1
        spent.hits = 1
        let rules = [active, disabled, expired, spent]

        XCTAssertEqual(NetworkRuleGrouping.inForce(rules, at: now, session: session).map(\.id), [active.id])
        XCTAssertEqual(Set(NetworkRuleGrouping.resting(rules, at: now, session: session).map(\.id)),
                       Set([disabled.id, expired.id, spent.id]))
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
