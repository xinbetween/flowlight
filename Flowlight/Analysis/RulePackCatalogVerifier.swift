import CryptoKit
import Foundation

struct RulePackCatalogTrustedSigner: Equatable, Sendable {
    var keyID: String
    var publisher: String
    var catalogID: String
    var packIDPrefix: String
    var publicKeyPEM: String
    var validFrom: Int64
    var validUntil: Int64
    var revoked: Bool
}

struct RulePackCatalogSignature: Codable, Equatable, Sendable {
    var algorithm: String
    var keyID: String
    var value: String
}

struct RulePackCatalogWireManifest: Codable, Equatable, Sendable {
    var id: String
    var version: String
    var generatedAt: Int64
    var entryCount: UInt32
    var contentSHA256: String
    var minimumAppVersion: String
    var minimumExtensionProtocol: UInt16
    var titleKey: String
    var summaryKey: String
    var caveatKey: String
    var source: String
    var license: String
    var format: UInt16

    fileprivate func definition(entries: [RulePackEntry]) -> RulePackDefinition {
        RulePackDefinition(
            manifest: RulePackManifest(
                id: id,
                version: version,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(generatedAt)),
                entryCount: Int(entryCount),
                contentSHA256: contentSHA256,
                minimumAppVersion: minimumAppVersion,
                minimumExtensionProtocol: minimumExtensionProtocol,
                titleKey: titleKey,
                summaryKey: summaryKey,
                caveatKey: caveatKey,
                source: source,
                license: license,
                format: format
            ),
            entries: entries
        )
    }
}

struct RulePackCatalogWirePack: Codable, Equatable, Sendable {
    var manifest: RulePackCatalogWireManifest
    var entries: [RulePackEntry]

    fileprivate var definition: RulePackDefinition { manifest.definition(entries: entries) }
}

struct RulePackCatalogPayload: Codable, Equatable, Sendable {
    var catalogID: String
    var channel: String
    var sourceURL: String
    var sequence: Int64
    var issuedAt: Int64
    var expiresAt: Int64
    var publisher: String
    var packs: [RulePackCatalogWirePack]
}

struct RulePackCatalogEnvelope: Codable, Equatable, Sendable {
    var format: UInt16
    var payload: RulePackCatalogPayload
    var signatures: [RulePackCatalogSignature]
}

struct VerifiedRulePackCatalog: Equatable, Sendable {
    var definitions: [RulePackDefinition]
    var sequence: Int64
    var issuedAt: Int64 = 0
    var digest: String
    var signerKeyID: String
    var stale: Bool
    /// Exact input bytes for last-known-good storage and re-verification.
    var rawEnvelope: Data
}

enum RulePackCatalogVerificationError: Error, Equatable {
    case dataTooLarge
    case invalidEnvelope
    case unsupportedFormat
    case wrongCatalogID
    case wrongChannel
    case wrongSourceURL
    case wrongPublisher
    case invalidSequence
    case invalidTimestamp
    case issuedTooFarInFuture
    case invalidExpiry
    case expired
    case invalidPackCount
    case tooManyPacks
    case tooManyEntries
    case stringTooLarge
    case invalidAppVersion
    case unsortedPacks
    case duplicateTrustedKeyID(String)
    case duplicateSignatureKeyID(String)
    case tooManySignatures
    case unsupportedSignatureAlgorithm
    case malformedSignature
    case unknownSigner
    case revokedSigner
    case signerNotYetValid
    case signerExpired
    case wrongSignerScope
    case invalidPublicKey
    case invalidSignature
    case invalidPriorReceipt
    case rollback
    case equivocation
}

enum RulePackCatalogVerifier {
    static let catalogFormat: UInt16 = 1
    static let catalogID = "flowlight.official"
    static let channel = "official"
    static let sourceURL = "https://flowlight.xinbetween.com/packs/v1/official.json"
    static let publisher = "Flowlight"
    static let signatureAlgorithm = "p256-sha256"
    static let signatureDomain = "flowlight-rule-pack-catalog-signature-v1"

    static let maximumDataBytes = 8 * 1024 * 1024
    static let maximumPacks = 16
    static let maximumTotalEntries = 250_000
    static let maximumStringBytes = 16 * 1024
    static let maximumJSONNestingDepth = 64
    static let maximumFutureIssueSkew: Int64 = 5 * 60

    // Public material only. Embedding it keeps trust independent from resource-bundle selection in test hosts.
    private static let productionPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdUePgJD0obTUDpM5Pa/4MzikIB0p
    hr50v5rS+wl+ofiaCFXHXFN9Sd70U4k3YYCEPuave7l7YRk3zRJCJxP9Cg==
    -----END PUBLIC KEY-----
    """

    static let productionTrustedSigners = [
        RulePackCatalogTrustedSigner(
            keyID: "flowlight-rule-packs-2026-01",
            publisher: publisher,
            catalogID: catalogID,
            packIDPrefix: "official.",
            publicKeyPEM: productionPublicKeyPEM,
            validFrom: 1_767_225_600, // 2026-01-01T00:00:00Z
            validUntil: 1_893_456_000, // 2030-01-01T00:00:00Z
            revoked: false
        ),
    ]

    static func verify(
        data: Data,
        trustedSigners: [RulePackCatalogTrustedSigner] = productionTrustedSigners,
        now: Int64,
        currentAppVersion: String,
        priorSequence: Int64? = nil,
        priorDigest: String? = nil,
        allowExpiredLastKnownGood: Bool = false
    ) throws -> VerifiedRulePackCatalog {
        guard data.count <= maximumDataBytes else { throw RulePackCatalogVerificationError.dataTooLarge }
        guard numericVersion(currentAppVersion) != nil else {
            throw RulePackCatalogVerificationError.invalidAppVersion
        }
        try validateUniqueTrustedKeyIDs(trustedSigners)
        guard (priorSequence == nil) == (priorDigest == nil) else {
            throw RulePackCatalogVerificationError.invalidPriorReceipt
        }

        let envelope = try strictDecode(data)
        try validateEnvelope(envelope, now: now)
        let canonical = try canonicalPayload(format: envelope.format, payload: envelope.payload)
        let digest = sha256Hex(canonical)

        let stale = now > envelope.payload.expiresAt
        if stale {
            guard allowExpiredLastKnownGood,
                  priorSequence == envelope.payload.sequence,
                  priorDigest == digest else {
                throw RulePackCatalogVerificationError.expired
            }
        }

        let signerKeyID = try verifySignatures(
            envelope.signatures,
            payload: envelope.payload,
            canonical: canonical,
            trustedSigners: trustedSigners,
            now: now
        )
        let definitions = envelope.payload.packs.map(\.definition)
        try RulePackValidator.validate(
            definitions,
            extensionProtocol: RulePackSnapshot.protocolVersion,
            currentAppVersion: currentAppVersion
        )
        try validateReceipt(sequence: envelope.payload.sequence, digest: digest,
                            priorSequence: priorSequence, priorDigest: priorDigest)

        return VerifiedRulePackCatalog(
            definitions: definitions,
            sequence: envelope.payload.sequence,
            issuedAt: envelope.payload.issuedAt,
            digest: digest,
            signerKeyID: signerKeyID,
            stale: stale,
            rawEnvelope: data
        )
    }

    static func canonicalPayload(for envelope: RulePackCatalogEnvelope) throws -> Data {
        try canonicalPayload(format: envelope.format, payload: envelope.payload)
    }

    static func canonicalPayload(format: UInt16, payload: RulePackCatalogPayload) throws -> Data {
        guard format == catalogFormat else { throw RulePackCatalogVerificationError.unsupportedFormat }
        guard payload.sequence > 0 else { throw RulePackCatalogVerificationError.invalidSequence }
        guard payload.issuedAt >= 0, payload.expiresAt >= 0 else {
            throw RulePackCatalogVerificationError.invalidTimestamp
        }
        guard !payload.packs.isEmpty else { throw RulePackCatalogVerificationError.invalidPackCount }
        guard payload.packs.count <= maximumPacks else { throw RulePackCatalogVerificationError.tooManyPacks }

        var previousPackID: String?
        var totalEntries = 0
        for pack in payload.packs {
            if let previousPackID, previousPackID >= pack.manifest.id {
                throw RulePackCatalogVerificationError.unsortedPacks
            }
            previousPackID = pack.manifest.id
            let (nextTotal, overflow) = totalEntries.addingReportingOverflow(pack.entries.count)
            guard !overflow, nextTotal <= maximumTotalEntries else {
                throw RulePackCatalogVerificationError.tooManyEntries
            }
            totalEntries = nextTotal
        }

        var bytes = CanonicalBytes(limit: maximumDataBytes)
        try bytes.append(signatureDomain)
        try bytes.append(format)
        try bytes.append(payload.catalogID)
        try bytes.append(payload.channel)
        try bytes.append(payload.sourceURL)
        try bytes.append(UInt64(payload.sequence))
        try bytes.append(UInt64(payload.issuedAt))
        try bytes.append(UInt64(payload.expiresAt))
        try bytes.append(payload.publisher)
        try bytes.append(UInt32(payload.packs.count))

        for pack in payload.packs {
            let manifest = pack.manifest
            guard manifest.generatedAt >= 0 else { throw RulePackCatalogVerificationError.invalidTimestamp }
            guard numericVersion(manifest.minimumAppVersion) != nil else {
                throw RulePackCatalogVerificationError.invalidAppVersion
            }
            try bytes.append(manifest.id)
            try bytes.append(manifest.version)
            try bytes.append(UInt64(manifest.generatedAt))
            try bytes.append(manifest.entryCount)
            try bytes.append(manifest.contentSHA256)
            try bytes.append(manifest.minimumAppVersion)
            try bytes.append(manifest.minimumExtensionProtocol)
            try bytes.append(manifest.titleKey)
            try bytes.append(manifest.summaryKey)
            try bytes.append(manifest.caveatKey)
            try bytes.append(manifest.source)
            try bytes.append(manifest.license)
            try bytes.append(manifest.format)
            try bytes.append(UInt32(pack.entries.count))
            for entry in pack.entries {
                try bytes.append(entry.id)
                try bytes.append(entry.host)
                try bytes.append(entry.match.rawValue)
                try bytes.append(entry.category.rawValue)
            }
        }
        return bytes.data
    }

    private static func validateUniqueTrustedKeyIDs(_ signers: [RulePackCatalogTrustedSigner]) throws {
        var keyIDs = Set<String>()
        for signer in signers {
            guard keyIDs.insert(signer.keyID).inserted else {
                throw RulePackCatalogVerificationError.duplicateTrustedKeyID(signer.keyID)
            }
        }
    }

    private static func validateEnvelope(_ envelope: RulePackCatalogEnvelope, now: Int64) throws {
        guard envelope.format == catalogFormat else { throw RulePackCatalogVerificationError.unsupportedFormat }
        guard envelope.payload.catalogID == catalogID else { throw RulePackCatalogVerificationError.wrongCatalogID }
        guard envelope.payload.channel == channel else { throw RulePackCatalogVerificationError.wrongChannel }
        guard envelope.payload.sourceURL == sourceURL else { throw RulePackCatalogVerificationError.wrongSourceURL }
        guard envelope.payload.publisher == publisher else { throw RulePackCatalogVerificationError.wrongPublisher }
        guard envelope.payload.sequence > 0 else { throw RulePackCatalogVerificationError.invalidSequence }
        guard now >= 0, envelope.payload.issuedAt >= 0, envelope.payload.expiresAt >= 0 else {
            throw RulePackCatalogVerificationError.invalidTimestamp
        }
        if envelope.payload.issuedAt > now {
            let (delta, overflow) = envelope.payload.issuedAt.subtractingReportingOverflow(now)
            guard !overflow, delta <= maximumFutureIssueSkew else {
                throw RulePackCatalogVerificationError.issuedTooFarInFuture
            }
        }
        guard envelope.payload.expiresAt > envelope.payload.issuedAt else {
            throw RulePackCatalogVerificationError.invalidExpiry
        }
        guard !envelope.signatures.isEmpty else { throw RulePackCatalogVerificationError.unknownSigner }
        guard envelope.signatures.count <= 16 else { throw RulePackCatalogVerificationError.tooManySignatures }

        var signatureKeyIDs = Set<String>()
        for signature in envelope.signatures {
            try validateBoundedString(signature.algorithm)
            try validateBoundedString(signature.keyID)
            try validateBoundedString(signature.value)
            guard signature.algorithm == signatureAlgorithm else {
                throw RulePackCatalogVerificationError.unsupportedSignatureAlgorithm
            }
            guard signatureKeyIDs.insert(signature.keyID).inserted else {
                throw RulePackCatalogVerificationError.duplicateSignatureKeyID(signature.keyID)
            }
            guard let bytes = Data(base64Encoded: signature.value),
                  bytes.base64EncodedString() == signature.value,
                  (try? P256.Signing.ECDSASignature(derRepresentation: bytes)) != nil else {
                throw RulePackCatalogVerificationError.malformedSignature
            }
        }
    }

    private static func validateReceipt(sequence: Int64, digest: String,
                                        priorSequence: Int64?, priorDigest: String?) throws {
        guard let priorSequence, let priorDigest else { return }
        if sequence < priorSequence { throw RulePackCatalogVerificationError.rollback }
        if sequence == priorSequence, digest != priorDigest { throw RulePackCatalogVerificationError.equivocation }
    }

    private static func verifySignatures(
        _ signatures: [RulePackCatalogSignature],
        payload: RulePackCatalogPayload,
        canonical: Data,
        trustedSigners: [RulePackCatalogTrustedSigner],
        now: Int64
    ) throws -> String {
        var sawKnown = false
        var sawRevoked = false
        var sawNotYetValid = false
        var sawExpired = false
        var sawWrongScope = false
        var sawInvalidKey = false

        for signature in signatures {
            guard let signer = trustedSigners.first(where: { $0.keyID == signature.keyID }) else { continue }
            sawKnown = true
            guard !signer.revoked else { sawRevoked = true; continue }
            guard now >= signer.validFrom, payload.issuedAt >= signer.validFrom else {
                sawNotYetValid = true
                continue
            }
            guard now <= signer.validUntil, payload.issuedAt <= signer.validUntil else {
                sawExpired = true
                continue
            }
            guard signer.publisher == payload.publisher,
                  signer.catalogID == payload.catalogID,
                  !signer.packIDPrefix.isEmpty,
                  payload.packs.allSatisfy({ $0.manifest.id.hasPrefix(signer.packIDPrefix) }) else {
                sawWrongScope = true
                continue
            }
            guard let publicKey = try? P256.Signing.PublicKey(pemRepresentation: signer.publicKeyPEM) else {
                sawInvalidKey = true
                continue
            }
            guard let signatureData = Data(base64Encoded: signature.value),
                  let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
                continue
            }
            if publicKey.isValidSignature(parsed, for: canonical) { return signer.keyID }
        }

        if !sawKnown { throw RulePackCatalogVerificationError.unknownSigner }
        if sawRevoked { throw RulePackCatalogVerificationError.revokedSigner }
        if sawNotYetValid { throw RulePackCatalogVerificationError.signerNotYetValid }
        if sawExpired { throw RulePackCatalogVerificationError.signerExpired }
        if sawWrongScope { throw RulePackCatalogVerificationError.wrongSignerScope }
        if sawInvalidKey { throw RulePackCatalogVerificationError.invalidPublicKey }
        throw RulePackCatalogVerificationError.invalidSignature
    }

    static func validateStrictJSONSyntax(_ data: Data) throws {
        var scanner = StrictJSONScanner(data: data)
        try scanner.validate()
    }

    private static func strictDecode(_ data: Data) throws -> RulePackCatalogEnvelope {
        do {
            try validateStrictJSONSyntax(data)
            let object = try JSONSerialization.jsonObject(with: data)
            try StrictSchema.validateEnvelope(object)
            return try JSONDecoder().decode(RulePackCatalogEnvelope.self, from: data)
        } catch let error as RulePackCatalogVerificationError {
            throw error
        } catch {
            throw RulePackCatalogVerificationError.invalidEnvelope
        }
    }

    private static func validateBoundedString(_ string: String) throws {
        guard string.lengthOfBytes(using: .utf8) <= maximumStringBytes else {
            throw RulePackCatalogVerificationError.stringTooLarge
        }
    }

    private static func numericVersion(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var result: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(component), number <= Int64.max else { return nil }
            result.append(number)
        }
        return result
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalBytes {
        var data = Data()
        let limit: Int

        mutating func append<T: FixedWidthInteger>(_ value: T) throws {
            var bigEndian = value.bigEndian
            try withUnsafeBytes(of: &bigEndian) { try append(Data($0)) }
        }

        mutating func append(_ string: String) throws {
            let utf8 = Data(string.utf8)
            guard utf8.count <= RulePackCatalogVerifier.maximumStringBytes else {
                throw RulePackCatalogVerificationError.stringTooLarge
            }
            try append(UInt32(utf8.count))
            try append(utf8)
        }

        private mutating func append(_ newData: Data) throws {
            let (size, overflow) = data.count.addingReportingOverflow(newData.count)
            guard !overflow, size <= limit else { throw RulePackCatalogVerificationError.dataTooLarge }
            data.append(newData)
        }
    }

    private struct StrictJSONScanner {
        private let bytes: [UInt8]
        private var index = 0

        init(data: Data) { bytes = Array(data) }

        mutating func validate() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw RulePackCatalogVerificationError.invalidEnvelope }
        }

        private mutating func parseValue(depth: Int) throws {
            guard depth <= RulePackCatalogVerifier.maximumJSONNestingDepth,
                  index < bytes.count else { throw RulePackCatalogVerificationError.invalidEnvelope }
            switch bytes[index] {
            case 0x7B: try parseObject(depth: depth + 1)
            case 0x5B: try parseArray(depth: depth + 1)
            case 0x22: _ = try parseString()
            case 0x74: try consumeLiteral("true")
            case 0x66: try consumeLiteral("false")
            case 0x6E: try consumeLiteral("null")
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw RulePackCatalogVerificationError.invalidEnvelope
            }
        }

        private mutating func parseObject(depth: Int) throws {
            guard depth <= RulePackCatalogVerifier.maximumJSONNestingDepth else {
                throw RulePackCatalogVerificationError.invalidEnvelope
            }
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }
            var keys = Set<String>()
            while true {
                let key = try parseString()
                guard keys.insert(key).inserted else { throw RulePackCatalogVerificationError.invalidEnvelope }
                skipWhitespace()
                guard consume(0x3A) else { throw RulePackCatalogVerificationError.invalidEnvelope }
                skipWhitespace()
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw RulePackCatalogVerificationError.invalidEnvelope }
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            guard depth <= RulePackCatalogVerifier.maximumJSONNestingDepth else {
                throw RulePackCatalogVerificationError.invalidEnvelope
            }
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw RulePackCatalogVerificationError.invalidEnvelope }
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            guard consume(0x22) else { throw RulePackCatalogVerificationError.invalidEnvelope }
            let start = index
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                    if byte == 0x75 {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy({ isHex($0) }) else {
                            throw RulePackCatalogVerificationError.invalidEnvelope
                        }
                        index += 5
                    } else {
                        guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) else {
                            throw RulePackCatalogVerificationError.invalidEnvelope
                        }
                        index += 1
                    }
                    continue
                }
                if byte == 0x5C { escaped = true; index += 1; continue }
                if byte == 0x22 {
                    let end = index
                    index += 1
                    let quoted = Data(bytes[(start - 1)...end])
                    guard let decoded = try? JSONDecoder().decode(String.self, from: quoted) else {
                        throw RulePackCatalogVerificationError.invalidEnvelope
                    }
                    return decoded
                }
                guard byte >= 0x20 else { throw RulePackCatalogVerificationError.invalidEnvelope }
                index += 1
            }
            throw RulePackCatalogVerificationError.invalidEnvelope
        }

        private mutating func parseNumber() throws {
            let start = index
            if consume(0x2D), index == bytes.count { throw RulePackCatalogVerificationError.invalidEnvelope }
            if consume(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw RulePackCatalogVerificationError.invalidEnvelope
                }
            } else {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                    throw RulePackCatalogVerificationError.invalidEnvelope
                }
                repeat { index += 1 } while index < bytes.count && (0x30...0x39).contains(bytes[index])
            }
            if index < bytes.count, bytes[index] == 0x2E { try consumeDigits(afterMarker: true) }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                try consumeDigits(afterMarker: false)
            }
            guard index > start else { throw RulePackCatalogVerificationError.invalidEnvelope }
        }

        private mutating func consumeDigits(afterMarker: Bool) throws {
            if afterMarker { index += 1 }
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > start else { throw RulePackCatalogVerificationError.invalidEnvelope }
        }

        private mutating func consumeLiteral(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw RulePackCatalogVerificationError.invalidEnvelope
            }
            index += expected.count
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    private enum StrictSchema {
        private static let envelopeKeys: Set<String> = ["format", "payload", "signatures"]
        private static let payloadKeys: Set<String> = [
            "catalogID", "channel", "sourceURL", "sequence", "issuedAt", "expiresAt", "publisher", "packs",
        ]
        private static let signatureKeys: Set<String> = ["algorithm", "keyID", "value"]
        private static let packKeys: Set<String> = ["manifest", "entries"]
        private static let manifestKeys: Set<String> = [
            "id", "version", "generatedAt", "entryCount", "contentSHA256", "minimumAppVersion",
            "minimumExtensionProtocol", "titleKey", "summaryKey", "caveatKey", "source", "license", "format",
        ]
        private static let entryKeys: Set<String> = ["id", "host", "match", "category"]

        static func validateEnvelope(_ object: Any) throws {
            let envelope = try dictionary(object, keys: envelopeKeys)
            let payload = try dictionary(envelope["payload"], keys: payloadKeys)
            for signature in try array(envelope["signatures"]) {
                _ = try dictionary(signature, keys: signatureKeys)
            }
            for packValue in try array(payload["packs"]) {
                let pack = try dictionary(packValue, keys: packKeys)
                _ = try dictionary(pack["manifest"], keys: manifestKeys)
                for entry in try array(pack["entries"]) {
                    _ = try dictionary(entry, keys: entryKeys)
                }
            }
        }

        private static func dictionary(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
            guard let dictionary = value as? [String: Any], Set(dictionary.keys) == keys else {
                throw RulePackCatalogVerificationError.invalidEnvelope
            }
            return dictionary
        }

        private static func array(_ value: Any?) throws -> [Any] {
            guard let array = value as? [Any] else { throw RulePackCatalogVerificationError.invalidEnvelope }
            return array
        }
    }
}
