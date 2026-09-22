import AppKit
import Foundation

enum InstallError: LocalizedError {
    case mountFailed, appMissing, wrongApp(String), copyFailed(String), cancelled

    var errorDescription: String? {
        switch self {
        case .mountFailed: return "The disk image couldn't be opened."
        case .appMissing: return "The disk image doesn't contain Flowlight.app."
        case .wrongApp(let detail): return "The downloaded app doesn't look like this update (\(detail)), so it wasn't installed."
        case .copyFailed(let detail): return "Couldn't prepare the update: \(detail)"
        case .cancelled: return "Installation was cancelled."
        }
    }
}

/// Replaces the running copy of Flowlight with the app from a verified disk image, then relaunches it.
///
/// A running app can't be overwritten in place (Finder refuses with "the item is in use"), so the swap is done by a
/// small helper script that waits for this process to exit, moves the new bundle into place (keeping the old one
/// until the move succeeds), and opens it. If the install location isn't writable, for example after a `.pkg`
/// install into a root-owned bundle, macOS asks for an administrator password first.
enum UpdateInstaller {
    /// Where the update goes: the running bundle, unless it's running from a disk image or App Translocation.
    static func installTarget(for bundleURL: URL = Bundle.main.bundleURL) -> URL {
        let path = bundleURL.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return URL(fileURLWithPath: "/Applications/Flowlight.app")
        }
        return bundleURL
    }

    /// Mounts the disk image, copies Flowlight.app to a staging folder and checks it's the expected version.
    static func stage(dmg: URL, expectedVersion: String, bundleID: String?) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            throw InstallError.mountFailed
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let source = mount.appendingPathComponent("Flowlight.app")
        guard let bundle = Bundle(url: source), bundle.executableURL != nil else { throw InstallError.appMissing }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard version == expectedVersion else { throw InstallError.wrongApp("version \(version), expected \(expectedVersion)") }
        if let bundleID, bundle.bundleIdentifier != bundleID {
            throw InstallError.wrongApp("bundle \(bundle.bundleIdentifier ?? "?")")
        }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("Flowlight.app")
        // ditto keeps the code signature, symlinks and extended attributes intact.
        guard run("/usr/bin/ditto", [source.path, staged.path]) == 0 else { throw InstallError.copyFailed("ditto failed") }
        return staged
    }

    /// True when the current user can replace `target` without an administrator password.
    static func canWrite(_ target: URL) -> Bool {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parent) else { return false }
        return !fm.fileExists(atPath: target.path) || fm.isWritableFile(atPath: target.appendingPathComponent("Contents").path)
    }

    /// Starts the helper that swaps the bundle once this process exits. Call `NSApp.terminate` right after.
    static func launchSwap(staged: URL, target: URL) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-install-\(UUID().uuidString).sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let args = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, String(getuid())]

        if canWrite(target) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } else {
            // Runs in the background as root; the script relaunches the app as this user.
            let command = (["/bin/sh"] + args).map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1 &"
            let source = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
                throw cancelled ? InstallError.cancelled : InstallError.copyFailed(error[NSAppleScript.errorMessage] as? String ?? "authorization failed")
            }
        }
    }

    /// $1 pid to wait for, $2 staged app, $3 install target, $4 uid to relaunch as, $5 "--no-launch" (tests only).
    static let swapScript = """
    #!/bin/sh
    pid="$1"; staged="$2"; target="$3"; uid="$4"
    for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    backup="$target.previous"
    rm -rf "$backup"
    [ -e "$target" ] && mv "$target" "$backup"
    if mv "$staged" "$target" 2>/dev/null || /usr/bin/ditto "$staged" "$target"; then
      rm -rf "$backup"
    else
      rm -rf "$target"; [ -e "$backup" ] && mv "$backup" "$target"
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
    rm -rf "$(dirname "$staged")"
    if [ "$5" = "--no-launch" ]; then
      :
    elif [ "$(id -u)" = "0" ]; then
      /bin/launchctl asuser "$uid" /usr/bin/sudo -u "#$uid" /usr/bin/open "$target"
    else
      /usr/bin/open "$target"
    fi
    rm -f "$0"
    """

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
