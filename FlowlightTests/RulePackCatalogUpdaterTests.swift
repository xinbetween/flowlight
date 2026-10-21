import CryptoKit
import XCTest
@testable import Flowlight

final class RulePackCatalogUpdaterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testBootstrapAcceptsBundledCatalogWithoutNetwork() async throws {
        let fixture = try productionFixture()
        let db = try database("bootstrap")
        let store = RulePackStore()
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { fixture },
            transport: { _ in counter.calls += 1; throw URLError(.badServerResponse) },
            now: { self.now }
        )

        await updater.bootstrap()

        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(updater.receipt?.sequence, 1)
        XCTAssertEqual(updater.status, .current)
        XCTAssertEqual(store.definitions, BuiltInRulePacks.all.sorted { $0.id < $1.id })
        XCTAssertFalse(updater.isDownloadedUpdate(BuiltInRulePacks.advertising))
        XCTAssertNotNil(store.reviewReceipt(for: BuiltInRulePacks.advertising))
    }

    @MainActor
    func testConditional304ReverifiesCacheAndAdvancesSchedule() async throws {
        let fixture = try productionFixture()
        let db = try database("not-modified")
        let store = RulePackStore()
        final class Capture: @unchecked Sendable { var request: URLRequest? }
        let capture = Capture()
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: RulePackCatalogVerifier.sourceURL)),
            statusCode: 304, httpVersion: nil, headerFields: nil
        )!
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { fixture },
            transport: { request in capture.request = request; return (Data(), response) },
            now: { self.now }
        )
        await updater.bootstrap()
        _ = try db.raw("UPDATE rule_pack_catalog_cache SET etag = ?, last_modified = ?",
                       [.text(#""catalog-1""#), .text("Mon, 19 Oct 2026 00:00:00 GMT")]) { _ in 0 }
        await updater.bootstrap()
        updater.startScheduling(networkingEnabled: true)

        await updater.checkNow()

        XCTAssertEqual(capture.request?.value(forHTTPHeaderField: "If-None-Match"), #""catalog-1""#)
        XCTAssertEqual(capture.request?.value(forHTTPHeaderField: "If-Modified-Since"),
                       "Mon, 19 Oct 2026 00:00:00 GMT")
        XCTAssertEqual(capture.request?.value(forHTTPHeaderField: "User-Agent"), "Flowlight/0.15.4")
        XCTAssertEqual(updater.status, .current)
        XCTAssertEqual(updater.catalogState.update.lastStatus, "not-modified")
        XCTAssertEqual(updater.catalogState.update.nextEligibleAttempt,
                       now.addingTimeInterval(RulePackCatalogUpdater.healthyInterval))
    }

    @MainActor
    func testVerified200PersistsValidatorsAndInstallsNewPackDefaultOff() async throws {
        let key = P256.Signing.PrivateKey()
        let data = try signedCatalog(key: key, sequence: 2, definitions: [newDefinition()])
        let db = try database("accepted-200")
        let store = RulePackStore()
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: RulePackCatalogVerifier.sourceURL)),
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json; charset=utf-8",
                           "ETag": #""catalog-2""#, "Last-Modified": "Tue, 20 Oct 2026 00:00:00 GMT"]
        )!
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { data }, transport: { _ in (data, response) },
            trustedSigners: [signer(key)], now: { self.now }
        )
        await updater.bootstrap()
        updater.startScheduling(networkingEnabled: true)

        await updater.checkNow()

        XCTAssertEqual(updater.receipt?.sequence, 2)
        XCTAssertEqual(updater.catalogState.cache?.etag, #""catalog-2""#)
        XCTAssertEqual(updater.catalogState.cache?.lastModified, "Tue, 20 Oct 2026 00:00:00 GMT")
        let downloaded = try XCTUnwrap(store.definitions.first { $0.id == "official.new" })
        XCTAssertTrue(updater.isDownloadedUpdate(downloaded))
        XCTAssertFalse(store.configuration(for: "official.new").enabled)
        XCTAssertNil(store.snapshot)
    }

    @MainActor
    func testWrongMIMELeavesLastKnownGoodAndPersistsBackoff() async throws {
        let fixture = try productionFixture()
        let db = try database("mime-failure")
        let store = RulePackStore()
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: RulePackCatalogVerifier.sourceURL)),
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]
        )!
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { fixture }, transport: { _ in (fixture, response) },
            now: { self.now }
        )
        await updater.bootstrap()
        let prior = updater.receipt
        updater.startScheduling(networkingEnabled: true)

        await updater.checkNow()

        XCTAssertEqual(updater.receipt, prior)
        XCTAssertEqual(updater.catalogState.update.failureCount, 1)
        XCTAssertEqual(updater.catalogState.update.nextEligibleAttempt,
                       now.addingTimeInterval(RulePackCatalogUpdater.failureBackoff[0]))
        guard case .failed(_, let usingLastKnownGood) = updater.status else {
            return XCTFail("wrong MIME should be a visible refresh failure")
        }
        XCTAssertTrue(usingLastKnownGood)
    }

    @MainActor
    func testHigherWatermarkWithMissingCacheEntersRecoveryAndOmitsValidators() async throws {
        let key = P256.Signing.PrivateKey()
        let sequenceTwo = try signedCatalog(key: key, sequence: 2, definitions: [newDefinition()])
        let verified = try RulePackCatalogVerifier.verify(
            data: sequenceTwo, trustedSigners: [signer(key)], now: Int64(now.timeIntervalSince1970),
            currentAppVersion: "0.15.4"
        )
        let composed = try RulePackCatalogComposition.compose(verified)
        let db = try database("missing-cache")
        _ = try db.acceptVerifiedRulePackCatalog(
            composed, etag: "stale-validator", checkedAt: now,
            nextEligibleAt: now.addingTimeInterval(60)
        )
        _ = try db.raw("DELETE FROM rule_pack_catalog_cache") { _ in 0 }
        let store = RulePackStore()
        final class Capture: @unchecked Sendable { var request: URLRequest? }
        let capture = Capture()
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: RulePackCatalogVerifier.sourceURL)),
            statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { try self.productionFixture() },
            transport: { request in capture.request = request; return (sequenceTwo, response) },
            trustedSigners: [signer(key)], now: { self.now }
        )

        await updater.bootstrap()
        XCTAssertTrue(store.definitions.isEmpty)
        XCTAssertNil(store.snapshot)
        guard case .recovery = updater.status else { return XCTFail("missing cache must require recovery") }
        updater.startScheduling(networkingEnabled: true)
        await updater.checkNow()

        XCTAssertNil(capture.request?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertNil(capture.request?.value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertEqual(updater.receipt?.sequence, 2)
        XCTAssertEqual(updater.status, .current)
        XCTAssertFalse(store.definitions.isEmpty)
    }

    @MainActor
    func testNetworkingDisabledNeverInvokesTransport() async throws {
        let fixture = try productionFixture()
        let db = try database("disabled-network")
        let store = RulePackStore()
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let updater = RulePackCatalogUpdater(
            db: db, store: store, currentAppVersion: "0.15.4",
            bundledCatalog: { fixture },
            transport: { _ in counter.calls += 1; throw URLError(.notConnectedToInternet) },
            now: { self.now }
        )
        await updater.bootstrap()
        updater.startScheduling(networkingEnabled: false)

        await updater.checkNow()

        XCTAssertEqual(counter.calls, 0)
        XCTAssertEqual(updater.status, .current)
    }

    private func productionFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "official", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func database(_ name: String) throws -> TrafficDatabase {
        try TrafficDatabase(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-updater-\(name)-\(UUID().uuidString).sqlite"))
    }

    private func signer(_ key: P256.Signing.PrivateKey) -> RulePackCatalogTrustedSigner {
        RulePackCatalogTrustedSigner(
            keyID: "test-key", publisher: RulePackCatalogVerifier.publisher,
            catalogID: RulePackCatalogVerifier.catalogID, packIDPrefix: "official.",
            publicKeyPEM: key.publicKey.pemRepresentation,
            validFrom: Int64(now.timeIntervalSince1970) - 10_000,
            validUntil: Int64(now.timeIntervalSince1970) + 10_000,
            revoked: false
        )
    }

    private func newDefinition() -> RulePackDefinition {
        let entries = [RulePackEntry(id: 1, host: "new.example", category: .advertising)]
        return RulePackDefinition(
            manifest: RulePackManifest(
                id: "official.new", version: "1", generatedAt: now.addingTimeInterval(-100),
                entryCount: entries.count, contentSHA256: RulePackValidator.digest(entries),
                titleKey: "pack.new.title", summaryKey: "pack.new.summary", caveatKey: "pack.new.caveat",
                source: "test", license: "MIT"
            ),
            entries: entries
        )
    }

    private func signedCatalog(key: P256.Signing.PrivateKey, sequence: Int64,
                               definitions: [RulePackDefinition]) throws -> Data {
        let packs = definitions.sorted { $0.id < $1.id }.map { definition in
            RulePackCatalogWirePack(
                manifest: RulePackCatalogWireManifest(
                    id: definition.id, version: definition.manifest.version,
                    generatedAt: Int64(definition.manifest.generatedAt.timeIntervalSince1970),
                    entryCount: UInt32(definition.entries.count),
                    contentSHA256: definition.manifest.contentSHA256,
                    minimumAppVersion: definition.manifest.minimumAppVersion,
                    minimumExtensionProtocol: definition.manifest.minimumExtensionProtocol,
                    titleKey: definition.manifest.titleKey, summaryKey: definition.manifest.summaryKey,
                    caveatKey: definition.manifest.caveatKey, source: definition.manifest.source,
                    license: definition.manifest.license, format: definition.manifest.format
                ),
                entries: definition.entries
            )
        }
        var envelope = RulePackCatalogEnvelope(
            format: RulePackCatalogVerifier.catalogFormat,
            payload: RulePackCatalogPayload(
                catalogID: RulePackCatalogVerifier.catalogID,
                channel: RulePackCatalogVerifier.channel,
                sourceURL: RulePackCatalogVerifier.sourceURL,
                sequence: sequence,
                issuedAt: Int64(now.timeIntervalSince1970) - 100,
                expiresAt: Int64(now.timeIntervalSince1970) + 3_600,
                publisher: RulePackCatalogVerifier.publisher,
                packs: packs
            ),
            signatures: []
        )
        let signature = try key.signature(for: RulePackCatalogVerifier.canonicalPayload(for: envelope))
        envelope.signatures = [RulePackCatalogSignature(
            algorithm: RulePackCatalogVerifier.signatureAlgorithm,
            keyID: "test-key",
            value: Data(signature.derRepresentation).base64EncodedString()
        )]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
}
