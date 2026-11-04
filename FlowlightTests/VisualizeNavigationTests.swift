import XCTest
@testable import Flowlight

@MainActor
final class VisualizeNavigationTests: XCTestCase {
    func testForgettingAgentConfigurationDisablesAutomaticDiscoveryUntilManualRefresh() {
        let suite = "visualize-workspace-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentWorkspaceStore(defaults: defaults)

        store.refresh(gatewaysOnly: true)
        let staleGeneration = store.discoveryGeneration
        XCTAssertTrue(store.scanning)

        store.forget()
        store.storeDiscovery(
            [AgentWorkspace(agent: "claude", root: "~/.claude", isProject: false)],
            generation: staleGeneration,
            gatewaysOnly: true
        )
        XCTAssertTrue(store.workspaces.isEmpty,
                      "an in-flight scan must not repopulate configuration after Forget")
        XCTAssertFalse(store.scanning)
        XCTAssertTrue(defaults.bool(forKey: AgentWorkspaceStore.Keys.discoveryDisabled))

        store.refresh(gatewaysOnly: true)
        XCTAssertFalse(store.scanning,
                       "opening Visualize must not undo the explicit Forget privacy choice")
    }

    func testVisualizeIsReachableFromTrafficWithoutStealingExistingShortcuts() {
        XCTAssertTrue(SidebarItem.availableCases.contains(.visualize))
        XCTAssertEqual(SidebarItem.visualize.section, .traffic)
        XCTAssertEqual(SidebarSection.traffic.items, [.live, .agents, .reports, .visualize, .alerts])
        XCTAssertNil(SidebarItem.visualize.shortcut,
                     "an eleventh direct-build screen must remain reachable without hijacking Space")
        XCTAssertEqual(SidebarItem.availableCases.filter { $0.shortcut == nil }, [.visualize])
        XCTAssertEqual(SidebarItem.alerts.shortcut, "4")
        XCTAssertEqual(SidebarItem.rules.shortcut, "5")
    }

    func testConnectionsKeepsTheCompatibleVisualizeRouteAndHelpAnchor() {
        XCTAssertEqual(SidebarItem.visualize.rawValue, "visualize")
        XCTAssertEqual(SidebarItem.visualize.helpAnchor, "visualize")
        XCTAssertEqual(SidebarItem.visualize.englishTitle, "Connections")
    }

    func testConnectionsLoadingAlwaysOutranksAStaleSnapshot() {
        XCTAssertTrue(ConnectionsRenderPolicy.showsLoading(isLoading: true, hasSnapshot: true))
        XCTAssertTrue(ConnectionsRenderPolicy.showsLoading(isLoading: true, hasSnapshot: false))
        XCTAssertFalse(ConnectionsRenderPolicy.showsLoading(isLoading: false, hasSnapshot: true))
    }

    func testConnectionsRejectsAStaleAsyncCompletion() {
        let current = UUID()
        XCTAssertTrue(ConnectionsRenderPolicy.canCommit(requestID: current, currentID: current, cancelled: false))
        XCTAssertFalse(ConnectionsRenderPolicy.canCommit(requestID: UUID(), currentID: current, cancelled: false))
        XCTAssertFalse(ConnectionsRenderPolicy.canCommit(requestID: current, currentID: current, cancelled: true))
    }

    func testCrossScreenBackRestoresReportOriginAndScope() {
        let nav = AppNavigation()
        nav.show(.visualize)
        let reportFilter = TrafficFilter(bundleID: "claude", domain: "api.anthropic.com")

        nav.showReport(filter: reportFilter, granularity: .hour, end: Date(timeIntervalSince1970: 42))
        nav.updateCurrentReportScope(filter: reportFilter, granularity: .hour,
                                     startDate: Date(timeIntervalSince1970: 0),
                                     endDate: Date(timeIntervalSince1970: 42), followNow: false)
        nav.showInspect(app: ("claude", "Claude Code"), host: "api.anthropic.com")

        XCTAssertEqual(nav.backDestination, .reports)
        nav.goBack()
        XCTAssertEqual(nav.selection, .reports)
        XCTAssertEqual(nav.reportRequest?.filter, reportFilter)
        XCTAssertEqual(nav.reportRequest?.granularity, .hour)
        XCTAssertEqual(nav.reportRequest?.end, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(nav.backDestination, .visualize)
        nav.goBack()
        XCTAssertEqual(nav.selection, .visualize)
        XCTAssertNil(nav.backDestination)
    }

    func testPackReviewNavigationClearsCrossScreenTrailAndOpensPacks() {
        let nav = AppNavigation()
        nav.show(.visualize)
        nav.showReport(filter: TrafficFilter(domain: "api.anthropic.com"))
        nav.showInspect(app: ("claude", "Claude Code"), host: "api.anthropic.com")
        XCTAssertNotNil(nav.backDestination)

        nav.showPackReviews()

        XCTAssertEqual(nav.selection, .rules)
        XCTAssertEqual(nav.rulesTab, .packs)
        XCTAssertNil(
            nav.backDestination,
            "pack review navigation starts a new task and must not retain an unrelated investigation trail"
        )
    }

    func testExactInspectNavigationCarriesExactMemberScope() {
        let nav = AppNavigation()
        VisualizeActionScope.showInspect(nav, filter: TrafficFilter(
            bundleID: "node",
            agentParent: "claude",
            mcpServer: "github",
            domain: "api.github.com",
            remoteIP: "203.0.113.9"
        ), sourceTitle: "Node")

        XCTAssertEqual(nav.inspectRequest?.appID, "node")
        XCTAssertEqual(nav.inspectRequest?.appName, "Node")
        XCTAssertEqual(nav.inspectRequest?.host, "api.github.com")
        XCTAssertEqual(nav.inspectRequest?.hostIncludesSubdomains, false)
        XCTAssertEqual(nav.inspectRequest?.agentParent, "claude")
        XCTAssertEqual(nav.inspectRequest?.mcpServer, "github")
    }

    func testIPOnlyDestinationDoesNotOfferUnsupportedInspectScope() {
        let nav = AppNavigation()
        let filter = TrafficFilter(bundleID: "node", remoteIP: "203.0.113.9")

        XCTAssertFalse(VisualizeActionScope.canInspect(filter))
        XCTAssertTrue(VisualizeActionScope.canBlock(filter))
        VisualizeActionScope.showInspect(nav, filter: filter)
        XCTAssertNil(nav.inspectRequest)
    }

    func testDisplayOnlyDestinationDoesNotOfferDeadActions() {
        let nav = AppNavigation()
        for displayOnly in ["(unconnected)", "AirDrop and Handoff · nearby device"] {
            let filter = TrafficFilter(bundleID: "sharingd", domain: displayOnly, remoteIP: displayOnly)
            XCTAssertFalse(VisualizeActionScope.canInspect(filter))
            XCTAssertFalse(VisualizeActionScope.canBlock(filter))
            XCTAssertNil(VisualizeActionScope.blockRule(for: filter))
            VisualizeActionScope.showInspect(nav, filter: filter)
            XCTAssertNil(nav.inspectRequest)
        }
    }

    func testMergedAliasScopePreservesExactInspectAliasesAndDisablesAmbiguousBlock() {
        let nav = AppNavigation()
        let filter = TrafficFilter(
            bundleIDs: ["claude", "claude-code"],
            domain: "api.anthropic.com"
        )

        VisualizeActionScope.showInspect(nav, filter: filter, sourceTitle: "Claude Code")

        XCTAssertNil(nav.inspectRequest?.appID)
        XCTAssertEqual(nav.inspectRequest?.appIDs, ["claude", "claude-code"])
        XCTAssertEqual(nav.inspectRequest?.appName, "Claude Code")
        XCTAssertEqual(nav.inspectRequest?.host, "api.anthropic.com")
        XCTAssertNil(VisualizeActionScope.blockRule(for: filter))
    }

    func testGlobalFocusDoesNotMakeAnExactAppActionAmbiguous() {
        let nav = AppNavigation()
        let filter = TrafficFilter(
            bundleID: "claude",
            domain: "api.anthropic.com",
            focus: FocusScope(bundleIDs: ["claude", "claude-code"])
        )

        VisualizeActionScope.showInspect(nav, filter: filter, sourceTitle: "Claude Code")

        XCTAssertEqual(nav.inspectRequest?.appID, "claude")
        XCTAssertEqual(VisualizeActionScope.blockRule(for: filter)?.app, "claude")
    }

    func testReportsOfferInspectOnlyWhenTheCompleteScopeIsRepresentable() {
        XCTAssertTrue(InspectNavigationScope.canInspect(
            TrafficFilter(bundleID: "node", agentParent: "claude", mcpServer: "github", domain: "api.github.com"),
            requireDestination: false
        ))
        XCTAssertFalse(InspectNavigationScope.canInspect(
            TrafficFilter(bundleID: "node", remoteIP: "203.0.113.9"),
            requireDestination: false
        ))
        XCTAssertFalse(InspectNavigationScope.canInspect(
            TrafficFilter(bundleID: "node", domainSuffix: "github.com"),
            requireDestination: false
        ))
    }

    func testAttributedChildBlockDraftTargetsTheProvenAgent() {
        let rule = try! XCTUnwrap(VisualizeActionScope.blockRule(for: TrafficFilter(
            bundleID: "node",
            agentParent: "claude",
            mcpServer: "github",
            domain: "api.github.com",
            remoteIP: "203.0.113.9"
        )))

        XCTAssertEqual(rule.app, "claude")
        XCTAssertEqual(rule.destination, "api.github.com")
        XCTAssertEqual(rule.destinationMatch, .exact)
        XCTAssertTrue(rule.matches(FlowFacts(agentKey: "claude", bundleID: "node",
                                             host: "api.github.com", ip: "203.0.113.9",
                                             port: 443, hostSettled: true)))
        XCTAssertFalse(rule.matches(FlowFacts(agentKey: "cursor", bundleID: "node",
                                              host: "api.github.com", ip: "203.0.113.9",
                                              port: 443, hostSettled: true)),
                       "the same child executable working for another agent must stay outside the draft")
        XCTAssertFalse(rule.matches(FlowFacts(agentKey: "claude", bundleID: "node",
                                              host: "child.api.github.com", ip: "203.0.113.10",
                                              port: 443, hostSettled: true)),
                       "an exact visualization member must not draft a suffix rule")
    }
}
