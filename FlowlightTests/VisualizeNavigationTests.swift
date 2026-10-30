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
}
