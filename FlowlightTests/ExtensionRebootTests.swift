import XCTest
@testable import Flowlight

/// The upgrade failure that kept coming back, and was never the bug it looked like.
///
/// Reported three times as "the extension stops working after an update". Each time the version check was
/// examined, and each time it was correct. `systemextensionsctl` on the affected Mac showed why:
///
///     com.flowlight.app.filter (0.9.5/21)  [activated enabled]
///     com.flowlight.app.filter (0.9.4/21)  [terminated waiting to uninstall on reboot]
///     com.flowlight.app.filter (0.9.3/21)  [terminated waiting to uninstall on reboot]
///     com.flowlight.app.filter (0.9.1/21)  [terminated waiting to uninstall on reboot]
///
/// The build matching the app is installed and enabled, so nothing is stale and no repair is warranted — while
/// macOS, which runs one content filter at a time, has not started it, because the copies it is holding for
/// removal still have the slot. The app then redialled an extension that could not answer until a restart, six
/// times, and fell back to the sampler without ever naming the one thing that would fix it.
final class ExtensionRebootTests: XCTestCase {

    private func check(installed: [String], awaiting: [String], app: String) -> ExtensionManager.VersionCheck {
        ExtensionManager.VersionCheck(installed: installed, appVersion: app, awaitingReboot: awaiting)
    }

    /// The exact state from the machine this was found on.
    func testTheReportedStateAsksForARestart() {
        let state = check(installed: ["0.9.5"], awaiting: ["0.9.4", "0.9.3", "0.9.1"], app: "0.9.5")
        XCTAssertTrue(state.needsRestart)
        XCTAssertFalse(ExtensionVersion.isStale(installed: state.installed, appVersion: state.appVersion),
                       "nothing is stale here, which is exactly why the version check never fixed it")
    }

    func testAnOrdinaryHealthyInstallAsksForNothing() {
        XCTAssertFalse(check(installed: ["0.9.5"], awaiting: [], app: "0.9.5").needsRestart)
    }

    /// The 0.10.0 upgrade, verbatim from `systemextensionsctl list`: the new build enabled, three previous ones
    /// held for removal on reboot. It must be a restart problem, not a stale one — and "0.10.0" must sort after
    /// "0.9.x" so the enabled build is recognised as the current one.
    func testTheZeroTenUpgradeAsksForARestart() {
        let state = check(installed: ["0.10.0/22"], awaiting: ["0.9.5/21", "0.9.7/21", "0.9.7/21"], app: "0.10.0")
        XCTAssertTrue(state.needsRestart)
        XCTAssertFalse(ExtensionVersion.isStale(installed: state.installed, appVersion: state.appVersion))
    }

    /// A genuinely stale extension is a different fault with a different remedy: re-activation replaces it, and
    /// telling someone to restart instead would be advice that does not work.
    func testAStaleExtensionIsNotARestartProblem() {
        let state = check(installed: ["0.9.4"], awaiting: [], app: "0.9.5")
        XCTAssertFalse(state.needsRestart)
        XCTAssertTrue(ExtensionVersion.isStale(installed: state.installed, appVersion: state.appVersion))
    }

    /// Both at once — an old build still enabled *and* others queued for removal. The repair is the stronger
    /// claim, because re-activating may itself resolve the queue; asking for a restart first would be premature.
    func testAStaleExtensionWithLeftoversPrefersTheRepair() {
        let state = check(installed: ["0.9.4"], awaiting: ["0.9.1"], app: "0.9.5")
        XCTAssertFalse(state.needsRestart)
        XCTAssertTrue(ExtensionVersion.isStale(installed: state.installed, appVersion: state.appVersion))
    }

    /// Knowing nothing is not knowing something is wrong. With no enabled copy at all there is nothing to say a
    /// restart would start.
    func testNothingInstalledIsNotARestartProblem() {
        XCTAssertFalse(check(installed: [], awaiting: ["0.9.4"], app: "0.9.5").needsRestart)
    }

    func testNoAppVersionIsNotARestartProblem() {
        XCTAssertFalse(check(installed: ["0.9.5"], awaiting: ["0.9.4"], app: "").needsRestart)
    }

    /// `systemextensionsctl` prints "0.9.5/21"; the properties API gives "0.9.5". Both have to read as the same
    /// version, because the comparison is the whole of the decision.
    func testTheBuildSuffixDoesNotDefeatTheComparison() {
        XCTAssertTrue(check(installed: ["0.9.5/21"], awaiting: ["0.9.4/21"], app: "0.9.5").needsRestart)
    }
}
