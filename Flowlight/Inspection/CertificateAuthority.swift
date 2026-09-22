import CryptoKit
import Foundation
import Security

enum InspectionError: LocalizedError {
    case openssl(String), importFailed(OSStatus), trust(String)

    var errorDescription: String? {
        switch self {
        case .openssl(let detail): return "Couldn't create a certificate: \(detail)"
        case .importFailed(let status): return "Couldn't load a certificate (error \(status))."
        case .trust(let detail): return detail
        }
    }
}

/// The local certificate authority behind HTTPS inspection.
///
/// It's created on this Mac the first time inspection is turned on and never leaves it. The CA key signs a short-lived
/// certificate for each host Flowlight inspects; one shared leaf key is used for all of them. Nothing is trusted until
/// the user approves `trust()` (macOS asks for their password), and `remove()` deletes the trust setting and every key.
/// Certificates are made with the LibreSSL `openssl` that ships with macOS.
final class CertificateAuthority: @unchecked Sendable {
    static let shared = CertificateAuthority()

    let directory: URL
    private let lock = NSLock()
    private var identities: [String: SecIdentity] = [:]
    private static let p12Password = "flowlight"

    init(directory: URL = CertificateAuthority.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flowlight/Inspection", isDirectory: true)
    }

    var caCertificateURL: URL { directory.appendingPathComponent("flowlight-ca.pem") }
    private var caKeyURL: URL { directory.appendingPathComponent("flowlight-ca.key") }
    private var leafKeyURL: URL { directory.appendingPathComponent("leaf.key") }
    /// System roots plus the Flowlight CA, for command-line tools that read a PEM bundle (curl, Python, Node, Git).
    var bundleURL: URL { directory.appendingPathComponent("ca-bundle.pem") }

    var exists: Bool { FileManager.default.fileExists(atPath: caCertificateURL.path) && FileManager.default.fileExists(atPath: caKeyURL.path) }

    /// Creates the CA and the shared leaf key if they don't exist yet.
    func ensure() throws {
        lock.lock(); defer { lock.unlock() }
        if exists { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tag = String(UUID().uuidString.prefix(8))
        let config = directory.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Flowlight Inspection CA \(tag)
        O = Flowlight (local, this Mac only)
        [v3_ca]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: config) }
        try Self.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", caKeyURL.path])
        try Self.openssl(["req", "-x509", "-new", "-key", caKeyURL.path, "-sha256", "-days", "3650",
                          "-config", config.path, "-extensions", "v3_ca", "-out", caCertificateURL.path])
        try Self.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leafKeyURL.path])
        for url in [caKeyURL, leafKeyURL] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try writeBundle()
    }

    private func writeBundle() throws {
        var pem = (try? String(contentsOfFile: "/etc/ssl/cert.pem", encoding: .utf8)) ?? ""
        if !pem.hasSuffix("\n") { pem += "\n" }
        pem += try String(contentsOf: caCertificateURL, encoding: .utf8)
        try pem.write(to: bundleURL, atomically: true, encoding: .utf8)
    }

    /// A TLS server identity for `host`, signed by the CA. Cached in memory for the life of the app.
    func identity(for host: String) throws -> SecIdentity {
        let name = host.lowercased()
        lock.lock()
        if let cached = identities[name] { lock.unlock(); return cached }
        lock.unlock()
        try ensure()

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-leaf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let isIP = name.contains(":") || name.allSatisfy { $0.isNumber || $0 == "." }
        let ext = work.appendingPathComponent("leaf.cnf")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = \(Self.configSafe(name))
        [v3_leaf]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature
        extendedKeyUsage = serverAuth
        subjectAltName = \(isIP ? "IP" : "DNS"):\(Self.configSafe(name))
        """.write(to: ext, atomically: true, encoding: .utf8)
        let csr = work.appendingPathComponent("leaf.csr"), pem = work.appendingPathComponent("leaf.pem")
        let p12 = work.appendingPathComponent("leaf.p12")
        try Self.openssl(["req", "-new", "-key", leafKeyURL.path, "-config", ext.path, "-out", csr.path])
        // Apple rejects TLS server certificates valid for more than 398 days.
        try Self.openssl(["x509", "-req", "-in", csr.path, "-CA", caCertificateURL.path, "-CAkey", caKeyURL.path,
                          "-set_serial", String(UInt64.random(in: 1...UInt64(Int64.max))), "-days", "397", "-sha256",
                          "-extfile", ext.path, "-extensions", "v3_leaf", "-out", pem.path])
        try Self.openssl(["pkcs12", "-export", "-inkey", leafKeyURL.path, "-in", pem.path, "-certfile", caCertificateURL.path,
                          "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
                          "-passout", "pass:\(Self.p12Password)", "-out", p12.path])
        let identity = try Self.importIdentity(Data(contentsOf: p12))
        lock.lock(); identities[name] = identity; lock.unlock()
        return identity
    }

    /// Imports a PKCS #12 blob into memory only; nothing is added to a keychain.
    static func importIdentity(_ data: Data) throws -> SecIdentity {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String] else { throw InspectionError.importFailed(status) }
        return value as! SecIdentity
    }

    // MARK: Trust

    private func caCertificate() -> SecCertificate? {
        guard let pem = try? String(contentsOf: caCertificateURL, encoding: .utf8) else { return nil }
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// Whether the user has marked the Flowlight CA as trusted for this account.
    var isTrusted: Bool {
        guard let cert = caCertificate() else { return false }
        var settings: CFArray?
        return SecTrustSettingsCopyTrustSettings(cert, .user, &settings) == errSecSuccess
    }

    /// SHA-1 fingerprint, as the `security` tool prints it.
    var fingerprint: String? {
        guard let cert = caCertificate() else { return nil }
        let der = SecCertificateCopyData(cert) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// Adds the CA to the login keychain and trusts it for TLS. macOS asks for the user's password.
    func trust() throws {
        try ensure()
        let keychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path
        let result = Self.run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain, caCertificateURL.path])
        guard result.status == 0 else {
            throw InspectionError.trust(result.output.contains("authorization") || result.output.contains("canceled")
                                        ? "Trust wasn't granted." : "Couldn't trust the certificate: \(result.output)")
        }
    }

    /// Removes the trust setting and the certificate from the keychain, and deletes every key and certificate on disk.
    func remove() {
        if exists {
            _ = Self.run("/usr/bin/security", ["remove-trusted-cert", caCertificateURL.path])
            if let fingerprint {
                _ = Self.run("/usr/bin/security", ["delete-certificate", "-Z", fingerprint])
            }
        }
        lock.lock(); identities.removeAll(); lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// Hostnames come from untrusted clients; keep only characters valid in a DNS name or IP literal.
    static func configSafe(_ host: String) -> String {
        String(host.filter { $0.isLetter || $0.isNumber || "-.:_*".contains($0) }.prefix(253))
    }

    private static func openssl(_ arguments: [String]) throws {
        let result = run("/usr/bin/openssl", arguments)
        guard result.status == 0 else { throw InspectionError.openssl(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
