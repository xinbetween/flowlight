import XCTest
@testable import Flowlight

@MainActor
final class VisualizeNavigationTests: XCTestCase {
    func testVisualizeIsReachableFromTrafficWithoutStealingExistingShortcuts() {
        XCTAssertTrue(SidebarItem.availableCases.contains(.visualize))
        XCTAssertEqual(SidebarItem.visualize.section, .traffic)
        XCTAssertEqual(SidebarSection.traffic.items, [.live, .agents, .reports, .visualize, .alerts])
        XCTAssertNil(SidebarItem.visualize.shortcut)
        XCTAssertEqual(SidebarItem.alerts.shortcut, "4")
        XCTAssertEqual(SidebarItem.rules.shortcut, "5")
    }

    func testVisualizeUsesItsOwnHelpSection() {
        XCTAssertEqual(SidebarItem.visualize.helpAnchor, "visualize")
        XCTAssertEqual(SidebarItem.visualize.englishTitle, "Visualize")
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
        XCTAssertTrue(rule.matches(FlowFacts(agentKey: "claude", bundleID: "node",
                                             host: "api.github.com", ip: "203.0.113.9",
                                             port: 443, hostSettled: true)))
        XCTAssertFalse(rule.matches(FlowFacts(agentKey: "cursor", bundleID: "node",
                                              host: "api.github.com", ip: "203.0.113.9",
                                              port: 443, hostSettled: true)),
                       "the same child executable working for another agent must stay outside the draft")
    }
}
