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
}
