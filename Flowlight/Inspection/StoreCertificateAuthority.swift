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
    private let caTag: Data
    private let leafTag: Data
    private static let leafCertificateLabel = "Flowlight Inspection Leaf"
    private static let maximumLeafIdentities = 128

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

    var exists: Bool {
        guard FileManager.default.fileExists(atPath: caCertificateURL.path),
              let caKey = key(tag: caTag),
              key(tag: leafTag) != nil,
              let certificate = caCertificate() else {
            return false
        }
        return Self.certificate(certificate, matches: caKey)
    }

    func ensure() throws {
        lock.lock(); defer { lock.unlock() }
        if exists { return }

        // Recover atomically from an interrupted first run. Only app-owned keys and generated leaf certificates are
        // removed; a CA the user imported into their keychain remains theirs to remove.
        deleteKey(tag: caTag)
        deleteKey(tag: leafTag)
        deleteLeafCertificates()
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
        } catch {
            deleteKey(tag: caTag)
            deleteKey(tag: leafTag)
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
            deleteLeafCertificates()
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
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: Self.leafCertificateLabel,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            throw InspectionError.native(Self.message(added, fallback: "the leaf certificate could not be stored"))
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else {
            throw InspectionError.native(Self.message(status, fallback: "the leaf key could not be paired with its certificate"))
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
    func remove() {
        lock.lock(); defer { lock.unlock() }
        identities.removeAll()
        deleteKey(tag: caTag)
        deleteKey(tag: leafTag)
        deleteLeafCertificates()
        try? FileManager.default.removeItem(at: directory)
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

    private static func externalRepresentation(of key: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        if let bytes = SecKeyCopyExternalRepresentation(key, &error) as Data? {
            return bytes
        }
        _ = error?.takeRetainedValue()
        return nil
    }

    private func deleteKey(tag: Data) {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ] as CFDictionary)
    }

    private func deleteLeafCertificates() {
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.leafCertificateLabel,
        ] as CFDictionary)
    }

    private func writeBundle() throws {
        var roots = (try? String(contentsOfFile: "/etc/ssl/cert.pem", encoding: .utf8)) ?? ""
        if !roots.hasSuffix("\n") { roots += "\n" }
        roots += try String(contentsOf: caCertificateURL, encoding: .utf8)
        try roots.write(to: bundleURL, atomically: true, encoding: .utf8)
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
