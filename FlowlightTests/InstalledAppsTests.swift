import XCTest
@testable import Flowlight

final class InstalledAppsTests: XCTestCase {
    private let apps = [
        InstalledApps.App(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", path: "/Applications/Cursor.app"),
        InstalledApps.App(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
    ]

    func testSearchMatchesNameOrIdentifier() {
        XCTAssertEqual(InstalledApps.search("curs", in: apps).map(\.name), ["Cursor"])
        XCTAssertEqual(InstalledApps.search("com.apple", in: apps).map(\.name), ["Safari"])
        XCTAssertTrue(InstalledApps.search("  ", in: apps).isEmpty, "a blank query isn't a match for everything")
    }

    func testTypingANameResolvesToItsIdentifier() {
        // Focus matches on bundle identifier, so a typed name has to become one or it would silently never match.
        XCTAssertEqual(InstalledApps.target(forTyped: "cursor", apps: apps)?.value, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(InstalledApps.target(forTyped: "Cursor", apps: apps)?.label, "Cursor")
    }

    func testAnIdentifierIsTakenAtItsWord() {
        XCTAssertEqual(InstalledApps.target(forTyped: "com.apple.Safari", apps: apps)?.value, "com.apple.Safari")
    }

    /// A command-line agent has no application bundle, and refusing to focus on one you can name would be daft.
    func testSomethingNotInstalledIsStillFocusable() {
        let target = InstalledApps.target(forTyped: "claude", apps: apps)
        XCTAssertEqual(target?.value, "claude")
        XCTAssertEqual(target?.kind, .app)
    }

    func testBlankInputIsRefused() {
        XCTAssertNil(InstalledApps.target(forTyped: "   ", apps: apps))
    }
}

/// Focus is symmetric: either half alone is a complete focus.
final class FocusSymmetryTests: XCTestCase {
    func testOneAppAloneIsAFocus() {
        let scope = FocusScope(bundleIDs: ["com.a"])
        XCTAssertFalse(scope.isEmpty)
        XCTAssertTrue(scope.matches(bundleID: "com.a", domain: "anywhere.test", remoteIP: "9.9.9.9"))
        XCTAssertFalse(scope.matches(bundleID: "com.b", domain: "anywhere.test", remoteIP: "9.9.9.9"))
    }

    func testOneDestinationAloneIsAFocus() {
        let scope = FocusScope(hosts: ["example.com"])
        XCTAssertFalse(scope.isEmpty)
        XCTAssertTrue(scope.matches(bundleID: "com.anything", domain: "api.example.com", remoteIP: "9.9.9.9"))
    }
}
