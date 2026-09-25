import XCTest
@testable import Flowlight

/// Which applications the Alerts list treats as Apple's own.
final class AppleSystemAppTests: XCTestCase {

    func testApplesOwnApplicationsAreRecognised() {
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "com.apple.Safari"))
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "com.apple.Maps"))
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "com.apple.softwareupdated"))
    }

    func testDaemonsWithNoBundleIdentifierAreRecognisedByPath() {
        // These report an executable name, not an identifier.
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "mDNSResponder", path: "/usr/sbin/mDNSResponder"))
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "trustd", path: "/usr/libexec/trustd"))
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "timed", path: "/System/Library/PrivateFrameworks/timed"))
    }

    func testEverythingElseIsNot() {
        XCTAssertFalse(AppleSystemApps.contains(bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"))
        XCTAssertFalse(AppleSystemApps.contains(bundleID: "com.flowlight.app", path: "/Applications/Flowlight.app"))
        XCTAssertFalse(AppleSystemApps.contains(bundleID: "claude", path: "/opt/homebrew/bin/claude"))
    }

    func testAnApplePrefixIsNotATrustDecision() {
        // Anything can claim the identifier, which is why this only decides what to list. The name of the
        // setting says "ignore in Alerts", and nothing here is exempt from a rule or an allowlist.
        XCTAssertTrue(AppleSystemApps.contains(bundleID: "com.apple.NotReallyApple", path: "/tmp/evil.app"))
    }

    func testTheSettingIsOnUnlessSomeoneTurnsItOff() {
        AnomalySettings.registerDefaults()
        XCTAssertTrue(AnomalySettings.current.ignoreAppleApps)
    }
}
