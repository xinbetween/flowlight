import CryptoKit
import Foundation

enum PluginPackageError: LocalizedError, Equatable {
    case reservedBuiltInID
    case invalidID
    case scriptTooLarge
    case unsupportedPackage
    case unknownSigner(String)
    case wrongPublisher
    case invalidSignature
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .reservedBuiltInID: return L("Installed plugin IDs cannot reuse a built-in plugin ID.")
        case .invalidID: return L("Plugin IDs must contain only letters, numbers, dots, underscores, and hyphens.")
        case .scriptTooLarge: return L("Plugin scripts must be 128 KB or smaller.")
        case .unsupportedPackage: return L("This plugin package format is not supported.")
        case .unknownSigner(let key): return L("The plugin package was signed by an unknown key: %@.", key)
        case .wrongPublisher: return L("The plugin package signature does not match the declared publisher.")
        case .invalidSignature: return L("The plugin package signature did not verify.")
        case .digestMismatch: return L("The plugin package contents do not match their signed digest.")
        }
    }
}

struct PluginTrustedSigner: Equatable, Sendable {
    var keyID: String
    var publisher: PluginManifest.Publisher
    var publisherName: String
    var channel: PluginProvenance.DistributionChannel
    var publicKeyPEM: String
}

enum PluginPackageVerifier {
    private static let builtInSigners: [PluginTrustedSigner] = []

    static func review(data: Data, trustedSigners: [PluginTrustedSigner] = builtInSigners) throws -> PluginPackageReview {
        let package = try JSONDecoder().decode(PluginPackage.self, from: data)
        guard package.packageVersion == 1 else { throw PluginPackageError.unsupportedPackage }
        var manifest = package.manifest
        try validateBase(manifest)
        manifest.source = .installed
        if manifest.capabilities.isEmpty { manifest.capabilities = [.annotate] }
        manifest.permissions = normalizedPermissions(manifest)
        if manifest.privacy.categories.isEmpty { manifest.privacy.categories = [.metadataOnly] }
        if manifest.privacy.summary.isEmpty { manifest.privacy.summary = manifest.privacySummary }

        let scriptDigest = sha256Hex(Data(manifest.script.utf8))
        let packageDigest = digest(for: manifest)
        let signatureStatus: PluginProvenance.ReviewStatus
        var warnings: [String] = []
        if let signature = package.signature {
            guard signature.algorithm == "p256-sha256" else { throw PluginPackageError.unsupportedPackage }
            guard let signer = trustedSigners.first(where: { $0.keyID == signature.keyID }) else { throw PluginPackageError.unknownSigner(signature.keyID) }
            try verify(signature, digest: packageDigest, signer: signer)
            if signer.publisher == .official, manifest.publisher != .official { throw PluginPackageError.wrongPublisher }
            if manifest.publisher == .official, signer.publisher != .official { throw PluginPackageError.wrongPublisher }
            manifest.publisher = signer.publisher
            signatureStatus = signer.publisher == .official ? .verifiedOfficial : .verifiedCommunity
            manifest.provenance.publisherName = signer.publisherName
            manifest.provenance.signingKeyID = signer.keyID
            manifest.provenance.signedAt = signature.signedAt
            manifest.provenance.distributionChannel = signer.channel
        } else {
            if manifest.publisher == .official { manifest.publisher = .thirdParty }
            signatureStatus = .unsigned
            manifest.provenance.distributionChannel = .local
            warnings.append(L("Unsigned local packages can run advisory JavaScript, but they cannot claim official provenance."))
        }
        manifest.provenance.packageDigest = packageDigest
        manifest.provenance.scriptDigest = scriptDigest
        manifest.provenance.reviewStatus = signatureStatus
        let approval = approvalFingerprint(for: manifest)
        manifest.provenance.approvalFingerprint = approval
        return PluginPackageReview(manifest: manifest, signatureStatus: signatureStatus, packageDigest: packageDigest,
                                   scriptDigest: scriptDigest, approvalFingerprint: approval, warnings: warnings,
                                   signature: package.signature)
    }

    static func signedPackage(manifest: PluginManifest, keyID: String, privateKey: P256.Signing.PrivateKey,
                              signedAt: String = ISO8601DateFormatter().string(from: Date())) throws -> PluginPackage {
        var copy = manifest
        copy.enabled = true
        copy.configuration = [:]
        let digest = digest(for: copy)
        let signature = try privateKey.signature(for: signatureMessage(digest: digest, keyID: keyID))
        return PluginPackage(manifest: copy,
                             signature: PluginSignature(keyID: keyID, signedAt: signedAt,
                                                        value: Data(signature.derRepresentation).base64EncodedString()),
                             packageVersion: 1)
    }

    static func digest(for manifest: PluginManifest) -> String {
        let payload = signedPayload(for: manifest)
        return sha256Hex(payload)
    }

    static func approvalFingerprint(for manifest: PluginManifest) -> String {
        let parts = [
            manifest.id,
            manifest.version,
            String(manifest.ruleVersion),
            manifest.publisher.rawValue,
            manifest.provenance.signingKeyID,
            manifest.capabilities.map(\.rawValue).sorted().joined(separator: ","),
            manifest.permissions.map(\.rawValue).sorted().joined(separator: ","),
            manifest.privacy.categories.map(\.rawValue).sorted().joined(separator: ","),
            manifest.provenance.packageDigest,
            manifest.provenance.scriptDigest,
        ]
        return sha256Hex(Data(parts.joined(separator: "\u{1}").utf8))
    }

    private static func validateBase(_ manifest: PluginManifest) throws {
        guard manifest.id.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw PluginPackageError.invalidID }
        guard !PluginEngine.builtInManifests.contains(where: { $0.id == manifest.id }) else { throw PluginPackageError.reservedBuiltInID }
        guard manifest.script.lengthOfBytes(using: .utf8) <= PluginScriptRunner.maxScriptBytes else { throw PluginPackageError.scriptTooLarge }
    }

    private static func normalizedPermissions(_ manifest: PluginManifest) -> [PluginPermission] {
        var set = Set(manifest.permissions.isEmpty ? PluginPermission.defaultMetadata : manifest.permissions)
        if manifest.capabilities.contains(.suggestGuardrail) { set.insert(.suggestGuardrail) }
        return PluginPermission.allCases.filter { set.contains($0) }
    }

    private static func signedPayload(for manifest: PluginManifest) -> Data {
        var object: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "version": manifest.version,
            "kind": manifest.kind.rawValue,
            "publisher": manifest.publisher.rawValue,
            "guardrailProvider": manifest.guardrailProvider.rawValue,
            "description": manifest.description,
            "ruleVersion": manifest.ruleVersion,
            "privacySummary": manifest.privacySummary,
            "capabilities": manifest.capabilities.map(\.rawValue).sorted(),
            "schemaVersion": manifest.schemaVersion,
            "permissions": manifest.permissions.map(\.rawValue).sorted(),
            "privacy": [
                "categories": manifest.privacy.categories.map(\.rawValue).sorted(),
                "summary": manifest.privacy.summary,
            ],
            "scriptDigest": sha256Hex(Data(manifest.script.utf8)),
        ]
        if !manifest.provenance.sourceURL.isEmpty { object["sourceURL"] = manifest.provenance.sourceURL }
        if !manifest.provenance.repositoryURL.isEmpty { object["repositoryURL"] = manifest.provenance.repositoryURL }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data ?? Data()
    }

    private static func verify(_ signature: PluginSignature, digest: String, signer: PluginTrustedSigner) throws {
        guard let signatureData = Data(base64Encoded: signature.value),
              let publicKey = publicKey(fromPEM: signer.publicKeyPEM),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            throw PluginPackageError.invalidSignature
        }
        guard publicKey.isValidSignature(parsed, for: signatureMessage(digest: digest, keyID: signature.keyID)) else {
            throw PluginPackageError.invalidSignature
        }
    }

    private static func publicKey(fromPEM pem: String) -> P256.Signing.PublicKey? {
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("-----") }
        guard let data = Data(base64Encoded: lines.joined()) else { return nil }
        return try? P256.Signing.PublicKey(pemRepresentation: pem) ?? (try? P256.Signing.PublicKey(derRepresentation: data))
    }

    private static func signatureMessage(digest: String, keyID: String) -> Data {
        Data("flowlight-plugin-signature-v1\u{1}\(keyID)\u{1}\(digest)".utf8)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
