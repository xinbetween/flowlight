import XCTest
@testable import Flowlight

/// Relaunching through the proxy assumed the thing that starts an agent is a terminal somebody typed in. On a
/// Mac where agents are started by a supervisor, that assumption made the feature do nothing visible: Flowlight
/// opened a window with the right environment, and the next agent was still started by a daemon that had never
/// seen it.
///
/// The reported setup, from `ps`:
///
///     Ghostty → zsh → herdr → herdr server → zsh → claude --resume …
///
/// Walking up from `claude`, the first non-shell ancestor is `herdr server` — not Ghostty. That is the process
/// whose environment the next agent inherits, and these pin that it is the one found.
final class AgentLauncherTests: XCTestCase {

    private typealias Entry = (pid: Int32, name: String, bundleID: String, argv: [String])

    private func entry(_ pid: Int32, _ name: String, _ bundleID: String = "", _ argv: [String] = []) -> Entry {
        (pid: pid, name: name, bundleID: bundleID, argv: argv.isEmpty ? [name] : argv)
    }

    // MARK: The reported setup

    func testTheSupervisorIsFoundRatherThanTheTerminalAboveIt() {
        let chain = [entry(23900, "-zsh"),
                     entry(23361, "herdr", "", ["/Users/x/.local/bin/herdr", "server"]),
                     entry(23360, "herdr"),
                     entry(1700, "-zsh"),
                     entry(1617, "ghostty", "com.mitchellh.ghostty")]
        let found = AgentLauncher.find(ancestors: chain)
        XCTAssertEqual(found?.pid, 23361, "the daemon that spawns the agent shells, not the terminal above it")
        XCTAssertEqual(found?.kind, .supervisor)
        XCTAssertTrue(found!.restartEndsSessions)
    }

    /// Its own argv, because `herdr server` is not `herdr` — restarting the bare name would start something
    /// that does not spawn agents.
    func testASupervisorIsRestartedWithTheArgumentsItIsRunning() {
        let chain = [entry(1, "-zsh"),
                     entry(2, "herdr", "", ["/Users/x/.local/bin/herdr", "server"])]
        let launcher = AgentLauncher.find(ancestors: chain)!
        XCTAssertEqual(AgentLauncher.restartCommand(launcher), ["/Users/x/.local/bin/herdr", "server"])
    }

    // MARK: Terminals still behave the old way

    func testATerminalIsRecognisedSoTheOldBehaviourStillApplies() {
        let chain = [entry(10, "-zsh"), entry(11, "ghostty", "com.mitchellh.ghostty")]
        let found = AgentLauncher.find(ancestors: chain)
        XCTAssertEqual(found?.kind, .terminal)
        XCTAssertFalse(found!.restartEndsSessions, "opening a new window ends nothing")
        XCTAssertNil(AgentLauncher.restartCommand(found!), "a terminal is not restarted; a window is opened")
    }

    func testTerminalAppIsRecognisedByBundleIdentifier() {
        XCTAssertEqual(AgentLauncher.kind(name: "Terminal", bundleID: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(AgentLauncher.kind(name: "iTerm2", bundleID: "com.googlecode.iterm2"), .terminal)
    }

    /// A terminal launched from a shell has no bundle identifier in the process table, so the name has to be
    /// enough on its own.
    func testTerminalIsRecognisedByNameWhenNoBundleIdentifierIsKnown() {
        XCTAssertEqual(AgentLauncher.kind(name: "ghostty", bundleID: ""), .terminal)
        XCTAssertEqual(AgentLauncher.kind(name: "wezterm-gui", bundleID: ""), .terminal)
        XCTAssertEqual(AgentLauncher.kind(name: "kitty", bundleID: ""), .terminal)
    }

    // MARK: Shells

    func testShellsAreSteppedOverHoweverManyThereAre() {
        let chain = [entry(1, "zsh"), entry(2, "-bash"), entry(3, "sh"), entry(4, "fish"),
                     entry(5, "tmux", "", ["tmux", "-CC"])]
        XCTAssertEqual(AgentLauncher.find(ancestors: chain)?.name, "tmux")
    }

    /// A login shell arrives as `-zsh`. Treating the leading dash as part of the name made the shell itself
    /// look like a supervisor, which would have offered to restart the user's login shell.
    func testALoginShellIsStillAShell() {
        XCTAssertEqual(AgentLauncher.kind(name: "-zsh", bundleID: ""), .shell)
        XCTAssertEqual(AgentLauncher.kind(name: "login", bundleID: ""), .shell)
    }

    /// From the reported machine, where the chain contained `-/bin/zsh` and `/usr/bin/login` — a leading dash
    /// and a full path at once. Handling only one of the two made a shell read as a supervisor, and the feature
    /// would have offered to restart the user's login shell.
    func testAShellWithBothADashAndAPathIsStillAShell() {
        XCTAssertEqual(AgentLauncher.kind(name: "-/bin/zsh", bundleID: ""), .shell)
        XCTAssertEqual(AgentLauncher.kind(name: "/usr/bin/login", bundleID: ""), .shell)
        XCTAssertEqual(AgentLauncher.kind(name: "/bin/bash", bundleID: ""), .shell)
    }

    /// The same normalisation must not swallow a supervisor that happens to be given as a path.
    func testASupervisorGivenAsAPathIsStillASupervisor() {
        XCTAssertEqual(AgentLauncher.kind(name: "/Users/x/.local/bin/herdr", bundleID: ""), .supervisor)
    }

    func testNothingButShellsFindsNoLauncher() {
        XCTAssertNil(AgentLauncher.find(ancestors: [entry(1, "zsh"), entry(2, "-bash")]))
    }

    func testAnEmptyChainFindsNoLauncher() {
        XCTAssertNil(AgentLauncher.find(ancestors: []))
    }

    // MARK: Other supervisors with the same shape

    func testAnEditorHostIsASupervisorToo() {
        // Codex under VS Code: the extension host outlives any window and spawns the agent the same way.
        let chain = [entry(4303, "codex", "", ["codex", "app-server"]),
                     entry(4018, "Code Helper (Plugin)", "com.microsoft.VSCode")]
        let found = AgentLauncher.find(ancestors: chain)
        XCTAssertEqual(found?.pid, 4303)
        XCTAssertEqual(found?.kind, .supervisor)
    }

    func testASessionManagerIsASupervisor() {
        for name in ["tmux", "zellij", "screen", "herdr", "supervisord"] {
            XCTAssertEqual(AgentLauncher.kind(name: name, bundleID: ""), .supervisor, name)
        }
    }
}
