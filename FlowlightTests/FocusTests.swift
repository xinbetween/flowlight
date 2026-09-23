import XCTest
@testable import Flowlight

final class FocusTests: XCTestCase {
    var db: TrafficDatabase!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-focus-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
    }

    private func key(_ app: String, _ domain: String, ip: String = "1.2.3.4") -> FlowKey {
        FlowKey(pid: 10, bundleID: app, appName: app, appPath: "", remoteIP: ip, domain: domain, port: 443, transport: .tcp, appProtocol: "https")
    }

    // MARK: Targets

    func testHostTargetsAreNormalized() {
        XCTAssertEqual(FocusTarget.host("https://API.GitHub.com:443/repos")?.value, "api.github.com")
        XCTAssertEqual(FocusTarget.host("*.npmjs.org")?.value, "npmjs.org")
        XCTAssertEqual(FocusTarget.host("1.2.3.4")?.value, "1.2.3.4")
        XCTAssertNil(FocusTarget.host("not a host"))
    }

    /// A range would match in the live feed but not in SQL, so it's refused rather than half-supported.
    func testCIDRIsRefused() {
        XCTAssertNil(FocusTarget.host("10.0.0.0/8"))
    }

    func testAppTargetFallsBackToTheBundleID() {
        XCTAssertEqual(FocusTarget.app("com.example.app", name: "")?.label, "com.example.app")
        XCTAssertNil(FocusTarget.app("  ", name: "Nothing"))
    }

    // MARK: Matching

    func testScopeIsAUnionOfAppsAndHosts() {
        let scope = FocusScope(bundleIDs: ["com.a"], hosts: ["example.com"])
        XCTAssertTrue(scope.matches(bundleID: "com.a", domain: "anywhere.test", remoteIP: "9.9.9.9"))
        XCTAssertTrue(scope.matches(bundleID: "com.z", domain: "api.example.com", remoteIP: "9.9.9.9"))
        XCTAssertFalse(scope.matches(bundleID: "com.z", domain: "other.test", remoteIP: "9.9.9.9"))
    }

    func testEmptyScopeMatchesNothingButIsReportedEmpty() {
        XCTAssertTrue(FocusScope.none.isEmpty)
        XCTAssertFalse(FocusScope.none.matches(bundleID: "com.a", domain: "a.com", remoteIP: "1.2.3.4"))
    }

    func testIPTargetMatchesTheAddressNotTheHostname() {
        let scope = FocusScope(hosts: ["5.6.7.8"])
        XCTAssertTrue(scope.matches(bundleID: "com.a", domain: "", remoteIP: "5.6.7.8"))
        XCTAssertFalse(scope.matches(bundleID: "com.a", domain: "5.6.7.8.example.com", remoteIP: "1.1.1.1"))
    }

    // MARK: Queries

    func testFocusNarrowsSeriesAndBreakdown() throws {
        let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86400)
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: key("com.a", "a.com"), counters: FlowCounters(bytesIn: 100, bytesOut: 0, flows: 1)),
            TrafficRecord(key: key("com.b", "b.com", ip: "5.6.7.8"), counters: FlowCounters(bytesIn: 7, bytesOut: 0, flows: 1)),
            TrafficRecord(key: key("com.c", "api.a.com", ip: "9.9.9.9"), counters: FlowCounters(bytesIn: 3, bytesOut: 0, flows: 1)),
        ])])
        let from = Date(timeIntervalSince1970: TimeInterval(t0 - 60))
        let to = Date(timeIntervalSince1970: TimeInterval(t0 + 60))

        let all = try db.series(.second, from: from, to: to)
        XCTAssertEqual(all.reduce(0) { $0 + $1.bytesIn }, 110)

        // One app.
        let byApp = TrafficFilter(focus: FocusScope(bundleIDs: ["com.b"]))
        XCTAssertEqual(try db.series(.second, from: from, to: to, filter: byApp).reduce(0) { $0 + $1.bytesIn }, 7)

        // A domain takes its subdomains with it.
        let byHost = TrafficFilter(focus: FocusScope(hosts: ["a.com"]))
        XCTAssertEqual(try db.series(.second, from: from, to: to, filter: byHost).reduce(0) { $0 + $1.bytesIn }, 103)

        // Apps and hosts are OR-ed, never AND-ed.
        let both = TrafficFilter(focus: FocusScope(bundleIDs: ["com.b"], hosts: ["a.com"]))
        XCTAssertEqual(try db.series(.second, from: from, to: to, filter: both).reduce(0) { $0 + $1.bytesIn }, 110)
        XCTAssertEqual(Set(try db.breakdown(.second, from: from, to: to, filter: both).map(\.bundleID)), ["com.a", "com.b", "com.c"])
    }

    func testFocusCombinesWithAChosenFilter() throws {
        let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86400)
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: key("com.a", "a.com"), counters: FlowCounters(bytesIn: 100, bytesOut: 0, flows: 1)),
            TrafficRecord(key: key("com.b", "a.com"), counters: FlowCounters(bytesIn: 5, bytesOut: 0, flows: 1)),
        ])])
        let from = Date(timeIntervalSince1970: TimeInterval(t0 - 60)), to = Date(timeIntervalSince1970: TimeInterval(t0 + 60))
        // The screen's own filter still applies: Focus narrows, it doesn't widen.
        var filter = TrafficFilter(bundleID: "com.a")
        filter.focus = FocusScope(hosts: ["a.com"])
        XCTAssertEqual(try db.series(.second, from: from, to: to, filter: filter).reduce(0) { $0 + $1.bytesIn }, 100)

        filter.focus = FocusScope(bundleIDs: ["com.b"])
        XCTAssertEqual(try db.series(.second, from: from, to: to, filter: filter).reduce(0) { $0 + $1.bytesIn }, 0)
    }

    func testAlertsNarrowByAppAndAreLeftAloneByDestinations() throws {
        _ = try db.addAlert(kind: "newApp", bundleID: "com.a", appName: "A", detail: "", severity: 1)
        _ = try db.addAlert(kind: "newApp", bundleID: "com.b", appName: "B", detail: "", severity: 1)

        XCTAssertEqual(try db.alerts().count, 2)
        XCTAssertEqual(try db.alerts(focus: FocusScope(bundleIDs: ["com.a"])).map(\.bundleID), ["com.a"])
        // An alert records no destination, so a host-only focus can't narrow the list rather than emptying it.
        XCTAssertEqual(try db.alerts(focus: FocusScope(hosts: ["a.com"])).count, 2)

        // The badge has to agree with the list it opens.
        XCTAssertEqual(try db.unacknowledgedAlertCount(), 2)
        XCTAssertEqual(try db.unacknowledgedAlertCount(focus: FocusScope(bundleIDs: ["com.a"])), 1)
        XCTAssertEqual(try db.unacknowledgedAlertCount(focus: FocusScope(hosts: ["a.com"])), 2)
    }

    func testFocusIsNotConfusedWithAScreensOwnFilter() {
        var filter = TrafficFilter.none
        filter.focus = FocusScope(bundleIDs: ["com.a"])
        XCTAssertTrue(filter.isEmpty, "Focus is applied everywhere, so it shouldn't read as the user narrowing this screen")
    }

    // MARK: Store

    @MainActor
    func testStoreRemembersTargetsAndTurnsOnWhenSomethingIsAdded() throws {
        let defaults = UserDefaults(suiteName: "focus-test-\(UUID().uuidString)")!
        let store = FocusStore(defaults: defaults)
        XCTAssertFalse(store.isOn)
        XCTAssertTrue(store.scope.isEmpty)

        store.add(FocusTarget.host("example.com")!)
        XCTAssertTrue(store.isOn)
        XCTAssertEqual(store.scope.hosts, ["example.com"])

        // A second store over the same defaults sees what the first saved.
        let reloaded = FocusStore(defaults: defaults)
        XCTAssertTrue(reloaded.isOn)
        XCTAssertEqual(reloaded.targets.map(\.value), ["example.com"])

        reloaded.toggle(FocusTarget.host("example.com")!)
        XCTAssertTrue(reloaded.targets.isEmpty)
    }

    @MainActor
    func testFocusOnWithNothingListedIsNotActive() {
        let store = FocusStore(defaults: UserDefaults(suiteName: "focus-test-\(UUID().uuidString)")!)
        store.isOn = true
        XCTAssertFalse(store.isActive, "An empty list would hide every screen, so it has to read as off")
        XCTAssertTrue(store.scope.isEmpty)
    }

    @MainActor
    func testSummaryCountsBothKinds() {
        let store = FocusStore(defaults: UserDefaults(suiteName: "focus-test-\(UUID().uuidString)")!)
        store.add(FocusTarget.app("com.a", name: "A")!)
        XCTAssertEqual(store.summary, "1 app")
        store.add(FocusTarget.host("example.com")!)
        XCTAssertEqual(store.summary, "1 app, 1 destination")
    }
}
