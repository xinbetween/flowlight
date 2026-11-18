import AppKit
import Combine
import XCTest
@testable import Flowlight

/// `WindowVisibility` decides whether the live chart series and the per-app list are built at all, so it is the
/// switch between an idle Flowlight costing nothing and an idle Flowlight rebuilding both every second for a
/// window nobody can see. A stuck `true` is invisible from the outside — the app keeps working correctly and only
/// the battery shows it — so the drift cases are covered explicitly.
final class WindowVisibilityTests: XCTestCase {
    /// Stand-in for an NSWindow. Only identity is ever used.
    private final class FakeWindow {}

    private final class TrackingWindow: NSWindow {
        private(set) var didClose = false

        override func close() {
            didClose = true
        }
    }

    func testNothingIsVisibleUntilAWindowSaysSo() {
        var windows = WindowVisibility()
        XCTAssertFalse(windows.isVisible)

        let window = FakeWindow()
        XCTAssertEqual(windows.update(window, isVisible: true), .becameVisible)
        XCTAssertTrue(windows.isVisible)

        XCTAssertEqual(windows.update(window, isVisible: false), .becameHidden)
        XCTAssertFalse(windows.isVisible)
    }

    @MainActor
    func testHeadlessCaptureRendersLiveOnlyForTheExplicitDemoFixture() {
        XCTAssertTrue(TrafficMonitor.needsLiveUI(windowVisible: true, demoEnabled: false, forceRender: false))
        XCTAssertFalse(TrafficMonitor.needsLiveUI(windowVisible: false, demoEnabled: false, forceRender: false))
        XCTAssertFalse(TrafficMonitor.needsLiveUI(windowVisible: false, demoEnabled: false, forceRender: true),
                       "the fixture must not disable hidden-window savings in a normal run")
        XCTAssertFalse(TrafficMonitor.needsLiveUI(windowVisible: false, demoEnabled: true, forceRender: false),
                       "demo mode alone must not disable hidden-window savings")
        XCTAssertTrue(TrafficMonitor.needsLiveUI(windowVisible: false, demoEnabled: true, forceRender: true))
    }

    @MainActor
    func testLiveTicksDoNotInvalidateTheWholeTrafficMonitor() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-live-state-\(UUID()).sqlite")
        let monitor = TrafficMonitor(databaseURL: url)
        var monitorChanges = 0
        var liveChanges = 0
        let monitorObservation = monitor.objectWillChange.sink { monitorChanges += 1 }
        let liveObservation = monitor.liveState.objectWillChange.sink { liveChanges += 1 }

        monitor.liveState.publish(LiveSnapshot(currentIn: 128, isReceiving: true))

        XCTAssertEqual(liveChanges, 1)
        XCTAssertEqual(monitorChanges, 0,
                       "one-second rate updates must not rebuild every screen that observes TrafficMonitor")
        withExtendedLifetime((monitorObservation, liveObservation)) {}
    }

    /// AppKit posts occlusion changes freely, including ones that repeat the current state. A counter drifted
    /// here; identity cannot.
    func testRepeatedUpdatesForOneWindowDoNotDrift() {
        var windows = WindowVisibility()
        let window = FakeWindow()

        XCTAssertEqual(windows.update(window, isVisible: true), .becameVisible)
        for _ in 0..<5 {
            XCTAssertEqual(windows.update(window, isVisible: true), .unchanged, "a repeat is not a new window")
        }

        XCTAssertEqual(windows.update(window, isVisible: false), .becameHidden,
                       "one hide must undo any number of shows for the same window")
        for _ in 0..<3 {
            XCTAssertEqual(windows.update(window, isVisible: false), .unchanged)
        }
        XCTAssertFalse(windows.isVisible)
    }

    func testVisibleWhileAnyWindowIsVisible() {
        var windows = WindowVisibility()
        let first = FakeWindow()
        let second = FakeWindow()

        XCTAssertEqual(windows.update(first, isVisible: true), .becameVisible)
        XCTAssertEqual(windows.update(second, isVisible: true), .unchanged, "already visible overall")

        XCTAssertEqual(windows.update(first, isVisible: false), .unchanged, "the second is still on screen")
        XCTAssertTrue(windows.isVisible)

        XCTAssertEqual(windows.update(second, isVisible: false), .becameHidden)
        XCTAssertFalse(windows.isVisible)
    }

    /// A window torn down while already occluded reports hidden twice. Under the old counter that double
    /// decrement was clamped, and the matching double increment was not — which is how a session ended up
    /// permanently "visible".
    func testHidingAWindowThatWasNeverVisibleIsHarmless() {
        var windows = WindowVisibility()
        let ghost = FakeWindow()
        let real = FakeWindow()

        XCTAssertEqual(windows.update(ghost, isVisible: false), .unchanged)
        XCTAssertFalse(windows.isVisible)

        XCTAssertEqual(windows.update(real, isVisible: true), .becameVisible)
        XCTAssertEqual(windows.update(ghost, isVisible: false), .unchanged, "a stranger cannot hide someone else")
        XCTAssertTrue(windows.isVisible)
    }

    /// Two windows closing in either order must both end hidden; only the last one reports the flip.
    func testOnlyTheLastWindowReportsTheFlip() {
        var windows = WindowVisibility()
        let a = FakeWindow()
        let b = FakeWindow()
        windows.update(a, isVisible: true)
        windows.update(b, isVisible: true)

        XCTAssertEqual(windows.update(b, isVisible: false), .unchanged)
        XCTAssertEqual(windows.update(a, isVisible: false), .becameHidden)
        XCTAssertFalse(windows.isVisible)
    }

    @MainActor
    func testMainWindowPresentationWaitsForRegistrationAndReusesExactWindow() {
        let presenter = MainWindowPresenter()
        var openCount = 0

        presenter.present { openCount += 1 }
        XCTAssertEqual(openCount, 1)
        XCTAssertTrue(presenter.presentationPending)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        presenter.register(window)
        XCTAssertFalse(presenter.presentationPending)
        XCTAssertTrue(window.isVisible)

        presenter.present { openCount += 1 }
        XCTAssertEqual(openCount, 1, "a registered main window must be restored instead of opening another scene")
        presenter.unregister(window)
        presenter.present { openCount += 1 }
        XCTAssertEqual(openCount, 2)
        window.orderOut(nil)
    }

    @MainActor
    func testBackgroundLaunchRetainsButHidesMainWindowUntilPresentation() {
        let presenter = MainWindowPresenter(suppressInitialPresentation: { true })
        var openCount = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.orderFront(nil)

        presenter.register(window)
        XCTAssertFalse(window.isVisible,
                       "background launch must hide the guaranteed main scene")
        presenter.present { openCount += 1 }

        XCTAssertEqual(openCount, 0)
        XCTAssertTrue(window.isVisible,
                      "menu presentation must foreground the retained main scene")
        window.orderOut(nil)
    }

    @MainActor
    func testClosedRegisteredWindowReopensDirectlyWithoutSceneAction() {
        let presenter = MainWindowPresenter()
        var openCount = 0
        let closedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                    styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        presenter.register(closedWindow)
        XCTAssertFalse(closedWindow.isReleasedWhenClosed)
        closedWindow.orderFront(nil)
        closedWindow.close()
        XCTAssertFalse(closedWindow.isVisible)

        presenter.present { openCount += 1 }

        XCTAssertEqual(openCount, 0,
                       "a retained main window must not depend on SwiftUI's inactive-scene open action")
        XCTAssertTrue(closedWindow.isVisible)
        closedWindow.orderOut(nil)
    }

    @MainActor
    func testBackgroundSuppressionAppliesOnlyToInitialRegistration() {
        let presenter = MainWindowPresenter(suppressInitialPresentation: { true })
        let initial = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                               styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        initial.orderFront(nil)
        presenter.register(initial)
        XCTAssertFalse(initial.isVisible)

        presenter.present {}
        XCTAssertTrue(initial.isVisible)

        let replacement = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                    styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        replacement.orderFront(nil)
        presenter.register(replacement)
        XCTAssertTrue(replacement.isVisible,
                      "a replacement registered after presentation must not be hidden as a second launch")
        initial.orderOut(nil)
        replacement.orderOut(nil)
    }

    @MainActor
    func testDuplicateRestoredRegistrationClosesTheDuplicateAndKeepsThePrimary() {
        let presenter = MainWindowPresenter()
        var openCount = 0
        let primary = TrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                     styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        let staleDuplicate = TrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                            styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)

        presenter.register(primary)
        presenter.register(staleDuplicate)
        primary.orderFront(nil)
        presenter.present { openCount += 1 }

        XCTAssertEqual(openCount, 0)
        XCTAssertTrue(primary.isVisible, "the first registered main scene remains canonical")
        XCTAssertFalse(primary.didClose)
        XCTAssertTrue(staleDuplicate.didClose,
                      "a legacy restored scene must be retired instead of competing with app-wide navigation")

        presenter.unregister(primary)
        presenter.present { openCount += 1 }
        XCTAssertEqual(openCount, 1,
                       "a retired duplicate must not be reused after the canonical window unregisters")
        primary.orderOut(nil)
    }
}
