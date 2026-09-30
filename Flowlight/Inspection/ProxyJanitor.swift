import Foundation

/// The crash backstop for "always monitor".
///
/// When Flowlight persists proxy routing into an agent's settings file (`SettingsEnforcer`), that file points the
/// agent at `127.0.0.1:<port>`. While Flowlight is running this is safe — it strips the routing the moment the proxy
/// stops or the app quits. A crash runs none of that, and the proxy dies with the app, so the file would be left
/// pointing at a dead port and the agent could no longer reach its API.
///
/// This is a tiny `launchctl` agent that closes only that gap. Every 30 seconds it checks: is Flowlight gone, is
/// something still enforced (a manifest present), and is the port actually dead? Only then does it move the staged
/// clean copy back over the live file — a plain `mv`, no JSON parsing — and drop the manifest. A clean quit already
/// removes the manifest, so "app gone and manifest present" only ever means a crash; the port check is a belt on top.
enum ProxyJanitor {
    static let label = "com.flowlight.janitor"

    /// The recovery logic, as a self-contained shell program. Also run directly by the tests against a temporary
    /// manifest, so the behavior the crash path depends on is verified without waiting on `launchd` or killing the
    /// app. `FL_MANIFEST` names the manifest; `FL_APP_RUNNING` is `auto` in production (checked with `pgrep`) and
    /// forced to `0`/`1` by tests that can't stage a real process.
    static let restoreScript = #"""
    manifest="${FL_MANIFEST:?}"
    [ -f "$manifest" ] || exit 0
    case "${FL_APP_RUNNING:-auto}" in
      auto) pgrep -x Flowlight >/dev/null 2>&1 && exit 0 ;;
      1) exit 0 ;;
    esac
    while IFS=$'\t' read -r port live clean; do
      [ -n "$port" ] || continue
      # A connection that succeeds means the proxy is still up; leave the file pointing at it.
      if bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then continue; fi
      if [ "$clean" = "DELETE" ]; then
        rm -f "$live"
      elif [ -f "$clean" ]; then
        mv -f "$clean" "$live"
      fi
    done < "$manifest"
    rm -f "$manifest"
    """#

    private static var launchAgentsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL { launchAgentsDir.appendingPathComponent("\(label).plist") }

    /// The launchd job description, pinned to this Mac's manifest path so the script needn't rely on `$HOME`.
    static func plist(manifestPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/bash", "-c", restoreScript],
            "EnvironmentVariables": ["FL_MANIFEST": manifestPath],
            "RunAtLoad": true,
            "StartInterval": 30,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
    }

    /// Write the agent and load it. Idempotent: reloads if it was already installed, so a changed manifest path or
    /// script takes effect. Runs in the user domain, so it needs no administrator.
    static func install(manifestPath: String) {
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(manifestPath: manifestPath),
                                                          format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch { return }
        let domain = "gui/\(getuid())"
        // Replace any previous copy, then load. bootout on a job that isn't loaded fails harmlessly.
        run(["bootout", "\(domain)/\(label)"])
        run(["bootstrap", domain, plistURL.path])
    }

    /// Unload and remove the agent. Called when nothing is enforced any more.
    static func uninstall() {
        run(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
