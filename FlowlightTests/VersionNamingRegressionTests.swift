import XCTest
@testable import Flowlight

/// Claude Code appeared in the database as `2.1.260`, then `2.1.267`, then `2.1.283`.
///
/// The path-based rule in `ProcessNaming` was right and was never reached: `proc_pidpath` fails for a process
/// that has already exited, the caller fell back to `proc_name`, and `proc_name` is the filename — which for an
/// installer that keeps one executable per release is the version. So the agent got a new identity, and a new
/// allowlist and history with it, every time it updated.
final class VersionNamingRegressionTests: XCTestCase {

    func testTheRuleStillHandlesAReadablePath() {
        XCTAssertEqual(ProcessNaming.displayName(path: "/Users/x/.local/share/claude/versions/2.1.283"), "claude")
    }

    /// The case that actually shipped: no path at all, only the filename.
    func testAVersionIsNeverAcceptedAsAnIdentity() {
        XCTAssertNotEqual(ProcessNaming.identity(fromFilename: "2.1.283", pid: 42), "2.1.283")
    }

    func testAVersionFilenameResolvesOnceTheToolHasBeenSeenProperly() {
        ProcessNaming.remember(version: "9.9.99", as: "someagent")
        XCTAssertEqual(ProcessNaming.identity(fromFilename: "9.9.99", pid: 42), "someagent")
    }

    /// Better an obviously incomplete label than a confident wrong one: a row saying `pid 42` invites a second
    /// look, where `2.1.283` looks like an answer and quietly splits the history.
    func testAnUnknownVersionFallsBackToThePidRatherThanTheVersion() {
        XCTAssertEqual(ProcessNaming.identity(fromFilename: "123.456.789", pid: 42), "pid 42")
    }

    func testAnOrdinaryFilenameIsLeftAlone() {
        XCTAssertEqual(ProcessNaming.identity(fromFilename: "python3.13", pid: 42), "python3.13")
        XCTAssertEqual(ProcessNaming.identity(fromFilename: "curl", pid: 42), "curl")
    }

    /// A version must never be learned *as* a name, or one bad reading would teach the memo to repeat itself.
    func testTheMemoRefusesToLearnAVersionAsAName() {
        ProcessNaming.remember(version: "8.8.88", as: "7.7.77")
        XCTAssertNil(ProcessNaming.rememberedName(forVersion: "8.8.88"))
    }
}
