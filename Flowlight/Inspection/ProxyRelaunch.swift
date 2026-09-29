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

    // MARK: What starts this agent

    /// Walks up from a running agent to the process that will start the next one.
    ///
    /// Reading the chain here rather than in `AgentLauncher` keeps the decision testable without a process
    /// tree; this half is only the sysctl walk that feeds it.
    /// A live process for this agent, to walk up from.
    ///
    /// The traffic tables carry a pid, but by the time someone reads a hint the flow that produced it may be
    /// long gone, and a dead pid answers nothing about what is starting agents now. Asking the process table
    /// for a current one keeps the question in the present tense.
    static func runningPID(bundleID: String, name: String) -> Int32? {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: capacity * 2)
        let written = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.size * pids.count))
        guard written > 0 else { return nil }
        let lookup = ProcessLookup()
        for pid in pids.prefix(Int(written)) where pid > 1 {
            let info = lookup.info(pid: pid)
            if !bundleID.isEmpty, info.bundleID == bundleID { return pid }
            if !name.isEmpty, info.name.caseInsensitiveCompare(name) == .orderedSame { return pid }
        }
        return nil
    }

    static func launcher(forAgentPID pid: Int32) -> AgentLauncher.Launcher? {
        var chain: [(pid: Int32, name: String, bundleID: String, argv: [String])] = []
        var current = pid
        // Eight is past any real nesting of shell inside session manager inside terminal, and stops a cycle in
        // a corrupt process table from spinning.
        for _ in 0..<8 {
            guard let snapshot = SystemProcessTable.shared.snapshot(current), snapshot.ppid > 1,
                  snapshot.ppid != current, let parent = SystemProcessTable.shared.snapshot(snapshot.ppid) else { break }
            chain.append((pid: parent.pid, name: parent.name, bundleID: parent.bundleID, argv: parent.argv))
            current = parent.pid
        }
        return AgentLauncher.find(ancestors: chain)
    }

    /// Starts a supervisor again with the proxy environment, so the agents it spawns inherit it.
    ///
    /// This is the case a new terminal window could never fix: the agents are started by something that
    /// outlives any window, and the environment has to be put where *it* will pass it on. Its own argv is
    /// reused, because `herdr server` is not `herdr`.
    ///
    /// The caller is responsible for having said that this ends the sessions the supervisor is running. It
    /// does, unavoidably — the whole point is that the replacement starts with a different environment.
    static func restartSupervisor(_ launcher: AgentLauncher.Launcher,
                                  environment: [String: String]) -> Error? {
        guard let command = AgentLauncher.restartCommand(launcher) else {
            return Failure.couldNotStart(L("%@ can't be started again automatically.", launcher.name))
        }
        // SIGTERM rather than SIGKILL: a session manager asked to stop gets to write its state out, and one
        // that ignores the request is a thing to report rather than to override.
        if kill(launcher.pid, SIGTERM) != 0, errno != ESRCH {
            return Failure.quitRefused(launcher.name)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        do {
            try process.run()
            return nil
        } catch {
            return Failure.couldNotStart(error.localizedDescription)
        }
    }

    /// A Terminal window with the environment exported and the agent already running in it. The shell is left
    /// in place afterwards (`exec` replaces it only for the agent's lifetime, so the window closes with the
    /// agent unless the agent exits, which is the same shape as typing the command yourself).
    /// The terminal to open a relaunch script in: the one this agent was started from, if it was started from
    /// one at all. Nil falls back to whatever handles `.command`.
    static var preferredTerminal: URL?

    /// Remembers the terminal an agent came from, so the next relaunch opens there rather than in Terminal.app.
    static func rememberTerminal(_ launcher: AgentLauncher.Launcher?) {
        guard let launcher, launcher.kind == .terminal, !launcher.bundleID.isEmpty else { return }
        preferredTerminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: launcher.bundleID)
    }

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
            // Opened in the terminal the agent was actually started from, when that is known. Handing the
            // script to the default handler sent everyone to Terminal.app, which for someone who lives in
            // Ghostty or iTerm is a window in the wrong application with the right environment in it. Every
            // terminal worth naming declares `.command` as a document type, so this is the same open with a
            // destination.
            if let terminal = preferredTerminal {
                NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(script)
            }
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
