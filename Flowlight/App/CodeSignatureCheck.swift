import Foundation
import Security

/// Whether a bundle about to replace this one was signed by whoever signed this one.
///
/// The update path checked that the downloaded app called itself Flowlight and carried the expected version —
/// both of which are strings inside the bundle, and neither of which anything signs. A disk image that got
/// past the checksum would have been installed on the strength of its own `Info.plist`, and the installer then
/// removed the quarantine flag, which is the attribute that would have made macOS check the signature on first
/// launch. So the one check that mattered was being skipped and the one macOS would have done was being
/// deleted.
///
/// The team is read from the running app rather than written down here. "Signed by the same team as the copy
/// asking for the update" is the property that actually matters, it needs no constant to fall out of date, and
/// on an unsigned local build — where `teamIdentifier` is nil — it declines to pretend it verified anything.
enum CodeSignatureCheck {
    enum Failure: LocalizedError, Equatable {
        case unreadable(OSStatus)
        case notSigned
        case wrongTeam(found: String?, expected: String)
        case invalid(OSStatus)
        case selfUnknown

        var errorDescription: String? {
            switch self {
            case .unreadable(let status):
                return "The downloaded app's signature couldn't be read (OSStatus \(status))."
            case .notSigned:
                return "The downloaded app isn't signed."
            case .wrongTeam(let found, let expected):
                return "The downloaded app is signed by team \(found ?? "none"), not \(expected)."
            case .invalid(let status):
                return "The downloaded app's signature didn't verify (OSStatus \(status))."
            case .selfUnknown:
                return "This copy of Flowlight isn't signed with a Developer ID, so it can't tell whether an update is."
            }
        }
    }

    /// The Team ID of the running process, or nil when it has no Developer ID — an ad-hoc local build.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Throws unless `url` is a valid signature from `expectedTeam`, checked with the same strictness Gatekeeper
    /// uses: the whole bundle, nested code included, against Apple's anchor.
    static func verify(_ url: URL, expectedTeam: String) throws {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else { throw Failure.unreadable(created) }

        // Signed by Apple's Developer ID anchor, by this team, and every nested binary along with it. The
        // requirement is what makes this more than "has a signature": an attacker's own valid signature fails.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeam)\""
        var securityRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &securityRequirement) == errSecSuccess,
              let securityRequirement else { throw Failure.unreadable(errSecParam) }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, securityRequirement)
        guard status == errSecSuccess else {
            // Say which of the two it was, because "signed by someone else" and "signature damaged" mean very
            // different things to whoever reads the error.
            let found = teamIdentifier(of: staticCode)
            if let found, found != expectedTeam { throw Failure.wrongTeam(found: found, expected: expectedTeam) }
            if found == nil { throw Failure.notSigned }
            throw Failure.invalid(status)
        }
    }
}
