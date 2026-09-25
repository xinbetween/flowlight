import XCTest
@testable import Flowlight

/// "Show 25 more" — the row that stands in for the rest of a long list.
final class TrafficTreePagingTests: XCTestCase {

    func testAShortListGetsNoShowMoreRow() {
        let capped = TrafficNode.capped(nodes(10), parentID: "app", parent: parent, limits: [:])
        XCTAssertEqual(capped.count, 10)
        XCTAssertNil(capped.first(where: { $0.kind == .more }))
    }

    func testALongListIsCutToAPagePlusTheSummaryRow() {
        let capped = TrafficNode.capped(nodes(91), parentID: "app", parent: parent, limits: [:])
        XCTAssertEqual(capped.count, TrafficNode.pageSize + 1)
        let more = try? XCTUnwrap(capped.last)
        XCTAssertEqual(more?.kind, .more)
        XCTAssertEqual(more?.moreCount, 66, "the row has to name how many are hidden")
        XCTAssertEqual(more?.id, "app" + TrafficNode.moreSuffix)
    }

    func testTheSummaryRowCarriesTheHiddenTotalsRatherThanZero() {
        // The row shows a share and a byte count; if those were empty the column wouldn't add up.
        let capped = TrafficNode.capped(nodes(30), parentID: "app", parent: parent, limits: [:])
        XCTAssertEqual(capped.last?.total, 5 * 1_000)
    }

    func testClickingShowMoreRevealsAnotherPage() {
        var limits: [String: Int] = [:]
        var capped = TrafficNode.capped(nodes(91), parentID: "app", parent: parent, limits: limits)
        let more = capped.last!

        limits = TrafficNode.showingMore(limits, after: more.id)
        capped = TrafficNode.capped(nodes(91), parentID: "app", parent: parent, limits: limits)
        XCTAssertEqual(limits["app"], 50)
        XCTAssertEqual(capped.count, 51)
        XCTAssertEqual(capped.last?.moreCount, 41)
    }

    func testEachClickAddsAPageRatherThanResettingToOne() {
        // The bug this guards: raising the limit from the page size instead of the current limit, which makes
        // the second click show the same rows as the first.
        var limits: [String: Int] = [:]
        for _ in 0..<3 { limits = TrafficNode.showingMore(limits, after: "app" + TrafficNode.moreSuffix) }
        XCTAssertEqual(limits["app"], 100)
    }

    func testTheRootListStartsWiderAndStillGrowsByAPage() {
        let capped = TrafficNode.capped(nodes(200), parentID: TrafficNode.rootID, parent: nil, limits: [:])
        XCTAssertEqual(capped.count, TrafficNode.rootPageSize + 1)
        let limits = TrafficNode.showingMore([:], after: TrafficNode.rootID + TrafficNode.moreSuffix)
        XCTAssertEqual(limits[TrafficNode.rootID], 125)
    }

    func testAnOrdinaryRowIsNotMistakenForASummaryRow() {
        XCTAssertNil(TrafficNode.parent(ofMoreRow: "app|github.com"))
        XCTAssertEqual(TrafficNode.showingMore(["app": 25], after: "app|github.com"), ["app": 25])
    }

    // MARK: -

    private let parent = TrafficNode(id: "app", kind: .app, title: "Codex", filter: .none)

    private func nodes(_ count: Int) -> [TrafficNode] {
        (0..<count).map {
            TrafficNode(id: "app|\($0)", kind: .domain, title: "host\($0).example.com", filter: .none,
                        counters: FlowCounters(bytesIn: 1_000, bytesOut: 0, flows: 1))
        }
    }
}
