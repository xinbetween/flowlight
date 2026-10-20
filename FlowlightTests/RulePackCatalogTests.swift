import CryptoKit
import XCTest
@testable import Flowlight

final class RulePackCatalogTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    func testValidCatalogVerifiesAndPreservesRawEnvelope() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try signedEnvelope(key: key)
        let data = try encoded(envelope)

        let verified = try RulePackCatalogVerifier.verify(
            data: data,
            trustedSigners: [signer(key: key)],
            now: now,
            currentAppVersion: "0.15.3"
        )

        XCTAssertEqual(verified.definitions, envelope.payload.packs.map { pack in
            RulePackDefinition(
                manifest: RulePackManifest(
                    id: pack.manifest.id, version: pack.manifest.version,
                    generatedAt: Date(timeIntervalSince1970: TimeInterval(pack.manifest.generatedAt)),
                    entryCount: Int(pack.manifest.entryCount), contentSHA256: pack.manifest.contentSHA256,
                    minimumAppVersion: pack.manifest.minimumAppVersion,
                    minimumExtensionProtocol: pack.manifest.minimumExtensionProtocol,
                    titleKey: pack.manifest.titleKey, summaryKey: pack.manifest.summaryKey,
                    caveatKey: pack.manifest.caveatKey, source: pack.manifest.source,
                    license: pack.manifest.license, format: pack.manifest.format
                ),
                entries: pack.entries
            )
        })
        XCTAssertEqual(verified.sequence, 7)
        XCTAssertEqual(verified.signerKeyID, "test-key")
        XCTAssertFalse(verified.stale)
        XCTAssertEqual(verified.rawEnvelope, data)
        XCTAssertEqual(verified.digest.count, 64)
    }

    func testCanonicalDigestIsDeterministic() throws {
        let envelope = unsignedEnvelope()
        let digest = SHA256.hash(data: try RulePackCatalogVerifier.canonicalPayload(for: envelope))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "90f12812d932c1360f88d3b9108de122cdf525eb503924ccc09a7b3648e7be74")
    }

    func testTamperInvalidatesSignature() throws {
        let key = P256.Signing.PrivateKey()
        var envelope = try signedEnvelope(key: key)
        envelope.payload.packs[0].manifest.titleKey = "tampered"
        assertError(.invalidSignature) {
            try verify(envelope, signers: [signer(key: key)])
        }
    }

    func testUnknownRevokedAndWindowedSignersAreRejected() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try signedEnvelope(key: key)
        assertError(.unknownSigner) { try verify(envelope, signers: []) }

        var trust = signer(key: key)
        trust.revoked = true
        assertError(.revokedSigner) { try verify(envelope, signers: [trust]) }

        trust = signer(key: key)
        trust.validFrom = envelope.payload.issuedAt + 1
        assertError(.signerNotYetValid) { try verify(envelope, signers: [trust]) }

        trust = signer(key: key)
        trust.validUntil = envelope.payload.issuedAt - 1
        assertError(.signerExpired) { try verify(envelope, signers: [trust]) }

        trust = signer(key: key)
        trust.validUntil = now - 1
        assertError(.signerExpired) { try verify(envelope, signers: [trust]) }
    }

    func testWrongSignerScopesAreRejected() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try signedEnvelope(key: key)
        for mutate in [
            { (value: inout RulePackCatalogTrustedSigner) in value.publisher = "Other" },
            { (value: inout RulePackCatalogTrustedSigner) in value.catalogID = "other.catalog" },
            { (value: inout RulePackCatalogTrustedSigner) in value.packIDPrefix = "community." },
        ] {
            var trust = signer(key: key)
            mutate(&trust)
            assertError(.wrongSignerScope) { try verify(envelope, signers: [trust]) }
        }
    }

    func testMalformedAlgorithmAndSignatureAreRejected() throws {
        let key = P256.Signing.PrivateKey()
        var envelope = try signedEnvelope(key: key)
        envelope.signatures[0].algorithm = "P256-SHA256"
        assertError(.unsupportedSignatureAlgorithm) { try verify(envelope, signers: [signer(key: key)]) }

        envelope = try signedEnvelope(key: key)
        envelope.signatures[0].value = "not base64"
        assertError(.malformedSignature) { try verify(envelope, signers: [signer(key: key)]) }

        envelope = try signedEnvelope(key: key)
        envelope.signatures[0].value.removeLast()
        assertError(.malformedSignature) { try verify(envelope, signers: [signer(key: key)]) }

        envelope = try signedEnvelope(key: key)
        envelope.signatures[0].value = Data([0x30, 0x00]).base64EncodedString()
        assertError(.malformedSignature) { try verify(envelope, signers: [signer(key: key)]) }
    }

    func testDuplicateTrustAndSignatureKeyIDsAreRejected() throws {
        let key = P256.Signing.PrivateKey()
        var envelope = try signedEnvelope(key: key)
        let trust = signer(key: key)
        assertError(.duplicateTrustedKeyID("test-key")) {
            try verify(envelope, signers: [trust, trust])
        }

        envelope.signatures.append(envelope.signatures[0])
        assertError(.duplicateSignatureKeyID("test-key")) {
            try verify(envelope, signers: [trust])
        }

        envelope = try signedEnvelope(key: key)
        envelope.signatures = (0...16).map { index in
            RulePackCatalogSignature(algorithm: "p256-sha256", keyID: "key-\(index)",
                                     value: envelope.signatures[0].value)
        }
        assertError(.tooManySignatures) { try verify(envelope, signers: [trust]) }
    }

    func testSignatureRotationAcceptsOneActiveTrustedSignature() throws {
        let oldKey = P256.Signing.PrivateKey()
        let newKey = P256.Signing.PrivateKey()
        var envelope = unsignedEnvelope()
        let canonical = try RulePackCatalogVerifier.canonicalPayload(for: envelope)
        envelope.signatures = [
            RulePackCatalogSignature(
                algorithm: "p256-sha256", keyID: "old-key",
                value: Data(try oldKey.signature(for: canonical).derRepresentation).base64EncodedString()
            ),
            RulePackCatalogSignature(
                algorithm: "p256-sha256", keyID: "new-key",
                value: Data(try newKey.signature(for: canonical).derRepresentation).base64EncodedString()
            ),
        ]
        var oldTrust = signer(key: oldKey)
        oldTrust.keyID = "old-key"
        oldTrust.revoked = true
        var newTrust = signer(key: newKey)
        newTrust.keyID = "new-key"

        XCTAssertEqual(try verify(envelope, signers: [oldTrust, newTrust]).signerKeyID, "new-key")
        newTrust.revoked = true
        assertError(.revokedSigner) { try verify(envelope, signers: [oldTrust, newTrust]) }
    }

    func testMalformedPublicKeyIsRejected() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try signedEnvelope(key: key)
        var trust = signer(key: key)
        trust.publicKeyPEM = "not a public key"
        assertError(.invalidPublicKey) { try verify(envelope, signers: [trust]) }
    }

    func testRollbackEquivocationAndReplayRules() throws {
        let key = P256.Signing.PrivateKey()
        let trust = signer(key: key)
        let envelope = try signedEnvelope(key: key)
        let accepted = try verify(envelope, signers: [trust])

        assertError(.rollback) {
            try RulePackCatalogVerifier.verify(
                data: try encoded(envelope), trustedSigners: [trust], now: now,
                currentAppVersion: "0.15.3", priorSequence: envelope.payload.sequence + 1,
                priorDigest: accepted.digest
            )
        }
        assertError(.equivocation) {
            try RulePackCatalogVerifier.verify(
                data: try encoded(envelope), trustedSigners: [trust], now: now,
                currentAppVersion: "0.15.3", priorSequence: envelope.payload.sequence,
                priorDigest: String(repeating: "0", count: 64)
            )
        }
        XCTAssertNoThrow(try RulePackCatalogVerifier.verify(
            data: try encoded(envelope), trustedSigners: [trust], now: now,
            currentAppVersion: "0.15.3", priorSequence: accepted.sequence,
            priorDigest: accepted.digest
        ))
    }

    func testFreshnessFutureSkewAndLastKnownGood() throws {
        let key = P256.Signing.PrivateKey()
        let trust = signer(key: key)
        var envelope = unsignedEnvelope()
        envelope.payload.issuedAt = now + RulePackCatalogVerifier.maximumFutureIssueSkew
        envelope.payload.expiresAt = envelope.payload.issuedAt + 60
        envelope = try signed(envelope, key: key)
        XCTAssertNoThrow(try verify(envelope, signers: [trust]))

        envelope.payload.issuedAt += 1
        envelope.payload.expiresAt += 1
        envelope = try signed(envelope, key: key)
        assertError(.issuedTooFarInFuture) { try verify(envelope, signers: [trust]) }

        envelope = unsignedEnvelope()
        envelope.payload.issuedAt = now - 200
        envelope.payload.expiresAt = now - 100
        envelope = try signed(envelope, key: key)
        assertError(.expired) { try verify(envelope, signers: [trust]) }

        let digest = SHA256.hash(data: try RulePackCatalogVerifier.canonicalPayload(for: envelope))
            .map { String(format: "%02x", $0) }.joined()
        let stale = try RulePackCatalogVerifier.verify(
            data: try encoded(envelope), trustedSigners: [trust], now: now,
            currentAppVersion: "0.15.3", priorSequence: envelope.payload.sequence,
            priorDigest: digest, allowExpiredLastKnownGood: true
        )
        XCTAssertTrue(stale.stale)

        assertError(.expired) {
            try RulePackCatalogVerifier.verify(
                data: try encoded(envelope), trustedSigners: [trust], now: now,
                currentAppVersion: "0.15.3", priorSequence: envelope.payload.sequence,
                priorDigest: String(repeating: "1", count: 64), allowExpiredLastKnownGood: true
            )
        }
    }

    func testEnvelopeIdentityAndTimesAreStrict() throws {
        let key = P256.Signing.PrivateKey()
        let trust = signer(key: key)
        let mutations: [(RulePackCatalogVerificationError, (inout RulePackCatalogEnvelope) -> Void)] = [
            (.unsupportedFormat, { $0.format = 2 }),
            (.wrongCatalogID, { $0.payload.catalogID = "flowlight.other" }),
            (.wrongChannel, { $0.payload.channel = "beta" }),
            (.wrongSourceURL, { $0.payload.sourceURL = "https://example.com/catalog.json" }),
            (.wrongPublisher, { $0.payload.publisher = "Other" }),
            (.invalidSequence, { $0.payload.sequence = 0 }),
            (.invalidTimestamp, { $0.payload.issuedAt = -1 }),
            (.invalidExpiry, { $0.payload.expiresAt = $0.payload.issuedAt }),
        ]
        for (expected, mutate) in mutations {
            var envelope = unsignedEnvelope()
            mutate(&envelope)
            assertError(expected) { try verify(envelope, signers: [trust]) }
        }
    }

    func testStrictDecodeRejectsUnknownAndDuplicateFields() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try signedEnvelope(key: key)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(envelope)) as? [String: Any])
        object["unexpected"] = true
        let data = try JSONSerialization.data(withJSONObject: object)
        assertError(.invalidEnvelope) {
            try RulePackCatalogVerifier.verify(data: data, trustedSigners: [signer(key: key)],
                                               now: now, currentAppVersion: "0.15.3")
        }

        let duplicate = Data(#"{"format":1,"format":1,"payload":{},"signatures":[]}"#.utf8)
        assertError(.invalidEnvelope) {
            try RulePackCatalogVerifier.verify(data: duplicate, trustedSigners: [signer(key: key)],
                                               now: now, currentAppVersion: "0.15.3")
        }
    }

    func testBoundsAndOrderingAreRejectedBeforeVerification() throws {
        let key = P256.Signing.PrivateKey()
        let trust = signer(key: key)
        let oversize = Data(repeating: 0x20, count: RulePackCatalogVerifier.maximumDataBytes + 1)
        assertError(.dataTooLarge) {
            try RulePackCatalogVerifier.verify(data: oversize, trustedSigners: [trust],
                                               now: now, currentAppVersion: "0.15.3")
        }

        var envelope = unsignedEnvelope()
        envelope.payload.packs = []
        assertError(.invalidPackCount) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }

        envelope = unsignedEnvelope()
        envelope.payload.packs = Array(repeating: envelope.payload.packs[0],
                                       count: RulePackCatalogVerifier.maximumPacks + 1)
        assertError(.tooManyPacks) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }

        envelope = unsignedEnvelope()
        envelope.payload.packs[0].manifest.titleKey = String(repeating: "a", count: RulePackCatalogVerifier.maximumStringBytes + 1)
        assertError(.stringTooLarge) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }

        for invalidVersion in ["0.15.beta", "0.15.١", "0.\(String(repeating: "9", count: 40))"] {
            envelope = unsignedEnvelope()
            envelope.payload.packs[0].manifest.minimumAppVersion = invalidVersion
            assertError(.invalidAppVersion) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }
        }

        envelope = unsignedEnvelope()
        var second = envelope.payload.packs[0]
        second.manifest.id = "official.aaa"
        envelope.payload.packs.append(second)
        assertError(.unsortedPacks) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }

        envelope = unsignedEnvelope()
        envelope.payload.packs[0].entries = Array(
            repeating: envelope.payload.packs[0].entries[0],
            count: RulePackCatalogVerifier.maximumTotalEntries + 1
        )
        assertError(.tooManyEntries) { try RulePackCatalogVerifier.canonicalPayload(for: envelope) }
    }

    func testSemanticMismatchFailsAfterValidSignature() throws {
        let key = P256.Signing.PrivateKey()
        var envelope = unsignedEnvelope()
        envelope.payload.packs[0].manifest.entryCount += 1
        envelope = try signed(envelope, key: key)
        XCTAssertThrowsError(try verify(envelope, signers: [signer(key: key)])) { error in
            XCTAssertEqual(error as? RulePackValidationError, .countMismatch("official.test"))
        }
    }

    func testProductionFixtureMatchesBundledBaseline() throws {
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "official", withExtension: "json"))
        let data = try Data(contentsOf: fixture)
        let verified = try RulePackCatalogVerifier.verify(
            data: data,
            now: 1_800_000_000,
            currentAppVersion: "0.15.3"
        )
        XCTAssertEqual(verified.signerKeyID, "flowlight-rule-packs-2026-01")
        XCTAssertEqual(verified.sequence, 1)
        XCTAssertEqual(verified.digest, "61e413b20d155f6698ee6d928b40bda33de7aa1fdb1ae590fad8869071569670")
        XCTAssertEqual(
            verified.definitions.sorted { $0.id < $1.id },
            BuiltInRulePacks.all.sorted { $0.id < $1.id }
        )
    }

    private func verify(_ envelope: RulePackCatalogEnvelope,
                        signers: [RulePackCatalogTrustedSigner]) throws -> VerifiedRulePackCatalog {
        try RulePackCatalogVerifier.verify(
            data: encoded(envelope), trustedSigners: signers,
            now: now, currentAppVersion: "0.15.3"
        )
    }

    private func signer(key: P256.Signing.PrivateKey) -> RulePackCatalogTrustedSigner {
        RulePackCatalogTrustedSigner(
            keyID: "test-key", publisher: "Flowlight", catalogID: "flowlight.official",
            packIDPrefix: "official.", publicKeyPEM: key.publicKey.pemRepresentation,
            validFrom: now - 10_000, validUntil: now + 10_000, revoked: false
        )
    }

    private func signedEnvelope(key: P256.Signing.PrivateKey) throws -> RulePackCatalogEnvelope {
        try signed(unsignedEnvelope(), key: key)
    }

    private func signed(_ value: RulePackCatalogEnvelope,
                        key: P256.Signing.PrivateKey) throws -> RulePackCatalogEnvelope {
        var envelope = value
        envelope.signatures = []
        let signature = try key.signature(for: RulePackCatalogVerifier.canonicalPayload(for: envelope))
        envelope.signatures = [RulePackCatalogSignature(
            algorithm: "p256-sha256", keyID: "test-key",
            value: Data(signature.derRepresentation).base64EncodedString()
        )]
        return envelope
    }

    private func unsignedEnvelope() -> RulePackCatalogEnvelope {
        let entries = [
            RulePackEntry(id: 1, host: "ads.example", match: .suffix, category: .advertising),
            RulePackEntry(id: 2, host: "exact.example", match: .exact, category: .tracking),
        ]
        let manifest = RulePackCatalogWireManifest(
            id: "official.test", version: "1.2.3", generatedAt: 1_799_999_000,
            entryCount: UInt32(entries.count), contentSHA256: RulePackValidator.digest(entries),
            minimumAppVersion: "0.15.0", minimumExtensionProtocol: 1,
            titleKey: "pack.test.title", summaryKey: "pack.test.summary", caveatKey: "pack.test.caveat",
            source: "https://example.com/source", license: "MIT", format: 1
        )
        return RulePackCatalogEnvelope(
            format: 1,
            payload: RulePackCatalogPayload(
                catalogID: "flowlight.official", channel: "official",
                sourceURL: "https://flowlight.xinbetween.com/packs/v1/official.json",
                sequence: 7, issuedAt: now - 100, expiresAt: now + 3_600,
                publisher: "Flowlight", packs: [RulePackCatalogWirePack(manifest: manifest, entries: entries)]
            ),
            signatures: []
        )
    }

    private func encoded(_ envelope: RulePackCatalogEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private func assertError<T>(_ expected: RulePackCatalogVerificationError,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ expression: () throws -> T) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? RulePackCatalogVerificationError, expected, file: file, line: line)
        }
    }
}
