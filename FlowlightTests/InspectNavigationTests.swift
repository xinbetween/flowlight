import XCTest
@testable import Flowlight

@MainActor
final class InspectNavigationTests: XCTestCase {
    func testAskingForInspectSwitchesScreenAndCarriesTheSubject() {
        let nav = AppNavigation()
        nav.selection = .live
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
}
