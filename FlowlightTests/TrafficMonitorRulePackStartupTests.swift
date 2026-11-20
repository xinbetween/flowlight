import CryptoKit
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
        let verified = try productionCatalog()
        let composed = try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.18.6")
        let definition = try XCTUnwrap(
            composed.definitions.first { $0.id == AdvertisingPackTierPolicy.balancedID }
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            composed, checkedAt: Date(), nextEligibleAt: Date().addingTimeInterval(86_400)
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
        try await waitUntil(timeout: 30) { source.started }

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
        try await waitUntil(timeout: 30) { monitor.inspection.attached }

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
        let verified = try productionCatalog()
        let composed = try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.18.6")
        let definition = try XCTUnwrap(
            composed.definitions.first { $0.id == AdvertisingPackTierPolicy.balancedID }
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            composed, checkedAt: Date(), nextEligibleAt: Date().addingTimeInterval(86_400)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)

        let source = ExtensionTrafficSource()
        let monitor = TrafficMonitor(databaseURL: url, trafficSourceFactory: { source })
        monitor.start()
        try await waitUntil(timeout: 30) {
            source.onRulePackStatus != nil && monitor.rulePacks.snapshot != nil
        }
        let snapshot = try XCTUnwrap(monitor.rulePacks.snapshot)
        let digest = snapshot.digest

        XCTAssertFalse(monitor.inspection.attached)
        XCTAssertFalse(monitor.inspection.policyStateReady)

        source.onRulePackStatus?(.init(status: .committed, generation: snapshot.generation,
                                       activeDigest: "not-\(digest)"))
        try await waitUntil {
            if case .failed = monitor.rulePacks.status { return true }
            return false
        }
        XCTAssertFalse(monitor.inspection.attached)
        XCTAssertFalse(monitor.inspection.policyStateReady)

        source.onRulePackStatus?(.init(status: .committed, generation: UUID(), activeDigest: digest))
        try await waitUntil {
            if case .failed = monitor.rulePacks.status { return true }
            return false
        }
        XCTAssertFalse(monitor.inspection.attached)
        XCTAssertFalse(monitor.inspection.policyStateReady,
                       "matching bytes from the wrong transfer generation must fail closed")

        source.onRulePackStatus?(.init(status: .committed, generation: snapshot.generation,
                                       activeDigest: digest))
        try await waitUntil { monitor.inspection.attached }
        XCTAssertTrue(monitor.inspection.policyStateReady)
    }

    @MainActor
    func testReverseSameGenerationPreparationCompletionKeepsNewerSuccess() async throws {
        let url = temporaryDatabaseURL("pack-reverse-preparation")
        let db = try TrafficDatabase(url: url)
        let verified = try productionCatalog()
        let composed = try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.18.6")
        let definition = try XCTUnwrap(
            composed.definitions.first { $0.id == AdvertisingPackTierPolicy.balancedID }
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            composed, checkedAt: Date(), nextEligibleAt: Date().addingTimeInterval(86_400)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)

        let scheduler = MonitorPreparationScheduler()
        let source = ExtensionTrafficSource()
        let monitor = TrafficMonitor(
            databaseURL: url,
            trafficSourceFactory: { source },
            liveRulePacks: LiveRulePacks(preparationScheduler: { job in scheduler.schedule(job) })
        )
        monitor.start()
        try await waitUntil(timeout: 30) {
            source.onRulePackStatus != nil && monitor.rulePacks.snapshot != nil
        }
        let snapshot = try XCTUnwrap(monitor.rulePacks.snapshot)
        let digest = snapshot.digest

        source.onRulePackStatus?(.init(status: .committed, generation: snapshot.generation,
                                       activeDigest: digest))
        source.onRulePackStatus?(.init(status: .committed, generation: snapshot.generation,
                                       activeDigest: digest))
        try await waitUntil { scheduler.count == 2 }

        scheduler.run(at: 1)
        try await waitUntil { monitor.rulePacks.status == .enforcing }
        XCTAssertTrue(monitor.inspection.attached)
        XCTAssertTrue(monitor.inspection.policyStateReady)

        scheduler.run(at: 0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(monitor.rulePacks.status, .enforcing)
        XCTAssertTrue(monitor.inspection.attached)
        XCTAssertTrue(monitor.inspection.policyStateReady)
    }

    @MainActor
    func testRepeatedCommittedDigestAfterPreparationIsIdempotent() async throws {
        let url = temporaryDatabaseURL("pack-repeated-commit")
        let db = try TrafficDatabase(url: url)
        let verified = try productionCatalog()
        let composed = try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.18.6")
        let definition = try XCTUnwrap(
            composed.definitions.first { $0.id == AdvertisingPackTierPolicy.balancedID }
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            composed, checkedAt: Date(), nextEligibleAt: Date().addingTimeInterval(86_400)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)

        let scheduler = MonitorPreparationScheduler()
        let source = ExtensionTrafficSource()
        let live = LiveRulePacks(preparationScheduler: { job in scheduler.schedule(job) })
        let monitor = TrafficMonitor(
            databaseURL: url,
            trafficSourceFactory: { source },
            liveRulePacks: live
        )
        monitor.start()
        try await waitUntil(timeout: 30) {
            source.onRulePackStatus != nil && monitor.rulePacks.snapshot != nil
        }
        let snapshot = try XCTUnwrap(monitor.rulePacks.snapshot)
        let digest = snapshot.digest

        monitor.updateRulePackStatus(.init(status: .committed, generation: snapshot.generation,
                                           activeDigest: digest))
        XCTAssertEqual(scheduler.count, 1)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.configuredPackIDs, [definition.id])
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.desiredGeneration, snapshot.generation)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.extensionGeneration, snapshot.generation)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.extensionDigest, digest)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.proxyDigest, "")
        XCTAssertFalse(monitor.rulePacks.runtimeDiagnostics.isEnforcingDesiredDigest,
                       "extension acknowledgement alone is not runtime enforcement")
        scheduler.run(at: 0)
        try await waitUntil { monitor.rulePacks.status == .enforcing }
        XCTAssertEqual(live.activeDigest, digest)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.desiredDigest, digest)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.extensionDigest, digest)
        XCTAssertEqual(monitor.rulePacks.runtimeDiagnostics.proxyDigest, digest)
        XCTAssertTrue(monitor.rulePacks.runtimeDiagnostics.isEnforcingDesiredDigest)
        XCTAssertEqual(live.match(host: definition.entries[0].host, bundleID: "com.apple.Safari")?.packID,
                       definition.id)
        XCTAssertTrue(monitor.inspection.attached)
        XCTAssertTrue(monitor.inspection.policyStateReady)

        monitor.updateRulePackStatus(.init(status: .committed, generation: snapshot.generation,
                                           activeDigest: digest))

        XCTAssertEqual(scheduler.count, 0, "an already-live committed digest must not schedule another matcher build")
        XCTAssertEqual(live.activeDigest, digest, "the live matcher must not be cleared")
        XCTAssertEqual(live.match(host: definition.entries[0].host, bundleID: "com.apple.Safari")?.packID,
                       definition.id)
        XCTAssertEqual(monitor.rulePacks.status, .enforcing, "the visible status must not regress to applying")
        XCTAssertTrue(monitor.inspection.attached)
        XCTAssertTrue(monitor.inspection.policyStateReady, "the running inspection proxy must not be stopped")
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
        try await waitUntil(timeout: 30) { source.onFilterAvailabilityChanged != nil }

        source.onFilterAvailabilityChanged?(false, "filter unavailable")
        try await waitUntil { monitor.captureWarning == "filter unavailable" }

        source.onFilterAvailabilityChanged?(true, nil)
        try await waitUntil { monitor.captureWarning == nil }
    }

    @MainActor
    func testEnabledPacksSurviveFreshMonitorStartup() async throws {
        let url = temporaryDatabaseURL("enabled-restart")
        let firstSource = RecordingTrafficSource()
        let first = TrafficMonitor(databaseURL: url, trafficSourceFactory: { firstSource })
        first.start()
        try await waitUntil(timeout: 30) {
            firstSource.started && first.rulePacks.definitions.count == 4
        }

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
        XCTAssertEqual(saved.count, 4)
        XCTAssertEqual(saved.filter(\.enabled).count, 3)
        XCTAssertFalse(saved.first { $0.packID == AdvertisingPackTierPolicy.balancedID }?.enabled ?? true)
        XCTAssertTrue(saved.first { $0.packID == AdvertisingPackTierPolicy.aggressiveID }?.enabled ?? false)

        let restartedSource = RecordingTrafficSource()
        let restarted = TrafficMonitor(databaseURL: url, trafficSourceFactory: { restartedSource })
        restarted.start()
        try await waitUntil(timeout: 30) { restartedSource.started }

        let expectedIDs = first.rulePacks.configurations.filter(\.enabled).map(\.packID)
        XCTAssertEqual(restarted.rulePacks.configurations.filter(\.enabled).map(\.packID), expectedIDs)
        XCTAssertEqual(restarted.rulePacks.snapshot?.configurations.map(\.packID), expectedIDs)
        XCTAssertEqual(restartedSource.rulePackSnapshots.last??.configurations.map(\.packID), expectedIDs)
    }

    @MainActor
    func testAdvertisingTierReplacementSurvivesRestartAndReachesExtensionSnapshot() async throws {
        let url = temporaryDatabaseURL("advertising-tier-restart")
        let fixture = try advertisingCatalogFixture()
        let firstSource = RecordingTrafficSource()
        let first = TrafficMonitor(
            databaseURL: url,
            bundledRulePackCatalog: { fixture.data },
            rulePackCatalogTrustedSigners: [fixture.signer],
            trafficSourceFactory: { firstSource }
        )
        first.start()
        try await waitUntil(timeout: 30) {
            firstSource.started && first.rulePacks.definitions.count == 4
        }

        let balancedDefinition = try XCTUnwrap(
            first.rulePacks.definitions.first { $0.id == AdvertisingPackTierPolicy.balancedID }
        )
        var balanced = first.rulePacks.configuration(for: balancedDefinition.id)
        balanced.enabled = true
        var balancedSave: RulePackStore.SaveResult?
        first.rulePacks.save(
            balanced,
            reviewedDefinition: balancedDefinition,
            receipt: try XCTUnwrap(first.rulePacks.reviewReceipt(for: balancedDefinition))
        ) { balancedSave = $0 }
        try await waitUntil { balancedSave != nil }
        XCTAssertEqual(balancedSave, .saved)

        let balancedOverride = RulePackOverride(
            packID: balancedDefinition.id,
            app: "com.apple.Safari",
            host: "doubleclick.net"
        )
        var overrideSaved: Bool?
        first.rulePacks.addOverride(balancedOverride) { overrideSaved = $0 }
        try await waitUntil { overrideSaved != nil }
        XCTAssertEqual(overrideSaved, true)

        let aggressiveDefinition = try XCTUnwrap(
            first.rulePacks.definitions.first { $0.id == AdvertisingPackTierPolicy.aggressiveID }
        )
        var aggressive = first.rulePacks.configuration(for: aggressiveDefinition.id)
        aggressive.enabled = true
        var aggressiveSave: RulePackStore.SaveResult?
        first.rulePacks.save(
            aggressive,
            reviewedDefinition: aggressiveDefinition,
            receipt: try XCTUnwrap(first.rulePacks.reviewReceipt(for: aggressiveDefinition))
        ) { aggressiveSave = $0 }
        try await waitUntil { aggressiveSave != nil }
        XCTAssertEqual(aggressiveSave, .saved)
        try await waitUntil {
            firstSource.rulePackSnapshots.last??.configurations.map(\.packID)
                == [AdvertisingPackTierPolicy.aggressiveID]
        }

        let firstSnapshot = try XCTUnwrap(first.rulePacks.snapshot)
        XCTAssertEqual(firstSnapshot.configurations.map(\.packID), [AdvertisingPackTierPolicy.aggressiveID])
        XCTAssertEqual(firstSnapshot.overrides.count, 1)
        XCTAssertEqual(firstSnapshot.overrides.first?.packID, AdvertisingPackTierPolicy.aggressiveID)
        XCTAssertEqual(firstSnapshot.overrides.first?.host, balancedOverride.host)

        let restartedSource = RecordingTrafficSource()
        let restarted = TrafficMonitor(
            databaseURL: url,
            bundledRulePackCatalog: { fixture.data },
            rulePackCatalogTrustedSigners: [fixture.signer],
            trafficSourceFactory: { restartedSource }
        )
        restarted.start()
        try await waitUntil(timeout: 30) {
            restartedSource.started && restarted.rulePacks.definitions.count == 4
        }

        XCTAssertFalse(restarted.rulePacks.configuration(for: AdvertisingPackTierPolicy.balancedID).enabled)
        XCTAssertTrue(restarted.rulePacks.configuration(for: AdvertisingPackTierPolicy.aggressiveID).enabled)
        XCTAssertEqual(
            restarted.rulePacks.snapshot?.configurations.map(\.packID),
            [AdvertisingPackTierPolicy.aggressiveID]
        )
        XCTAssertEqual(
            restartedSource.rulePackSnapshots.last??.configurations.map(\.packID),
            [AdvertisingPackTierPolicy.aggressiveID]
        )
        XCTAssertEqual(restarted.rulePacks.snapshot?.overrides.first?.packID,
                       AdvertisingPackTierPolicy.aggressiveID)
    }

    @MainActor
    func testTestModeBootstrapDoesNotInvokeCatalogTransport() async throws {
        let source = RecordingTrafficSource()
        let monitor = TrafficMonitor(
            databaseURL: temporaryDatabaseURL("no-network"),
            trafficSourceFactory: { source }
        )

        monitor.start()
        try await waitUntil(timeout: 30) { source.started }

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
        try await waitUntil(timeout: 30) {
            sourceCount == 1 && oldExtension.onRulePackStatus != nil
        }
        monitor.reconnectSource()
        try await waitUntil { replacement.started }

        oldExtension.onRulePackStatus?(.init(status: .committed, activeDigest: "stale"))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(monitor.rulePacks.status, .off)
    }

    private func advertisingCatalogFixture() throws -> (
        data: Data,
        signer: RulePackCatalogTrustedSigner
    ) {
        let testBundle = Bundle(for: Self.self)
        let sourceURL = try XCTUnwrap(
            testBundle.url(forResource: "official-source", withExtension: "json"),
            "the generated catalog fixture must be copied into the test bundle"
        )
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        var envelope = try JSONDecoder().decode(RulePackCatalogEnvelope.self, from: source)
        let now = Int64(Date().timeIntervalSince1970)
        envelope.payload.issuedAt = now - 60
        envelope.payload.expiresAt = now + 3_600
        envelope.signatures = []

        let key = P256.Signing.PrivateKey()
        let signature = try key.signature(for: RulePackCatalogVerifier.canonicalPayload(for: envelope))
        envelope.signatures = [RulePackCatalogSignature(
            algorithm: RulePackCatalogVerifier.signatureAlgorithm,
            keyID: "startup-test-key",
            value: Data(signature.derRepresentation).base64EncodedString()
        )]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let signer = RulePackCatalogTrustedSigner(
            keyID: "startup-test-key",
            publisher: RulePackCatalogVerifier.publisher,
            catalogID: RulePackCatalogVerifier.catalogID,
            packIDPrefix: "official.",
            publicKeyPEM: key.publicKey.pemRepresentation,
            validFrom: now - 3_600,
            validUntil: now + 3_600,
            revoked: false
        )
        return (data, signer)
    }

    private func productionCatalog() throws -> VerifiedRulePackCatalog {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "official", withExtension: "json"))
        return try RulePackCatalogVerifier.verify(
            data: Data(contentsOf: url),
            trustedSigners: RulePackCatalogVerifier.productionTrustedSigners,
            now: 1_800_000_000, currentAppVersion: "0.18.6"
        )
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-monitor-\(name)-\(UUID().uuidString).sqlite")
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2,
                           _ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<max(1, Int(timeout * 100)) {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for monitor startup after \(timeout) seconds")
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

private final class MonitorPreparationScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    func schedule(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    func run(at index: Int) {
        lock.lock()
        let job = jobs.remove(at: index)
        lock.unlock()
        job()
    }
}
