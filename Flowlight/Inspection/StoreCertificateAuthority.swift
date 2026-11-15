#if APP_STORE
import CryptoKit
import Darwin
import Foundation
import Security

/// Store-safe local certificate authority.
///
/// Private P-256 keys live in this app's keychain access group. Certificates are assembled and signed in-process
/// with Security.framework; the only file offered to the user is the public CA certificate. Trust remains an explicit
/// user action in macOS — this type reads trust state but never changes it.
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    let directory: URL
    private let lock = NSLock()
    private var identities: [String: SecIdentity] = [:]
    private var didPrunePersistedLeaves = false
    private var leafRecordCache: [LeafRecord]?
    /// Overridable only by Store-hosted tests to prove each post-import failure path cleans up its Keychain leaf.
    var leafManifestWriter: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }
    var importedLeafReferenceProvider: (SecCertificate) -> (OSStatus, Data?) = { certificate in
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == CFDataGetTypeID() else {
            return (status, nil)
        }
        return (status, unsafeBitCast(result, to: CFData.self) as Data)
    }
    var leafIdentityProvider: (SecCertificate) -> (OSStatus, SecIdentity?) = { certificate in
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        return (status, identity)
    }
    private let bundleValidationLock = NSLock()
    private var cachedBundleValidation: (stamp: BundleStamp, valid: Bool)?
    private let caTag: Data
    private let leafTag: Data
    private static let leafCertificateLabel = "Flowlight Inspection Leaf"
    private static let maximumLeafIdentities = 128
    private struct LeafRecord: Codable {
        var der: Data
        var persistentReference: Data?
    }
    private struct FileStamp: Equatable {
        var size: Int64
        var inode: UInt64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }
    private struct BundleStamp: Equatable {
        var systemRoots: FileStamp
        var authority: FileStamp
        var bundle: FileStamp
    }

    init(directory: URL = CertificateAuthority.defaultDirectory) {
        self.directory = directory
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        caTag = Data("com.flowlight.inspection.ca.\(digest)".utf8)
        leafTag = Data("com.flowlight.inspection.leaf.\(digest)".utf8)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flowlight/StoreInspection", isDirectory: true)
    }

    var caCertificateURL: URL { directory.appendingPathComponent("flowlight-ca.pem") }
    var bundleURL: URL { directory.appendingPathComponent("ca-bundle.pem") }
    private var leafManifestURL: URL { directory.appendingPathComponent("leaf-certificates.plist") }
    #if DEBUG
    var generatedLeafPersistentReferences: [Data] {
        ((try? loadLeafRecords()) ?? []).compactMap(\.persistentReference)
    }
    #endif

    var exists: Bool { hasValidAuthority && hasValidBundle }

    private var hasValidAuthority: Bool {
        guard FileManager.default.fileExists(atPath: caCertificateURL.path),
              let caKey = key(tag: caTag),
              key(tag: leafTag) != nil,
              let certificate = caCertificate() else {
            return false
        }
        return Self.certificate(certificate, matches: caKey)
    }

    private var hasValidBundle: Bool {
        guard let stamp = bundleStamp() else { return false }
        bundleValidationLock.lock()
        if let cached = cachedBundleValidation, cached.stamp == stamp {
            bundleValidationLock.unlock()
            return cached.valid
        }
        bundleValidationLock.unlock()

        let valid: Bool
        if let expected = try? expectedBundle(),
           let bundle = try? String(contentsOf: bundleURL, encoding: .utf8) {
            valid = bundle == expected
        } else {
            valid = false
        }
        bundleValidationLock.lock()
        cachedBundleValidation = (stamp, valid)
        bundleValidationLock.unlock()
        return valid
    }

    private func bundleStamp() -> BundleStamp? {
        func stamp(_ url: URL) -> FileStamp? {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
            return FileStamp(
                size: info.st_size,
                inode: UInt64(info.st_ino),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
            )
        }
        let systemRoots = URL(fileURLWithPath: "/etc/ssl/cert.pem")
        guard let rootsStamp = stamp(systemRoots),
              let authorityStamp = stamp(caCertificateURL),
              let bundleStamp = stamp(bundleURL) else { return nil }
        return BundleStamp(systemRoots: rootsStamp, authority: authorityStamp, bundle: bundleStamp)
    }

    func ensure() throws {
        lock.lock(); defer { lock.unlock() }
        if hasValidAuthority {
            try prunePersistedLeavesIfNeeded()
            if !hasValidBundle { try writeBundle() }
            return
        }

        // Recover atomically from an interrupted first run. Only app-owned keys and generated leaf certificates are
        // removed; a CA the user imported into their keychain remains theirs to remove.
        try deleteLeafCertificates()
        try deleteKey(tag: caTag)
        try deleteKey(tag: leafTag)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let caKey = try createKey(tag: caTag, label: "Flowlight Inspection CA Key")
            _ = try createKey(tag: leafTag, label: "Flowlight Inspection Leaf Key")
            let tag = String(UUID().uuidString.prefix(8))
            let name = X509.Name(
                commonName: "Flowlight Inspection CA \(tag)",
                organization: "Flowlight (local, this Mac only)"
            )
            let der = try X509.certificate(
                subject: name,
                issuer: name,
                publicKey: try publicKey(of: caKey),
                signingKey: caKey,
                validFor: 10 * 365 * 24 * 60 * 60,
                extensions: X509.caExtensions
            )
            try pem(der, label: "CERTIFICATE").write(
                to: caCertificateURL,
                atomically: true,
                encoding: .utf8
            )
            try writeBundle()
            didPrunePersistedLeaves = true
        } catch {
            try? deleteLeafCertificates()
            try? deleteKey(tag: caTag)
            try? deleteKey(tag: leafTag)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// A TLS server identity for one DNS name or IP literal, signed by the local CA.
    func identity(for host: String) throws -> SecIdentity {
        let name = host.lowercased()
        guard Self.configSafe(name) == name, !name.isEmpty else {
            throw InspectionError.native("the requested host name is invalid")
        }

        lock.lock()
        if let cached = identities[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        try ensure()
        lock.lock(); defer { lock.unlock() }
        if let cached = identities[name] { return cached }
        guard let caKey = key(tag: caTag), let leafKey = key(tag: leafTag),
              let ca = caCertificate() else {
            throw InspectionError.native("the local certificate authority is incomplete")
        }

        if identities.count >= Self.maximumLeafIdentities {
            identities.removeAll()
            try deleteLeafCertificates()
        }

        let issuer = try X509.name(from: ca)
        let der = try X509.certificate(
            subject: X509.Name(commonName: name, organization: nil),
            issuer: issuer,
            publicKey: try publicKey(of: leafKey),
            signingKey: caKey,
            validFor: 397 * 24 * 60 * 60,
            extensions: try X509.leafExtensions(host: name)
        )
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw InspectionError.native("the generated leaf certificate could not be parsed")
        }
        // A stop between import and manifest update is recovered by the cryptographic sweep in deleteLeafCertificates.
        // Finalize the ownership record once, after the opaque reference exists, to keep TLS setup off a double-write path.
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: Self.leafCertificateLabel,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            throw InspectionError.native(Self.message(added, fallback: "the leaf certificate could not be stored"))
        }
        let (persistentStatus, persistentReference) = importedLeafReferenceProvider(certificate)
        guard persistentStatus == errSecSuccess, let persistentReference else {
            let referenceError = InspectionError.native(
                persistentStatus == errSecSuccess
                    ? "the leaf certificate reference had an unexpected representation"
                    : Self.message(persistentStatus, fallback: "the leaf certificate reference could not be retained")
            )
            try cleanupAfterLeafImportFailure(referenceError)
        }
        do {
            try recordLeafCertificate(der, persistentReference: persistentReference)
        } catch let manifestError {
            try cleanupAfterLeafImportFailure(manifestError)
        }
        let (status, identity) = leafIdentityProvider(certificate)
        guard status == errSecSuccess, let identity else {
            let pairingError = InspectionError.native(Self.message(
                status,
                fallback: "the leaf key could not be paired with its certificate"
            ))
            try cleanupAfterLeafImportFailure(pairingError)
        }
        identities[name] = identity
        return identity
    }

    func caCertificate() -> SecCertificate? {
        guard let pem = try? String(contentsOf: caCertificateURL, encoding: .utf8) else { return nil }
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    enum SSLTrustDecision: Equatable {
        case trusted
        case denied
        case noDecision
    }

    /// Trust Settings records are usage constrained. Merely finding a record is not enough: it may explicitly deny
    /// this CA or trust it only for S/MIME. Flowlight needs unconstrained SSL-server trust because it mints leaves for
    /// many hosts, not one policy string or one application.
    static func sslTrustDecision(_ settings: [[String: Any]]) -> SSLTrustDecision {
        if settings.isEmpty { return .trusted }
        var foundTrust = false
        for setting in settings where appliesToAllSSLServers(setting) {
            let rawResult = (setting[kSecTrustSettingsResult as String] as? NSNumber)?.intValue
                ?? Int(SecTrustSettingsResult.trustRoot.rawValue)
            switch SecTrustSettingsResult(rawValue: UInt32(rawResult)) {
            case .deny:
                return .denied
            case .trustRoot:
                foundTrust = true
            case .trustAsRoot, .unspecified, .invalid, nil:
                break
            @unknown default:
                break
            }
        }
        return foundTrust ? .trusted : .noDecision
    }

    private static func appliesToAllSSLServers(_ setting: [String: Any]) -> Bool {
        // A host, application, or key-usage restriction cannot establish the product-wide trust shown in the UI.
        guard setting[kSecTrustSettingsApplication as String] == nil,
              setting[kSecTrustSettingsPolicyString as String] == nil,
              setting[kSecTrustSettingsKeyUsage as String] == nil else {
            return false
        }
        guard let value = setting[kSecTrustSettingsPolicy as String] else { return true }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == SecPolicyGetTypeID() else { return false }
        let policy = unsafeBitCast(cfValue, to: SecPolicy.self)
        guard let properties = SecPolicyCopyProperties(policy) as? [String: Any],
              let oid = properties[kSecPolicyOid as String] as? String else {
            return false
        }
        return oid == (kSecPolicyAppleSSL as String)
    }

    private static func trustDecision(
        for cert: SecCertificate,
        domain: SecTrustSettingsDomain
    ) -> SSLTrustDecision? {
        var raw: CFArray?
        guard SecTrustSettingsCopyTrustSettings(cert, domain, &raw) == errSecSuccess,
              let settings = raw as? [[String: Any]] else {
            return nil
        }
        return sslTrustDecision(settings)
    }

    static func isTrustedForSSL(decisions: [SSLTrustDecision?]) -> Bool {
        for decision in decisions {
            switch decision {
            case .trusted: return true
            case .denied: return false
            case .noDecision, nil: continue
            }
        }
        return false
    }

    private static func isTrustedForSSL(
        _ cert: SecCertificate,
        domains: [SecTrustSettingsDomain]
    ) -> Bool {
        isTrustedForSSL(decisions: domains.map { trustDecision(for: cert, domain: $0) })
    }

    var isTrusted: Bool {
        guard let cert = caCertificate() else { return false }
        return Self.isTrustedForSSL(cert, domains: [.user])
    }

    var isTrustedAnywhere: Bool {
        guard let cert = caCertificate() else { return false }
        // Per-user Trust Settings override administrator settings for the usages they decide.
        return Self.isTrustedForSSL(cert, domains: [.user, .admin])
    }

    /// The Store product never mutates keychain trust. The public certificate is exported and macOS owns the
    /// user-mediated import/trust flow.
    func setTrusted(_ trusted: Bool) throws {
        throw InspectionError.trust("Trust this certificate in macOS System Settings or Keychain Access.")
    }

    func trust() throws {
        throw InspectionError.trust("Trust this certificate in macOS System Settings or Keychain Access.")
    }

    /// Deletes app-owned private keys, generated leaf certificates and exported files. A CA explicitly imported and
    /// trusted by the user is intentionally not removed from their keychain by the sandboxed Store app.
    func remove() throws {
        lock.lock(); defer { lock.unlock() }
        identities.removeAll()
        // Do not discard the keys or ownership manifest unless every exact leaf cleanup succeeded. A locked Keychain
        // remains retryable, and the UI can report the failure instead of claiming that removal completed.
        try deleteLeafCertificates()
        try deleteKey(tag: caTag)
        try deleteKey(tag: leafTag)
        didPrunePersistedLeaves = false
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func configSafe(_ host: String) -> String {
        String(host.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.:_*".unicodeScalars.contains($0))
        }.prefix(253))
    }

    private func key(tag: Data) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    private func createKey(tag: Data, label: String) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: label,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw InspectionError.native(error?.takeRetainedValue().localizedDescription ?? "key generation failed")
        }
        return key
    }

    private func publicKey(of privateKey: SecKey) throws -> SecKey {
        guard let key = SecKeyCopyPublicKey(privateKey) else {
            throw InspectionError.native("the public key could not be derived")
        }
        return key
    }

    /// A parseable certificate and an app-owned key are not enough: another product or an interrupted migration may
    /// have replaced only the public file. Accept persisted state only when both halves name the same P-256 key.
    private static func certificate(_ certificate: SecCertificate, matches privateKey: SecKey) -> Bool {
        guard let certificateKey = SecCertificateCopyKey(certificate),
              let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let certificateBytes = externalRepresentation(of: certificateKey),
              let privateBytes = externalRepresentation(of: privatePublicKey) else {
            return false
        }
        return certificateBytes == privateBytes
    }

    private struct DERElement {
        var tag: UInt8
        var encoded: Range<Int>
        var content: Range<Int>
    }

    private static func certificate(_ certificate: SecCertificate, wasSignedBy authority: SecCertificate) -> Bool {
        let der = SecCertificateCopyData(certificate) as Data
        var outerIndex = 0
        guard let outer = derElement(in: der, index: &outerIndex), outer.tag == 0x30,
              outer.encoded.upperBound == der.count else { return false }
        var fieldIndex = outer.content.lowerBound
        guard let tbs = derElement(in: der, index: &fieldIndex), tbs.tag == 0x30,
              let algorithm = derElement(in: der, index: &fieldIndex), algorithm.tag == 0x30,
              let signature = derElement(in: der, index: &fieldIndex), signature.tag == 0x03,
              fieldIndex == outer.content.upperBound,
              signature.content.count > 1,
              der[signature.content.lowerBound] == 0,
              let authorityKey = SecCertificateCopyKey(authority) else { return false }
        let message = Data(der[tbs.encoded])
        let signatureBytes = Data(der[der.index(after: signature.content.lowerBound)..<signature.content.upperBound])
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            authorityKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            signatureBytes as CFData,
            &error
        )
        _ = error?.takeRetainedValue()
        return verified
    }

    private static func derElement(in data: Data, index: inout Int) -> DERElement? {
        let start = index
        guard index < data.count else { return nil }
        let tag = data[index]
        index += 1
        guard index < data.count else { return nil }
        let firstLength = Int(data[index])
        index += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = firstLength
        } else {
            let byteCount = firstLength & 0x7f
            guard byteCount > 0, byteCount <= MemoryLayout<Int>.size,
                  index <= data.count - byteCount else { return nil }
            var decoded = 0
            for _ in 0..<byteCount {
                guard decoded <= (Int.max - Int(data[index])) / 256 else { return nil }
                decoded = decoded * 256 + Int(data[index])
                index += 1
            }
            length = decoded
        }
        guard length >= 0, index <= data.count - length else { return nil }
        let content = index..<(index + length)
        index += length
        return DERElement(tag: tag, encoded: start..<index, content: content)
    }

    private static func externalRepresentation(of key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        if let bytes = SecKeyCopyExternalRepresentation(key, &error) as Data? {
            return bytes
        }
        _ = error?.takeRetainedValue()
        return nil
    }

    private func deleteKey(tag: Data) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InspectionError.native(Self.message(
                status,
                fallback: "an app-owned inspection key could not be removed"
            ))
        }
    }

    private func prunePersistedLeavesIfNeeded() throws {
        guard !didPrunePersistedLeaves else { return }
        identities.removeAll()
        try deleteLeafCertificates()
        didPrunePersistedLeaves = true
    }

    private func loadLeafRecords() throws -> [LeafRecord] {
        if let leafRecordCache { return leafRecordCache }
        guard FileManager.default.fileExists(atPath: leafManifestURL.path) else {
            leafRecordCache = []
            return []
        }
        let data = try Data(contentsOf: leafManifestURL)
        let records = try PropertyListDecoder().decode([LeafRecord].self, from: data)
        leafRecordCache = records
        return records
    }

    private func recordLeafCertificate(_ der: Data, persistentReference: Data?) throws {
        var records = try loadLeafRecords()
        if let index = records.firstIndex(where: { $0.der == der }) {
            if let persistentReference { records[index].persistentReference = persistentReference }
        } else {
            records.append(LeafRecord(der: der, persistentReference: persistentReference))
        }
        let data = try PropertyListEncoder().encode(records)
        try leafManifestWriter(data, leafManifestURL)
        leafRecordCache = records
    }

    private func cleanupAfterLeafImportFailure(_ originalError: Error) throws -> Never {
        identities.removeAll()
        do {
            try deleteLeafCertificates()
            didPrunePersistedLeaves = true
        } catch let cleanupError {
            // No later identity attempt may import another leaf until ensure retries and completes this sweep.
            didPrunePersistedLeaves = false
            throw InspectionError.native(
                "\(originalError.localizedDescription); generated-leaf cleanup also failed: "
                    + cleanupError.localizedDescription
            )
        }
        throw originalError
    }

    /// The manifest contains only public certificate bytes and opaque Keychain references. A reference is trusted only
    /// when it still resolves to the recorded DER; stale or migrated references fall back to a DER lookup. The final
    /// cryptographic sweep also covers a stop after Keychain import but before the one manifest write completes.
    /// Public metadata is retained unless every owned item was removed or already absent, so failures remain retryable.
    private func deleteLeafCertificates() throws {
        let records: [LeafRecord]
        do {
            records = try loadLeafRecords()
        } catch is DecodingError {
            // A truncated or schema-incompatible manifest cannot identify exact references. Recover through the same
            // cryptographic ownership boundary as a pre-manifest upgrade, then remove the unusable public metadata.
            try deleteLegacyLeafCertificates()
            try FileManager.default.removeItem(at: leafManifestURL)
            leafRecordCache = []
            return
        }
        for record in records {
            var removed = false
            if let persistentReference = record.persistentReference {
                removed = try deleteCertificate(
                    persistentReference: persistentReference,
                    expectedDER: record.der
                )
            }
            if !removed { try deleteCertificate(der: record.der) }
        }
        try deleteLegacyLeafCertificates()
        if FileManager.default.fileExists(atPath: leafManifestURL.path) {
            try FileManager.default.removeItem(at: leafManifestURL)
        }
        leafRecordCache = []
    }

    /// Certificate-class Keychain items do not reliably retain the label supplied at import. A pre-manifest leaf is
    /// therefore owned only when both cryptographic boundaries agree: it uses this directory's app-owned leaf key and
    /// validates to this directory's Flowlight CA. Imported roots and every unrelated certificate fail those checks.
    private func deleteLegacyLeafCertificates() throws {
        // Without this app-owned key no certificate can satisfy the first ownership boundary. This also keeps removal
        // idempotent after the keys were deleted but a later filesystem cleanup failed.
        guard let leafKey = key(tag: leafTag) else { return }
        var stored: CFTypeRef?
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        let status = SecItemCopyMatching(lookup as CFDictionary, &stored)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let certificates = stored as? [SecCertificate] else {
            throw InspectionError.native(Self.message(
                status,
                fallback: "legacy generated leaf certificates could not be enumerated for cleanup"
            ))
        }
        let candidates = certificates.filter { Self.certificate($0, matches: leafKey) }
        guard !candidates.isEmpty else { return }
        guard let authorityKey = key(tag: caTag),
              let authority = caCertificate(),
              Self.certificate(authority, matches: authorityKey) else {
            // The leaf key identifies candidates, but only the original matching CA can prove which certificates
            // Flowlight generated. Keep every key and public file so restoring that CA can make cleanup retryable.
            throw InspectionError.native(
                "the local certificate authority is unavailable, so legacy generated certificates cannot be removed safely"
            )
        }
        for certificate in candidates where Self.certificate(certificate, wasSignedBy: authority) {
            guard let reference = try persistentReference(for: certificate) else { continue }
            let der = SecCertificateCopyData(certificate) as Data
            _ = try deleteCertificate(persistentReference: reference, expectedDER: der)
        }
    }

    private func deleteCertificate(der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw InspectionError.native("a recorded generated leaf certificate is malformed")
        }
        guard let reference = try persistentReference(for: certificate) else { return }
        _ = try deleteCertificate(persistentReference: reference, expectedDER: der)
    }

    private func persistentReference(for certificate: SecCertificate) throws -> Data? {
        var persistentResult: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &persistentResult)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let persistentResult,
              CFGetTypeID(persistentResult) == CFDataGetTypeID() else {
            throw InspectionError.native(Self.message(
                status,
                fallback: "a generated leaf certificate reference could not be recovered"
            ))
        }
        return unsafeBitCast(persistentResult, to: CFData.self) as Data
    }

    /// Returns false without deleting when a stale reference is absent or resolves to bytes other than the manifest's
    /// recorded DER. The caller then performs an exact DER lookup, so a migrated reference cannot leak our leaf and a
    /// reused reference can never delete an unrelated certificate.
    private func deleteCertificate(persistentReference: Data, expectedDER: Data) throws -> Bool {
        var stored: CFTypeRef?
        let lookup: [String: Any] = [
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnRef as String: true,
        ]
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &stored)
        if lookupStatus == errSecItemNotFound { return false }
        guard lookupStatus == errSecSuccess, let stored,
              CFGetTypeID(stored) == SecCertificateGetTypeID() else {
            throw InspectionError.native(Self.message(
                lookupStatus,
                fallback: "a generated leaf certificate could not be found for cleanup"
            ))
        }
        let certificate = unsafeBitCast(stored, to: SecCertificate.self)
        guard SecCertificateCopyData(certificate) as Data == expectedDER else { return false }
        let deleteStatus = SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ] as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw InspectionError.native(Self.message(
                deleteStatus,
                fallback: "a generated leaf certificate could not be removed"
            ))
        }
        return true
    }

    private func writeBundle() throws {
        try expectedBundle().write(to: bundleURL, atomically: true, encoding: .utf8)
        bundleValidationLock.lock()
        cachedBundleValidation = nil
        bundleValidationLock.unlock()
    }

    private func expectedBundle() throws -> String {
        guard var roots = try? String(contentsOfFile: "/etc/ssl/cert.pem", encoding: .utf8),
              !roots.isEmpty else {
            throw InspectionError.native("the macOS system trust store could not be read")
        }
        if !roots.hasSuffix("\n") { roots += "\n" }
        roots += try String(contentsOf: caCertificateURL, encoding: .utf8)
        return roots
    }

    private func pem(_ data: Data, label: String) -> String {
        let body = data.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }

    private static func message(_ status: OSStatus, fallback: String) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? fallback
    }
}

private enum X509 {
    struct Name {
        var commonName: String
        var organization: String?
    }

    static let caExtensions: [Data] = [
        ext("2.5.29.19", critical: true, value: DER.sequence([
            DER.boolean(true), DER.integer(Data([0]))
        ])),
        ext("2.5.29.15", critical: true, value: DER.bitString(Data([0x06]), unusedBits: 1)),
    ]

    static func leafExtensions(host: String) throws -> [Data] {
        let generalName: Data
        if let bytes = ipBytes(host) {
            generalName = DER.raw(tag: 0x87, content: bytes)
        } else {
            guard host.utf8.allSatisfy({ $0 < 0x80 }) else {
                throw InspectionError.native("the requested DNS name is not an ASCII host")
            }
            generalName = DER.raw(tag: 0x82, content: Data(host.utf8))
        }
        return [
            ext("2.5.29.19", critical: true, value: DER.sequence([])),
            ext("2.5.29.15", critical: true, value: DER.bitString(Data([0x80]), unusedBits: 7)),
            ext("2.5.29.37", critical: false, value: DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])),
            ext("2.5.29.17", critical: false, value: DER.sequence([generalName])),
        ]
    }

    static func certificate(
        subject: Name,
        issuer: Name,
        publicKey: SecKey,
        signingKey: SecKey,
        validFor lifetime: TimeInterval,
        extensions: [Data]
    ) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw InspectionError.native(error?.takeRetainedValue().localizedDescription ?? "public-key export failed")
        }
        let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        let publicKeyAlgorithm = DER.sequence([
            DER.oid("1.2.840.10045.2.1"),
            DER.oid("1.2.840.10045.3.1.7"),
        ])
        let now = Date().addingTimeInterval(-300)
        let tbs = DER.sequence([
            DER.explicit(tag: 0, DER.integer(Data([2]))),
            DER.integer(randomSerial()),
            signatureAlgorithm,
            encodedName(issuer),
            DER.sequence([DER.time(now), DER.time(now.addingTimeInterval(lifetime))]),
            encodedName(subject),
            DER.sequence([publicKeyAlgorithm, DER.bitString(publicBytes, unusedBits: 0)]),
            DER.explicit(tag: 3, DER.sequence(extensions)),
        ])
        guard let signature = SecKeyCreateSignature(
            signingKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw InspectionError.native(error?.takeRetainedValue().localizedDescription ?? "certificate signing failed")
        }
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString(signature, unusedBits: 0)])
    }

    static func name(from certificate: SecCertificate) throws -> Name {
        guard let summary = SecCertificateCopySubjectSummary(certificate) as String?, !summary.isEmpty else {
            throw InspectionError.native("the CA subject could not be read")
        }
        return Name(commonName: summary, organization: "Flowlight (local, this Mac only)")
    }

    private static func encodedName(_ name: Name) -> Data {
        var rdns: [Data] = []
        if let organization = name.organization {
            rdns.append(DER.set([DER.sequence([DER.oid("2.5.4.10"), DER.utf8(organization)])]))
        }
        rdns.append(DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8(name.commonName)])]))
        return DER.sequence(rdns)
    }

    private static func ext(_ oid: String, critical: Bool, value: Data) -> Data {
        var fields = [DER.oid(oid)]
        if critical { fields.append(DER.boolean(true)) }
        fields.append(DER.octetString(value))
        return DER.sequence(fields)
    }

    private static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { bytes = Array(UUID().uuidString.utf8.prefix(16)) }
        bytes[0] &= 0x7f
        if bytes.allSatisfy({ $0 == 0 }) { bytes[bytes.count - 1] = 1 }
        return Data(bytes)
    }

    private static func ipBytes(_ host: String) -> Data? {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: &v4) { Data($0) }
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: &v6) { Data($0) }
        }
        return nil
    }
}

private enum DER {
    static func raw(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func sequence(_ values: [Data]) -> Data { raw(tag: 0x30, content: values.reduce(into: Data(), { $0.append($1) })) }
    static func set(_ values: [Data]) -> Data { raw(tag: 0x31, content: values.reduce(into: Data(), { $0.append($1) })) }
    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return raw(tag: 0x02, content: value)
    }
    static func boolean(_ value: Bool) -> Data { raw(tag: 0x01, content: Data([value ? 0xff : 0])) }
    static func octetString(_ value: Data) -> Data { raw(tag: 0x04, content: value) }
    static func bitString(_ value: Data, unusedBits: UInt8) -> Data {
        raw(tag: 0x03, content: Data([unusedBits]) + value)
    }
    static func utf8(_ value: String) -> Data { raw(tag: 0x0c, content: Data(value.utf8)) }
    static func explicit(tag: UInt8, _ value: Data) -> Data { raw(tag: 0xa0 | tag, content: value) }

    static func oid(_ value: String) -> Data {
        let arcs = value.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2 && arcs[0] <= 2)
        var bytes = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var encoded = [UInt8(arc & 0x7f)]
            var rest = arc >> 7
            while rest > 0 {
                encoded.insert(UInt8(rest & 0x7f) | 0x80, at: 0)
                rest >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return raw(tag: 0x06, content: Data(bytes))
    }

    static func time(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return raw(tag: year < 2050 ? 0x17 : 0x18, content: Data(formatter.string(from: date).utf8))
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
#endif
