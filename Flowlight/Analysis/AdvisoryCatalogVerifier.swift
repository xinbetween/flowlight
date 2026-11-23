import CryptoKit
import Foundation

/// Verification is deliberately separate from `SecurityAdvisory.matches`: publisher trust decides whether a
/// catalog may be stored, while local identity/version matching decides whether one advisory applies to one app.
enum AdvisoryCatalogVerifier {
    static let catalogFormat: UInt16 = 1
    static let catalogID = "flowlight.advisories"
    static let channel = "official"
    static let sourceURL = "https://flowlight.xinbetween.com/advisories/v1/catalog.json"
    static let publisher = "Flowlight"
    static let signatureAlgorithm = "p256-sha256"
    static let signatureDomain = "flowlight-advisory-catalog-signature-v1"
    static let maximumDataBytes = 4 * 1024 * 1024
    static let maximumAdvisories = 4_096
    static let maximumConfigurations = 64
    static let maximumNodes = 64
    static let maximumMatches = 256
    static let maximumStringBytes = 16 * 1024
    static let maximumFutureIssueSkew: Int64 = 5 * 60

    // Public material only. Empty bundled content is still signed so a resource-selection mistake cannot become
    // an implicit trust bypass when the first real advisory feed is shipped.
    private static let productionPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpi/rbJr0pZwcLN+mbwAPAi9l2NnL
    K8gEqICZh3vk1IZzzmO1/8VdxTpkS96nixtcB+Kykic/6x+neKTlTtilbg==
    -----END PUBLIC KEY-----
    """

    static let productionTrustedSigners = [
        AdvisoryCatalogTrustedSigner(
            keyID: "flowlight-advisories-2026-11",
            publisher: publisher,
            catalogID: catalogID,
            advisoryIDPrefix: "CVE-",
            publicKeyPEM: productionPublicKeyPEM,
            validFrom: 1_794_700_800,
            validUntil: 1_956_528_000,
            revoked: false
        ),
    ]

    static func verify(data: Data,
                       trustedSigners: [AdvisoryCatalogTrustedSigner] = productionTrustedSigners,
                       now: Int64,
                       priorSequence: Int64? = nil,
                       priorDigest: String? = nil,
                       allowExpiredLastKnownGood: Bool = false) throws -> VerifiedAdvisoryCatalog {
        guard data.count <= maximumDataBytes else { throw AdvisoryCatalogVerificationError.dataTooLarge }
        try validateUniqueTrustedKeyIDs(trustedSigners)
        guard (priorSequence == nil) == (priorDigest == nil) else {
            throw AdvisoryCatalogVerificationError.invalidPriorReceipt
        }

        let envelope = try strictDecode(data)
        try validateEnvelope(envelope, now: now)
        let canonical = try canonicalPayload(for: envelope)
        let digest = sha256Hex(canonical)
        let stale = now > envelope.payload.expiresAt
        if stale {
            guard allowExpiredLastKnownGood, priorSequence == envelope.payload.sequence, priorDigest == digest else {
                throw AdvisoryCatalogVerificationError.expired
            }
        }
        let signerKeyID = try verifySignatures(envelope.signatures, payload: envelope.payload,
                                               canonical: canonical, trustedSigners: trustedSigners, now: now)
        try validateReceipt(sequence: envelope.payload.sequence, digest: digest,
                            priorSequence: priorSequence, priorDigest: priorDigest)
        return VerifiedAdvisoryCatalog(
            advisories: envelope.payload.advisories.map(\.advisory), sequence: envelope.payload.sequence,
            digest: digest, signerKeyID: signerKeyID, stale: stale, rawEnvelope: data
        )
    }

    static func validateStrictJSONSyntax(_ data: Data) throws {
        var scanner = DuplicateKeyScanner(data: data)
        try scanner.validate()
    }

    static func canonicalPayload(for envelope: AdvisoryCatalogEnvelope) throws -> Data {
        guard envelope.format == catalogFormat else { throw AdvisoryCatalogVerificationError.unsupportedFormat }
        let payload = envelope.payload
        guard payload.sequence > 0 else { throw AdvisoryCatalogVerificationError.invalidSequence }
        guard payload.issuedAt >= 0, payload.expiresAt > payload.issuedAt else {
            throw AdvisoryCatalogVerificationError.invalidExpiry
        }
        guard payload.advisories.count <= maximumAdvisories else {
            throw AdvisoryCatalogVerificationError.tooManyAdvisories
        }

        var bytes = CanonicalBytes(limit: maximumDataBytes)
        try bytes.append(signatureDomain)
        try bytes.append(envelope.format)
        try bytes.append(payload.catalogID)
        try bytes.append(payload.channel)
        try bytes.append(payload.sourceURL)
        try bytes.append(UInt64(payload.sequence))
        try bytes.append(UInt64(payload.issuedAt))
        try bytes.append(UInt64(payload.expiresAt))
        try bytes.append(payload.publisher)
        try bytes.append(UInt32(payload.advisories.count))

        var previousID: String?
        for advisory in payload.advisories {
            guard !advisory.id.isEmpty, advisory.id == advisory.id.uppercased(),
                  advisory.id.range(of: #"^[A-Z0-9][A-Z0-9_.:-]*$"#, options: .regularExpression) != nil else {
                throw AdvisoryCatalogVerificationError.invalidAdvisoryID
            }
            if let previousID, previousID >= advisory.id {
                throw AdvisoryCatalogVerificationError.duplicateAdvisoryID(advisory.id)
            }
            previousID = advisory.id
            guard advisory.configurations.count <= maximumConfigurations else {
                throw AdvisoryCatalogVerificationError.invalidConfiguration
            }
            try bytes.append(advisory.id)
            try bytes.append(advisory.summary)
            try bytes.append(advisory.published ?? -1)
            try bytes.append(advisory.lastModified ?? -1)
            try bytes.append(UInt32(advisory.configurations.count))
            for configuration in advisory.configurations {
                guard !configuration.nodes.isEmpty, configuration.nodes.count <= maximumNodes else {
                    throw AdvisoryCatalogVerificationError.invalidConfiguration
                }
                try bytes.append(UInt32(configuration.nodes.count))
                for node in configuration.nodes {
                    guard !node.matches.isEmpty, node.matches.count <= maximumMatches else {
                        throw AdvisoryCatalogVerificationError.invalidConfiguration
                    }
                    try bytes.append(node.operation.rawValue)
                    try bytes.append(node.negate ? UInt8(1) : UInt8(0))
                    try bytes.append(UInt32(node.matches.count))
                    for match in node.matches {
                        guard !match.criteria.isEmpty, !match.bundleIDs.isEmpty else {
                            throw AdvisoryCatalogVerificationError.invalidCPEMatch
                        }
                        try bytes.append(match.criteria)
                        try bytes.append(match.matchCriteriaID)
                        try bytes.append(match.vulnerable ? UInt8(1) : UInt8(0))
                        try bytes.append(UInt32(match.bundleIDs.count))
                        for bundleID in match.bundleIDs { try bytes.append(bundleID) }
                        try bytes.append(match.versionStartIncluding)
                        try bytes.append(match.versionStartExcluding)
                        try bytes.append(match.versionEndIncluding)
                        try bytes.append(match.versionEndExcluding)
                    }
                }
            }
        }
        return bytes.data
    }

    private static func validateEnvelope(_ envelope: AdvisoryCatalogEnvelope, now: Int64) throws {
        guard envelope.format == catalogFormat else { throw AdvisoryCatalogVerificationError.unsupportedFormat }
        guard envelope.payload.catalogID == catalogID else { throw AdvisoryCatalogVerificationError.wrongCatalogID }
        guard envelope.payload.channel == channel else { throw AdvisoryCatalogVerificationError.wrongChannel }
        guard envelope.payload.sourceURL == sourceURL else { throw AdvisoryCatalogVerificationError.wrongSourceURL }
        guard envelope.payload.publisher == publisher else { throw AdvisoryCatalogVerificationError.wrongPublisher }
        guard now >= 0, envelope.payload.issuedAt >= 0, envelope.payload.expiresAt > envelope.payload.issuedAt else {
            throw AdvisoryCatalogVerificationError.invalidTimestamp
        }
        if envelope.payload.issuedAt > now {
            let (delta, overflow) = envelope.payload.issuedAt.subtractingReportingOverflow(now)
            guard !overflow, delta <= maximumFutureIssueSkew else {
                throw AdvisoryCatalogVerificationError.issuedTooFarInFuture
            }
        }
        guard !envelope.payload.advisories.isEmpty || envelope.payload.sequence == 1 else {
            throw AdvisoryCatalogVerificationError.invalidAdvisoryCount
        }
        guard !envelope.signatures.isEmpty, envelope.signatures.count <= 16 else {
            throw AdvisoryCatalogVerificationError.tooManySignatures
        }
        for signature in envelope.signatures {
            try validateString(signature.algorithm); try validateString(signature.keyID); try validateString(signature.value)
            guard signature.algorithm == signatureAlgorithm else { throw AdvisoryCatalogVerificationError.unsupportedSignatureAlgorithm }
            guard Data(base64Encoded: signature.value).map({ $0.base64EncodedString() == signature.value }) == true,
                  (try? P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: signature.value)!)) != nil else {
                throw AdvisoryCatalogVerificationError.malformedSignature
            }
        }
        _ = try canonicalPayload(for: envelope)
    }

    private static func verifySignatures(_ signatures: [AdvisoryCatalogSignature], payload: AdvisoryCatalogPayload,
                                         canonical: Data, trustedSigners: [AdvisoryCatalogTrustedSigner], now: Int64) throws -> String {
        var sawKnown = false, sawRevoked = false, sawNotYetValid = false, sawExpired = false, sawWrongScope = false, sawInvalidKey = false
        var seen = Set<String>()
        for signature in signatures {
            guard seen.insert(signature.keyID).inserted else {
                throw AdvisoryCatalogVerificationError.duplicateSignatureKeyID(signature.keyID)
            }
            guard let signer = trustedSigners.first(where: { $0.keyID == signature.keyID }) else { continue }
            sawKnown = true
            guard !signer.revoked else { sawRevoked = true; continue }
            guard now >= signer.validFrom, payload.issuedAt >= signer.validFrom else { sawNotYetValid = true; continue }
            guard now <= signer.validUntil, payload.issuedAt <= signer.validUntil else { sawExpired = true; continue }
            guard signer.publisher == payload.publisher, signer.catalogID == payload.catalogID,
                  payload.sequence >= signer.minimumSequence, payload.sequence <= signer.maximumSequence,
                  payload.advisories.allSatisfy({ $0.id.hasPrefix(signer.advisoryIDPrefix) }) else {
                sawWrongScope = true; continue
            }
            guard let key = try? P256.Signing.PublicKey(pemRepresentation: signer.publicKeyPEM) else {
                sawInvalidKey = true; continue
            }
            guard let value = Data(base64Encoded: signature.value),
                  let parsed = try? P256.Signing.ECDSASignature(derRepresentation: value) else { continue }
            if key.isValidSignature(parsed, for: canonical) { return signer.keyID }
        }
        if !sawKnown { throw AdvisoryCatalogVerificationError.unknownSigner }
        if sawRevoked { throw AdvisoryCatalogVerificationError.revokedSigner }
        if sawNotYetValid { throw AdvisoryCatalogVerificationError.signerNotYetValid }
        if sawExpired { throw AdvisoryCatalogVerificationError.signerExpired }
        if sawWrongScope { throw AdvisoryCatalogVerificationError.wrongSignerScope }
        if sawInvalidKey { throw AdvisoryCatalogVerificationError.invalidPublicKey }
        throw AdvisoryCatalogVerificationError.invalidSignature
    }

    private static func validateReceipt(sequence: Int64, digest: String, priorSequence: Int64?, priorDigest: String?) throws {
        guard let priorSequence, let priorDigest else { return }
        if sequence < priorSequence { throw AdvisoryCatalogVerificationError.rollback }
        if sequence == priorSequence, digest != priorDigest { throw AdvisoryCatalogVerificationError.equivocation }
    }

    private static func validateUniqueTrustedKeyIDs(_ signers: [AdvisoryCatalogTrustedSigner]) throws {
        var ids = Set<String>()
        for signer in signers where !ids.insert(signer.keyID).inserted {
            throw AdvisoryCatalogVerificationError.duplicateTrustedKeyID(signer.keyID)
        }
    }

    private static func validateString(_ value: String?) throws {
        if let value, value.lengthOfBytes(using: .utf8) > maximumStringBytes {
            throw AdvisoryCatalogVerificationError.stringTooLarge
        }
    }

    private static func strictDecode(_ data: Data) throws -> AdvisoryCatalogEnvelope {
        do {
            try validateStrictJSONSyntax(data)
            let object = try JSONSerialization.jsonObject(with: data)
            try StrictSchema.validate(object)
            return try JSONDecoder().decode(AdvisoryCatalogEnvelope.self, from: data)
        } catch let error as AdvisoryCatalogVerificationError { throw error }
          catch { throw AdvisoryCatalogVerificationError.invalidEnvelope }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalBytes {
        var data = Data(); let limit: Int
        mutating func append<T: FixedWidthInteger>(_ value: T) throws { var v = value.bigEndian; try withUnsafeBytes(of: &v) { try append(Data($0)) } }
        mutating func append(_ value: String?) throws { try append(value == nil ? UInt8(0) : UInt8(1)); if let value { try append(value) } }
        mutating func append(_ value: String) throws { let bytes = Data(value.utf8); guard bytes.count <= AdvisoryCatalogVerifier.maximumStringBytes else { throw AdvisoryCatalogVerificationError.stringTooLarge }; try append(UInt32(bytes.count)); try append(bytes) }
        private mutating func append(_ bytes: Data) throws { let (size, overflow) = data.count.addingReportingOverflow(bytes.count); guard !overflow, size <= limit else { throw AdvisoryCatalogVerificationError.dataTooLarge }; data.append(bytes) }
    }

    private enum StrictSchema {
        static func validate(_ value: Any) throws {
            _ = try dictionary(value, keys: ["format", "payload", "signatures"])
            let root = value as! [String: Any]
            let payload = try dictionaryValue(root["payload"], keys: ["catalogID", "channel", "sourceURL", "sequence", "issuedAt", "expiresAt", "publisher", "advisories"])
            for signature in try array(root["signatures"]) { _ = try dictionary(signature, keys: ["algorithm", "keyID", "value"]) }
            for advisory in try array(payload["advisories"]) {
                let a = try dictionary(advisory, keys: ["id", "summary", "published", "lastModified", "configurations"], optional: ["summary", "published", "lastModified"])
                for configuration in try array(a["configurations"]) {
                    let c = try dictionary(configuration, keys: ["nodes"])
                    for node in try array(c["nodes"]) {
                        let n = try dictionary(node, keys: ["operation", "negate", "matches"])
                        for match in try array(n["matches"]) {
                            _ = try dictionary(match, keys: ["criteria", "matchCriteriaID", "vulnerable", "bundleIDs", "versionStartIncluding", "versionStartExcluding", "versionEndIncluding", "versionEndExcluding"], optional: ["matchCriteriaID", "versionStartIncluding", "versionStartExcluding", "versionEndIncluding", "versionEndExcluding"])
                        }
                    }
                }
            }
        }
        private static func dictionaryValue(_ value: Any?, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] { try dictionary(value as Any, keys: keys, optional: optional) }
        private static func dictionary(_ value: Any, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
            guard let dict = value as? [String: Any], Set(dict.keys).isSubset(of: keys), keys.subtracting(optional).isSubset(of: Set(dict.keys)) else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; return dict
        }
        private static func array(_ value: Any?) throws -> [Any] { guard let value = value as? [Any] else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; return value }
    }

    private struct DuplicateKeyScanner {
        let data: [UInt8]; var index = 0
        init(data: Data) { self.data = Array(data) }
        mutating func validate() throws { skip(); try value(depth: 0); skip(); guard index == data.count else { throw AdvisoryCatalogVerificationError.invalidEnvelope } }
        mutating private func value(depth: Int) throws { guard depth < 64, index < data.count else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; switch data[index] { case 34: _ = try string(); case 91: try array(depth + 1); case 123: try object(depth + 1); case 45, 48...57: number(); case 116: literal("true"); case 102: literal("false"); case 110: literal("null"); default: throw AdvisoryCatalogVerificationError.invalidEnvelope } }
        mutating private func object(_ depth: Int) throws { index += 1; skip(); var keys = Set<String>(); if consume(125) { return }; while true { let key = try string(); guard keys.insert(key).inserted else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; skip(); guard consume(58) else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; skip(); try value(depth: depth); skip(); if consume(125) { return }; guard consume(44) else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; skip() } }
        mutating private func array(_ depth: Int) throws { index += 1; skip(); if consume(93) { return }; while true { try value(depth: depth); skip(); if consume(93) { return }; guard consume(44) else { throw AdvisoryCatalogVerificationError.invalidEnvelope }; skip() } }
        mutating private func string() throws -> String {
            guard consume(34) else { throw AdvisoryCatalogVerificationError.invalidEnvelope }
            var escaped = false
            let start = index
            while index < data.count {
                let byte = data[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    let raw = Data(data[(start - 1)..<index])
                    guard let decoded = try? JSONSerialization.jsonObject(with: raw) as? String else {
                        throw AdvisoryCatalogVerificationError.invalidEnvelope
                    }
                    return decoded
                }
                if byte < 32 { throw AdvisoryCatalogVerificationError.invalidEnvelope }
            }
            throw AdvisoryCatalogVerificationError.invalidEnvelope
        }
        mutating private func number() { while index < data.count && (data[index] == 45 || data[index] == 43 || data[index] == 46 || data[index] == 101 || data[index] == 69 || (48...57).contains(data[index])) { index += 1 } }
        mutating private func literal(_ literal: String) { index += literal.utf8.count }
        mutating private func consume(_ byte: UInt8) -> Bool { guard index < data.count, data[index] == byte else { return false }; index += 1; return true }
        mutating private func skip() { while index < data.count && [32, 9, 10, 13].contains(data[index]) { index += 1 } }
    }
}
