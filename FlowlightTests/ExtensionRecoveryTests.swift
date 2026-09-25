import XCTest
@testable import Flowlight

final class ExtensionRecoveryTests: XCTestCase {
    /// Drives the ladder until it stops, collecting what it asked for. The real source spaces these out over a
    /// minute of timers; here the whole sequence is one line, which is the point of keeping the decision pure.
    private func ladder(_ recovery: inout ExtensionRecovery, failures: Int) -> [ExtensionRecovery.Step] {
        (0..<failures).map { _ in recovery.next() }
    }

    /// The first drop is nearly always a blip — the extension restarting, the Mac waking. Reaching for a repair
    /// there would put a System Settings prompt on screen for something that fixes itself in five seconds.
    func testTheFirstFailuresJustRedial() {
        var recovery = ExtensionRecovery()
        XCTAssertEqual(recovery.next(), .redial(after: 5))
        XCTAssertEqual(recovery.next(), .redial(after: 10))
        XCTAssertFalse(recovery.versionChecked, "nothing has been asked of macOS yet")
    }

    /// Two redials having failed is the signal that this isn't a blip. The version check is the one fault the
    /// app can repair by itself, so it comes before giving up, not after.
    func testTheThirdFailureChecksTheVersion() {
        var recovery = ExtensionRecovery()
        let steps = ladder(&recovery, failures: 3)
        XCTAssertEqual(steps.last, .repairVersion(after: 15))
        XCTAssertTrue(recovery.versionChecked)
    }

    /// The check can end in an activation request, and an activation request can end in a prompt. Once is a
    /// repair; on a five-second timer it is a Mac nobody can get any work done on.
    func testTheVersionCheckIsOnlyEverAskedForOnce() {
        var recovery = ExtensionRecovery()
        let steps = ladder(&recovery, failures: ExtensionRecovery.maxAttempts)
        XCTAssertEqual(steps.filter { if case .repairVersion = $0 { return true } else { return false } }.count, 1)
    }

    /// The whole reason this exists: the old code redialled every five seconds for as long as the app was left
    /// running. The ladder has to end somewhere, and it ends with the sampler capturing instead.
    func testItGivesUpAfterABoundedNumberOfTries() {
        var recovery = ExtensionRecovery()
        let steps = ladder(&recovery, failures: ExtensionRecovery.maxAttempts)
        XCTAssertEqual(steps.last, .fallBack)
        XCTAssertTrue(recovery.gaveUp)
    }

    /// Having given up once, later failures say the same thing. A source that flipped back to redialling would
    /// undo the fallback the moment the sampler's replacement connection dropped.
    func testGivingUpSticks() {
        var recovery = ExtensionRecovery()
        _ = ladder(&recovery, failures: ExtensionRecovery.maxAttempts)
        XCTAssertEqual(recovery.next(), .fallBack)
        XCTAssertEqual(recovery.next(), .fallBack)
    }

    /// A connection that comes up and registers has earned a clean run at the next failure, or a Mac that sleeps
    /// twice a day would work its way to the sampler over a week of ordinary use.
    func testRegisteringResetsTheLadder() {
        var recovery = ExtensionRecovery()
        _ = ladder(&recovery, failures: 2)
        recovery.succeeded()
        XCTAssertEqual(recovery.next(), .redial(after: 5))
    }

    /// But it doesn't earn a fresh version check. That question has been answered, and asking macOS again every
    /// time the connection flickers is how the prompt-on-a-loop gets back in.
    func testASuccessDoesNotBuyASecondVersionCheck() {
        var recovery = ExtensionRecovery()
        _ = ladder(&recovery, failures: 3)
        recovery.succeeded()
        let steps = ladder(&recovery, failures: 3)
        XCTAssertFalse(steps.contains { if case .repairVersion = $0 { return true } else { return false } })
    }

    /// An extension that registers and drops again on a loop resets `attempts` every time round, so the session
    /// total is what stops it. Without this the fallback would never be reached by the one failure mode that
    /// looks busiest from the outside.
    func testFlappingStillReachesTheFallback() {
        var recovery = ExtensionRecovery()
        var steps: [ExtensionRecovery.Step] = []
        // Fail, register, fail again — far more times than the consecutive limit would ever allow.
        for _ in 0..<ExtensionRecovery.maxTotalAttempts {
            steps.append(recovery.next())
            recovery.succeeded()
        }
        XCTAssertEqual(steps.last, .fallBack)
        XCTAssertTrue(recovery.gaveUp)
    }

    /// A repair actually being under way is different from another blind redial: the thing that was wrong is
    /// being fixed, and replacing a system extension takes longer than the delay that was about to be used.
    func testARepairBuysTheLadderItsRungsBack() {
        var recovery = ExtensionRecovery()
        _ = ladder(&recovery, failures: 3)   // ends on the version check
        recovery.repairStarted()
        XCTAssertEqual(recovery.next(), .redial(after: 5))
    }

    /// Backing off matters because the failure that gets this far is usually permanent. Hammering a refused
    /// connection twelve times a minute costs power and tells us nothing we didn't know after the second try.
    func testDelaysBackOffAndAreCapped() {
        XCTAssertEqual(ExtensionRecovery.delay(forAttempt: 1), 5)
        XCTAssertEqual(ExtensionRecovery.delay(forAttempt: 4), 20)
        XCTAssertEqual(ExtensionRecovery.delay(forAttempt: 99), 30, "no amount of failing makes the wait unbounded")
    }

    /// The bug this fixes was as much about the status line as the retries: "Extension connection invalidated"
    /// sat there unchanged while the app tried and failed every five seconds and never said so.
    func testTheStatusLineSaysWhatHappensNext() {
        let redial = ExtensionRecovery.statusLine("Extension connection invalidated",
                                                  step: .redial(after: 10), attempt: 2)
        XCTAssertTrue(redial.contains("Extension connection invalidated"))
        XCTAssertTrue(redial.contains("10s"), "the wait is the part someone is actually looking for")
        XCTAssertTrue(redial.contains("2 of \(ExtensionRecovery.maxAttempts)"), "and how much patience is left")

        let repair = ExtensionRecovery.statusLine("Extension connection invalidated",
                                                  step: .repairVersion(after: 15), attempt: 3)
        XCTAssertTrue(repair.contains("matches this app"))

        let fallBack = ExtensionRecovery.statusLine("Extension connection invalidated", step: .fallBack, attempt: 6)
        XCTAssertTrue(fallBack.contains("sampler"), "giving up has to name what takes over")
    }
}

final class ExtensionVersionTests: XCTestCase {
    /// The failure this whole path exists for: the app updated, macOS kept running the extension it had, and
    /// the XPC connection between two different builds is refused with no explanation worth reading.
    func testADifferentInstalledBuildIsStale() {
        XCTAssertTrue(ExtensionVersion.isStale(installed: ["0.4.0"], appVersion: "0.5.0"))
    }

    func testAMatchingBuildIsNotStale() {
        XCTAssertFalse(ExtensionVersion.isStale(installed: ["0.5.0"], appVersion: "0.5.0"))
    }

    /// macOS reports two while a replacement is pending. If one of them is ours there is nothing to repair —
    /// re-activating in that window would only fight the install already in progress.
    func testAnyMatchingCopyIsEnough() {
        XCTAssertFalse(ExtensionVersion.isStale(installed: ["0.4.0", "0.5.0"], appVersion: "0.5.0"))
    }

    /// Knowing nothing is not the same as knowing something is wrong. An empty answer from macOS, or an app with
    /// no version in its Info.plist, must not be allowed to trigger a repair that can prompt the user.
    func testNothingKnownIsNotAReasonToRepair() {
        XCTAssertFalse(ExtensionVersion.isStale(installed: [], appVersion: "0.5.0"))
        XCTAssertFalse(ExtensionVersion.isStale(installed: ["0.5.0"], appVersion: ""))
    }

    /// "0.5" and "0.5.0" are the same build shipped by two tools that disagree about trailing zeros. Treating
    /// them as different would reinstall the extension on every launch.
    func testMissingComponentsCountAsZero() {
        XCTAssertEqual(ExtensionVersion.compare("0.5", "0.5.0"), .orderedSame)
        XCTAssertFalse(ExtensionVersion.isStale(installed: ["0.5"], appVersion: "0.5.0"))
    }

    /// String comparison puts "0.10.0" before "0.9.0", which is exactly backwards and would have the app
    /// reinstalling a newer extension with an older one.
    func testComponentsCompareAsNumbersNotText() {
        XCTAssertEqual(ExtensionVersion.compare("0.10.0", "0.9.0"), .orderedDescending)
        XCTAssertEqual(ExtensionVersion.compare("0.9.0", "0.10.0"), .orderedAscending)
    }

    /// `systemextensionsctl list` prints the short version and the build together. Whatever reads it should get
    /// the same answer as the properties request, which only carries the short version.
    func testTheBuildSuffixIsIgnored() {
        XCTAssertEqual(ExtensionVersion.compare("0.5.0/8", "0.5.0"), .orderedSame)
    }
}
