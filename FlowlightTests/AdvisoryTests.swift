import CryptoKit
import XCTest
@testable import Flowlight

final class AdvisoryTests: XCTestCase {
    private let range = AdvisoryVersionRange(startIncluding: "1.2.0", endExcluding: "2.0.0")

    func testVersionRangeUsesNumericComponentsAndInclusiveExclusiveBounds() {
        XCTAssertTrue(VersionRangeMatcher.matches(version: "1.2", range: range))
        XCTAssertTrue(VersionRangeMatcher.matches(version: "1.9.99", range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "1.1.99", range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "2.0.0", range: range))
        XCTAssertTrue(VersionRangeMatcher.matches(version: "1.2.0.0", range: range))
    }

    func testUnknownVersionSyntaxDoesNotMatch() {
        XCTAssertFalse(VersionRangeMatcher.matches(version: nil, range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "", range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "1.2-beta", range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "v1.2.3", range: range))
        XCTAssertFalse(VersionRangeMatcher.matches(version: "1.5", range: AdvisoryVersionRange(startIncluding: "not-a-version")))
    }

    func testAdvisoryRequiresExplicitBundleIdentityAndVersionEvidence() {
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:sample:*:*:*:*:*:macos:*:*",
                                      bundleIDs: ["com.example.Sample"],
                                      versionStartIncluding: "1.0",
                                      versionEndExcluding: "2.0")
        let advisory = SecurityAdvisory(id: "CVE-2099-0001",
                                        configurations: [AdvisoryConfiguration(nodes: [AdvisoryNode(matches: [match])])])

        XCTAssertTrue(advisory.matches(AdvisoryAppVersion(bundleID: "com.example.Sample",
                                                          marketingVersion: "1.4", buildVersion: "14")))
        XCTAssertFalse(advisory.matches(AdvisoryAppVersion(bundleID: "com.other.Sample", marketingVersion: "1.4")))
        XCTAssertFalse(advisory.matches(AdvisoryAppVersion(bundleID: "com.example.Sample")))
        XCTAssertFalse(advisory.matches(AdvisoryAppVersion(bundleID: "com.example.Sample", marketingVersion: "2.0")))
        let artifact = AdvisoryArtifact(kind: .application, identifier: "com.example.Sample", name: "Sample",
                                        path: "/Applications/Sample.app", version: "1.4", versionScheme: .numeric,
                                        identityEvidence: .applicationBundle, versionEvidence: .bundleInfoDictionary,
                                        source: "Application bundle", iconPath: "/Applications/Sample.app")
        XCTAssertTrue(advisory.matches(artifact), "legacy bundleIDs must remain usable by the generic inventory")
    }

    func testExactCPEVersionIsAlsoAConstraintWhenNoRangeIsPresent() {
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:sample:1.5:*:*:*:*:macos:*:*",
                                      bundleIDs: ["com.example.Sample"])

        XCTAssertTrue(VersionRangeMatcher.matches(AdvisoryAppVersion(bundleID: "com.example.Sample", marketingVersion: "1.5"), match: match))
        XCTAssertFalse(VersionRangeMatcher.matches(AdvisoryAppVersion(bundleID: "com.example.Sample", marketingVersion: "1.6"), match: match))
    }

    func testKnownMarketingVersionIsPreferredToBuildVersion() {
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:sample:*:*:*:*:*:macos:*:*",
                                      bundleIDs: ["com.example.Sample"], versionEndExcluding: "2.0")
        let app = AdvisoryAppVersion(bundleID: "com.example.Sample", marketingVersion: "2.1", buildVersion: "1")
        XCTAssertFalse(VersionRangeMatcher.matches(app, match: match), "a coincidentally low build number must not override a known marketing version")
    }

    func testNonVulnerableCPEMatchesNeverProduceFindings() {
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:sample:*:*:*:*:*:macos:*:*",
                                      vulnerable: false, bundleIDs: ["com.example.Sample"], versionEndExcluding: "2.0")
        let advisory = SecurityAdvisory(id: "CVE-2099-0002",
                                        configurations: [AdvisoryConfiguration(nodes: [AdvisoryNode(matches: [match])])])
        XCTAssertFalse(advisory.matches(AdvisoryAppVersion(bundleID: "com.example.Sample", marketingVersion: "1.5")))
    }

    func testTypedNodePackageMatchingUsesStrictSemverAndExplicitIdentity() {
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:npm:package:*:*:*:*:*:*:*:*",
                                      targets: [AdvisoryTarget(kind: .nodePackage, identifier: "@scope/package")],
                                      versionStartIncluding: "1.2.0", versionEndExcluding: "2.0.0")
        let advisory = SecurityAdvisory(id: "CVE-2099-0003",
                                        configurations: [AdvisoryConfiguration(nodes: [AdvisoryNode(matches: [match])])])
        let package = AdvisoryArtifact(kind: .nodePackage, identifier: "@scope/package", name: "package",
                                       path: "/tmp/node_modules/@scope/package", version: "1.5.0+local",
                                       versionScheme: .semver, identityEvidence: .packageManifest,
                                       versionEvidence: .packageJSON, source: "package.json", iconPath: nil)
        let prerelease = AdvisoryArtifact(kind: .nodePackage, identifier: "@scope/package", name: "package",
                                          path: package.path, version: "1.2.0-beta.1", versionScheme: .semver,
                                          identityEvidence: .packageManifest, versionEvidence: .packageJSON,
                                          source: "package.json", iconPath: nil)
        let wrongIdentity = AdvisoryArtifact(kind: .nodePackage, identifier: "package", name: "package",
                                             path: package.path, version: "1.5.0", versionScheme: .semver,
                                             identityEvidence: .packageManifest, versionEvidence: .packageJSON,
                                             source: "package.json", iconPath: nil)

        XCTAssertTrue(advisory.matches(package))
        XCTAssertFalse(advisory.matches(prerelease), "a prerelease must not be treated as a stable affected version")
        XCTAssertFalse(advisory.matches(wrongIdentity), "same text in another identity is not a match")
    }

    func testGenericPackageMatchingRequiresTheSamePackageManager() {
        let match = AdvisoryCPEMatch(
            criteria: "cpe:2.3:a:example:shared:*:*:*:*:*:*:*:*",
            targets: [AdvisoryTarget(kind: .package, identifier: "shared", packageManager: .npm)],
            versionStartIncluding: "1.0.0",
            versionEndExcluding: "2.0.0"
        )
        let advisory = SecurityAdvisory(
            id: "CVE-2099-0004",
            configurations: [AdvisoryConfiguration(nodes: [AdvisoryNode(matches: [match])])]
        )
        let npm = AdvisoryArtifact(kind: .package, identifier: "shared", name: "shared", path: "/tmp/npm/shared",
                                   version: "1.5.0", versionScheme: .semver, identityEvidence: .packageManifest,
                                   versionEvidence: .packageMetadata, source: "npm", iconPath: nil,
                                   packageManager: .npm)
        let cargo = AdvisoryArtifact(kind: .package, identifier: "shared", name: "shared", path: "/tmp/cargo/shared",
                                     version: "1.5.0", versionScheme: .semver, identityEvidence: .packageManifest,
                                     versionEvidence: .packageMetadata, source: "Cargo", iconPath: nil,
                                     packageManager: .cargo)

        XCTAssertTrue(advisory.matches(npm))
        XCTAssertFalse(advisory.matches(cargo))
    }

    func testBundledAdvisoryCatalogBootstrapsWithProductionTrust() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Flowlight/Resources/Advisories/advisories.json")
        let data = try Data(contentsOf: url)

        XCTAssertNoThrow(try AdvisoryCatalogVerifier.validateStrictJSONSyntax(data))
        XCTAssertNoThrow(try JSONDecoder().decode(AdvisoryCatalogEnvelope.self, from: data))
        XCTAssertNoThrow(try AdvisoryCatalogVerifier.verify(data: data, now: 1_795_000_000))
    }

    func testNonemptySignedCatalogUsesWireSchemaKeys() throws {
        let key = P256.Signing.PrivateKey()
        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:tool:*:*:*:*:*:*:*:*",
                                      targets: [AdvisoryTarget(kind: .executable, identifier: "curl")],
                                      versionStartIncluding: "1.0.0")
        let advisory = AdvisoryCatalogWireAdvisory(
            id: "CVE-2099-0100",
            summary: "Test advisory",
            configurations: [AdvisoryConfiguration(nodes: [AdvisoryNode(matches: [match])])]
        )
        let payload = AdvisoryCatalogPayload(
            catalogID: AdvisoryCatalogVerifier.catalogID,
            channel: AdvisoryCatalogVerifier.channel,
            sourceURL: AdvisoryCatalogVerifier.sourceURL,
            sequence: 1,
            issuedAt: 1_799_000_000,
            expiresAt: 1_900_000_000,
            publisher: AdvisoryCatalogVerifier.publisher,
            advisories: [advisory]
        )
        var envelope = AdvisoryCatalogEnvelope(format: AdvisoryCatalogVerifier.catalogFormat, payload: payload, signatures: [])
        let signature = try key.signature(for: AdvisoryCatalogVerifier.canonicalPayload(for: envelope))
        envelope.signatures = [AdvisoryCatalogSignature(
            algorithm: AdvisoryCatalogVerifier.signatureAlgorithm,
            keyID: "test-key",
            value: signature.derRepresentation.base64EncodedString()
        )]
        let signer = AdvisoryCatalogTrustedSigner(
            keyID: "test-key", publisher: AdvisoryCatalogVerifier.publisher,
            catalogID: AdvisoryCatalogVerifier.catalogID, advisoryIDPrefix: "CVE-",
            publicKeyPEM: key.publicKey.pemRepresentation,
            validFrom: 1_790_000_000, validUntil: 1_900_000_000
        )

        XCTAssertNoThrow(try AdvisoryCatalogVerifier.verify(
            data: JSONEncoder().encode(envelope), trustedSigners: [signer], now: 1_800_000_000
        ))
    }

    func testTypedTargetCatalogRoundTripsAlongsideLegacyBundleIDs() throws {
        let typed = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:tool:*:*:*:*:*:*:*:*",
                                      targets: [AdvisoryTarget(kind: .executable, identifier: "curl")])
        let legacy = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:app:*:*:*:*:*:*:*:*",
                                      bundleIDs: ["com.example.App"])
        let data = try JSONEncoder().encode([typed, legacy])
        let decoded = try JSONDecoder().decode([AdvisoryCPEMatch].self, from: data)
        XCTAssertEqual(decoded, [typed, legacy])
    }

    func testNewDatabaseDefaultsAutomaticRefreshOff() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-default-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        let state = try db.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID)
        XCTAssertFalse(state.update.automaticRefresh)
    }

    func testCatalogAcceptancePreservesAutomaticRefreshPreference() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-preference-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        let catalog = VerifiedAdvisoryCatalog(advisories: [], sequence: 1, digest: "digest-1", signerKeyID: "test-key", stale: false, rawEnvelope: Data([1]))
        let checked = Date(timeIntervalSince1970: 1_000)
        let next = checked.addingTimeInterval(3600)

        try db.setAdvisoryCatalogAutomaticRefresh(catalogID: AdvisoryCatalogVerifier.catalogID, enabled: false)
        _ = try db.acceptVerifiedAdvisoryCatalog(catalog, checkedAt: checked, nextEligibleAt: next)
        XCTAssertFalse(try db.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID).update.automaticRefresh)

        try db.setAdvisoryCatalogAutomaticRefresh(catalogID: AdvisoryCatalogVerifier.catalogID, enabled: true)
        try db.recordAdvisoryCatalogFailure(catalogID: AdvisoryCatalogVerifier.catalogID, attemptedAt: checked,
                                            failureCount: 1, nextEligibleAt: next, status: "failed", error: "offline")
        XCTAssertTrue(try db.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID).update.automaticRefresh)
    }

    func testStrictJSONRejectsEscapedDuplicateKeysAtEveryObjectDepth() {
        let root = Data(#"{"format":1,"format":1}"#.utf8)
        let nested = Data(#"{"payload":{"format":1,"format":1}}"#.utf8)
        XCTAssertThrowsError(try AdvisoryCatalogVerifier.validateStrictJSONSyntax(root))
        XCTAssertThrowsError(try AdvisoryCatalogVerifier.validateStrictJSONSyntax(nested))
    }

    func testClearingCatalogRemovesReceiptCacheAndUpdateState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-clear-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        let catalog = VerifiedAdvisoryCatalog(advisories: [], sequence: 1, digest: "digest-clear", signerKeyID: "test-key", stale: false, rawEnvelope: Data([1]))
        _ = try db.acceptVerifiedAdvisoryCatalog(catalog, checkedAt: Date(timeIntervalSince1970: 1_000), nextEligibleAt: Date(timeIntervalSince1970: 2_000))
        try db.clearAdvisoryCatalog()

        let state = try db.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID)
        XCTAssertNil(state.receipt)
        XCTAssertNil(state.cache)
        XCTAssertFalse(state.update.automaticRefresh)
        XCTAssertTrue(try db.loadAdvisories().isEmpty)
    }
}
