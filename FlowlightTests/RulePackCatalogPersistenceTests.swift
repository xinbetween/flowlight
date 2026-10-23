import XCTest
@testable import Flowlight

final class RulePackCatalogPersistenceTests: XCTestCase {
    private let catalogID = RulePackCatalogVerifier.catalogID
    private let acceptedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let nextCheck = Date(timeIntervalSince1970: 1_800_086_400)

    func testCompositionOverlaysAddsAndRetainsOmittedBuiltIns() throws {
        var replacement = BuiltInRulePacks.advertising
        replacement.manifest.version = "2"
        var added = BuiltInRulePacks.tracking
        added.manifest.id = "official.added"
        let catalog = verifiedCatalog(
            sequence: 2, digest: String(repeating: "a", count: 64),
            definitions: [added, replacement]
        )

        let composed = try RulePackCatalogComposition.compose(catalog, currentAppVersion: "0.15.4")

        XCTAssertEqual(composed.definitions.map(\.id),
                       ["official.added", "official.advertising", "official.telemetry", "official.tracking"])
        XCTAssertEqual(composed.definitions.first { $0.id == replacement.id }?.manifest.version, "2")
        XCTAssertEqual(composed.definitions.first { $0.id == BuiltInRulePacks.telemetry.id },
                       BuiltInRulePacks.telemetry)
        XCTAssertEqual(composed.rawEnvelope, catalog.rawEnvelope)
        XCTAssertEqual(composed.digest, catalog.digest)
    }

    func testCompositionUsesRunningAppVersionForCompatibleCatalog() throws {
        var definition = BuiltInRulePacks.advertising
        definition.manifest.minimumAppVersion = "0.15.4"
        let catalog = verifiedCatalog(
            sequence: 2,
            digest: String(repeating: "a", count: 64),
            definitions: [definition]
        )

        XCTAssertNoThrow(try RulePackCatalogComposition.compose(catalog, currentAppVersion: "0.15.4"))
        XCTAssertThrowsError(try RulePackCatalogComposition.compose(catalog, currentAppVersion: "0.15.3")) {
            XCTAssertEqual($0 as? RulePackValidationError, .incompatibleProtocol(definition.id))
        }
    }

    func testCatalogAcceptancePersistsExactBytesAndSurvivesReopen() throws {
        let url = temporaryDatabaseURL("catalog-reopen")
        var db: TrafficDatabase? = try TrafficDatabase(url: url)
        let catalog = verifiedCatalog(sequence: 2, digest: String(repeating: "a", count: 64))

        let accepted = try XCTUnwrap(db).acceptVerifiedRulePackCatalog(
            catalog, etag: #""sequence-2""#, lastModified: "Mon, 19 Oct 2026 00:00:00 GMT",
            checkedAt: acceptedAt, nextEligibleAt: nextCheck
        )

        XCTAssertEqual(accepted.state.receipt?.sequence, 2)
        XCTAssertEqual(accepted.state.receipt?.digest, catalog.digest)
        XCTAssertEqual(accepted.state.receipt?.signerKeyID, catalog.signerKeyID)
        XCTAssertEqual(accepted.state.cache?.rawEnvelope, catalog.rawEnvelope)
        XCTAssertEqual(accepted.state.cache?.etag, #""sequence-2""#)
        XCTAssertEqual(accepted.state.cache?.lastModified, "Mon, 19 Oct 2026 00:00:00 GMT")
        XCTAssertEqual(accepted.state.update.lastSuccess, acceptedAt)
        XCTAssertEqual(accepted.state.update.nextEligibleAttempt, nextCheck)
        XCTAssertEqual(accepted.state.update.failureCount, 0)

        db = nil
        let reopened = try TrafficDatabase(url: url)
        XCTAssertEqual(try reopened.loadRulePackCatalogState(catalogID: catalogID), accepted.state)
    }

    func testAcceptanceTransactionRejectsRollbackAndEquivocation() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-rollback"))
        let sequenceTwo = verifiedCatalog(sequence: 2, digest: String(repeating: "2", count: 64))
        _ = try db.acceptVerifiedRulePackCatalog(sequenceTwo, checkedAt: acceptedAt, nextEligibleAt: nextCheck)

        XCTAssertThrowsError(try db.acceptVerifiedRulePackCatalog(
            verifiedCatalog(sequence: 1, digest: String(repeating: "1", count: 64)),
            checkedAt: acceptedAt.addingTimeInterval(1), nextEligibleAt: nextCheck
        )) { error in
            XCTAssertEqual(error as? RulePackCatalogPersistenceError, .rollback)
        }
        XCTAssertThrowsError(try db.acceptVerifiedRulePackCatalog(
            verifiedCatalog(sequence: 2, digest: String(repeating: "e", count: 64)),
            checkedAt: acceptedAt.addingTimeInterval(2), nextEligibleAt: nextCheck
        )) { error in
            XCTAssertEqual(error as? RulePackCatalogPersistenceError, .equivocation)
        }

        let state = try db.loadRulePackCatalogState(catalogID: catalogID)
        XCTAssertEqual(state.receipt?.sequence, 2)
        XCTAssertEqual(state.receipt?.digest, sequenceTwo.digest)
        XCTAssertEqual(state.cache?.rawEnvelope, sequenceTwo.rawEnvelope)
    }

    func testEqualReceiptCanRecoverExactCacheBytes() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-recovery"))
        let original = verifiedCatalog(sequence: 2, digest: String(repeating: "a", count: 64), raw: Data("first".utf8))
        _ = try db.acceptVerifiedRulePackCatalog(original, etag: "old", checkedAt: acceptedAt,
                                                 nextEligibleAt: nextCheck)
        let recovered = verifiedCatalog(sequence: 2, digest: original.digest, raw: Data("recovered".utf8))
        _ = try db.acceptVerifiedRulePackCatalog(recovered, etag: "new",
                                                 checkedAt: acceptedAt.addingTimeInterval(10),
                                                 nextEligibleAt: nextCheck.addingTimeInterval(10))

        let state = try db.loadRulePackCatalogState(catalogID: catalogID)
        XCTAssertEqual(state.receipt?.sequence, 2)
        XCTAssertEqual(state.receipt?.acceptedAt, acceptedAt,
                       "reaccepting identical content must preserve migration evidence")
        XCTAssertEqual(state.cache?.rawEnvelope, recovered.rawEnvelope)
        XCTAssertEqual(state.cache?.etag, "new")
    }

    func testAcceptanceAtomicallyInvalidatesChangedConsentButKeepsDormantRows() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-consent"))
        let original = BuiltInRulePacks.advertising
        var active = RulePackConfiguration(packID: original.id, enabled: true,
                                           scope: .selectedApps, apps: ["com.apple.Safari"])
        active.consentedVersion = original.manifest.version
        active.consentedContentSHA256 = original.manifest.contentSHA256
        let dormant = RulePackConfiguration(packID: "official.omitted", enabled: false,
                                            scope: .selectedApps, apps: ["com.apple.curl"])
        try db.saveRulePackConfiguration(active)
        try db.saveRulePackConfiguration(dormant)

        var changed = original
        changed.entries.append(RulePackEntry(id: UInt32(changed.entries.count + 1), host: "zz-new-ad.example",
                                             category: .advertising))
        changed.entries.sort { "\($0.host)|\($0.match.rawValue)" < "\($1.host)|\($1.match.rawValue)" }
        changed.manifest.version = "2"
        changed.manifest.entryCount = changed.entries.count
        changed.manifest.contentSHA256 = RulePackValidator.digest(changed.entries)
        let catalog = verifiedCatalog(sequence: 2, digest: String(repeating: "b", count: 64),
                                      definitions: [changed])

        let accepted = try db.acceptVerifiedRulePackCatalog(catalog, checkedAt: acceptedAt,
                                                            nextEligibleAt: nextCheck)
        let invalidated = try XCTUnwrap(accepted.configurations.first { $0.packID == active.packID })
        XCTAssertFalse(invalidated.enabled)
        XCTAssertEqual(invalidated.scope, active.scope)
        XCTAssertEqual(invalidated.apps, active.apps)
        XCTAssertEqual(invalidated.consentedVersion, active.consentedVersion)
        XCTAssertEqual(invalidated.consentedContentSHA256, active.consentedContentSHA256)
        XCTAssertEqual(accepted.configurations.first { $0.packID == dormant.packID }, dormant)
        XCTAssertEqual(try db.loadRulePackConfigurations().sorted { $0.packID < $1.packID },
                       accepted.configurations)
    }

    func testBootstrapBackfillsReviewForPackDisabledByPreviousRelease() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-review-backfill"))
        let original = BuiltInRulePacks.advertising
        var changed = original
        changed.manifest.version = "2"
        changed.entries.append(RulePackEntry(
            id: 999, host: "legacy-change.example", category: .advertising
        ))
        changed.entries.sort { "\($0.host)|\($0.match.rawValue)" < "\($1.host)|\($1.match.rawValue)" }
        changed.manifest.entryCount = changed.entries.count
        changed.manifest.contentSHA256 = RulePackValidator.digest(changed.entries)
        let catalog = verifiedCatalog(
            sequence: 2,
            digest: String(repeating: "b", count: 64),
            definitions: [changed]
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog,
            checkedAt: acceptedAt,
            nextEligibleAt: nextCheck
        )
        var legacyStopped = RulePackConfiguration(packID: original.id)
        legacyStopped.consentedVersion = original.manifest.version
        legacyStopped.consentedContentSHA256 = original.manifest.contentSHA256
        try db.saveRulePackConfiguration(legacyStopped)
        _ = try db.raw(
            "UPDATE rule_packs SET updated = ? WHERE pack_id = ?",
            [.int(Int64(acceptedAt.timeIntervalSince1970)), .text(original.id)]
        ) { _ in 0 }
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog,
            checkedAt: acceptedAt.addingTimeInterval(10),
            nextEligibleAt: nextCheck.addingTimeInterval(10)
        )

        let bootstrap = try db.loadRulePackCatalogBootstrap(catalogID: catalogID)
        let repaired = try db.reconcileRulePackCatalogBootstrap(
            bootstrap,
            definitions: catalog.definitions
        )

        XCTAssertEqual(repaired.pendingReviewPackIDs, [original.id])
        XCTAssertFalse(try XCTUnwrap(repaired.configurations.first).enabled)
    }

    func testBootstrapDoesNotMarkPackUserDisabledAfterCatalogAcceptance() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-user-disabled"))
        let original = BuiltInRulePacks.advertising
        var changed = original
        changed.manifest.version = "2"
        changed.entries.append(RulePackEntry(id: 999, host: "changed.example", category: .advertising))
        changed.entries.sort { "\($0.host)|\($0.match.rawValue)" < "\($1.host)|\($1.match.rawValue)" }
        changed.manifest.entryCount = changed.entries.count
        changed.manifest.contentSHA256 = RulePackValidator.digest(changed.entries)
        let catalog = verifiedCatalog(
            sequence: 2,
            digest: String(repeating: "b", count: 64),
            definitions: [changed]
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog,
            checkedAt: acceptedAt,
            nextEligibleAt: nextCheck
        )
        var userDisabled = RulePackConfiguration(packID: original.id)
        userDisabled.consentedVersion = original.manifest.version
        userDisabled.consentedContentSHA256 = original.manifest.contentSHA256
        try db.saveRulePackConfiguration(userDisabled)

        let bootstrap = try db.loadRulePackCatalogBootstrap(catalogID: catalogID)
        let repaired = try db.reconcileRulePackCatalogBootstrap(
            bootstrap,
            definitions: catalog.definitions
        )

        XCTAssertTrue(repaired.pendingReviewPackIDs.isEmpty)
    }

    func testAcknowledgedLegacyBackfillDoesNotReappearOnNextBootstrap() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-review-ack-stable"))
        let original = BuiltInRulePacks.advertising
        var changed = original
        changed.manifest.version = "2"
        changed.entries.append(RulePackEntry(id: 999, host: "legacy-change.example", category: .advertising))
        changed.entries.sort { "\($0.host)|\($0.match.rawValue)" < "\($1.host)|\($1.match.rawValue)" }
        changed.manifest.entryCount = changed.entries.count
        changed.manifest.contentSHA256 = RulePackValidator.digest(changed.entries)
        let catalog = verifiedCatalog(
            sequence: 2,
            digest: String(repeating: "b", count: 64),
            definitions: [changed]
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog,
            checkedAt: acceptedAt,
            nextEligibleAt: nextCheck
        )
        var legacyStopped = RulePackConfiguration(packID: original.id)
        legacyStopped.consentedVersion = original.manifest.version
        legacyStopped.consentedContentSHA256 = original.manifest.contentSHA256
        try db.saveRulePackConfiguration(legacyStopped)
        _ = try db.raw(
            "UPDATE rule_packs SET updated = ? WHERE pack_id = ?",
            [.int(Int64(acceptedAt.timeIntervalSince1970)), .text(original.id)]
        ) { _ in 0 }
        let first = try db.reconcileRulePackCatalogBootstrap(
            db.loadRulePackCatalogBootstrap(catalogID: catalogID),
            definitions: catalog.definitions
        )
        XCTAssertEqual(first.pendingReviewPackIDs, [original.id])

        try db.setRulePackReviewRequired(false, packID: original.id)
        let second = try db.reconcileRulePackCatalogBootstrap(
            db.loadRulePackCatalogBootstrap(catalogID: catalogID),
            definitions: catalog.definitions
        )

        XCTAssertTrue(second.pendingReviewPackIDs.isEmpty)
    }

    func testBootstrapDisablesAndPersistsLegacyOmittedActivePack() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-omitted-backfill"))
        let catalog = verifiedCatalog(
            sequence: 2,
            digest: String(repeating: "b", count: 64),
            definitions: []
        )
        _ = try db.acceptVerifiedRulePackCatalog(
            catalog,
            checkedAt: acceptedAt,
            nextEligibleAt: nextCheck
        )
        var legacyActive = RulePackConfiguration(packID: "official.legacy-omitted", enabled: true)
        legacyActive.consentedVersion = "1"
        legacyActive.consentedContentSHA256 = String(repeating: "a", count: 64)
        try db.saveRulePackConfiguration(legacyActive)

        let bootstrap = try db.loadRulePackCatalogBootstrap(catalogID: catalogID)
        let repaired = try db.reconcileRulePackCatalogBootstrap(
            bootstrap,
            definitions: catalog.definitions
        )

        XCTAssertEqual(repaired.pendingReviewPackIDs, [legacyActive.packID])
        XCTAssertFalse(try XCTUnwrap(repaired.configurations.first).enabled)
        XCTAssertFalse(try XCTUnwrap(db.loadRulePackConfigurations().first).enabled)
    }

    func testFailedCacheWriteRollsBackReceiptAndConsentReconciliation() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-atomic-failure"))
        var configuration = RulePackConfiguration(packID: BuiltInRulePacks.advertising.id, enabled: true)
        configuration.consentedVersion = "older"
        configuration.consentedContentSHA256 = String(repeating: "0", count: 64)
        try db.saveRulePackConfiguration(configuration)
        _ = try db.raw("DROP TABLE rule_pack_catalog_cache") { _ in 0 }

        XCTAssertThrowsError(try db.acceptVerifiedRulePackCatalog(
            verifiedCatalog(sequence: 2, digest: String(repeating: "c", count: 64)),
            checkedAt: acceptedAt, nextEligibleAt: nextCheck
        ))

        XCTAssertEqual(try db.raw("SELECT COUNT(*) FROM rule_pack_catalog_receipts") { $0.int(0) }, [0])
        XCTAssertEqual(try db.loadRulePackConfigurations(), [configuration],
                       "consent must not change when catalog persistence rolls back")
    }

    func testClearAllPreservesCatalogWatermarkAndCache() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-clear"))
        let catalog = verifiedCatalog(sequence: 3, digest: String(repeating: "d", count: 64))
        _ = try db.acceptVerifiedRulePackCatalog(catalog, checkedAt: acceptedAt, nextEligibleAt: nextCheck)

        try db.clearAll()

        let state = try db.loadRulePackCatalogState(catalogID: catalogID)
        XCTAssertEqual(state.receipt?.sequence, 3)
        XCTAssertEqual(state.receipt?.digest, catalog.digest)
        XCTAssertEqual(state.cache?.rawEnvelope, catalog.rawEnvelope)
    }

    func testNotModifiedRequiresTheReverifiedDurableReceipt() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-not-modified"))
        let catalog = verifiedCatalog(sequence: 4, digest: String(repeating: "4", count: 64))
        _ = try db.acceptVerifiedRulePackCatalog(catalog, checkedAt: acceptedAt, nextEligibleAt: nextCheck)

        XCTAssertThrowsError(try db.recordRulePackCatalogNotModified(
            catalogID: catalogID, expectedSequence: 3, expectedDigest: catalog.digest,
            checkedAt: acceptedAt.addingTimeInterval(10), nextEligibleAt: nextCheck
        )) { error in
            XCTAssertEqual(error as? RulePackCatalogPersistenceError, .invalidReceipt)
        }
        let checked = acceptedAt.addingTimeInterval(20)
        try db.recordRulePackCatalogNotModified(
            catalogID: catalogID, expectedSequence: catalog.sequence, expectedDigest: catalog.digest,
            checkedAt: checked, nextEligibleAt: nextCheck.addingTimeInterval(20)
        )
        XCTAssertEqual(try db.loadRulePackCatalogState(catalogID: catalogID).update.lastStatus,
                       "not-modified")
    }

    func testReviewedSaveIsCheckedAgainstDurableCatalogReceipt() throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-reviewed-save"))
        let definition = BuiltInRulePacks.advertising
        let catalog = verifiedCatalog(sequence: 5, digest: String(repeating: "5", count: 64),
                                      definitions: [definition])
        _ = try db.acceptVerifiedRulePackCatalog(catalog, checkedAt: acceptedAt, nextEligibleAt: nextCheck)
        var configuration = RulePackConfiguration(packID: definition.id, enabled: true)
        configuration.consentedVersion = definition.manifest.version
        configuration.consentedContentSHA256 = definition.manifest.contentSHA256
        let current = RulePackReviewReceipt(
            packID: definition.id, version: definition.manifest.version,
            contentSHA256: definition.manifest.contentSHA256,
            catalogSequence: catalog.sequence, catalogDigest: catalog.digest
        )
        try db.saveRulePackConfiguration(configuration, reviewed: current)

        var stale = current
        stale.catalogSequence -= 1
        XCTAssertThrowsError(try db.saveRulePackConfiguration(configuration, reviewed: stale)) { error in
            XCTAssertEqual(error as? RulePackCatalogPersistenceError, .staleReview)
        }
        configuration.enabled = false
        XCTAssertNoThrow(try db.saveRulePackConfiguration(configuration, reviewed: nil))
        XCTAssertNoThrow(try db.saveRulePackConfiguration(configuration, reviewed: current))
    }

    func testAsyncResultReturnsValuesAndPropagatesErrors() async throws {
        let db = try TrafficDatabase(url: temporaryDatabaseURL("catalog-async"))
        let value = try await db.asyncResult { _ in 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await db.asyncResult { _ -> Int in throw RulePackCatalogPersistenceError.invalidReceipt }
            XCTFail("expected persistence error")
        } catch {
            XCTAssertEqual(error as? RulePackCatalogPersistenceError, .invalidReceipt)
        }
    }

    private func verifiedCatalog(sequence: Int64, digest: String,
                                 raw: Data? = nil,
                                 definitions: [RulePackDefinition] = BuiltInRulePacks.all) -> VerifiedRulePackCatalog {
        VerifiedRulePackCatalog(
            definitions: definitions, sequence: sequence, digest: digest,
            signerKeyID: "test-key", stale: false,
            rawEnvelope: raw ?? Data("catalog-\(sequence)-\(digest)".utf8)
        )
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-\(name)-\(UUID().uuidString).sqlite")
    }
}
