import XCTest
@testable import Flowlight

final class RulePackTests: XCTestCase {
    func testCanonicalizesCaseTrailingDotUnicodeAndAddresses() {
        XCTAssertEqual(HostCanonicalizer.host(" Example.COM. "), "example.com")
        XCTAssertEqual(HostCanonicalizer.host("bücher.example"), "xn--bcher-kva.example")
        XCTAssertEqual(HostCanonicalizer.host("2001:0db8::1"), "2001:db8::1")
        XCTAssertNil(HostCanonicalizer.host("-bad.example"))
        XCTAssertNil(HostCanonicalizer.host("two..dots.example"))
    }

    func testSuffixAndExactEntriesHaveDifferentReach() throws {
        let definition = pack(entries: [
            RulePackEntry(id: 1, host: "ads.example", match: .suffix, category: .advertising),
            RulePackEntry(id: 2, host: "exact.example", match: .exact, category: .tracking),
        ])
        let matcher = try RulePackMatcher(snapshot: snapshot(definition))
        XCTAssertEqual(matcher.matches(host: "cdn.ads.example", bundleID: "com.example.app").map(\.entry.id), [1])
        XCTAssertEqual(matcher.matches(host: "exact.example", bundleID: "com.example.app").map(\.entry.id), [2])
        XCTAssertTrue(matcher.matches(host: "sub.exact.example", bundleID: "com.example.app").isEmpty)
    }

    func testSelectedAppScopeUsesConnectionOpeningBundleID() throws {
        let definition = pack(entries: [RulePackEntry(id: 1, host: "ads.example", category: .advertising)])
        let value = RulePackSnapshot.make(
            definitions: [definition],
            configurations: [RulePackConfiguration(packID: definition.id, enabled: true,
                                                   scope: .selectedApps, apps: ["com.apple.Safari"])],
            overrides: [])
        let matcher = try RulePackMatcher(snapshot: value)
        XCTAssertEqual(matcher.matches(host: "ads.example", bundleID: "com.apple.Safari").count, 1)
        XCTAssertTrue(matcher.matches(host: "ads.example", bundleID: "com.google.Chrome").isEmpty)
    }

    func testExactPackOverrideDoesNotSuppressSubdomains() throws {
        let definition = pack(entries: [
            RulePackEntry(id: 1, host: "ads.example", match: .suffix, category: .advertising),
        ])
        let value = RulePackSnapshot.make(
            definitions: [definition],
            configurations: [RulePackConfiguration(packID: definition.id, enabled: true)],
            overrides: [RulePackOverride(packID: definition.id, app: "com.example.app",
                                         host: "ads.example", match: .exact)])
        let matcher = try RulePackMatcher(snapshot: value)
        XCTAssertTrue(matcher.matches(host: "ads.example", bundleID: "com.example.app").isEmpty)
        XCTAssertEqual(matcher.matches(host: "cdn.ads.example", bundleID: "com.example.app").count, 1)
    }

    func testPackAllowOverrideSuppressesOnlyThatPack() throws {
        let first = pack(id: "official.ads", entries: [
            RulePackEntry(id: 1, host: "ads.example", category: .advertising),
        ])
        let second = pack(id: "official.tracking", entries: [
            RulePackEntry(id: 1, host: "ads.example", category: .tracking),
        ])
        let value = RulePackSnapshot.make(
            definitions: [first, second],
            configurations: [RulePackConfiguration(packID: first.id, enabled: true),
                             RulePackConfiguration(packID: second.id, enabled: true)],
            overrides: [RulePackOverride(packID: first.id, app: "com.example.app", host: "ads.example")])
        let matches = try RulePackMatcher(snapshot: value).matches(host: "cdn.ads.example", bundleID: "com.example.app")
        XCTAssertEqual(matches.map(\.packID), [second.id])
    }

    func testValidatorRejectsTamperDuplicateAndProtocolMismatch() throws {
        let valid = pack(entries: [RulePackEntry(id: 1, host: "ads.example", category: .advertising)])
        XCTAssertNoThrow(try RulePackValidator.validate([valid]))

        var tampered = valid
        tampered.entries[0].host = "changed.example"
        XCTAssertThrowsError(try RulePackValidator.validate([tampered])) {
            XCTAssertEqual($0 as? RulePackValidationError, .digestMismatch(valid.id))
        }

        let duplicate = pack(entries: [
            RulePackEntry(id: 1, host: "ads.example", category: .advertising),
            RulePackEntry(id: 2, host: "ads.example", category: .advertising),
        ])
        XCTAssertThrowsError(try RulePackValidator.validate([duplicate]))

        var future = valid
        future.manifest.minimumExtensionProtocol = RulePackSnapshot.protocolVersion + 1
        XCTAssertThrowsError(try RulePackValidator.validate([future])) {
            XCTAssertEqual($0 as? RulePackValidationError, .incompatibleProtocol(valid.id))
        }

        var newerApp = valid
        newerApp.manifest.minimumAppVersion = "0.15.1"
        XCTAssertThrowsError(try RulePackValidator.validate([newerApp], currentAppVersion: "0.15.0")) {
            XCTAssertEqual($0 as? RulePackValidationError, .incompatibleProtocol(valid.id))
        }
    }

    func testSimulationReportsOnlyNewlyBlockedTraffic() throws {
        let definition = pack(entries: [RulePackEntry(id: 1, host: "ads.example", category: .advertising)])
        let candidate = RulePackConfiguration(packID: definition.id)
        let flow = RuleSimulation.Flow(when: Date(), agentKey: "com.apple.Safari", bundleID: "com.apple.Safari",
                                       appName: "Safari", host: "cdn.ads.example", ip: "203.0.113.7", port: 443,
                                       bytes: 50, connections: 2)
        let result = RulePackSimulation.run(candidate: candidate, definitions: [definition], configurations: [],
                                            overrides: [], rules: [], flows: [flow])
        XCTAssertEqual(result.connectionsRefused, 2)

        let alreadyBlocked = Rule(action: .block, destination: "ads.example")
        let unchanged = RulePackSimulation.run(candidate: candidate, definitions: [definition], configurations: [],
                                               overrides: [], rules: [alreadyBlocked], flows: [flow])
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testSimulationUsesSafetyPauseRulesAndAgentPolicyPrecedence() {
        let definition = pack(entries: [
            RulePackEntry(id: 1, host: "ads.example", category: .advertising),
            RulePackEntry(id: 2, host: "icloud.com", category: .telemetry),
        ])
        let candidate = RulePackConfiguration(packID: definition.id)
        let ad = RuleSimulation.Flow(when: Date(), agentKey: "claude", bundleID: "curl", appName: "curl",
                                     host: "ads.example", ip: "203.0.113.7", port: 443,
                                     bytes: 50, connections: 2)
        let essential = RuleSimulation.Flow(when: Date(), agentKey: "com.apple.Safari",
                                            bundleID: "com.apple.Safari", appName: "Safari",
                                            host: "gateway.icloud.com", ip: "17.0.0.1", port: 443,
                                            bytes: 20, connections: 1)

        let exempt = RulePackSimulation.run(candidate: candidate, definitions: [definition], configurations: [],
                                            overrides: [], rules: [], flows: [essential])
        XCTAssertTrue(exempt.isEmpty)

        let paused = RulePackSimulation.run(candidate: candidate, definitions: [definition], configurations: [],
                                            overrides: [], rules: [], paused: true, flows: [ad])
        XCTAssertTrue(paused.isEmpty)

        let policy = AgentPolicy(agentID: "claude", allowAIProviders: false, patterns: [], enforce: true)
        let policyAlreadyBlocks = RulePackSimulation.run(candidate: candidate, definitions: [definition],
                                                         configurations: [], overrides: [], rules: [],
                                                         policies: ["claude": policy], flows: [ad])
        XCTAssertTrue(policyAlreadyBlocks.isEmpty)

        let explicitAllow = Rule(action: .allow, app: "curl", destination: "ads.example")
        let userAllowWins = RulePackSimulation.run(candidate: candidate, definitions: [definition],
                                                   configurations: [], overrides: [], rules: [explicitAllow],
                                                   policies: ["claude": policy], flows: [ad])
        XCTAssertTrue(userAllowWins.isEmpty)
    }

    func testConfigurationOverridesAndAggregatedEventsPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let configuration = RulePackConfiguration(packID: "official.ads", enabled: true,
                                                  scope: .selectedApps, apps: ["com.apple.Safari"])
        let override = RulePackOverride(packID: "official.ads", app: "com.apple.Safari", host: "ads.example")
        try db.saveRulePackConfiguration(configuration)
        try db.saveRulePackOverride(override)
        try db.recordRulePackEvents([
            RulePackEvent(bucket: 1_700_000_000, packID: "official.ads", packVersion: "1", entryID: 7,
                          category: .advertising, action: .block, count: 3, firstAt: 1_700_000_001,
                          lastAt: 1_700_000_020, bundleID: "com.apple.Safari", appName: "Safari",
                          agentKey: "com.apple.Safari", agentName: "Safari", host: "cdn.ads.example",
                          matchedHost: "ads.example", port: 443),
            RulePackEvent(bucket: 1_700_000_000, packID: "official.ads", packVersion: "1", entryID: 7,
                          category: .advertising, action: .block, count: 2, firstAt: 1_700_000_021,
                          lastAt: 1_700_000_030, bundleID: "com.apple.Safari", appName: "Safari",
                          agentKey: "com.apple.Safari", agentName: "Safari", host: "cdn.ads.example",
                          matchedHost: "ads.example", port: 443),
        ])

        let batch = RulePackEventBatch(id: UUID(), events: [
            RulePackEvent(bucket: 1_700_000_060, packID: "official.ads", packVersion: "1", entryID: 8,
                          category: .advertising, action: .block, count: 4, firstAt: 1_700_000_061,
                          lastAt: 1_700_000_070, bundleID: "com.apple.Safari", appName: "Safari",
                          agentKey: "com.apple.Safari", agentName: "Safari", host: "ads.example",
                          matchedHost: "ads.example", port: 443),
        ], droppedHits: 2, droppedKeys: 1)
        XCTAssertTrue(try db.recordRulePackEventBatch(batch))
        XCTAssertFalse(try db.recordRulePackEventBatch(batch), "a retry is acknowledged without applying counts twice")
        XCTAssertEqual(try db.rulePackDeliveryStats(), RulePackDeliveryStats(droppedHits: 2, droppedKeys: 1))

        let reopened = try TrafficDatabase(url: url)
        XCTAssertEqual(try reopened.loadRulePackConfigurations(), [configuration])
        XCTAssertEqual(try reopened.loadRulePackOverrides(), [override])
        let events = try reopened.rulePackEvents()
        let event = events.first { $0.entryID == 7 }
        XCTAssertEqual(event?.count, 5)
        XCTAssertEqual(event?.matchedHost, "ads.example")
        XCTAssertEqual(event?.lastAt, Date(timeIntervalSince1970: 1_700_000_030))
        XCTAssertEqual(events.first { $0.entryID == 8 }?.count, 4)
        try reopened.deleteRulePackOverride(override.id)
        XCTAssertTrue(try reopened.loadRulePackOverrides().isEmpty)
    }

    @MainActor
    func testBuiltInPacksValidateAndDefaultOff() throws {
        XCTAssertNoThrow(try RulePackValidator.validate(BuiltInRulePacks.all))
        let store = RulePackStore()
        let definitionCount = store.definitions.count
        let enabledCount = store.enabledCount
        let snapshot = store.snapshot
        XCTAssertEqual(definitionCount, 3)
        XCTAssertEqual(enabledCount, 0)
        XCTAssertNil(snapshot)
    }

    @MainActor
    func testStorePublishesOnlyAfterConfigurationCommit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-store-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        var publications = [RulePackSnapshot?]()
        store.onChange = { publications.append($0) }
        var enabled = store.configuration(for: "official.advertising")
        enabled.enabled = true
        store.save(enabled)

        XCTAssertTrue(publications.isEmpty)
        try await waitUntil { publications.count == 1 }
        let saved = try db.sync { try $0.loadRulePackConfigurations() }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].packID, enabled.packID)
        XCTAssertEqual(saved[0].consentedVersion, BuiltInRulePacks.advertising.manifest.version)
        XCTAssertEqual(saved[0].consentedContentSHA256, BuiltInRulePacks.advertising.manifest.contentSHA256)
        XCTAssertEqual(publications[0]?.configurations, saved)
    }

    @MainActor
    func testStoreDisablesEmptySelectedAppConfiguration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-empty-scope-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        var candidate = store.configuration(for: "official.advertising")
        candidate.enabled = true
        candidate.scope = .selectedApps
        candidate.apps = ["  ", "\n"]
        var completed = false
        store.save(candidate) { success in
            XCTAssertTrue(success)
            completed = true
        }

        try await waitUntil { completed }
        let committed = store.configuration(for: candidate.packID)
        XCTAssertFalse(committed.enabled)
        XCTAssertEqual(committed.scope, .selectedApps)
        XCTAssertTrue(committed.apps.isEmpty)
        let persisted = try db.sync { try $0.loadRulePackConfigurations() }
        XCTAssertEqual(persisted, [committed])
    }

    @MainActor
    func testStoreSaveCompletionSeesCommittedConfiguration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-completion-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        var candidate = store.configuration(for: "official.advertising")
        candidate.enabled = true
        candidate.scope = .selectedApps
        candidate.apps = ["com.apple.curl"]
        var completed = false
        store.save(candidate) { success in
            XCTAssertTrue(success)
            XCTAssertEqual(store.configuration(for: candidate.packID).scope, .selectedApps)
            XCTAssertEqual(store.configuration(for: candidate.packID).apps, ["com.apple.curl"])
            XCTAssertNotNil(store.snapshot)
            completed = true
        }

        try await waitUntil { completed }
    }

    @MainActor
    func testStorePublishesAfterTransientFailureRecovers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-recovery-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        var publications = [RulePackSnapshot?]()
        store.onChange = { publications.append($0) }
        store.updateStatus(.failed("transient storage failure"))
        var enabled = store.configuration(for: "official.advertising")
        enabled.enabled = true
        store.save(enabled)

        try await waitUntil { publications.count == 1 }
        let saved = try db.sync { try $0.loadRulePackConfigurations() }
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].packID, enabled.packID)
        XCTAssertEqual(publications.count, 1, "a successful retry must publish after a transient failure")
        XCTAssertEqual(store.status, .ready)
    }

    @MainActor
    func testClearingStoreActivityKeepsConfigurationAndExceptions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-clear-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        var configuration = store.configuration(for: "official.advertising")
        configuration.enabled = true
        store.save(configuration)
        let exception = RulePackOverride(packID: configuration.packID, app: "com.apple.Safari", host: "ads.example")
        store.addOverride(exception)
        let batch = RulePackEventBatch(events: [
            RulePackEvent(bucket: 1_700_000_000, packID: configuration.packID, packVersion: "1", entryID: 1,
                          category: .advertising, action: .block, count: 2, firstAt: 1_700_000_001,
                          lastAt: 1_700_000_002, bundleID: "com.apple.Safari", appName: "Safari",
                          agentKey: "com.apple.Safari", agentName: "Safari", host: "ads.example",
                          matchedHost: "ads.example", port: 443),
        ], droppedHits: 3, droppedKeys: 1)
        await withCheckedContinuation { continuation in
            store.record(batch) { _ in continuation.resume() }
        }
        try await waitUntil { !store.events.isEmpty && !store.overrides.isEmpty }

        try await waitUntil { store.configuration(for: configuration.packID).enabled }
        configuration = store.configuration(for: configuration.packID)
        store.clearActivity()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.deliveryStats, RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0))
        XCTAssertEqual(store.configuration(for: configuration.packID), configuration)
        XCTAssertEqual(store.overrides, [exception])
    }

    @MainActor
    func testChangedPackRequiresFreshConsent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-consent-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        var original = BuiltInRulePacks.advertising
        var configuration = RulePackConfiguration(packID: original.id, enabled: true)
        configuration.consentedVersion = original.manifest.version
        configuration.consentedContentSHA256 = original.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)

        original.entries.append(RulePackEntry(id: UInt32(original.entries.count + 1), host: "new-ad.example",
                                              category: .advertising))
        original.entries.sort { ("\($0.host)|\($0.match.rawValue)") < ("\($1.host)|\($1.match.rawValue)") }
        original.manifest.version = "2"
        original.manifest.entryCount = original.entries.count
        original.manifest.contentSHA256 = RulePackValidator.digest(original.entries)
        let store = RulePackStore(definitions: [original])
        store.attach(db: db)
        try await waitUntil { store.configurations.count == 1 }

        XCTAssertFalse(store.configuration(for: original.id).enabled)
        XCTAssertNil(store.snapshot)
    }

    func testEditorReviewPreservesOffConfiguration() {
        let saved = RulePackConfiguration(packID: "official.advertising")
        let draft = RulePackEditorDraft(saved: saved, intent: .review)

        XCTAssertFalse(draft.configuration.enabled)
        XCTAssertEqual(draft.configuration.scope, .allApps)
        XCTAssertEqual(draft.requestSave(), .commit(saved))
    }

    func testEditorActivationAndCancelNeverMutateSavedConfiguration() {
        let saved = RulePackConfiguration(packID: "official.advertising")
        var draft = RulePackEditorDraft(saved: saved, intent: .activate)

        XCTAssertTrue(draft.configuration.enabled)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "com.apple.curl"
        XCTAssertEqual(draft.submitApp(installed: []), .added("com.apple.curl"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.curl"])
        XCTAssertEqual(saved, RulePackConfiguration(packID: "official.advertising"))
    }

    func testEditorReturnAddsAppWithoutSaving() {
        let saved = RulePackConfiguration(packID: "official.advertising")
        var draft = RulePackEditorDraft(saved: saved, intent: .activate)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "com.apple.curl"

        XCTAssertEqual(draft.submitApp(installed: []), .added("com.apple.curl"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.curl"])
        XCTAssertEqual(draft.typedApp, "")

        draft.typedApp = "com.example.second"
        XCTAssertEqual(draft.submitApp(installed: []), .added("com.example.second"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.curl", "com.example.second"])
        XCTAssertEqual(draft.requestSave(), .commit(draft.configuration),
                       "Return only edits the draft; explicit Save decides whether to commit")
    }

    func testConcurrentCardSavesStayTrackedIndependently() {
        var saves = RulePackSaveTracker()
        saves.begin("official.advertising")
        saves.begin("official.tracking")

        saves.finish("official.advertising")

        XCTAssertFalse(saves.contains("official.advertising"))
        XCTAssertTrue(saves.contains("official.tracking"))
    }

    func testEditorWaitsForInstalledAppsBeforeResolvingDisplayName() {
        let safari = InstalledApps.App(name: "Safari", bundleID: "com.apple.Safari",
                                       path: "/Applications/Safari.app")
        var draft = RulePackEditorDraft(saved: RulePackConfiguration(packID: "official.advertising"),
                                        intent: .activate)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "Safari"

        XCTAssertEqual(draft.submitApp(installed: [], appsLoaded: false), .loading)
        XCTAssertEqual(draft.typedApp, "Safari")
        XCTAssertTrue(draft.configuration.apps.isEmpty)

        XCTAssertEqual(draft.submitApp(installed: [safari], appsLoaded: true), .added("com.apple.Safari"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.Safari"])
        XCTAssertEqual(draft.typedApp, "")
    }

    func testEditorExplicitSaveAndBroadeningDecision() {
        var selected = RulePackConfiguration(packID: "official.advertising", enabled: true,
                                             scope: .selectedApps, apps: ["com.apple.curl"])
        var draft = RulePackEditorDraft(saved: selected, intent: .review)
        XCTAssertEqual(draft.requestSave(), .commit(selected))

        draft.configuration.scope = .allApps
        XCTAssertEqual(draft.requestSave(), .confirmBroadening)

        selected.apps = []
        let invalid = RulePackEditorDraft(saved: selected, intent: .review)
        XCTAssertNil(invalid.requestSave())
        XCTAssertFalse(invalid.canSave)
    }

    func testActivityKeepsPackProvenanceSeparateAndReceiptAfterPrune() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-provenance-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let batch = RulePackEventBatch(events: [
            event(version: "1", category: .advertising, matchedHost: "ads-v1.example", agentKey: "first-agent"),
            event(version: "2", category: .tracking, matchedHost: "ads-v2.example", agentKey: "second-agent"),
        ], droppedHits: 4, droppedKeys: 2)
        XCTAssertTrue(try db.recordRulePackEventBatch(batch))
        XCTAssertEqual(try db.rulePackEvents().count, 2)

        try db.pruneRulePackEvents(before: Date().addingTimeInterval(1))
        XCTAssertTrue(try db.rulePackEvents().isEmpty)
        XCTAssertEqual(try db.rulePackDeliveryStats(), RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0))
        XCTAssertFalse(try db.recordRulePackEventBatch(batch), "a pruned batch watermark must still deduplicate retry")
        XCTAssertTrue(try db.rulePackEvents().isEmpty)
    }

    func testTransferBufferIsBoundedIdempotentAndRejectsStaleCommit() throws {
        let first = UUID()
        let next = UUID()
        let empty = RulePackHandshake(protocolVersion: RulePackSnapshot.protocolVersion,
                                      activeGeneration: nil, activeDigest: "")
        let header = RulePackTransferHeader(protocolVersion: RulePackSnapshot.protocolVersion,
                                            generation: first, digest: "digest", totalBytes: 6, chunks: 2,
                                            expectedActiveGeneration: nil)
        var buffer = RulePackTransferBuffer(maxBytes: 6, maxChunks: 2)
        XCTAssertEqual(buffer.begin(header, active: empty).status, .accepted)
        XCTAssertTrue(buffer.append(generation: first.uuidString, index: 0, payload: Data("abc".utf8)))
        XCTAssertTrue(buffer.append(generation: first.uuidString, index: 0, payload: Data("abc".utf8)),
                      "an identical retry is idempotent")
        XCTAssertEqual(buffer.receivedBytes, 3)
        XCTAssertTrue(buffer.append(generation: first.uuidString, index: 0, payload: Data("ab".utf8)),
                      "a replacement is charged by its net size")
        XCTAssertEqual(buffer.receivedBytes, 2)
        XCTAssertFalse(buffer.append(generation: first.uuidString, index: 1, payload: Data("12345".utf8)),
                       "the declared byte count is a hard bound")
        XCTAssertTrue(buffer.append(generation: first.uuidString, index: 1, payload: Data("1234".utf8)))

        let changed = RulePackHandshake(protocolVersion: RulePackSnapshot.protocolVersion,
                                        activeGeneration: next, activeDigest: "new")
        guard case .rejected(let stale) = buffer.commit(generation: first.uuidString, active: changed) else {
            return XCTFail("a stale commit must be rejected")
        }
        XCTAssertEqual(stale.status, .stale)
        XCTAssertNil(buffer.header)
    }

    func testTransferBufferRejectsIncompleteAndReturnsOrderedPayload() throws {
        let generation = UUID()
        let active = RulePackHandshake(protocolVersion: RulePackSnapshot.protocolVersion,
                                       activeGeneration: nil, activeDigest: "")
        let header = RulePackTransferHeader(protocolVersion: RulePackSnapshot.protocolVersion,
                                            generation: generation, digest: "digest", totalBytes: 6, chunks: 2,
                                            expectedActiveGeneration: nil)
        var buffer = RulePackTransferBuffer(maxBytes: 6, maxChunks: 2)
        XCTAssertEqual(buffer.begin(header, active: active).status, .accepted)
        XCTAssertTrue(buffer.append(generation: generation.uuidString, index: 1, payload: Data("def".utf8)))
        guard case .rejected(let incomplete) = buffer.commit(generation: generation.uuidString, active: active) else {
            return XCTFail("an incomplete transfer must reply with a rejection")
        }
        XCTAssertEqual(incomplete.status, .invalid)

        XCTAssertEqual(buffer.begin(header, active: active).status, .accepted)
        XCTAssertTrue(buffer.append(generation: generation.uuidString, index: 1, payload: Data("def".utf8)))
        XCTAssertTrue(buffer.append(generation: generation.uuidString, index: 0, payload: Data("abc".utf8)))
        guard case .payload(let data, _) = buffer.commit(generation: generation.uuidString, active: active) else {
            return XCTFail("the complete transfer should assemble")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "abcdef")
    }

    func testOneHundredThousandEntriesRemainIndexed() throws {
        let entries = (0..<100_000).map {
            RulePackEntry(id: UInt32($0 + 1), host: String(format: "ad%06d.example", $0),
                          match: .suffix, category: .advertising)
        }
        let definition = pack(entries: entries)
        let matcher = try RulePackMatcher(snapshot: snapshot(definition))
        measure {
            for value in stride(from: 0, to: 100_000, by: 1_000) {
                XCTAssertEqual(matcher.matches(host: String(format: "cdn.ad%06d.example", value),
                                               bundleID: "com.example.app").count, 1)
            }
        }
    }

    private func event(version: String, category: RulePackEntry.Category, matchedHost: String,
                       agentKey: String) -> RulePackEvent {
        RulePackEvent(bucket: 1_700_000_000, packID: "official.ads", packVersion: version, entryID: 1,
                      category: category, action: .block, count: 1, firstAt: 1_700_000_001,
                      lastAt: 1_700_000_002, bundleID: "com.apple.Safari", appName: "Safari",
                      agentKey: agentKey, agentName: agentKey, host: "ads.example",
                      matchedHost: matchedHost, port: 443)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitError: Error { case timedOut }

    private func pack(id: String = "official.ads", entries: [RulePackEntry]) -> RulePackDefinition {
        let sorted = entries.sorted { ("\($0.host)|\($0.match.rawValue)") < ("\($1.host)|\($1.match.rawValue)") }
        let manifest = RulePackManifest(id: id, version: "1", generatedAt: Date(timeIntervalSince1970: 0),
                                        entryCount: sorted.count, contentSHA256: RulePackValidator.digest(sorted),
                                        titleKey: "pack.\(id).title", summaryKey: "pack.\(id).summary",
                                        caveatKey: "pack.\(id).caveat", source: "Flowlight", license: "GPL-3.0")
        return RulePackDefinition(manifest: manifest, entries: sorted)
    }

    private func snapshot(_ definitions: RulePackDefinition...) -> RulePackSnapshot {
        RulePackSnapshot.make(definitions: definitions,
                              configurations: definitions.map { RulePackConfiguration(packID: $0.id, enabled: true) },
                              overrides: [])
    }
}
