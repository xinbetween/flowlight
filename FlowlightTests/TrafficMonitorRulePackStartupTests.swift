import XCTest
@testable import Flowlight

private enum InjectedPolicyLoadError: LocalizedError {
    case failed
    var errorDescription: String? { "injected policy load failure" }
}

final class TrafficMonitorRulePackStartupTests: XCTestCase {
    private var priorInspectionEnabled: Any?

    override func setUp() {
        super.setUp()
        priorInspectionEnabled = UserDefaults.standard.object(forKey: InspectionController.Keys.enabled)
        UserDefaults.standard.set(false, forKey: InspectionController.Keys.enabled)
    }

    override func tearDown() {
        if let priorInspectionEnabled {
            UserDefaults.standard.set(priorInspectionEnabled, forKey: InspectionController.Keys.enabled)
        } else {
            UserDefaults.standard.removeObject(forKey: InspectionController.Keys.enabled)
        }
        super.tearDown()
    }

    @MainActor
    func testTrafficSourceStartsAfterCatalogAndExceptionsReload() async throws {
        let url = temporaryDatabaseURL("startup-order")
        let db = try TrafficDatabase(url: url)
        let definition = BuiltInRulePacks.advertising
        let verified = try productionCatalog()
        _ = try db.acceptVerifiedRulePackCatalog(
            try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.15.4"), checkedAt: Date(),
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
    func testPersistedGuardrailsLoadBeforeInspectionAttaches() async throws {
        let url = temporaryDatabaseURL("guardrail-barrier")
        let db = try TrafficDatabase(url: url)
        let persisted = Guardrail(agent: "custom-agent", tool: "write_file")
        try db.saveGuardrail(persisted)
        let source = RecordingTrafficSource()
        let monitor = TrafficMonitor(databaseURL: url, trafficSourceFactory: { source })

        monitor.start()
        try await waitUntil { monitor.inspection.attached }

        XCTAssertTrue(monitor.inspection.policyStateReady)
        XCTAssertEqual(monitor.guardrails.guardrails, [persisted])
        XCTAssertEqual(monitor.inspection.guardrails(), [persisted])
    }

    @MainActor
    func testPolicyLoadFailureCompletesStartupFailClosedWithVisibleError() async throws {
        let source = RecordingTrafficSource()
        let monitor = TrafficMonitor(
            databaseURL: temporaryDatabaseURL("policy-load-failure"),
            trafficSourceFactory: { source },
            policyLoader: { _ in throw InjectedPolicyLoadError.failed }
        )

        monitor.start()
        try await waitUntil { monitor.inspection.lastError?.contains("injected policy load failure") == true }

        XCTAssertFalse(monitor.inspection.policyStateReady)
        XCTAssertFalse(monitor.inspection.attached)
    }

    @MainActor
    func testEnabledManagedPackKeepsInspectionStoppedUntilExactCommit() async throws {
        let url = temporaryDatabaseURL("pack-commit-barrier")
        let db = try TrafficDatabase(url: url)
        let definition = BuiltInRulePacks.advertising
        let verified = try productionCatalog()
        _ = try db.acceptVerifiedRulePackCatalog(
            try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.15.4"), checkedAt: Date(),
            nextEligibleAt: Date().addingTimeInterval(86_400)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)

        let source = ExtensionTrafficSource()
        let monitor = TrafficMonitor(databaseURL: url, trafficSourceFactory: { source })
        monitor.start()
        try await waitUntil {
            source.onRulePackStatus != nil && monitor.rulePacks.snapshot != nil
        }
        let digest = try XCTUnwrap(monitor.rulePacks.snapshot?.digest)

        XCTAssertFalse(monitor.inspection.attached)
        XCTAssertFalse(monitor.inspection.policyStateReady)

        source.onRulePackStatus?(.init(status: .committed, activeDigest: "not-\(digest)"))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(monitor.inspection.attached)
        XCTAssertFalse(monitor.inspection.policyStateReady)

        source.onRulePackStatus?(.init(status: .committed, activeDigest: digest))
        try await waitUntil { monitor.inspection.attached }
        XCTAssertTrue(monitor.inspection.policyStateReady)
    }

    @MainActor
    func testFilterWarningClearsWhenTheSameExtensionRecovers() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "FLForceFilterWarning")
        defaults.set(false, forKey: "FLForceFilterWarning")
        defer {
            if let prior { defaults.set(prior, forKey: "FLForceFilterWarning") }
            else { defaults.removeObject(forKey: "FLForceFilterWarning") }
        }
        let source = ExtensionTrafficSource()
        let monitor = TrafficMonitor(
            databaseURL: temporaryDatabaseURL("filter-recovery"),
            trafficSourceFactory: { source }
        )
        monitor.start()
        try await waitUntil { source.onFilterAvailabilityChanged != nil }

        source.onFilterAvailabilityChanged?(false, "filter unavailable")
        try await waitUntil { monitor.captureWarning == "filter unavailable" }

        source.onFilterAvailabilityChanged?(true, nil)
        try await waitUntil { monitor.captureWarning == nil }
    }

    @MainActor
    func testAllEnabledPacksSurviveFreshMonitorStartup() async throws {
        let url = temporaryDatabaseURL("enabled-restart")
        let firstSource = RecordingTrafficSource()
        let first = TrafficMonitor(databaseURL: url, trafficSourceFactory: { firstSource })
        first.start()
        try await waitUntil { firstSource.started && first.rulePacks.definitions.count == 3 }

        for definition in first.rulePacks.definitions {
            var configuration = first.rulePacks.configuration(for: definition.id)
            configuration.enabled = true
            var saveResult: RulePackStore.SaveResult?
            first.rulePacks.save(
                configuration,
                reviewedDefinition: definition,
                receipt: try XCTUnwrap(first.rulePacks.reviewReceipt(for: definition))
            ) { saveResult = $0 }
            try await waitUntil { saveResult != nil }
            XCTAssertEqual(saveResult, .saved)
        }

        let saved = try TrafficDatabase(url: url).loadRulePackConfigurations()
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.allSatisfy(\.enabled))

        let restartedSource = RecordingTrafficSource()
        let restarted = TrafficMonitor(databaseURL: url, trafficSourceFactory: { restartedSource })
        restarted.start()
        try await waitUntil { restartedSource.started }

        let expectedIDs = first.rulePacks.definitions.map(\.id)
        XCTAssertEqual(restarted.rulePacks.configurations.filter(\.enabled).map(\.packID), expectedIDs)
        XCTAssertEqual(restarted.rulePacks.snapshot?.configurations.map(\.packID), expectedIDs)
        XCTAssertEqual(restartedSource.rulePackSnapshots.last??.configurations.map(\.packID), expectedIDs)
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

    @MainActor
    func testSupersededExtensionCannotPublishALatePackCommit() async throws {
        let oldExtension = ExtensionTrafficSource()
        let replacement = RecordingTrafficSource()
        var sourceCount = 0
        let monitor = TrafficMonitor(
            databaseURL: temporaryDatabaseURL("stale-extension-status"),
            trafficSourceFactory: {
                sourceCount += 1
                return sourceCount == 1 ? oldExtension : replacement
            }
        )

        monitor.start()
        try await waitUntil { sourceCount == 1 && oldExtension.onRulePackStatus != nil }
        monitor.reconnectSource()
        try await waitUntil { replacement.started }

        oldExtension.onRulePackStatus?(.init(status: .committed, activeDigest: "stale"))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(monitor.rulePacks.status, .off)
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
