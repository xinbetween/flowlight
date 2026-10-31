import XCTest
@testable import Flowlight

@MainActor
final class VisualizeNavigationTests: XCTestCase {
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

    func testVisualizeUsesItsOwnHelpSection() {
        XCTAssertEqual(SidebarItem.visualize.helpAnchor, "visualize")
        XCTAssertEqual(SidebarItem.visualize.englishTitle, "Visualize")
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
        VisualizeActionScope.showInspect(nav, filter: filter)
        XCTAssertNil(nav.inspectRequest)
    }

    func testAttributedChildBlockDraftTargetsTheProvenAgent() {
        let rule = VisualizeActionScope.blockRule(for: TrafficFilter(
            bundleID: "node",
            agentParent: "claude",
            mcpServer: "github",
            domain: "api.github.com",
            remoteIP: "203.0.113.9"
        ))

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
