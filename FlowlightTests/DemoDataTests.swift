import XCTest
@testable import Flowlight

/// Demo mode is the first thing anyone tries and the only thing the published screenshots come from, so it is
/// worth a test that says it actually wrote something.
final class DemoDataTests: XCTestCase {

    func testSeedingFillsTheRollupsTheViewsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)

        try DemoData.seed(db)

        let day = try db.breakdown(.hour, from: Date().addingTimeInterval(-24 * 3600), to: Date())
        XCTAssertFalse(day.isEmpty, "the last day has no hourly rollups, so every view that reads history is empty")
        XCTAssertTrue(day.contains { !$0.bundleID.isEmpty }, "rollups exist but name no app")
    }
}
