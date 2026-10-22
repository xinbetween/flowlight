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

    func testProxyMatcherOnlyPublishesTheExtensionCommittedDigest() {
        let definition = pack(entries: [
            RulePackEntry(id: 1, host: "ads.example", category: .advertising),
        ])
        let value = snapshot(definition)
        let live = LiveRulePacks()

        XCTAssertNil(live.match(host: "ads.example", bundleID: "com.example.app"))
        live.commit(snapshot: value, activeDigest: "different")
        XCTAssertNil(live.match(host: "ads.example", bundleID: "com.example.app"))
        XCTAssertEqual(live.activeDigest, "")

        live.commit(snapshot: value, activeDigest: value.digest)
        XCTAssertEqual(live.match(host: "cdn.ads.example", bundleID: "com.example.app")?.packID, definition.id)
        XCTAssertEqual(live.activeDigest, value.digest)

        live.replace(snapshot: nil)
        XCTAssertNil(live.match(host: "ads.example", bundleID: "com.example.app"))
        XCTAssertEqual(live.activeDigest, "")
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
        XCTAssertNoThrow(try RulePackValidator.validate([newerApp]),
                         "the extension validates protocol compatibility after the app has admitted the snapshot")
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

    func testSimulationIncludesOtherEnabledPacksInBaseline() {
        let entry = RulePackEntry(id: 1, host: "ads.example", category: .advertising)
        let candidateDefinition = pack(id: "official.candidate", entries: [entry])
        let activeDefinition = pack(id: "official.active", entries: [entry])
        let candidate = RulePackConfiguration(packID: candidateDefinition.id)
        let active = RulePackConfiguration(packID: activeDefinition.id, enabled: true)
        let flow = RuleSimulation.Flow(
            when: Date(), agentKey: "com.apple.Safari", bundleID: "com.apple.Safari",
            appName: "Safari", host: "cdn.ads.example", ip: "203.0.113.7", port: 443,
            bytes: 50, connections: 2
        )

        let result = RulePackSimulation.run(
            candidate: candidate,
            definitions: [activeDefinition, candidateDefinition],
            configurations: [active], overrides: [], rules: [], flows: [flow]
        )

        XCTAssertTrue(result.isEmpty, "an already-enforced destination is not a newly refused connection")
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
        try reopened.deleteRulePackOverride(override)
        XCTAssertTrue(try reopened.loadRulePackOverrides().isEmpty)
    }

    func testPreWatermarkFlagBatchDefaultsToDurableDelivery() throws {
        let batch = activityBatch()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any]
        )
        object.removeValue(forKey: "requiresDurableWatermark")

        let decoded = try JSONDecoder().decode(
            RulePackEventBatch.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.requiresDurableWatermark,
                      "a still-running older extension needs the original durable delivery behavior")
        XCTAssertEqual(decoded.id, batch.id)
        XCTAssertEqual(decoded.deliverySession, batch.deliverySession)
        XCTAssertEqual(decoded.sequence, batch.sequence)
        XCTAssertEqual(decoded.events, batch.events)
    }

    func testAppLocalPackBatchesDoNotCreatePermanentWatermarks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-local-watermark-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        var batch = activityBatch()
        batch.requiresDurableWatermark = false

        XCTAssertTrue(try db.recordRulePackEventBatch(batch))
        XCTAssertTrue(try db.raw("SELECT delivery_session FROM rule_pack_event_watermarks") { $0.text(0) }.isEmpty)
        XCTAssertEqual(try db.rulePackEvents(limit: 10).first?.count, 1)
    }

    func testStalePackEventMarkerRepairsThePhysicalUniqueKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-stale-key-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }

        do {
            let fixture = try SQLiteConnection(path: url.path)
            try fixture.execute("""
            CREATE TABLE rollup_state (tier TEXT PRIMARY KEY, watermark INTEGER NOT NULL);
            INSERT INTO rollup_state (tier, watermark) VALUES ('schema.rulePackEventKey', 2);
            CREATE TABLE rule_pack_event_rollups (
                id INTEGER PRIMARY KEY AUTOINCREMENT, bucket INTEGER NOT NULL, pack_id TEXT NOT NULL,
                pack_version TEXT NOT NULL, entry_id INTEGER NOT NULL, category TEXT NOT NULL,
                match TEXT NOT NULL DEFAULT 'suffix', action TEXT NOT NULL,
                count INTEGER NOT NULL, first_at INTEGER NOT NULL, last_at INTEGER NOT NULL,
                bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, agent TEXT NOT NULL, agent_name TEXT NOT NULL,
                host TEXT NOT NULL, matched_host TEXT NOT NULL, port INTEGER NOT NULL,
                UNIQUE(bucket, pack_id, pack_version, entry_id, category, action, bundle_id, app_name,
                       agent, agent_name, host, matched_host, port));
            CREATE INDEX rule_pack_events_time ON rule_pack_event_rollups(bucket DESC);
            CREATE INDEX rule_pack_events_pack ON rule_pack_event_rollups(pack_id, bucket DESC);
            INSERT INTO rule_pack_event_rollups
                (id, bucket, pack_id, pack_version, entry_id, category, match, action, count,
                 first_at, last_at, bundle_id, app_name, agent, agent_name, host, matched_host, port)
            VALUES (41, 1700000000, 'official.ads', '1', 7, 'advertising', 'suffix', 'block', 3,
                    1700000001, 1700000020, 'com.apple.Safari', 'Safari', 'com.apple.Safari', 'Safari',
                    'cdn.ads.example', 'ads.example', 443);
            """)
            XCTAssertThrowsError(try fixture.run("""
                INSERT INTO rule_pack_event_rollups
                    (bucket, pack_id, pack_version, entry_id, category, match, action, count,
                     first_at, last_at, bundle_id, app_name, agent, agent_name, host, matched_host, port)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(bucket, pack_id, pack_version, entry_id, category, match, action, bundle_id,
                            app_name, agent, agent_name, host, matched_host, port) DO UPDATE SET
                    count = count + excluded.count
                """, [.int(1_700_000_000), .text("official.ads"), .text("1"), .int(7),
                      .text("advertising"), .text("suffix"), .text("block"), .int(1),
                      .int(1_700_000_001), .int(1_700_000_020), .text("com.apple.Safari"),
                      .text("Safari"), .text("com.apple.Safari"), .text("Safari"),
                      .text("cdn.ads.example"), .text("ads.example"), .int(443)])) { error in
                XCTAssertTrue(String(describing: error).contains("ON CONFLICT clause does not match"))
            }
        }

        var repaired: TrafficDatabase? = try TrafficDatabase(url: url)
        let suffix = RulePackEvent(
            bucket: 1_700_000_000, packID: "official.ads", packVersion: "1", entryID: 7,
            category: .advertising, match: .suffix, action: .block, count: 2,
            firstAt: 1_699_999_999, lastAt: 1_700_000_030, bundleID: "com.apple.Safari",
            appName: "Safari", agentKey: "com.apple.Safari", agentName: "Safari",
            host: "cdn.ads.example", matchedHost: "ads.example", port: 443)
        var exact = suffix
        exact.match = .exact
        exact.count = 4
        try repaired?.recordRulePackEvents([suffix, exact])

        var events = try XCTUnwrap(repaired).rulePackEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.match == .suffix }?.id, 41)
        XCTAssertEqual(events.first { $0.match == .suffix }?.count, 5)
        XCTAssertEqual(events.first { $0.match == .suffix }?.firstAt,
                       Date(timeIntervalSince1970: 1_699_999_999))
        XCTAssertEqual(events.first { $0.match == .suffix }?.lastAt,
                       Date(timeIntervalSince1970: 1_700_000_030))
        XCTAssertEqual(events.first { $0.match == .exact }?.count, 4)

        let indexes = try XCTUnwrap(repaired).raw(
            "PRAGMA index_list(rule_pack_event_rollups)",
            map: { (name: $0.text(1), unique: $0.int(2), partial: $0.int(4)) }
        )
        let expected = ["bucket", "pack_id", "pack_version", "entry_id", "category", "match", "action",
                        "bundle_id", "app_name", "agent", "agent_name", "host", "matched_host", "port"]
        let matching = try indexes.filter { $0.unique == 1 && $0.partial == 0 }.contains { index in
            let escaped = index.name.replacingOccurrences(of: "'", with: "''")
            let columns = try XCTUnwrap(repaired).raw("PRAGMA index_info('\(escaped)')") { $0.text(2) }
            return columns == expected
        }
        XCTAssertTrue(matching)
        XCTAssertEqual(Set(indexes.map(\.name)).intersection(["rule_pack_events_time", "rule_pack_events_pack"]),
                       Set(["rule_pack_events_time", "rule_pack_events_pack"]))
        XCTAssertEqual(try XCTUnwrap(repaired).raw(
            "SELECT watermark FROM rollup_state WHERE tier = 'schema.rulePackEventKey'", map: { $0.int(0) }
        ), [2])

        repaired = nil
        let reopened = try TrafficDatabase(url: url)
        try reopened.recordRulePackEvents([suffix])
        let batch = RulePackEventBatch(events: [exact], droppedHits: 2, droppedKeys: 1)
        XCTAssertTrue(try reopened.recordRulePackEventBatch(batch))
        XCTAssertFalse(try reopened.recordRulePackEventBatch(batch))
        XCTAssertEqual(try reopened.rulePackDeliveryStats(), RulePackDeliveryStats(droppedHits: 2, droppedKeys: 1))
        events = try reopened.rulePackEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.match == .suffix }?.count, 7)
        XCTAssertEqual(events.first { $0.match == .suffix }?.id, 41)
        XCTAssertEqual(events.first { $0.match == .exact }?.count, 8)
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
        let store = try await attachedStore(db: db)

        var publications = [RulePackSnapshot?]()
        store.onChange = { publications.append($0) }
        let definition = BuiltInRulePacks.advertising
        var enabled = store.configuration(for: definition.id)
        enabled.enabled = true
        store.save(enabled, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition)))

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
        let store = try await attachedStore(db: db)

        var candidate = store.configuration(for: "official.advertising")
        candidate.enabled = true
        candidate.scope = .selectedApps
        candidate.apps = ["  ", "\n"]
        var completed = false
        store.save(candidate, reviewedDefinition: BuiltInRulePacks.advertising, receipt: nil) { result in
            XCTAssertEqual(result, .saved)
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
        let store = try await attachedStore(db: db)

        var candidate = store.configuration(for: "official.advertising")
        candidate.enabled = true
        candidate.scope = .selectedApps
        candidate.apps = ["com.apple.curl"]
        var completed = false
        let definition = BuiltInRulePacks.advertising
        store.save(candidate, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition))) { result in
            XCTAssertEqual(result, .saved)
            XCTAssertEqual(store.configuration(for: candidate.packID).scope, .selectedApps)
            XCTAssertEqual(store.configuration(for: candidate.packID).apps, ["com.apple.curl"])
            XCTAssertNotNil(store.snapshot)
            completed = true
        }

        try await waitUntil { completed }
    }

    @MainActor
    func testOverrideAppearsOnlyAfterDatabaseCommit() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-override-failure-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }
        _ = try db.raw("DROP TABLE rule_pack_overrides") { _ in 0 }

        let exception = RulePackOverride(packID: "official.advertising", app: "com.apple.Safari",
                                         host: "ads.example")
        var result: Bool?
        store.addOverride(exception) { result = $0 }

        try await waitUntil { result != nil }
        XCTAssertEqual(result, false)
        XCTAssertTrue(store.overrides.isEmpty)
        XCTAssertTrue(store.failureMessage?.contains("no such table") == true)
    }

    @MainActor
    func testRepeatedOverrideReplacesAndDeleteRemovesItsWholeScope() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-override-dedupe-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        let first = RulePackOverride(packID: "official.advertising", app: "com.apple.Safari",
                                     host: "ADS.EXAMPLE")
        let second = RulePackOverride(packID: first.packID, app: "COM.APPLE.SAFARI",
                                      host: "ads.example")
        var added = 0
        store.addOverride(first) { if $0 { added += 1 } }
        try await waitUntil { added == 1 }
        store.addOverride(second) { if $0 { added += 1 } }
        try await waitUntil { added == 2 }

        XCTAssertEqual(store.overrides, [second])
        XCTAssertEqual(try db.sync { try $0.loadRulePackOverrides() }, [second])

        let legacyJSON = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        _ = try db.raw(
            "INSERT INTO rule_pack_overrides (id, override, updated) VALUES (?,?,?)",
            [.text(first.id.uuidString), .text(legacyJSON), .int(1)]
        ) { _ in 0 }
        XCTAssertEqual(try db.sync { try $0.loadRulePackOverrides() }.count, 2)

        var deleted: Bool?
        store.deleteOverride(second) { deleted = $0 }
        try await waitUntil { deleted != nil }
        XCTAssertEqual(deleted, true)
        XCTAssertTrue(store.overrides.isEmpty)
        XCTAssertTrue(try db.sync { try $0.loadRulePackOverrides() }.isEmpty)
    }

    @MainActor
    func testOverrideRemainsAfterDatabaseDeleteFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-override-delete-failure-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count }

        let exception = RulePackOverride(packID: "official.advertising", app: "com.apple.Safari",
                                         host: "ads.example")
        var added: Bool?
        store.addOverride(exception) { added = $0 }
        try await waitUntil { added != nil }
        XCTAssertEqual(added, true)
        XCTAssertEqual(store.overrides, [exception])

        _ = try db.raw("DROP TABLE rule_pack_overrides") { _ in 0 }
        var deleted: Bool?
        store.deleteOverride(exception) { deleted = $0 }

        try await waitUntil { deleted != nil }
        XCTAssertEqual(deleted, false)
        XCTAssertEqual(store.overrides, [exception])
        XCTAssertTrue(store.failureMessage?.contains("no such table") == true)
    }

    @MainActor
    func testStorePublishesAfterTransientFailureRecovers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-pack-recovery-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)

        var publications = [RulePackSnapshot?]()
        store.onChange = { publications.append($0) }
        store.updateStatus(.failed("transient storage failure"))
        let definition = BuiltInRulePacks.advertising
        var enabled = store.configuration(for: definition.id)
        enabled.enabled = true
        store.save(enabled, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition)))

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
        let store = try await attachedStore(db: db)

        let definition = BuiltInRulePacks.advertising
        var configuration = store.configuration(for: definition.id)
        configuration.enabled = true
        store.save(configuration, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition)))
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
        store.clearPublishedActivityAfterDurableDeletion()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.deliveryStats, RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0))
        XCTAssertEqual(store.configuration(for: configuration.packID), configuration)
        XCTAssertEqual(store.overrides, [exception])
    }

    @MainActor
    func testSupersededInitialReloadStillCompletesStartupBarrier() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-startup-revision-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = RulePackStore()
        let blockerStarted = expectation(description: "database queue blocked")
        let completed = expectation(description: "startup barrier completed")
        let release = DispatchSemaphore(value: 0)
        db.queue.async {
            blockerStarted.fulfill()
            release.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 1)

        store.attach(db: db) { completed.fulfill() }
        store.beginActivityClear()
        release.signal()

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(store.events.isEmpty)
        store.finishActivityClear(succeeded: true)
    }

    @MainActor
    func testDurableAcknowledgementDoesNotWaitForMainActorPublication() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-durable-ack-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)
        let completed = DispatchSemaphore(value: 0)
        let result = LockedBool()

        store.record(activityBatch()) { committed in
            result.set(committed)
            completed.signal()
        }

        // This blocks MainActor publication. The durable acknowledgement must still come from the database queue.
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(result.value)
        XCTAssertEqual(try db.sync { try $0.rulePackEvents(limit: 10).count }, 1)
    }

    @MainActor
    func testActivityClearRemovesAPreClearBatchQueuedAheadOfDeletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-clear-inflight-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)
        let blockerStarted = expectation(description: "database queue blocked")
        let batchRetired = expectation(description: "pre-clear batch retired")
        let release = DispatchSemaphore(value: 0)
        db.queue.async {
            blockerStarted.fulfill()
            release.wait()
        }
        await fulfillment(of: [blockerStarted], timeout: 1)

        store.record(activityBatch()) { accepted in
            XCTAssertTrue(accepted)
            batchRetired.fulfill()
        }
        store.beginActivityClear()
        let clear = Task {
            try await db.asyncResult { try $0.clearAll() }
            store.finishActivityClear(succeeded: true)
        }
        release.signal()

        await fulfillment(of: [batchRetired], timeout: 2)
        try await clear.value
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(try db.rulePackEvents(limit: 10).isEmpty)
    }

    func testDeleteEverythingRemovesOrdinaryRuleEvents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-rule-events-clear-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let rule = Rule(action: .block, destination: "example.com")
        try db.recordRuleEvents([
            RuleEvent(
                at: 1_700_000_000,
                ruleID: rule.id,
                action: .block,
                engine: .flow,
                agentKey: "com.example.app",
                agentName: "Example",
                appName: "Example",
                bundleID: "com.example.app",
                host: "example.com",
                ip: "",
                port: 443
            ),
        ])
        XCTAssertEqual(try db.ruleEvents(limit: 10).count, 1)

        try db.clearAll()

        XCTAssertTrue(try db.ruleEvents(limit: 10).isEmpty)
    }

    @MainActor
    func testActivityArrivingDuringClearIsAcknowledgedWithoutWriting() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-clear-drop-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)
        let dropped = expectation(description: "batch acknowledged during clear")

        store.beginActivityClear()
        store.record(activityBatch()) { accepted in
            XCTAssertTrue(accepted)
            dropped.fulfill()
        }
        await fulfillment(of: [dropped], timeout: 1)
        store.finishActivityClear(succeeded: true)

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(try db.rulePackEvents(limit: 10).isEmpty)
    }

    @MainActor
    func testProxyActivityDuringClearFailsOpenWithoutWriting() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-clear-proxy-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)
        let allowed = expectation(description: "proxy refusal failed open during clear")

        store.beginActivityClear()
        store.record(activityBatch(), acknowledgeDuringClear: false) { committed in
            XCTAssertFalse(committed)
            allowed.fulfill()
        }
        await fulfillment(of: [allowed], timeout: 1)
        store.finishActivityClear(succeeded: true)

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(try db.rulePackEvents(limit: 10).isEmpty)
    }

    @MainActor
    func testClearingActivityRejectsCatalogInstallWithCapturedEvents() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-clear-race-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let definition = BuiltInRulePacks.advertising
        let catalog = VerifiedRulePackCatalog(
            definitions: [definition], sequence: 1, digest: String(repeating: "1", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("one".utf8)
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog, checkedAt: Date(timeIntervalSince1970: 100),
            nextEligibleAt: Date(timeIntervalSince1970: 200)
        )
        let batch = RulePackEventBatch(events: [
            RulePackEvent(
                bucket: 1_700_000_000, packID: definition.id, packVersion: definition.manifest.version,
                entryID: 1, category: .advertising, action: .block, count: 1,
                firstAt: 1_700_000_001, lastAt: 1_700_000_001,
                bundleID: "com.apple.Safari", appName: "Safari",
                agentKey: "com.apple.Safari", agentName: "Safari", host: "ads.example",
                matchedHost: "ads.example", port: 443
            ),
        ], droppedHits: 2, droppedKeys: 1)
        XCTAssertTrue(try db.recordRulePackEventBatch(batch))

        let store = RulePackStore(definitions: [definition], currentAppVersion: "0.15.4")
        XCTAssertEqual(
            store.installCommittedCatalog(
                catalog,
                acceptance: try db.loadRulePackCatalogBootstrap(
                    catalogID: RulePackCatalogVerifier.catalogID
                )
            ),
            .installed
        )
        XCTAssertFalse(store.events.isEmpty)
        let expectedRevision = store.catalogInstallRevision
        let captured = try db.loadRulePackCatalogBootstrap(
            catalogID: RulePackCatalogVerifier.catalogID
        )

        try db.clearAll()
        store.clearPublishedActivityAfterDurableDeletion()

        XCTAssertEqual(
            store.installCommittedCatalog(
                catalog,
                acceptance: captured,
                expectedRevision: expectedRevision
            ),
            .staleRevision
        )
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.deliveryStats, RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0))
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
        XCTAssertTrue(store.needsReview(original))
        XCTAssertNil(store.snapshot)
    }

    func testEditorReviewPreservesOffConfiguration() {
        let saved = RulePackConfiguration(packID: "official.advertising")
        let draft = RulePackEditorDraft(saved: saved, intent: .review)

        XCTAssertFalse(draft.configuration.enabled)
        XCTAssertEqual(draft.configuration.scope, .allApps)
        XCTAssertEqual(draft.requestSave(), .commit(saved, nil))
    }

    func testEditorSaveCarriesImmutableReviewedContentReceipt() {
        let definition = BuiltInRulePacks.advertising
        let receipt = RulePackReviewReceipt(
            packID: definition.id, version: definition.manifest.version,
            contentSHA256: definition.manifest.contentSHA256,
            catalogSequence: 7, catalogDigest: String(repeating: "7", count: 64)
        )
        let draft = RulePackEditorDraft(
            saved: RulePackConfiguration(packID: definition.id), intent: .activate,
            reviewedDefinition: definition, reviewReceipt: receipt
        )

        XCTAssertEqual(draft.reviewedDefinition, definition)
        XCTAssertEqual(draft.requestSave(), .commit(draft.configuration, receipt))
    }

    @MainActor
    func testSnapshotGenerationIsStableUntilCommittedStateChanges() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-generation-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let store = try await attachedStore(db: db)
        let definition = BuiltInRulePacks.advertising
        var configuration = store.configuration(for: definition.id)
        configuration.enabled = true
        store.save(configuration, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition)))
        try await waitUntil { store.snapshot != nil }

        let first = try XCTUnwrap(store.snapshot)
        let second = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(first, second)

        configuration = store.configuration(for: configuration.packID)
        configuration.scope = .selectedApps
        configuration.apps = ["com.apple.Safari"]
        store.save(configuration, reviewedDefinition: definition,
                   receipt: try XCTUnwrap(store.reviewReceipt(for: definition)))
        try await waitUntil { store.snapshot?.digest != first.digest }
        XCTAssertNotEqual(store.snapshot?.generation, first.generation)
    }

    @MainActor
    func testRefreshBeforeEditorSaveRejectsStaleReviewedContent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-stale-review-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let original = BuiltInRulePacks.advertising
        let originalCatalog = VerifiedRulePackCatalog(
            definitions: [original], sequence: 1, digest: String(repeating: "1", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("one".utf8)
        )
        let firstAcceptance = try db.acceptVerifiedRulePackCatalog(
            originalCatalog, checkedAt: Date(timeIntervalSince1970: 100),
            nextEligibleAt: Date(timeIntervalSince1970: 200)
        )
        let store = RulePackStore(definitions: [original])
        store.attach(db: db)
        try await waitUntil { store.reviewReceipt(for: original) != nil }
        let staleReceipt = try XCTUnwrap(store.reviewReceipt(for: original))

        var replacement = original
        replacement.entries.append(RulePackEntry(
            id: UInt32(replacement.entries.count + 1), host: "zz-stale-review.example",
            category: .advertising
        ))
        replacement.entries.sort { "\($0.host)|\($0.match.rawValue)" < "\($1.host)|\($1.match.rawValue)" }
        replacement.manifest.version = "2"
        replacement.manifest.entryCount = replacement.entries.count
        replacement.manifest.contentSHA256 = RulePackValidator.digest(replacement.entries)
        let replacementCatalog = VerifiedRulePackCatalog(
            definitions: [replacement], sequence: 2, digest: String(repeating: "2", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("two".utf8)
        )
        let secondAcceptance = try db.acceptVerifiedRulePackCatalog(
            replacementCatalog, checkedAt: Date(timeIntervalSince1970: 300),
            nextEligibleAt: Date(timeIntervalSince1970: 400)
        )
        store.installCommittedCatalog(replacementCatalog, acceptance: secondAcceptance)
        XCTAssertEqual(firstAcceptance.state.receipt?.sequence, 1)

        var candidate = RulePackConfiguration(packID: original.id, enabled: true)
        var result: RulePackStore.SaveResult?
        store.save(candidate, reviewedDefinition: original, receipt: staleReceipt) { result = $0 }
        XCTAssertEqual(result, .staleReview)
        XCTAssertFalse(store.configuration(for: original.id).enabled)
        XCTAssertNil(store.snapshot)
        candidate.enabled = false
    }

    @MainActor
    func testOmittedAndReintroducedPackRestoresDurableException() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-reintroduced-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        var definition = BuiltInRulePacks.advertising
        definition.manifest.id = "official.reintroduced"
        let first = VerifiedRulePackCatalog(
            definitions: [definition], sequence: 1, digest: String(repeating: "1", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("one".utf8)
        )
        let firstAcceptance = try db.acceptVerifiedRulePackCatalog(
            first, checkedAt: Date(timeIntervalSince1970: 100),
            nextEligibleAt: Date(timeIntervalSince1970: 200)
        )
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(configuration)
        let exception = RulePackOverride(
            packID: definition.id, app: "com.apple.Safari", host: definition.entries[0].host
        )
        try db.saveRulePackOverride(exception)

        let store = RulePackStore(definitions: [definition], currentAppVersion: "0.15.4")
        store.installCommittedCatalog(first, acceptance: try db.loadRulePackCatalogBootstrap(
            catalogID: RulePackCatalogVerifier.catalogID
        ))
        XCTAssertEqual(firstAcceptance.state.receipt?.sequence, 1)
        XCTAssertEqual(store.overrides, [exception])
        XCTAssertNotNil(store.snapshot)

        let omitted = VerifiedRulePackCatalog(
            definitions: [], sequence: 2, digest: String(repeating: "2", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("two".utf8)
        )
        let omissionAcceptance = try db.acceptVerifiedRulePackCatalog(
            omitted, checkedAt: Date(timeIntervalSince1970: 300),
            nextEligibleAt: Date(timeIntervalSince1970: 400)
        )
        store.installCommittedCatalog(omitted, acceptance: omissionAcceptance)
        XCTAssertTrue(store.overrides.isEmpty)
        XCTAssertNil(store.snapshot)

        let reintroduced = VerifiedRulePackCatalog(
            definitions: [definition], sequence: 3, digest: String(repeating: "3", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("three".utf8)
        )
        let reintroductionAcceptance = try db.acceptVerifiedRulePackCatalog(
            reintroduced, checkedAt: Date(timeIntervalSince1970: 500),
            nextEligibleAt: Date(timeIntervalSince1970: 600)
        )
        store.installCommittedCatalog(reintroduced, acceptance: reintroductionAcceptance)

        XCTAssertEqual(store.overrides, [exception])
        XCTAssertEqual(store.snapshot?.overrides, [exception])
        XCTAssertTrue(store.configuration(for: definition.id).enabled)
    }

    @MainActor
    func testCatalogInstallDoesNotOverwriteNewerLocalDisable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-pack-catalog-race-\(UUID().uuidString).sqlite")
        let db = try TrafficDatabase(url: url)
        let definition = BuiltInRulePacks.advertising
        let first = VerifiedRulePackCatalog(
            definitions: [definition], sequence: 1, digest: String(repeating: "1", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("one".utf8)
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            first, checkedAt: Date(timeIntervalSince1970: 100),
            nextEligibleAt: Date(timeIntervalSince1970: 200)
        )
        var enabled = RulePackConfiguration(packID: definition.id, enabled: true)
        enabled.consentedVersion = definition.manifest.version
        enabled.consentedContentSHA256 = definition.manifest.contentSHA256
        try db.saveRulePackConfiguration(enabled)

        let store = RulePackStore(definitions: [definition], currentAppVersion: "0.15.4")
        store.attach(db: db)
        try await waitUntil { store.reviewReceipt(for: definition) != nil }
        XCTAssertEqual(
            store.installCommittedCatalog(
                first,
                acceptance: try db.loadRulePackCatalogBootstrap(
                    catalogID: RulePackCatalogVerifier.catalogID
                )
            ),
            .installed
        )
        XCTAssertNotNil(store.snapshot)

        let expectedRevision = store.catalogInstallRevision
        let refreshed = VerifiedRulePackCatalog(
            definitions: [definition], sequence: 2, digest: String(repeating: "2", count: 64),
            signerKeyID: "test-key", stale: false, rawEnvelope: Data("two".utf8)
        )
        let staleAcceptance = try db.acceptVerifiedRulePackCatalog(
            refreshed, checkedAt: Date(timeIntervalSince1970: 300),
            nextEligibleAt: Date(timeIntervalSince1970: 400)
        )

        var disabled = enabled
        disabled.enabled = false
        await withCheckedContinuation { continuation in
            store.save(disabled) { saved in
                XCTAssertTrue(saved)
                continuation.resume()
            }
        }
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(
            store.installCommittedCatalog(
                refreshed,
                acceptance: staleAcceptance,
                expectedRevision: expectedRevision
            ),
            .staleRevision
        )
        XCTAssertFalse(store.configuration(for: definition.id).enabled)
        XCTAssertNil(store.snapshot)

        let currentRevision = store.catalogInstallRevision
        XCTAssertEqual(
            store.installCommittedCatalog(
                refreshed,
                acceptance: try db.loadRulePackCatalogBootstrap(
                    catalogID: RulePackCatalogVerifier.catalogID
                ),
                expectedRevision: currentRevision
            ),
            .installed
        )
        XCTAssertFalse(store.configuration(for: definition.id).enabled)
        XCTAssertNil(store.snapshot)
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
        XCTAssertEqual(draft.requestSave(), .commit(draft.configuration, nil),
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

    func testEditorAcceptsExplicitBundleIdentityDuringIncompleteScan() {
        var draft = RulePackEditorDraft(saved: RulePackConfiguration(packID: "official.advertising"),
                                        intent: .activate)
        draft.configuration.scope = .selectedApps

        draft.typedApp = "com.apple.Safari"
        XCTAssertEqual(draft.submitApp(installed: [], appsLoaded: false), .added("com.apple.Safari"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.Safari"])
    }

    func testEditorIncompleteScanAcceptsKnownCommandLineAgent() {
        var draft = RulePackEditorDraft(saved: RulePackConfiguration(packID: "official.advertising"),
                                        intent: .activate)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "claude"

        XCTAssertEqual(draft.submitApp(installed: [], appsLoaded: false), .added("claude"))
        XCTAssertEqual(draft.configuration.apps, ["claude"])
    }

    func testEditorIncompleteScanDoesNotGuessLowercaseDisplayNameIsAProcess() {
        var draft = RulePackEditorDraft(saved: RulePackConfiguration(packID: "official.advertising"),
                                        intent: .activate)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "zoom"

        XCTAssertEqual(draft.submitApp(installed: [], appsLoaded: false), .loading)
        XCTAssertEqual(draft.typedApp, "zoom")
        XCTAssertTrue(draft.configuration.apps.isEmpty)
    }

    func testEditorIncompleteScanStillResolvesKnownDisplayName() {
        let safari = InstalledApps.App(name: "Safari", bundleID: "com.apple.Safari",
                                       path: "/System/Applications/Safari.app")
        var draft = RulePackEditorDraft(saved: RulePackConfiguration(packID: "official.advertising"),
                                        intent: .activate)
        draft.configuration.scope = .selectedApps
        draft.typedApp = "Safari"

        XCTAssertEqual(draft.submitApp(installed: [safari], appsLoaded: false), .added("com.apple.Safari"))
        XCTAssertEqual(draft.configuration.apps, ["com.apple.Safari"])
    }

    func testEditorExplicitSaveAndBroadeningDecision() {
        var selected = RulePackConfiguration(packID: "official.advertising", enabled: true,
                                             scope: .selectedApps, apps: ["com.apple.curl"])
        var draft = RulePackEditorDraft(saved: selected, intent: .review)
        XCTAssertEqual(draft.requestSave(), .commit(selected, nil))

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

    private func activityBatch() -> RulePackEventBatch {
        RulePackEventBatch(events: [
            RulePackEvent(
                bucket: 1_700_000_000,
                packID: "official.advertising",
                packVersion: "1",
                entryID: 1,
                category: .advertising,
                action: .block,
                count: 1,
                firstAt: 1_700_000_001,
                lastAt: 1_700_000_001,
                bundleID: "com.google.Chrome",
                appName: "Google Chrome",
                agentKey: "com.google.Chrome",
                agentName: "Google Chrome",
                host: "ads.example",
                matchedHost: "ads.example",
                port: 443
            ),
        ])
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
    private func attachedStore(db: TrafficDatabase) async throws -> RulePackStore {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "official", withExtension: "json"))
        let data = try Data(contentsOf: fixture)
        let verified = try RulePackCatalogVerifier.verify(
            data: data, now: 1_800_000_000, currentAppVersion: "0.15.4"
        )
        let composed = try RulePackCatalogComposition.compose(verified, currentAppVersion: "0.15.4")
        _ = try db.acceptVerifiedRulePackCatalog(
            composed,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000),
            nextEligibleAt: Date(timeIntervalSince1970: 1_800_086_400)
        )
        let store = RulePackStore()
        store.attach(db: db)
        try await waitUntil { store.configurations.count == store.definitions.count
            && store.reviewReceipt(for: BuiltInRulePacks.advertising) != nil }
        return store
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

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
