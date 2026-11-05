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

    func testDestinationShortcutsFollowTheVisibleSidebarOrder() {
        XCTAssertTrue(SidebarItem.availableCases.contains(.visualize))
        XCTAssertEqual(SidebarItem.visualize.section, .traffic)
        XCTAssertEqual(SidebarSection.traffic.items, [.live, .agents, .reports, .visualize, .alerts])
        XCTAssertEqual(SidebarItem.sidebarOrder,
                       [.live, .agents, .reports, .visualize, .alerts,
                        .ask, .inspect, .rules, .sources])
        XCTAssertEqual(SidebarItem.visualize.shortcut, "4")
        XCTAssertEqual(SidebarItem.alerts.shortcut, "5")
        XCTAssertEqual(SidebarItem.rules.shortcut, "8")
        XCTAssertEqual(SidebarItem.sources.shortcut, "9")
        XCTAssertTrue(SidebarItem.sidebarOrder.allSatisfy { $0.shortcut != nil })
    }

    func testSourcesCoverageDistinguishesNoEvidenceFromZeroPercentNamed() {
        XCTAssertEqual(SourceSetupPolicy.coverageHealth(named: 0, hasTraffic: false), .empty)
        XCTAssertEqual(SourceSetupPolicy.coverageHealth(named: 0, hasTraffic: true), .warning)
        XCTAssertEqual(SourceSetupPolicy.coverageHealth(named: 0.8, hasTraffic: true), .warning)
        XCTAssertEqual(SourceSetupPolicy.coverageHealth(named: 0.81, hasTraffic: true), .good)
    }

    func testSourcesRecoveryChecklistRequiresAConfiguredCollectorAndArrivingData() {
        XCTAssertTrue(SourceSetupPolicy.collectorConfigured(mode: .nettop, extensionState: .notInstalled,
                                                            extensionFellBack: false),
                      "the sampler needs no separate filter setup")
        XCTAssertFalse(SourceSetupPolicy.collectorConfigured(mode: .networkExtension,
                                                             extensionState: .notInstalled,
                                                             extensionFellBack: false))
        XCTAssertTrue(SourceSetupPolicy.collectorConfigured(mode: .networkExtension,
                                                            extensionState: .enabled,
                                                            extensionFellBack: false))
        XCTAssertFalse(SourceSetupPolicy.collectorConfigured(mode: .networkExtension,
                                                             extensionState: .enabled,
                                                             extensionFellBack: true),
                       "fallback is working but is not the configured collector")
        XCTAssertFalse(SourceSetupPolicy.setupComplete(mode: .nettop, extensionState: .unknown,
                                                       extensionFellBack: false, isReceiving: false))
        XCTAssertTrue(SourceSetupPolicy.setupComplete(mode: .nettop, extensionState: .unknown,
                                                      extensionFellBack: false, isReceiving: true))
    }

    func testFocusNoticeClaimsFilteringOnlyWhereTheWholeScopeApplies() {
        let appOnly = FocusScope(bundleIDs: ["com.example.app"])
        let destinationOnly = FocusScope(hosts: ["example.com"])
        let mixed = FocusScope(bundleIDs: ["com.example.app"], hosts: ["example.com"])

        XCTAssertTrue(SidebarItem.live.fullyAppliesFocus(mixed))
        XCTAssertTrue(SidebarItem.agents.fullyAppliesFocus(mixed))
        XCTAssertTrue(SidebarItem.reports.fullyAppliesFocus(mixed))
        XCTAssertTrue(SidebarItem.visualize.fullyAppliesFocus(mixed))
        XCTAssertTrue(SidebarItem.inspect.fullyAppliesFocus(mixed))
        XCTAssertTrue(SidebarItem.alerts.fullyAppliesFocus(appOnly))
        XCTAssertFalse(SidebarItem.alerts.fullyAppliesFocus(destinationOnly))
        XCTAssertFalse(SidebarItem.alerts.fullyAppliesFocus(mixed))
        XCTAssertFalse(SidebarItem.ask.fullyAppliesFocus(mixed))
        XCTAssertFalse(SidebarItem.rules.fullyAppliesFocus(mixed))
        XCTAssertFalse(SidebarItem.sources.fullyAppliesFocus(mixed))
    }

    func testConnectionsKeepsTheCompatibleVisualizeRouteAndHelpAnchor() {
        XCTAssertEqual(SidebarItem.visualize.rawValue, "visualize")
        XCTAssertEqual(SidebarItem.visualize.helpAnchor, "visualize")
        XCTAssertEqual(SidebarItem.visualize.englishTitle, "Connections")
    }

    func testConnectionsLoadingAlwaysOutranksAStaleSnapshotAndYieldsToEmptyState() {
        XCTAssertTrue(ConnectionsRenderPolicy.showsLoading(isLoading: true, hasSnapshot: true))
        XCTAssertTrue(ConnectionsRenderPolicy.showsLoading(isLoading: true, hasSnapshot: false))
        XCTAssertFalse(ConnectionsRenderPolicy.showsLoading(isLoading: false, hasSnapshot: true))
        XCTAssertFalse(ConnectionsRenderPolicy.showsLoading(isLoading: false, hasSnapshot: false))
    }

    func testConnectionsRejectsAStaleAsyncCompletion() {
        let current = UUID()
        XCTAssertTrue(ConnectionsRenderPolicy.canCommit(requestID: current, currentID: current, cancelled: false))
        XCTAssertFalse(ConnectionsRenderPolicy.canCommit(requestID: UUID(), currentID: current, cancelled: false))
        XCTAssertFalse(ConnectionsRenderPolicy.canCommit(requestID: current, currentID: current, cancelled: true))
    }

    func testConnectionsWaitsForCurrentDataBeforeRebuilding() {
        let current = UUID()
        XCTAssertTrue(ConnectionsRenderPolicy.canRebuild(loadedID: current, currentLoadID: current))
        XCTAssertFalse(ConnectionsRenderPolicy.canRebuild(loadedID: nil, currentLoadID: current))
        XCTAssertFalse(ConnectionsRenderPolicy.canRebuild(loadedID: UUID(), currentLoadID: current))
    }

    func testCrossScreenBackRestoresReportOriginAndScope() {
        let nav = AppNavigation()
        nav.show(.visualize)
        let reportFilter = TrafficFilter(bundleID: "claude", domain: "api.anthropic.com")

        nav.showReport(filter: reportFilter, granularity: .hour, end: Date(timeIntervalSince1970: 42))
        nav.updateCurrentReportScope(filter: reportFilter, granularity: .hour,
                                     startDate: Date(timeIntervalSince1970: 0),
                                     endDate: Date(timeIntervalSince1970: 42), followNow: false,
                                     preset: nil)
        nav.showInspect(app: ("claude", "Claude Code"), host: "api.anthropic.com")

        XCTAssertEqual(nav.backDestination, .reports)
        nav.goBack()
        XCTAssertEqual(nav.selection, .reports)
        XCTAssertEqual(nav.reportRequest?.filter, reportFilter)
        XCTAssertEqual(nav.reportRequest?.granularity, .hour)
        XCTAssertEqual(nav.reportRequest?.end, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(nav.reportRequest?.duration, 42)
        XCTAssertNil(nav.reportRequest?.preset)
        XCTAssertEqual(nav.backDestination, .visualize)
        nav.goBack()
        XCTAssertEqual(nav.selection, .visualize)
        XCTAssertNil(nav.backDestination)
    }

    func testCrossScreenBackPreservesAFollowingHistoryDurationAndPreset() {
        let nav = AppNavigation()
        nav.show(.reports)
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(15 * 60)
        nav.updateCurrentReportScope(filter: .none, granularity: .minute,
                                     startDate: start, endDate: end, followNow: true,
                                     preset: .fifteenMinutes)

        nav.showInspect(host: "api.anthropic.com")
        nav.goBack()

        XCTAssertEqual(nav.selection, .reports)
        XCTAssertNil(nav.reportRequest?.start)
        XCTAssertNil(nav.reportRequest?.end)
        XCTAssertEqual(nav.reportRequest?.duration, 15 * 60)
        XCTAssertEqual(nav.reportRequest?.preset, .fifteenMinutes)
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

    func testReviewAlertsNavigationReturnsToTheAlertList() {
        let nav = AppNavigation()
        nav.show(.alerts)
        nav.alertsTab = .detection

        nav.showAlerts()

        XCTAssertEqual(nav.selection, .alerts)
        XCTAssertEqual(nav.alertsTab, .alerts)
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
