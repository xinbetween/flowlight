import XCTest
@testable import Flowlight

final class TrafficMonitorRulePackStartupTests: XCTestCase {
    @MainActor
    func testTrafficSourceStartsAfterCatalogAndExceptionsReload() async throws {
        let url = temporaryDatabaseURL("startup-order")
        let db = try TrafficDatabase(url: url)
        let definition = BuiltInRulePacks.advertising
        let verified = try productionCatalog()
        _ = try db.acceptVerifiedRulePackCatalog(
            try RulePackCatalogComposition.compose(verified), checkedAt: Date(),
            nextEligibleAt: Date().addingTimeInterval(86_400)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)
        let exception = RulePackOverride(
            packID: definition.id, app: "com.apple.Safari", host: definition.entries[0].host
        )
        try db.saveRulePackOverride(exception)

        let source = RecordingTrafficSource()
        let monitor = TrafficMonitor(databaseURL: url, trafficSourceFactory: { source })
        XCTAssertFalse(source.started)

        monitor.start()
        try await waitUntil { source.started }

        let snapshot = try XCTUnwrap(source.rulePackSnapshots.last ?? nil)
        XCTAssertEqual(snapshot.configurations.map(\.packID), [definition.id])
        XCTAssertEqual(snapshot.overrides, [exception])
        XCTAssertEqual(monitor.rulePackCatalog.receipt?.sequence, verified.sequence)
    }

    @MainActor
    func testTestModeBootstrapDoesNotInvokeCatalogTransport() async throws {
        let source = RecordingTrafficSource()
        let monitor = TrafficMonitor(
            databaseURL: temporaryDatabaseURL("no-network"),
            trafficSourceFactory: { source }
        )

        monitor.start()
        try await waitUntil { source.started }

        XCTAssertFalse(monitor.rulePackCatalog.networkingEnabled)
        XCTAssertFalse(monitor.rulePacks.definitions.isEmpty)
        XCTAssertNotNil(monitor.rulePackCatalog.receipt)
    }

    private func productionCatalog() throws -> VerifiedRulePackCatalog {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "official", withExtension: "json"))
        return try RulePackCatalogVerifier.verify(
            data: Data(contentsOf: url),
            trustedSigners: RulePackCatalogVerifier.productionTrustedSigners,
            now: 1_800_000_000, currentAppVersion: "0.15.4"
        )
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-monitor-\(name)-\(UUID().uuidString).sqlite")
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for monitor startup")
    }
}

private final class CallCounter: @unchecked Sendable {
    var calls = 0
}

private final class RecordingTrafficSource: TrafficSource {
    let displayName = "Test source"
    private(set) var started = false
    private(set) var rulePackSnapshots: [RulePackSnapshot?] = []

    func start(sink: @escaping ([TrafficBatch]) -> Void,
               status: @escaping (String) -> Void) {
        started = true
        status("ready")
    }

    func stop() {}
    func setRulePacks(_ snapshot: RulePackSnapshot?) { rulePackSnapshots.append(snapshot) }
}
