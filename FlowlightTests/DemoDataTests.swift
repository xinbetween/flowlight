import XCTest
@testable import Flowlight

/// Demo mode is the first thing anyone tries and the only thing the published screenshots come from, so it is
/// worth a test that says it actually wrote something.
final class DemoDataTests: XCTestCase {

    func testPluginReviewFixtureRequiresDemoMode() {
        let defaults = UserDefaults.standard
        let previousDemo = defaults.object(forKey: "FLDemo")
        let previousPath = defaults.object(forKey: "FLDemoPluginReview")
        defer {
            if let previousDemo { defaults.set(previousDemo, forKey: "FLDemo") }
            else { defaults.removeObject(forKey: "FLDemo") }
            if let previousPath { defaults.set(previousPath, forKey: "FLDemoPluginReview") }
            else { defaults.removeObject(forKey: "FLDemoPluginReview") }
        }

        defaults.set("/tmp/review-plugin.json", forKey: "FLDemoPluginReview")
        defaults.set(false, forKey: "FLDemo")
        XCTAssertNil(DemoData.pluginReviewURL)

        defaults.set(true, forKey: "FLDemo")
        XCTAssertEqual(DemoData.pluginReviewURL?.path, "/tmp/review-plugin.json")
    }

    func testSeedingFillsTheRollupsTheViewsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)

        try DemoData.seed(db)

        let day = try db.breakdown(.hour, from: Date().addingTimeInterval(-24 * 3600), to: Date())
        XCTAssertFalse(day.isEmpty, "the last day has no hourly rollups, so every view that reads history is empty")
        XCTAssertTrue(day.contains { !$0.bundleID.isEmpty }, "rollups exist but name no app")
        let blocked = try db.blockedAttempts(from: Date().addingTimeInterval(-24 * 3600), to: Date())
        XCTAssertTrue(blocked.contains { $0.destination == "www.google-analytics.com" })
        XCTAssertTrue(blocked.contains { $0.destination == "www.googletagmanager.com" && $0.count == 18 })
    }

    func testPackReviewFixtureWritesStaleConsentWithoutEnablingThePack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-pack-review-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)

        try DemoData.seedPackReview(db)

        let saved = try XCTUnwrap(db.loadRulePackConfigurations().first)
        XCTAssertEqual(saved.packID, BuiltInRulePacks.advertising.id)
        XCTAssertFalse(saved.enabled)
        XCTAssertFalse(saved.isConsented(to: BuiltInRulePacks.advertising))
        XCTAssertEqual(try db.loadRulePackReviewPackIDs(), [saved.packID])
    }
}
