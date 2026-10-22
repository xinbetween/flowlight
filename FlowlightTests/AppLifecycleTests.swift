import AppKit
import XCTest
@testable import Flowlight

@MainActor
final class AppLifecycleTests: XCTestCase {
    override func tearDown() {
        AppDelegate.resetStartupForTests()
        super.tearDown()
    }

    func testStartupRunsOnlyOnceAcrossRepeatedInstallations() {
        AppDelegate.resetStartupForTests(didFinishLaunching: true)
        var starts = 0

        AppDelegate.installStartup { starts += 1 }
        AppDelegate.installStartup { starts += 100 }

        XCTAssertEqual(starts, 1)
    }

    func testLatestPrelaunchOwnerStartsOnceWhenApplicationFinishesLaunching() {
        AppDelegate.resetStartupForTests()
        let delegate = AppDelegate()
        var starts = 0

        AppDelegate.installStartup { starts += 100 }
        AppDelegate.installStartup { starts += 1 }
        XCTAssertEqual(starts, 0)

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertEqual(starts, 1)
    }
}
