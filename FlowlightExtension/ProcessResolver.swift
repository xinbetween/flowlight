import Darwin
import Foundation
import Security

struct ProcessInfoRecord: Sendable {
    var pid: Int32
    var bundleID: String
    var name: String
    var path: String
    var teamID: String?
}

/// Maps a flow's audit token to pid, bundle id, path and signing identity.
final class ProcessResolver: @unchecked Sendable {
    private var cache: [Data: ProcessInfoRecord] = [:]
    private let lock = NSLock()

    func resolve(auditToken: Data?, signingIdentifier: String?) -> ProcessInfoRecord {
        guard let token = auditToken, token.count == MemoryLayout<audit_token_t>.size else {
            return ProcessInfoRecord(pid: -1, bundleID: signingIdentifier ?? "unknown", name: signingIdentifier ?? "unknown", path: "")
        }
        lock.lock()
        if let cached = cache[token] { lock.unlock(); return cached }
        lock.unlock()

        let record = Self.lookup(token: token, signingIdentifier: signingIdentifier)
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        cache[token] = record
        lock.unlock()
        return record
    }

    private static func lookup(token: Data, signingIdentifier: String?) -> ProcessInfoRecord {
        // audit_token_t.val[5] is the pid (what audit_token_to_pid returns).
        let auditToken = token.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        let pid = Int32(bitPattern: auditToken.val.5)

        var path = ""
        var identifier = signingIdentifier
        var teamID: String?

        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var url: CFURL?
                if SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url {
                    path = (url as URL).path
                }
                var info: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                   let dict = info as? [String: Any] {
                    identifier = (dict[kSecCodeInfoIdentifier as String] as? String) ?? identifier
                    teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
                }
            }
        }

        // Code signing can't identify every process (plain command-line tools especially). The extension runs as
        // root, so the executable path is still readable, which gives a name instead of a bare pid.
        if path.isEmpty {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { path = String(cString: buffer) }
        }
        let (bundleID, name) = bundleInfo(path: path, fallbackIdentifier: identifier, pid: pid)
        return ProcessInfoRecord(pid: pid, bundleID: bundleID, name: name, path: path, teamID: teamID)
    }

    /// Prefer the enclosing .app bundle so helpers roll up under their app.
    static func bundleInfo(path: String, fallbackIdentifier: String?, pid: Int32) -> (String, String) {
        let components = path.split(separator: "/")
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = "/" + components[...appIndex].joined(separator: "/")
            let name = String(components[appIndex].dropLast(4))
            if let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier { return (id, name) }
            return (fallbackIdentifier ?? name, name)
        }
        let name = components.last.map(String.init) ?? fallbackIdentifier ?? "pid \(pid)"
        return (fallbackIdentifier ?? name, name)
    }
}
