import AppKit
import Foundation

/// Starting an agent again with its traffic pointed at Flowlight's proxy.
///
/// Inspection can only read what comes through the proxy, and a program decides that when it starts: the proxy
/// variables are read once, at launch, by whatever HTTP client the agent uses. Turning inspection on later
/// cannot reach a process that is already running — which is why an agent can be visibly talking to its
/// provider while the Tool calls tab stays empty, and why the answer was a paragraph asking someone to quit it
/// and start it again from a particular shell.
///
/// This does that part. Both kinds of agent end up with the same environment; only the way they are started
/// differs, because a command-line tool wants a terminal it can be typed at afterwards and an app does not.
@MainActor
enum ProxyRelaunch {
    enum Target: Equatable {
        /// An application bundle. Relaunched by macOS with the environment applied.
        case app(URL)
        /// A command-line tool, started in a Terminal window that stays open for the next command.
        case commandLine(String)
    }

    /// What starting this agent again would mean, or nil when there is nothing we could start.
    ///
    /// The executable path is where the *running* process came from, which for a versioned install is a path
    /// that names one release (`~/.local/share/claude/versions/2.1.283`). A known agent is started by its own
    /// name instead, so the relaunch picks up whatever is on `PATH` — the version someone would get by typing
    /// it themselves, rather than the one that happened to be running.
    static func target(bundleID: String, name: String, appPath: String) -> Target? {
        if let range = appPath.range(of: ".app/") ?? appPath.range(of: ".app", options: .backwards) {
            return .app(URL(fileURLWithPath: String(appPath[..<range.lowerBound]) + ".app"))
        }
        if let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: name),
           let command = known.processNames.sorted().first {
            return .commandLine(command)
        }
        guard !appPath.isEmpty else { return nil }
        return .commandLine(appPath)
    }

    /// Chromium keeps its own network stack, which reads none of the proxy variables — an Electron agent would
    /// launch "inspected" and send its model traffic straight past the proxy. The flag is only passed to the
    /// ones known to take it: an app that doesn't understand it might refuse to start.
    static let chromiumBundleIDs: Set<String> = [
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf",
        "com.microsoft.VSCode",
        "com.electron.ollama",
    ]

    enum Failure: LocalizedError {
        case quitRefused(String)
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .quitRefused(let name): return L("%@ wouldn't quit. Quit it yourself and try again.", name)
            case .couldNotStart(let reason): return reason
            }
        }
    }

    /// Quits the agent if it is running, then starts it again with the proxy set.
    ///
    /// Quitting first is not incidental: two copies of a coding agent racing over the same project is worse
    /// than an uninspected one, and the environment can only be applied to a process that doesn't exist yet.
    /// A refusal to quit — an unsaved document, a modal — is reported rather than forced; `terminate()` asks,
    /// and asking is the right verb for someone else's editor.
    static func relaunch(_ target: Target, bundleID: String, name: String,
                         environment: [String: String], proxyURL: String,
                         completion: @escaping (Error?) -> Void) {
        switch target {
        case .app(let url):
            Task {
                do {
                    try await quit(bundleID: bundleID, name: name)
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.environment = environment
                    configuration.createsNewApplicationInstance = true
                    if chromiumBundleIDs.contains(bundleID) {
                        configuration.arguments = ["--proxy-server=\(proxyURL)"]
                    }
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    completion(nil)
                } catch {
                    completion(error as? Failure ?? Failure.couldNotStart(error.localizedDescription))
                }
            }
        case .commandLine(let command):
            completion(openTerminal(running: command, name: name, environment: environment))
        }
    }

    /// Asks the app to quit and waits for it to go. Ten seconds is long enough for an editor to save its state
    /// and short enough that nobody wonders whether the button did anything.
    private static func quit(bundleID: String, name: String, timeout: TimeInterval = 10) async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard running.allSatisfy(\.isTerminated) else { throw Failure.quitRefused(name) }
    }

    /// A Terminal window with the environment exported and the agent already running in it. The shell is left
    /// in place afterwards (`exec` replaces it only for the agent's lifetime, so the window closes with the
    /// agent unless the agent exits, which is the same shape as typing the command yourself).
    private static func openTerminal(running command: String, name: String,
                                     environment: [String: String]) -> Error? {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("Flowlight Inspected \(name).command")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let exports = environment.sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: "\n")
        let greeting = shellEscaped(L("Flowlight is inspecting %@'s HTTPS from this window.", name))
        let body = """
        #!/bin/sh
        \(exports)
        clear
        echo "\(greeting)"
        \(shellQuoted(command)) "$@"
        exec \(shell) -l
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            return nil
        } catch {
            return Failure.couldNotStart(error.localizedDescription)
        }
    }

    /// Single quotes, with the one escape that needs: a path or a translated greeting must reach the shell as
    /// text, not as something to run.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
