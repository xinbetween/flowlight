import XCTest
@testable import Flowlight

final class DatabaseTests: XCTestCase {
    var db: TrafficDatabase!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-test-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
    }

    func key(_ app: String, _ domain: String, ip: String = "1.2.3.4", port: UInt16 = 443) -> FlowKey {
        FlowKey(pid: 10, bundleID: app, appName: app, appPath: "", remoteIP: ip, domain: domain, port: port, transport: .tcp, appProtocol: "https")
    }

    func testRollupsAndQueries() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86400) // midnight UTC
        var batches: [TrafficBatch] = []
        for s in 0..<180 { // 3 minutes of traffic
            batches.append(TrafficBatch(timestamp: t0 + Int64(s), records: [
                TrafficRecord(key: key("com.a", "a.com"), counters: FlowCounters(bytesIn: 100, bytesOut: 10, flows: s == 0 ? 1 : 0)),
                TrafficRecord(key: key("com.b", "b.com", ip: "5.6.7.8"), counters: FlowCounters(bytesIn: 1, bytesOut: 2, flows: 0)),
            ]))
        }
        try db.insert(batches)
        try db.insert([TrafficBatch(timestamp: t0, records: [TrafficRecord(key: key("com.a", "a.com"), counters: FlowCounters(bytesIn: 5, bytesOut: 0, flows: 0))])])

        let now = Date(timeIntervalSince1970: TimeInterval(t0 + 3 * 60 + 30))
        try db.rollup(now: now, timeZone: utc)

        let from = Date(timeIntervalSince1970: TimeInterval(t0)), to = Date(timeIntervalSince1970: TimeInterval(t0 + 3600))
        let minutes = try db.series(.minute, from: from, to: to, calendar: calendar)
        XCTAssertEqual(minutes.count, 60)
        XCTAssertEqual(minutes[0].bytesIn, 60 * 101 + 5)
        XCTAssertEqual(minutes[2].bytesOut, 60 * 12)
        XCTAssertEqual(minutes[3].total, 0)

        let hour = try db.series(.hour, from: from, to: to, calendar: calendar)
        XCTAssertEqual(hour.first?.bytesIn, 180 * 101 + 5)
        let day = try db.series(.day, from: from, to: Date(timeIntervalSince1970: TimeInterval(t0 + 86400)), calendar: calendar)
        XCTAssertEqual(day.first?.bytesOut, 180 * 12)

        // Rolling up again must not double count.
        try db.rollup(now: now, timeZone: utc)
        XCTAssertEqual(try db.series(.hour, from: from, to: to, calendar: calendar).first?.bytesIn, 180 * 101 + 5)

        let breakdown = try db.breakdown(.hour, from: from, to: to)
        XCTAssertEqual(breakdown.first?.bundleID, "com.a")
        XCTAssertEqual(breakdown.first?.counters.flows, 1)

        let filtered = try db.series(.minute, from: from, to: to, filter: TrafficFilter(bundleID: "com.b"), calendar: calendar)
        XCTAssertEqual(filtered[0].bytesIn, 60)

        let nodes = TrafficNode.tree(from: breakdown)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes.first { $0.bundleID == "com.a" }?.children?.first?.children?.first?.remoteIP, "1.2.3.4")
    }

    func testTreeBackfillsDomainsAndFilters() {
        func row(_ app: String, _ domain: String, _ ip: String, _ bytes: Int64, port: String = "443") -> BreakdownRow {
            BreakdownRow(bundleID: app, appName: app, appPath: "", domain: domain, remoteIP: ip, ports: port, protocols: "https",
                         counters: FlowCounters(bytesIn: bytes, bytesOut: 0, flows: 1))
        }
        let rows = [row("com.a", "", "1.1.1.1", 10), row("com.a", "one.one", "1.1.1.1", 90),
                    row("com.a", "", "9.9.9.9", 5, port: "8443"), row("com.b", "", "1.1.1.1", 7)]
        let tree = TrafficNode.tree(from: rows)
        let a = tree.first { $0.bundleID == "com.a" }!
        XCTAssertEqual(a.total, 105)
        let one = a.children!.first { $0.domain == "one.one" }!
        XCTAssertEqual(one.children?.count, 1, "unresolved rows merge into the resolved IP")
        XCTAssertEqual(one.total, 100)
        XCTAssertEqual(a.children!.first { $0.domain == "" }?.total, 5)
        XCTAssertEqual(tree.first { $0.bundleID == "com.b" }?.children?.first?.domain, "one.one", "domains are shared across apps")
        XCTAssertEqual(a.ports, "443, 8443")

        let filtered = TrafficNode.filter(tree, query: "9.9.9")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].total, 5, "totals narrow to matching children")
        XCTAssertEqual(TrafficNode.filter(tree, query: "com.b").first?.total, 7)
    }

    private func groupingRows() -> [BreakdownRow] {
        func row(_ app: String, _ domain: String, _ ip: String, _ bytes: Int64, owner: String = "", asn: Int = 0) -> BreakdownRow {
            BreakdownRow(bundleID: app, appName: app.uppercased(), appPath: "/Applications/\(app).app/Contents/MacOS/x", domain: domain,
                         remoteIP: ip, ports: "443", protocols: "https", counters: FlowCounters(bytesIn: bytes, bytesOut: 0, flows: 1),
                         owner: owner, asn: asn)
        }
        return [row("chrome", "www.google.com", "142.250.1.1", 50), row("chrome", "mail.google.com", "142.250.1.2", 30),
                row("slack", "www.google.com", "142.250.1.1", 20), row("slack", "slack.com", "3.3.3.3", 40),
                row("zoom", "", "104.18.0.1", 5, owner: "Cloudflare, Inc.", asn: 13335)]
    }

    func testDestinationFirstGroupsAppsUnderDomains() {
        let tree = TrafficNode.tree(from: groupingRows(), grouping: .destination)
        XCTAssertEqual(Set(tree.map(\.title)), ["google.com", "slack.com", "Cloudflare, Inc. · AS13335"])
        let google = tree.first { $0.title == "google.com" }!
        XCTAssertEqual(google.kind, .domain)
        XCTAssertEqual(google.total, 100, "all google.com hostnames roll up")
        XCTAssertEqual(google.filter, TrafficFilter(domainSuffix: "google.com"))
        let apps = google.children!
        XCTAssertEqual(Set(apps.map(\.title)), ["CHROME", "SLACK"])
        let chrome = apps.first { $0.title == "CHROME" }!
        XCTAssertEqual(chrome.kind, .app)
        XCTAssertEqual(chrome.total, 80)
        XCTAssertEqual(chrome.filter, TrafficFilter(bundleID: "chrome", domainSuffix: "google.com"), "app rows keep the destination")
        let hosts = chrome.children!
        XCTAssertEqual(Set(hosts.map(\.detail)), ["www.google.com", "mail.google.com"])
        let leaf = hosts.first { $0.detail == "mail.google.com" }!
        XCTAssertEqual(leaf.title, "142.250.1.2")
        XCTAssertEqual(leaf.filter.remoteIP, "142.250.1.2")
        XCTAssertEqual(leaf.filter.domain, "mail.google.com")
        XCTAssertEqual(leaf.appName, "CHROME", "leaves know their app for 'Show only CHROME'")
        let cloudflare = tree.first { $0.kind == .owner }!
        XCTAssertEqual(cloudflare.filter.owner, "Cloudflare, Inc.")
        XCTAssertEqual(cloudflare.children?.first?.title, "ZOOM")
    }

    func testIPFirstGroupsAppsUnderAddresses() {
        let tree = TrafficNode.tree(from: groupingRows(), grouping: .ip)
        let shared = tree.first { $0.title == "142.250.1.1" }!
        XCTAssertEqual(shared.kind, .ip)
        XCTAssertEqual(shared.detail, "www.google.com", "IP rows show the hostname behind them")
        XCTAssertEqual(shared.total, 70)
        XCTAssertEqual(Set(shared.children!.map(\.title)), ["CHROME", "SLACK"])
        XCTAssertNil(shared.children!.first!.children, "apps are leaves in the IP grouping")
        XCTAssertEqual(tree.first { $0.title == "104.18.0.1" }?.detail, "Cloudflare, Inc.", "hostname-less IPs show their owner")
    }

    func testTreeNodesInheritReportFilterAndGroupingTotalsAgree() {
        let rows = groupingRows()
        let base = TrafficFilter(appProtocol: "https")
        let byApp = TrafficNode.tree(from: rows, grouping: .app, base: base)
        XCTAssertEqual(byApp.first { $0.title == "SLACK" }?.filter, TrafficFilter(bundleID: "slack", appProtocol: "https"))
        let totals = BreakdownGrouping.allCases.map { g in TrafficNode.tree(from: rows, grouping: g).reduce(Int64(0)) { $0 + $1.total } }
        XCTAssertEqual(Set(totals), [145], "every grouping accounts for the same bytes")
        XCTAssertEqual(BreakdownGrouping.destination.columnTitle, "Destination › App › IP")
    }

    func testAgentAttributionColumnsRoundTripAndMigrate() throws {
        var k = key("curl", "pastebin.example", ip: "203.0.113.7")
        k.parentAgent = "claude"; k.parentAgentName = "Claude Code"
        var m = key("node", "api.github.com", ip: "198.51.100.3")
        m.parentAgent = "claude"; m.parentAgentName = "Claude Code"; m.mcpServer = "github"
        let t0: Int64 = 1_700_000_040
        try db.insert([TrafficBatch(timestamp: t0, records: [TrafficRecord(key: k, counters: FlowCounters(bytesIn: 1, bytesOut: 5, flows: 1)),
                                                             TrafficRecord(key: m, counters: FlowCounters(bytesIn: 2, bytesOut: 3, flows: 1))])])
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(t0 + 120)), timeZone: TimeZone(identifier: "UTC")!)
        let rows = try db.breakdown(.hour, from: Date(timeIntervalSince1970: TimeInterval(t0 - 7200)), to: Date(timeIntervalSince1970: TimeInterval(t0 + 7200)))
        let curl = rows.first { $0.bundleID == "curl" }!
        XCTAssertEqual(curl.parentAgent, "claude")
        XCTAssertEqual(curl.parentAgentName, "Claude Code", "attribution survives rollups")
        XCTAssertEqual(rows.first { $0.bundleID == "node" }?.mcpServer, "github")
        // Re-opening an existing database runs the migration without error.
        _ = try TrafficDatabase(url: db.url)
        // Older batches without the fields still decode.
        let legacy = #"[{"timestamp":1,"records":[{"key":{"pid":1,"bundleID":"a","appName":"a","appPath":"","remoteIP":"1.1.1.1","domain":"","port":443,"transport":"tcp","appProtocol":"https"},"counters":{"bytesIn":1,"bytesOut":1,"flows":0}}]}]"#
        let decoded = try JSONDecoder().decode([TrafficBatch].self, from: Data(legacy.utf8))
        XCTAssertNil(decoded[0].records[0].key.parentAgent)
    }

    func testUnacknowledgedCountAndReadOnlyConnection() throws {
        try db.addAlert(kind: "k", bundleID: "b", appName: "a", detail: "d", severity: 2)
        let second = try db.addAlert(kind: "k", bundleID: "b", appName: "a", detail: "d", severity: 1)
        XCTAssertEqual(try db.unacknowledgedAlertCount(), 2)
        try db.acknowledgeAlerts(ids: [second.id])
        let reader = try TrafficDatabase(url: db.url, readOnly: true)
        XCTAssertEqual(try reader.unacknowledgedAlertCount(), 1)
        XCTAssertThrowsError(try reader.acknowledgeAlerts(ids: nil))
    }

    func testBucketContributors() throws {
        let t0: Int64 = 1_700_000_000
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: key("com.big", "upload.example.com"), counters: FlowCounters(bytesIn: 10, bytesOut: 5_000_000, flows: 1)),
            TrafficRecord(key: key("com.big", "other.example.com", ip: "5.5.5.5"), counters: FlowCounters(bytesIn: 10, bytesOut: 100, flows: 1)),
            TrafficRecord(key: key("com.small", "", ip: "104.18.0.1"), counters: FlowCounters(bytesIn: 900, bytesOut: 100, flows: 1)),
        ])])
        try db.saveOwner(ip: "104.18.0.1", IPOwner(asn: 13335, name: "Cloudflare, Inc."))
        let bucket = try db.contributors(.second, from: Date(timeIntervalSince1970: TimeInterval(t0)), to: Date(timeIntervalSince1970: TimeInterval(t0 + 1)), limit: 1)
        XCTAssertEqual(bucket.top.map(\.bundleID), ["com.big"])
        XCTAssertEqual(bucket.remainingApps, 1)
        XCTAssertEqual(bucket.remaining.bytesIn, 900)
        let apps = try db.contributors(.second, from: Date(timeIntervalSince1970: TimeInterval(t0)), to: Date(timeIntervalSince1970: TimeInterval(t0 + 1))).top
        XCTAssertEqual(apps.map(\.bundleID), ["com.big", "com.small"])
        XCTAssertEqual(apps[0].counters.bytesOut, 5_000_100)
        XCTAssertEqual(apps[0].topDestination, "upload.example.com")
        XCTAssertEqual(apps[1].topDestination, "Cloudflare, Inc. · 104.18.0.1")
        XCTAssertTrue(try db.contributors(.second, from: Date(timeIntervalSince1970: TimeInterval(t0 + 5)), to: Date(timeIntervalSince1970: TimeInterval(t0 + 6))).top.isEmpty)
    }

    func testTrimLeadingEmptyBuckets() {
        let points = (0..<72).map { i in SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(i * 3600)), bytesIn: i >= 70 ? 5 : 0, bytesOut: 0, flows: 0) }
        XCTAssertEqual(ReportsView.trimLeadingEmpty(points).count, 12, "keeps a minimum span")
        let early = (0..<72).map { i in SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(i * 3600)), bytesIn: i >= 20 ? 5 : 0, bytesOut: 0, flows: 0) }
        XCTAssertEqual(ReportsView.trimLeadingEmpty(early).first?.date, early[19].date, "starts one bucket before the first data")
        let empty = points.map { SeriesPoint(date: $0.date, bytesIn: 0, bytesOut: 0, flows: 0) }
        XCTAssertEqual(ReportsView.trimLeadingEmpty(empty).count, 72)
    }

    func testWeekMonthYearBucketing() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let jan1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let rows = (0..<60).map { d in
            SeriesPoint(date: calendar.date(byAdding: .day, value: d, to: jan1)!, bytesIn: 10, bytesOut: 1, flows: 1)
        }
        let months = TrafficDatabase.bucket(rows, granularity: .month, from: jan1,
                                            to: calendar.date(byAdding: .month, value: 3, to: jan1)!, calendar: calendar)
        XCTAssertEqual(months.map(\.bytesIn), [310, 280, 10])
        let years = TrafficDatabase.bucket(rows, granularity: .year, from: jan1, to: calendar.date(byAdding: .day, value: 60, to: jan1)!, calendar: calendar)
        XCTAssertEqual(years.first?.flows, 60)
    }

    func testBaselineAndSpike() throws {
        var b: TrafficDatabase.Baseline?
        for i in 0..<48 { b = AnomalyEngine.update(b, with: 1_000_000 + Double(i % 5) * 50_000) }
        XCTAssertEqual(b!.mean, 1_100_000, accuracy: 30_000)
        XCTAssertGreaterThan(AnomalyEngine.zScore(20_000_000, b!, floor: 64_000), 3)
        XCTAssertLessThan(AnomalyEngine.zScore(1_150_000, b!, floor: 64_000), 3)
    }

    func testFirstContactAndPortRules() throws {
        final class NoActivity: ActivitySnapshotting { func idleDuration(bundleID: String) -> TimeInterval? { nil } }
        let engine = AnomalyEngine(db: db, activity: NoActivity())
        var settings = AnomalySettings(); settings.learningPeriod = 60
        engine.settings = { settings }
        var fired: [AlertRecord] = []
        engine.onAlert = { fired += $0 }

        try engine.observe([TrafficBatch(timestamp: 1000, records: [TrafficRecord(key: key("com.a", "a.com"), counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1))])])
        XCTAssertTrue(fired.isEmpty, "learning period suppresses alerts")
        try engine.observe([TrafficBatch(timestamp: 2000, records: [
            TrafficRecord(key: key("com.a", "cdn.a.com"), counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1)), // same registrable domain
            TrafficRecord(key: key("com.a", "evil.example", port: 4444), counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1)),
        ])])
        XCTAssertEqual(Set(fired.map(\.kind)), [AnomalyEngine.Kind.firstContact.rawValue, AnomalyEngine.Kind.nonStandardPort.rawValue])
        XCTAssertEqual(try db.alerts().count, 2)
    }
}

final class DatabaseLocationTests: XCTestCase {
    private func makeDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAlwaysUsesApplicationSupport() {
        let support = makeDir(), group = makeDir()
        defer { for d in [support, group] { try? FileManager.default.removeItem(at: d) } }
        let url = TrafficDatabase.resolveURL(appSupport: support, group: group)
        XCTAssertEqual(url, support.appendingPathComponent("Flowlight/traffic.sqlite"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appendingPathComponent("traffic.sqlite").path))
    }

    func testAdoptsADatabaseLeftInTheGroupContainer() throws {
        let support = makeDir(), group = makeDir()
        defer { for d in [support, group] { try? FileManager.default.removeItem(at: d) } }
        for suffix in ["", "-wal"] {
            try Data("db\(suffix)".utf8).write(to: group.appendingPathComponent("traffic.sqlite\(suffix)"))
        }
        let url = TrafficDatabase.resolveURL(appSupport: support, group: group)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "db")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: url.path + "-wal"), encoding: .utf8), "db-wal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appendingPathComponent("traffic.sqlite").path))
    }

    func testKeepsTheExistingDatabaseWhenBothExist() throws {
        let support = makeDir(), group = makeDir()
        defer { for d in [support, group] { try? FileManager.default.removeItem(at: d) } }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Flowlight"), withIntermediateDirectories: true)
        try Data("current".utf8).write(to: support.appendingPathComponent("Flowlight/traffic.sqlite"))
        try Data("older".utf8).write(to: group.appendingPathComponent("traffic.sqlite"))
        let url = TrafficDatabase.resolveURL(appSupport: support, group: group)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "current")
    }
}
