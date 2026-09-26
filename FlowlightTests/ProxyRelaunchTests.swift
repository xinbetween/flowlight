import XCTest
@testable import Flowlight

@MainActor
final class ProxyRelaunchTests: XCTestCase {
    /// An app is relaunched as an app, from the bundle rather than from the executable inside it: macOS applies
    /// an environment to `Cursor.app`, not to `Cursor.app/Contents/MacOS/Cursor`.
    func testAnAppIsFoundFromTheExecutableInsideIt() {
        let target = ProxyRelaunch.target(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor",
                                          appPath: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        XCTAssertEqual(target, .app(URL(fileURLWithPath: "/Applications/Cursor.app")))
    }

    /// The path a versioned install runs from names one release. Starting Claude Code again should mean the
    /// `claude` on PATH — what someone would get by typing it — not the build that happened to be running.
    func testAKnownToolIsStartedByNameNotByItsVersionedPath() {
        let target = ProxyRelaunch.target(bundleID: "claude", name: "Claude Code",
                                          appPath: "/Users/x/.local/share/claude/versions/2.1.283")
        XCTAssertEqual(target, .commandLine("claude"))
    }

    /// Anything else is started from where it was seen running, which is all we know about it.
    func testAnUnknownToolIsStartedFromItsPath() {
        let target = ProxyRelaunch.target(bundleID: "example-agent", name: "example-agent",
                                          appPath: "/usr/local/bin/example-agent")
        XCTAssertEqual(target, .commandLine("/usr/local/bin/example-agent"))
    }

    /// An agent Flowlight only ever saw as traffic has nothing to start. The button has to be absent rather
    /// than present and broken, so this answers nil instead of guessing at a name.
    func testNothingToStartIsNil() {
        XCTAssertNil(ProxyRelaunch.target(bundleID: "unknown.thing", name: "unknown.thing", appPath: ""))
    }

    /// The command and the certificate paths are written into a shell script. A quote in either would end the
    /// string and run whatever followed, so quoting is the difference between a launcher and an exploit.
    func testValuesAreQuotedForTheShell() {
        XCTAssertEqual(ProxyRelaunch.shellQuoted("/usr/local/bin/agent"), "'/usr/local/bin/agent'")
        XCTAssertEqual(ProxyRelaunch.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(ProxyRelaunch.shellQuoted("; rm -rf /"), "'; rm -rf /'")
    }

    /// Chromium reads none of the proxy variables — it has its own network stack — so an Electron agent needs
    /// the flag as well. Passing it to something that isn't Chromium can stop it starting, so the list is
    /// explicit rather than a guess.
    func testOnlyKnownChromiumAppsGetTheFlag() {
        XCTAssertTrue(ProxyRelaunch.chromiumBundleIDs.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(ProxyRelaunch.chromiumBundleIDs.contains("com.apple.Safari"))
    }
}
