import XCTest
@testable import Flowlight

final class InsightsTests: XCTestCase {
    private func row(_ ts: Int64, app: String, domain: String = "", owner: String = "", ip: String = "1.1.1.1",
                     proto: String = "https", bytesIn: Int64 = 0, bytesOut: Int64 = 0) -> DimensionRow {
        DimensionRow(ts: ts, bundleID: app, appName: app.uppercased(), appPath: "", domain: domain, owner: owner,
                     remoteIP: ip, appProtocol: proto, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func testTopFivePlusOtherAndShares() {
        let rows = (1...8).map { i in row(0, app: "app\(i)", bytesIn: Int64(i) * 100) }
        let snap = InsightsBuilder.build(rows: rows, dimensions: [.app], metric: .total, granularity: .minute,
                                         from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 60), calendar: utc)
        let slices = snap.dimensions[0].slices
        XCTAssertEqual(slices.count, 6, "top 5 + Other")
        XCTAssertEqual(slices.first?.entity.key, "app8")
        XCTAssertEqual(slices.last?.entity.kind, .other)
        XCTAssertEqual(slices.last?.counters.bytesIn, 600, "apps 1–3 fold into Other")
        XCTAssertEqual(slices.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(snap.dimensions[0].leaderTrends.count, InsightsBuilder.maxTrends)
        XCTAssertEqual(snap.dimensions[0].entityCount, 8)
        XCTAssertEqual(snap.dimensions[0].hiddenCount, 3)
        XCTAssertEqual(snap.dimensions[0].ranked.count, 8, "the full list behind Other")
        let other = snap.dimensions[0].trends.first { $0.entity.kind == .other }
        XCTAssertEqual(other?.points.map(\.bytesIn).reduce(0, +), 1000, "Other line = apps 1–4 (100+200+300+400)")
    }

    func testDestinationsGroupByRegistrableDomainThenOwner() {
        let rows = [row(0, app: "a", domain: "yi-in-f113.1e100.net", bytesIn: 10),
                    row(0, app: "a", domain: "ym-in-f102.1e100.net", bytesIn: 20),
                    row(0, app: "a", owner: "Cloudflare, Inc.", ip: "104.18.0.1", bytesIn: 5),
                    row(0, app: "a", ip: "9.9.9.9", bytesIn: 1)]
        let snap = InsightsBuilder.build(rows: rows, dimensions: [.destination], metric: .received, granularity: .minute,
                                         from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 60), calendar: utc)
        let slices = snap.dimensions[0].slices
        XCTAssertEqual(slices.map(\.entity.label), ["1e100.net", "Cloudflare, Inc.", "Unknown"])
        XCTAssertEqual(slices[0].counters.bytesIn, 30)
        XCTAssertEqual(slices[1].entity.kind, .owner)
    }

    func testTrendsAreBucketedAndZeroFilled() {
        let rows = [row(0, app: "a", bytesOut: 5), row(30, app: "a", bytesOut: 5), row(120, app: "a", bytesOut: 7), row(60, app: "b", bytesOut: 1)]
        let snap = InsightsBuilder.build(rows: rows, dimensions: [.app], metric: .sent, granularity: .minute,
                                         from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 180), calendar: utc)
        let a = snap.dimensions[0].trends.first { $0.entity.key == "a" }!
        XCTAssertEqual(a.points.map(\.bytesOut), [10, 0, 7])
        // A window ending mid-bucket drops the still-filling bucket from trends.
        let partial = InsightsBuilder.build(rows: rows, dimensions: [.app], metric: .sent, granularity: .minute,
                                            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 150), calendar: utc)
        XCTAssertEqual(partial.dimensions[0].trends.first { $0.entity.key == "a" }?.points.map(\.bytesOut), [10, 0])
        XCTAssertEqual(snap.direction.map(\.bytesOut), [10, 1, 7])
        XCTAssertEqual(snap.total.bytesOut, 18)
    }

    func testMetricChangesRanking() {
        let rows = [row(0, app: "downloader", bytesIn: 1000, bytesOut: 1), row(0, app: "uploader", bytesIn: 1, bytesOut: 500)]
        let range = (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 60))
        let sent = InsightsBuilder.build(rows: rows, dimensions: [.app], metric: .sent, granularity: .minute, from: range.0, to: range.1, calendar: utc)
        XCTAssertEqual(sent.dimensions[0].slices.first?.entity.key, "uploader")
        let received = InsightsBuilder.build(rows: rows, dimensions: [.app], metric: .received, granularity: .minute, from: range.0, to: range.1, calendar: utc)
        XCTAssertEqual(received.dimensions[0].slices.first?.entity.key, "downloader")
    }

    func testManyEntitiesStayCheapAndComplete() throws {
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("many-\(UUID()).sqlite"))
        // 400 apps × 30 hostnames over 20 minutes: 240k raw combinations.
        var batches: [TrafficBatch] = []
        for minute in 0..<20 {
            var records: [TrafficRecord] = []
            for app in 0..<400 {
                for host in 0..<30 where (app + host + minute) % 10 == 0 {
                    records.append(TrafficRecord(key: FlowKey(pid: Int32(app), bundleID: "app\(app)", appName: "App \(app)", appPath: "",
                                                              remoteIP: "10.\(app % 250).\(host).1", domain: "h\(host).site\(app % 50).com", port: 443,
                                                              transport: .tcp, appProtocol: "https"),
                                                 counters: FlowCounters(bytesIn: Int64(app + 1), bytesOut: 1, flows: 0)))
                }
            }
            batches.append(TrafficBatch(timestamp: Int64(minute * 60), records: records))
        }
        try db.insert(batches)
        try db.rollup(now: Date(timeIntervalSince1970: 20 * 60 + 30), timeZone: TimeZone(identifier: "UTC")!)
        let from = Date(timeIntervalSince1970: 0), to = Date(timeIntervalSince1970: 20 * 60)
        let series = try db.series(.minute, from: from, to: to, calendar: utc)
        let snap = try InsightsBuilder.load(db: db, dimensions: [.app, .destination], series: series, metric: .received,
                                            granularity: .minute, from: from, to: to, filter: .none, calendar: utc)
        let apps = snap.dimensions[0], destinations = snap.dimensions[1]
        XCTAssertEqual(apps.entityCount, 400)
        XCTAssertEqual(destinations.entityCount, 50, "hostnames fold into 50 registrable domains")
        XCTAssertEqual(apps.slices.count, 6)
        let expected = series.reduce(Int64(0)) { $0 + $1.bytesIn }
        XCTAssertEqual(apps.slices.reduce(Int64(0)) { $0 + $1.counters.bytesIn }, expected, "top 5 + Other add up to the true total")
        // Each bucket: leaders + Other = overall.
        for i in apps.trends[0].points.indices {
            let sum = apps.trends.reduce(Int64(0)) { $0 + $1.points[i].bytesIn }
            let overall = series.first { $0.date == apps.trends[0].points[i].date }?.bytesIn ?? 0
            XCTAssertEqual(sum, overall)
        }
    }

    func testTableCapsLongChildLists() {
        let ips = (0..<60).map { i in
            TrafficNode(id: "a|d|\(i)", kind: .ip, title: "10.0.0.\(i)", bundleID: "a",
                        filter: TrafficFilter(bundleID: "a", domain: "d", remoteIP: "10.0.0.\(i)"),
                        counters: FlowCounters(bytesIn: Int64(100 - i), bytesOut: 0, flows: 0))
        }
        let domain = TrafficNode(id: "a|d", kind: .domain, title: "d", bundleID: "a",
                                 filter: TrafficFilter(bundleID: "a", domain: "d")).withChildren(ips)
        let app = TrafficNode(id: "a", kind: .app, title: "A", bundleID: "a", filter: TrafficFilter(bundleID: "a")).withChildren([domain])
        let capped = TrafficNode.capped([app], parentID: "__root__", parent: nil, limits: [:])
        let children = capped[0].children![0].children!
        XCTAssertEqual(children.count, TrafficNode.pageSize + 1)
        XCTAssertEqual(children.last?.moreCount, 35)
        XCTAssertEqual(children.last?.kind, .more)
        XCTAssertTrue(children.last?.title.hasSuffix("35 addresses not shown") == true)
        XCTAssertEqual(children.last?.counters.bytesIn, (25..<60).map { Int64(100 - $0) }.reduce(0, +), "summary row keeps the hidden bytes")
        let grown = TrafficNode.capped([app], parentID: "__root__", parent: nil, limits: ["a|d": 50])
        XCTAssertEqual(grown[0].children![0].children!.last?.moreCount, 10)
        XCTAssertEqual(capped[0].total, app.total, "totals are untouched by capping")
    }

    func testColorRegistryKeepsSurvivorsStable() {
        var registry = ColorRegistry()
        registry.assign(visible: ["a", "b", "c"])
        let (a, c) = (registry.slot(for: "a"), registry.slot(for: "c"))
        registry.assign(visible: ["c", "d", "a"])        // b leaves, d arrives, order changes
        XCTAssertEqual(registry.slot(for: "a"), a, "entities keep their color regardless of rank")
        XCTAssertEqual(registry.slot(for: "c"), c)
        XCTAssertEqual(registry.slot(for: "d"), 1, "newcomer takes the freed slot")
        XCTAssertNil(registry.slot(for: "b"))
    }

    func testAvailableDimensionsFollowScope() {
        XCTAssertEqual(InsightDimension.available(for: .none), [.app, .destination, .appProtocol])
        XCTAssertEqual(InsightDimension.available(for: TrafficFilter(bundleID: "x")), [.destination, .appProtocol])
        XCTAssertEqual(InsightDimension.available(for: TrafficFilter(domainSuffix: "google.com")), [.app, .ip, .appProtocol])
        XCTAssertEqual(InsightDimension.available(for: TrafficFilter(bundleID: "x", domainSuffix: "g.com", appProtocol: "quic")), [.ip])
    }

    func testNarrowing() {
        let domain = InsightEntity(key: "d:google.com", label: "google.com", kind: .domain)
        XCTAssertEqual(domain.narrowing(TrafficFilter(bundleID: "x"))?.domainSuffix, "google.com")
        XCTAssertEqual(domain.narrowing(TrafficFilter(bundleID: "x"))?.bundleID, "x")
        let owner = InsightEntity(key: "o:Cloudflare", label: "Cloudflare", kind: .owner).narrowing(.none)
        XCTAssertEqual(owner?.owner, "Cloudflare")
        XCTAssertEqual(owner?.domain, "", "owners describe hostname-less traffic")
        XCTAssertNil(InsightEntity.other.narrowing(.none))
    }

    func testSuffixAndProtocolFiltersInSQL() throws {
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("ins-\(UUID()).sqlite"))
        func record(_ domain: String, _ proto: String, _ bytes: Int64) -> TrafficRecord {
            TrafficRecord(key: FlowKey(pid: 1, bundleID: "a", appName: "A", appPath: "", remoteIP: "1.1.1.\(bytes)", domain: domain,
                                       port: 443, transport: .tcp, appProtocol: proto), counters: FlowCounters(bytesIn: bytes, bytesOut: 0, flows: 0))
        }
        try db.insert([TrafficBatch(timestamp: 10, records: [record("google.com", "https", 1), record("mail.google.com", "quic", 2),
                                                             record("notgoogle.com", "https", 4)])])
        let range = (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 20))
        let google = try db.dimensionTotals(.destination, .second, from: range.0, to: range.1, filter: TrafficFilter(domainSuffix: "google.com"))
        XCTAssertEqual(google.map(\.bytesIn).reduce(0, +), 3, "suffix matches the domain and subdomains only")
        let quic = try db.dimensionTotals(.destination, .second, from: range.0, to: range.1, filter: TrafficFilter(appProtocol: "quic"))
        XCTAssertEqual(quic.map(\.domain), ["mail.google.com"])
    }
}
