import XCTest
@testable import Flowlight

func makePreviouslyPromotedKey4Database(named name: String = "promoted-attribution") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID()).sqlite")
    let candidate = try SQLiteConnection(path: url.path)
    try candidate.execute("""
        CREATE TABLE flows_1s (
            ts INTEGER NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
            app_path TEXT NOT NULL, remote_ip TEXT NOT NULL, domain TEXT NOT NULL, port INTEGER NOT NULL,
            transport TEXT NOT NULL, protocol TEXT NOT NULL, bytes_in INTEGER NOT NULL DEFAULT 0,
            bytes_out INTEGER NOT NULL DEFAULT 0, flows INTEGER NOT NULL DEFAULT 0,
            agent_parent TEXT NOT NULL DEFAULT '', agent_parent_name TEXT NOT NULL DEFAULT '',
            mcp_server TEXT NOT NULL DEFAULT '', channel TEXT NOT NULL DEFAULT '',
            attribution_exact INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX flows_1s_key4 ON flows_1s(
            ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel,
            agent_parent, agent_parent_name, mcp_server, attribution_exact
        );
        INSERT INTO flows_1s VALUES(
            1700000000, 10, 'node', 'node', '/usr/bin/node', '203.0.113.9', 'api.github.com', 443,
            'tcp', 'https', 10, 20, 2, 'fabricated-parent', 'Fabricated Parent', 'fabricated-mcp', '', 1
        );
        """)
    for table in ["agg_1m", "agg_1h", "agg_1d"] {
        try candidate.execute("CREATE TABLE \(table) AS SELECT * FROM flows_1s WHERE 0")
        try candidate.execute("CREATE UNIQUE INDEX \(table)_key4 ON \(table)(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server, attribution_exact)")
    }
    try candidate.execute("INSERT INTO agg_1m SELECT * FROM flows_1s")
    try candidate.execute("UPDATE agg_1m SET ts = (ts / 60) * 60")
    return url
}

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

    func testAIVisualizationProjectionPreservesAttributionAndScope() throws {
        let t0: Int64 = 1_700_000_000
        var attributed = key("node", "api.github.com", ip: "203.0.113.9")
        attributed.appName = "node"
        attributed.appPath = "/usr/local/bin/node"
        attributed.parentAgent = "claude"
        attributed.parentAgentName = "Claude Code"
        attributed.mcpServer = "github"
        attributed.channel = .tunnel
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: attributed, counters: FlowCounters(bytesIn: 20, bytesOut: 10, flows: 1)),
            TrafficRecord(key: key("other", "example.com"), counters: FlowCounters(bytesIn: 99, bytesOut: 0, flows: 1)),
        ])])

        let from = Date(timeIntervalSince1970: TimeInterval(t0))
        let to = Date(timeIntervalSince1970: TimeInterval(t0 + 1))
        let rows = try db.aiVisualizationRows(.second, from: from, to: to,
                                               filter: TrafficFilter(focus: FocusScope(bundleIDs: ["node"])))

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "node")
        XCTAssertEqual(rows[0].appPath, "/usr/local/bin/node")
        XCTAssertEqual(rows[0].parentAgent, "claude")
        XCTAssertEqual(rows[0].parentAgentName, "Claude Code")
        XCTAssertEqual(rows[0].mcpServer, "github")
        XCTAssertEqual(rows[0].channel, .tunnel)
        XCTAssertEqual(rows[0].counters, FlowCounters(bytesIn: 20, bytesOut: 10, flows: 1))
        XCTAssertTrue(try db.aiVisualizationRows(.second, from: to, to: to.addingTimeInterval(1)).isEmpty,
                      "the projection keeps the database's half-open time window")
        let parentFocus = try db.aiVisualizationRows(.second, from: from, to: to,
                                                      filter: TrafficFilter(focus: FocusScope(bundleIDs: ["claude"])))
        XCTAssertEqual(parentFocus.map(\.bundleID), ["node"],
                       "focusing an AI root retains traffic from its attributed children")

        let exactChild = TrafficFilter(
            bundleID: "node",
            agentParent: "claude",
            mcpServer: "github",
            domain: "api.github.com",
            remoteIP: "203.0.113.9",
            focus: FocusScope(bundleIDs: ["claude"])
        )
        let report = try db.series(.second, from: from, to: to, filter: exactChild, calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(report.reduce(Int64(0)) { $0 + $1.bytesIn + $1.bytesOut }, 30,
                       "a child visible through its focused parent must remain visible after Reports drill-down")
    }

    func testAIRollupsKeepDistinctParentAndMCPAttribution() throws {
        let utc = TimeZone(identifier: "UTC")!
        let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86400)
        var first = key("node", "api.example", ip: "203.0.113.20")
        first.parentAgent = "agent.one"
        first.parentAgentName = "Agent One"
        first.mcpServer = "github"
        var second = first
        second.parentAgent = "agent.two"
        second.parentAgentName = "Agent Two"
        second.mcpServer = "filesystem"
        try db.insert([
            TrafficBatch(timestamp: t0, records: [
                TrafficRecord(key: first, counters: FlowCounters(bytesOut: 10, flows: 1)),
                TrafficRecord(key: second, counters: FlowCounters(bytesOut: 20, flows: 1))
            ])
        ])
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(t0 + 3_700)), timeZone: utc)

        let from = Date(timeIntervalSince1970: TimeInterval(t0))
        for granularity in [Granularity.second, .minute, .hour, .day] {
            let to = granularity == .day
                ? Date(timeIntervalSince1970: TimeInterval(t0 + 86_400))
                : Date(timeIntervalSince1970: TimeInterval(t0 + 3_600))
            let rows = try db.aiVisualizationRows(granularity, from: from, to: to)
            XCTAssertEqual(rows.count, 2, "\(granularity) must preserve attribution identity")
            XCTAssertEqual(Set(rows.map(\.parentAgent)), ["agent.one", "agent.two"])
            XCTAssertEqual(Set(rows.map(\.mcpServer)), ["github", "filesystem"])
            XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.counters.bytesOut }, 30)
        }
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

    func testLegacyMergedAttributionIsUntrustedWithoutLosingTraffic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-attribution-\(UUID()).sqlite")
        let legacy = try SQLiteConnection(path: url.path)
        try legacy.execute("""
            CREATE TABLE flows_1s (
                ts INTEGER NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                app_path TEXT NOT NULL, remote_ip TEXT NOT NULL, domain TEXT NOT NULL, port INTEGER NOT NULL,
                transport TEXT NOT NULL, protocol TEXT NOT NULL, bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0, flows INTEGER NOT NULL DEFAULT 0,
                agent_parent TEXT NOT NULL DEFAULT '', agent_parent_name TEXT NOT NULL DEFAULT '',
                mcp_server TEXT NOT NULL DEFAULT '', channel TEXT NOT NULL DEFAULT ''
            );
            CREATE UNIQUE INDEX flows_1s_key2 ON flows_1s(
                ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel
            );
            INSERT INTO flows_1s VALUES(
                1700000000, 10, 'node', 'node', '/usr/bin/node', '203.0.113.9', 'api.github.com', 443,
                'tcp', 'https', 10, 20, 2, 'claude', 'Claude Code', 'github', ''
            );
            """)
        for table in ["agg_1m", "agg_1h", "agg_1d"] {
            try legacy.execute("CREATE TABLE \(table) AS SELECT * FROM flows_1s WHERE 0")
            try legacy.execute("CREATE UNIQUE INDEX \(table)_key2 ON \(table)(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel)")
        }

        let migrated = try TrafficDatabase(url: url)
        let rows = try migrated.raw(
            "SELECT bytes_in, bytes_out, flows, agent_parent, agent_parent_name, mcp_server FROM flows_1s"
        ) { ($0.int(0), $0.int(1), $0.int(2), $0.text(3), $0.text(4), $0.text(5)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, 10)
        XCTAssertEqual(rows[0].1, 20)
        XCTAssertEqual(rows[0].2, 2)
        XCTAssertEqual(rows[0].3, "claude", "migration preserves historical fields and counters")
        XCTAssertEqual(rows[0].4, "Claude Code")
        XCTAssertEqual(rows[0].5, "github")
        let exact = try migrated.raw("SELECT attribution_exact FROM flows_1s") { $0.int(0) }
        XCTAssertEqual(exact, [0], "legacy merged attribution remains stored but cannot be used as lineage proof")
        let projected = try migrated.aiVisualizationRows(
            .second,
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].counters, FlowCounters(bytesIn: 10, bytesOut: 20, flows: 2))
        XCTAssertEqual(projected[0].parentAgent, "")
        XCTAssertEqual(projected[0].parentAgentName, "")
        XCTAssertEqual(projected[0].mcpServer, "")
        XCTAssertTrue(AgentsModel.build(rows: projected, alerts: []).isEmpty,
                      "AI Agents must not infer a parent or tool from untrusted historical labels")
        let ordinary = try migrated.breakdown(
            .second,
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertEqual(ordinary.first?.parentAgent, "claude",
                       "ordinary Reports retain historical labels; AI screens must use the guarded projection")
    }

    func testPrereleaseExactKeyDoesNotPromoteUnknownProvenance() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exact-attribution-\(UUID()).sqlite")
        let previous = try SQLiteConnection(path: url.path)
        try previous.execute("""
            CREATE TABLE flows_1s (
                ts INTEGER NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                app_path TEXT NOT NULL, remote_ip TEXT NOT NULL, domain TEXT NOT NULL, port INTEGER NOT NULL,
                transport TEXT NOT NULL, protocol TEXT NOT NULL, bytes_in INTEGER NOT NULL DEFAULT 0,
                bytes_out INTEGER NOT NULL DEFAULT 0, flows INTEGER NOT NULL DEFAULT 0,
                agent_parent TEXT NOT NULL DEFAULT '', agent_parent_name TEXT NOT NULL DEFAULT '',
                mcp_server TEXT NOT NULL DEFAULT '', channel TEXT NOT NULL DEFAULT ''
            );
            CREATE UNIQUE INDEX flows_1s_key3 ON flows_1s(
                ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel,
                agent_parent, agent_parent_name, mcp_server
            );
            INSERT INTO flows_1s VALUES(
                1700000000, 10, 'node', 'node', '/usr/bin/node', '203.0.113.9', 'api.github.com', 443,
                'tcp', 'https', 10, 20, 2, 'claude', 'Claude Code', 'github', ''
            );
            """)
        for table in ["agg_1m", "agg_1h", "agg_1d"] {
            try previous.execute("CREATE TABLE \(table) AS SELECT * FROM flows_1s WHERE 0")
            try previous.execute("CREATE UNIQUE INDEX \(table)_key3 ON \(table)(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server)")
        }

        let migrated = try TrafficDatabase(url: url)
        XCTAssertEqual(try migrated.raw("SELECT attribution_exact FROM flows_1s") { $0.int(0) }, [0])
        let projected = try migrated.aiVisualizationRows(
            .second,
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_001)
        )
        XCTAssertEqual(projected.first?.parentAgent, "")
        XCTAssertEqual(projected.first?.mcpServer, "")
    }

    func testPreviouslyPromotedKey4RowsStayQuarantinedAcrossReopen() throws {
        let url = try makePreviouslyPromotedKey4Database()
        let repaired = try TrafficDatabase(url: url)
        XCTAssertEqual(
            try repaired.raw("SELECT attribution_exact, attribution_epoch FROM flows_1s") {
                ($0.int(0), $0.int(1))
            }.map { "\($0.0):\($0.1)" },
            ["1:0"],
            "the bad candidate's bit is preserved but cannot satisfy the corrected provenance epoch"
        )
        XCTAssertEqual(
            try repaired.aiVisualizationRows(
                .second,
                from: Date(timeIntervalSince1970: 1_700_000_000),
                to: Date(timeIntervalSince1970: 1_700_000_001)
            ).first?.parentAgent,
            ""
        )
        XCTAssertEqual(
            try repaired.flowsForSimulation(since: Date(timeIntervalSince1970: 1_699_999_900)).first?.agentKey,
            "node",
            "rule simulation must not act on quarantined parent labels"
        )

        var fresh = key("node", "api.github.com", ip: "203.0.113.9")
        fresh.parentAgent = "claude"
        fresh.parentAgentName = "Claude Code"
        fresh.mcpServer = "github"
        try repaired.setRollupWatermarks(1_700_000_040)
        try repaired.insert([TrafficBatch(timestamp: 1_700_000_060, records: [
            TrafficRecord(key: fresh, counters: FlowCounters(bytesOut: 5, flows: 1))
        ])])
        try repaired.rollup(
            now: Date(timeIntervalSince1970: 1_700_000_186),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        let reopened = try TrafficDatabase(url: url)
        XCTAssertEqual(
            try reopened.raw("SELECT attribution_exact, attribution_epoch FROM flows_1s ORDER BY ts") {
                ($0.int(0), $0.int(1))
            }.map { "\($0.0):\($0.1)" },
            ["1:0", "1:1"],
            "reopening must preserve both quarantined history and exact corrected writes"
        )
        XCTAssertEqual(
            Set(try reopened.flowsForSimulation(
                since: Date(timeIntervalSince1970: 1_699_999_900)
            ).map(\.agentKey)),
            ["node", "claude"],
            "corrected attribution remains actionable while quarantined history belongs to its observed process"
        )
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
