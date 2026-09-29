import Foundation

/// What actually starts an agent, found by walking up from a running one.
///
/// Relaunching an agent through the proxy rests on one fact: the proxy variables are read once, at launch, by
/// whatever started the process. Until now Flowlight assumed that was a terminal a person typed in, and opened
/// one. Increasingly it is not. Agents are started by a supervisor that outlives any window — `herdr server`,
/// a `tmux` or `zellij` server, an editor's extension host — and a fresh terminal with the right environment is
/// then a shell that will never be any agent's parent. The relaunch appeared to work and changed nothing.
///
/// So the question is not "which terminal is this" but "which process will start the *next* agent". That is the
/// first ancestor above the shells, and what to do about it depends on what it turns out to be.
enum AgentLauncher {

    /// Shells are never the answer. They are what a terminal or a supervisor runs, and a new one is created for
    /// every session, so restarting one changes nothing beyond itself.
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "-zsh",
                                          "-bash", "-sh", "-fish", "login"]

    /// Terminal emulators, by bundle identifier and by executable name. These can be relaunched the old way —
    /// a new window with the environment exported is genuinely where the next agent will be typed.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "co.zeit.hyper", "com.termius-dmg.mac", "org.tabby",
    ]
    static let terminalNames: Set<String> = ["ghostty", "wezterm-gui", "wezterm", "kitty", "alacritty", "Warp",
                                             "Terminal", "iTerm2", "Hyper", "Tabby"]

    /// What one ancestor is, as far as this decision is concerned.
    enum Kind: Equatable, Sendable {
        /// A shell. Stepped over.
        case shell
        /// A terminal emulator. A new window here really will host the next agent.
        case terminal
        /// Something else that is starting agents: a session manager, a daemon, an editor's host process.
        /// Restarting it is what puts the environment where its children will inherit it.
        case supervisor
    }

    /// The process to act on, and what acting on it means.
    struct Launcher: Equatable, Sendable {
        var pid: Int32
        var name: String
        var bundleID: String
        var kind: Kind
        /// The command line, so a supervisor can be started again the way it was.
        var argv: [String]

        /// A supervisor's children are the agents, so restarting it ends whatever it is currently running.
        /// Saying that plainly is the whole difference between a useful button and a destructive surprise.
        var restartEndsSessions: Bool { kind == .supervisor }
    }

    static func kind(name: String, bundleID: String) -> Kind {
        // A login shell is `-zsh`, and `ps` may give the whole path — the reported Mac shows `-/bin/zsh` and
        // `/usr/bin/login` in the same chain. Strip the dash, then take the last path component: missing either
        // makes a shell look like a supervisor, and Flowlight would offer to restart someone's login shell.
        let undashed = name.hasPrefix("-") ? String(name.dropFirst()) : name
        let bare = undashed.split(separator: "/").last.map(String.init) ?? undashed
        if shellNames.contains(name) || shellNames.contains(undashed) || shellNames.contains(bare) { return .shell }
        if terminalBundleIDs.contains(bundleID) { return .terminal }
        if terminalNames.contains(bare) || terminalNames.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) {
            return .terminal
        }
        return .supervisor
    }

    /// Walks up from a running agent to the process that will start the next one.
    ///
    /// - Parameter ancestors: the chain from the agent upwards, nearest first, as `(pid, name, bundleID, argv)`.
    ///   Passed in rather than read here so the decision is testable without a process tree.
    ///
    /// Shells are skipped. The first thing above them decides: a terminal means the old behaviour is right, and
    /// anything else is a supervisor whose environment its children will inherit.
    static func find(ancestors: [(pid: Int32, name: String, bundleID: String, argv: [String])]) -> Launcher? {
        for entry in ancestors {
            let kind = kind(name: entry.name, bundleID: entry.bundleID)
            if kind == .shell { continue }
            return Launcher(pid: entry.pid, name: entry.name, bundleID: entry.bundleID, kind: kind, argv: entry.argv)
        }
        return nil
    }

    /// The command that starts a supervisor again, from the argv it is running with.
    ///
    /// Its own argv is used rather than a guess at a canonical invocation: `herdr server` is not `herdr`, and a
    /// session manager started with a config path started that way for a reason. The first element is the
    /// executable as the kernel recorded it.
    static func restartCommand(_ launcher: Launcher) -> [String]? {
        guard launcher.kind == .supervisor, !launcher.argv.isEmpty else { return nil }
        return launcher.argv
    }
}
