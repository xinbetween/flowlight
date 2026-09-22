import AppKit
import Foundation

/// One-time admin setup that grants this user read access to /dev/bpf* at every boot, the same
/// way Wireshark's ChmodBPF does (a launchd job adds group read permission for `access_bpf`).
enum CaptureAccess {
    static let daemonPlist = "/Library/LaunchDaemons/com.flowlight.bpf-access.plist"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: daemonPlist) }

    /// Another tool (e.g. Wireshark's ChmodBPF) may already provide access.
    static var providedByOtherTool: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/org.wireshark.ChmodBPF.plist")
    }

    enum Action: String { case install, uninstall }

    /// Runs the bundled script as root after the standard macOS admin prompt.
    @MainActor
    static func run(_ action: Action) -> Result<Void, Error> {
        guard let script = Bundle.main.path(forResource: "bpf-access", ofType: "sh") else {
            return .failure(Failure(message: "bpf-access.sh is missing from the app bundle"))
        }
        let source = """
        do shell script "/bin/sh " & quoted form of "\(script)" & " \(action.rawValue) " & quoted form of "\(NSUserName())" with administrator privileges
        """
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            if code == -128 { return .failure(Failure(message: "Cancelled")) }
            return .failure(Failure(message: errorInfo[NSAppleScript.errorMessage] as? String ?? "Setup failed"))
        }
        return .success(())
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
