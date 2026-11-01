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

    func testVersionedNameRepairMergesCollidingIdentityState() throws {
        let timestamp: Int64 = 1_700_000_000
        var versioned = key("2.1.260", "api.example.com")
        versioned.appName = "2.1.260"
        versioned.appPath = "/usr/local/bin/claude"
        var named = versioned
        named.bundleID = "claude"
        named.appName = "Claude Code"
        try db.insert([TrafficBatch(timestamp: timestamp, records: [
            TrafficRecord(key: versioned, counters: FlowCounters(bytesIn: 10, flows: 1)),
            TrafficRecord(key: named, counters: FlowCounters(bytesIn: 20, flows: 1))
        ])])
        try db.markSeen(destinations: [("claude", "api.example.com")], ports: [("claude", 443)],
                        apps: ["claude"], at: timestamp + 10)
        try db.markSeen(destinations: [("2.1.260", "api.example.com")], ports: [("2.1.260", 443)],
                        apps: ["2.1.260"], at: timestamp)
        try db.saveBaseline(bundleID: "claude", metric: "upload", .init(mean: 2, variance: 1, samples: 2))
        try db.saveBaseline(bundleID: "2.1.260", metric: "upload", .init(mean: 3, variance: 1, samples: 3))
        try db.savePolicy(AgentPolicy(agentID: "claude", patterns: ["target.example"]))
        try db.savePolicy(AgentPolicy(agentID: "2.1.260", patterns: ["version.example"]))

        try db.repairVersionedNames()

        let traffic = try db.raw(
            "SELECT bundle_id, bytes_in, flows FROM flows_1s",
            map: { ($0.text(0), $0.int(1), $0.int(2)) }
        )
        XCTAssertEqual(traffic.count, 1)
        XCTAssertEqual(traffic.first?.0, "claude")
        XCTAssertEqual(traffic.first?.1, 30)
        XCTAssertEqual(traffic.first?.2, 2)
        let seen = try db.loadSeen()
        XCTAssertEqual(seen.destinations, ["claude|api.example.com"])
        XCTAssertEqual(seen.ports, ["claude|443"])
        XCTAssertEqual(seen.apps, ["claude": timestamp])
        XCTAssertEqual(try db.raw("SELECT COUNT(*) FROM baselines WHERE bundle_id = '2.1.260'",
                                  map: { $0.int(0) }).first, 0)
        XCTAssertEqual(try db.raw("SELECT COUNT(*) FROM agent_policies WHERE agent_id = '2.1.260'",
                                  map: { $0.int(0) }).first, 0)
        XCTAssertNotNil(try db.baselines(metric: "upload")["claude"])
        XCTAssertNotNil(try db.loadPolicies()["claude"])
    }

    func testVersionedNameRepairRunsAfterShippedWatermarkAndUpdatesEnforcementHistory() throws {
        let url = db.url
        var versioned = key("2.1.260", "api.example.com")
        versioned.appName = "2.1.260"
        versioned.appPath = "/Users/test/.local/share/claude/versions/2.1.260"
        try db.insert([TrafficBatch(timestamp: 1_700_000_000, records: [
            TrafficRecord(key: versioned, counters: FlowCounters(bytesIn: 1, flows: 1))
        ])])
        try db.recordRuleEvents([
            RuleEvent(at: 1_700_000_001, ruleID: UUID(), action: .block, engine: .flow,
                      agentKey: "", agentName: "", appName: "2.1.260", bundleID: "2.1.260",
                      host: "telemetry.example", ip: "", port: 443)
        ])
        try db.recordRulePackEvents([
            RulePackEvent(bucket: 1_700_000_000, packID: "official.telemetry", packVersion: "1",
                          entryID: 1, category: .telemetry, action: .block, count: 2,
                          firstAt: 1_700_000_001, lastAt: 1_700_000_002, bundleID: "2.1.260",
                          appName: "2.1.260", agentKey: "", agentName: "", host: "metrics.example",
                          matchedHost: "metrics.example", port: 443)
        ])

        // Reproduce the state left by the shipped version-1 migration, not merely its marker: traffic was renamed
        // and kept the original path, while enforcement history stayed under the version-shaped identity.
        _ = try db.raw("UPDATE flows_1s SET bundle_id = 'claude', app_name = 'Claude Code' WHERE bundle_id = '2.1.260'",
                       map: { _ in () })
        XCTAssertEqual(try db.raw("SELECT DISTINCT bundle_id FROM flows_1s", map: { $0.text(0) }), ["claude"])
        XCTAssertEqual(try db.raw("SELECT DISTINCT bundle_id FROM rule_events", map: { $0.text(0) }), ["2.1.260"])
        XCTAssertEqual(try db.raw("SELECT DISTINCT bundle_id FROM rule_pack_event_rollups",
                                  map: { $0.text(0) }), ["2.1.260"])
        db = nil
        let legacy = try SQLiteConnection(path: url.path)
        try legacy.execute("INSERT OR REPLACE INTO rollup_state (tier, watermark) VALUES ('repair.versionedNames', 2)")

        let reopened = try TrafficDatabase(url: url)

        XCTAssertEqual(try reopened.raw("SELECT watermark FROM rollup_state WHERE tier = 'repair.versionedNames'",
                                        map: { $0.int(0) }).first, 4)
        XCTAssertEqual(try reopened.raw("SELECT DISTINCT bundle_id FROM rule_events", map: { $0.text(0) }), ["claude"])
        XCTAssertEqual(try reopened.raw("SELECT DISTINCT bundle_id FROM rule_pack_event_rollups",
                                        map: { $0.text(0) }), ["claude"])
    }

    func testVersionedNameRepairUpdatesChildProcessAgentEvidenceAndMergesPackCollisions() throws {
        let url = db.url
        let version = "2.1.260"
        var agent = key(version, "api.example.com")
        agent.appName = version
        agent.appPath = "/Users/test/.local/share/claude/versions/\(version)"
        try db.insert([TrafficBatch(timestamp: 1_700_000_000, records: [
            TrafficRecord(key: agent, counters: FlowCounters(bytesIn: 1, flows: 1))
        ])])
        _ = try db.insertExchange(HTTPExchange(
            id: nil, started: Date(timeIntervalSince1970: 1_700_000_001), duration: 0.1,
            scheme: "https", host: "api.example", port: 443, method: "GET", path: "/", status: 200,
            requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 10, bundleID: "curl", appName: "curl",
            agent: version, agentName: version, mcpServer: nil, toolCalls: [], note: nil,
            mockRule: nil, guardrail: nil
        ))
        try db.recordRuleEvents([
            RuleEvent(at: 1_700_000_001, ruleID: UUID(), action: .block, engine: .flow,
                      agentKey: version, agentName: version, appName: "curl", bundleID: "curl",
                      host: "telemetry.example", ip: "", port: 443)
        ])
        let collision = { (agentKey: String, agentName: String) in
            RulePackEvent(bucket: 1_700_000_000, packID: "official.telemetry", packVersion: "1",
                          entryID: 1, category: .telemetry, action: .block, count: 2,
                          firstAt: 1_700_000_001, lastAt: 1_700_000_002, bundleID: "curl",
                          appName: "curl", agentKey: agentKey, agentName: agentName,
                          host: "metrics.example", matchedHost: "metrics.example", port: 443)
        }
        try db.recordRulePackEvents([collision(version, version), collision("claude", "Claude Code")])
        db = nil
        let shipped = try SQLiteConnection(path: url.path)
        try shipped.execute("INSERT OR REPLACE INTO rollup_state (tier, watermark) VALUES ('repair.versionedNames', 3)")

        let reopened = try TrafficDatabase(url: url)

        XCTAssertEqual(try reopened.raw("SELECT watermark FROM rollup_state WHERE tier = 'repair.versionedNames'",
                                        map: { $0.int(0) }).first, 4)
        for table in ["http_exchanges", "rule_events", "rule_pack_event_rollups"] {
            XCTAssertEqual(try reopened.raw("SELECT DISTINCT agent, agent_name FROM \(table)",
                                            map: { ($0.text(0), $0.text(1)) }).map(\.0), ["claude"],
                           "\(table) must attach child-process evidence to the repaired agent")
        }
        let packRows = try reopened.raw(
            "SELECT count, first_at, last_at FROM rule_pack_event_rollups",
            map: { ($0.int(0), $0.int(1), $0.int(2)) }
        )
        XCTAssertEqual(packRows.count, 1)
        XCTAssertEqual(packRows.first?.0, 4, "rewriting the agent key must merge colliding rollups")
        let attempts = try reopened.blockedAttempts(
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_060)
        )
        XCTAssertTrue(attempts.allSatisfy { $0.agentKey == "claude" && $0.agentName == "Claude Code" })
    }

    func testVersionedNameRepairDoesNotGuessAcrossConflictingRetainedPaths() throws {
        let url = db.url
        let version = "2.1.260"
        var claude = key("claude", "api.example.com")
        claude.appName = "Claude Code"
        claude.appPath = "/Users/test/.local/share/claude/versions/\(version)"
        var conflicting = key("claude", "other.example.com", ip: "2.3.4.5")
        conflicting.appName = "Claude Code"
        conflicting.appPath = "/Users/test/.local/share/another-agent/versions/\(version)"
        try db.insert([TrafficBatch(timestamp: 1_700_000_000, records: [
            TrafficRecord(key: claude, counters: FlowCounters(bytesIn: 1, flows: 1)),
            TrafficRecord(key: conflicting, counters: FlowCounters(bytesIn: 1, flows: 1))
        ])])
        try db.recordRuleEvents([
            RuleEvent(at: 1_700_000_001, ruleID: UUID(), action: .block, engine: .flow,
                      agentKey: "", agentName: "", appName: version, bundleID: version,
                      host: "telemetry.example", ip: "", port: 443)
        ])

        // Version 1 collapsed every version-keyed traffic row to one chosen identity while retaining each original
        // path. Version 3 must treat the disagreeing retained path as conflicting evidence rather than ignore it.
        db = nil
        let shipped = try SQLiteConnection(path: url.path)
        try shipped.execute("INSERT OR REPLACE INTO rollup_state (tier, watermark) VALUES ('repair.versionedNames', 2)")

        let reopened = try TrafficDatabase(url: url)

        XCTAssertEqual(try reopened.raw("SELECT watermark FROM rollup_state WHERE tier = 'repair.versionedNames'",
                                        map: { $0.int(0) }).first, 4)
        XCTAssertEqual(try reopened.raw("SELECT DISTINCT bundle_id FROM flows_1s", map: { $0.text(0) }), ["claude"])
        XCTAssertEqual(try reopened.raw("SELECT DISTINCT bundle_id FROM rule_events", map: { $0.text(0) }), [version])
    }

    func testBlockedAttemptProjectionIsWindowedAndExcludesAllows() throws {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let ruleID = UUID()
        try db.recordRuleEvents([
            RuleEvent(at: 1_700_000_010, ruleID: ruleID, action: .block, engine: .flow,
                      agentKey: "", agentName: "", appName: "Browser", bundleID: "com.browser",
                      host: "www.google-analytics.com", ip: "", port: 443),
            RuleEvent(at: 1_700_000_011, ruleID: ruleID, action: .allow, engine: .flow,
                      agentKey: "", agentName: "", appName: "Browser", bundleID: "com.browser",
                      host: "analytics.google.com", ip: "", port: 443),
            RuleEvent(at: 1_700_000_100, ruleID: ruleID, action: .block, engine: .flow,
                      agentKey: "", agentName: "", appName: "Browser", bundleID: "com.browser",
                      host: "outside.example", ip: "", port: 443)
        ])
        try db.recordRulePackEvents([
            RulePackEvent(bucket: 1_700_000_020, packID: "official.privacy", packVersion: "1",
                          entryID: 7, category: .tracking, action: .block, count: 3,
                          firstAt: 1_700_000_020, lastAt: 1_700_000_029, bundleID: "com.browser",
                          appName: "Browser", agentKey: "", agentName: "", host: "telemetry.example",
                          matchedHost: "telemetry.example", port: 443),
            RulePackEvent(bucket: 1_700_000_020, packID: "official.privacy", packVersion: "1",
                          entryID: 8, category: .tracking, action: .allow, count: 9,
                          firstAt: 1_700_000_020, lastAt: 1_700_000_029, bundleID: "com.browser",
                          appName: "Browser", agentKey: "", agentName: "", host: "analytics.google.com",
                          matchedHost: "analytics.google.com", port: 443)
        ])
        let blockSession = UUID()
        var replayed = BlockEvent(at: 1_700_000_030, agentKey: "claude", agentName: "Claude Code",
                                  appName: "curl", bundleID: "curl", host: "uploads.example", ip: "", port: 443)
        replayed.deliverySession = blockSession
        replayed.deliverySequence = 1
        var ordinaryBlock = BlockEvent(at: 1_700_000_031, agentKey: "claude", agentName: "Claude Code",
                                       appName: "curl", bundleID: "curl", host: "duplicate.example", ip: "", port: 443,
                                       rule: "Block duplicate")
        ordinaryBlock.deliverySession = blockSession
        ordinaryBlock.deliverySequence = 2
        XCTAssertEqual(try db.recordBlockEvents([replayed, ordinaryBlock]), [replayed, ordinaryBlock])
        XCTAssertTrue(try db.recordBlockEvents([replayed]).isEmpty,
                      "an XPC redelivery after a lost reply must not duplicate evidence or alerts")
        var ruleReplay = BlockEvent(at: 1_700_000_032, agentKey: "claude", agentName: "Claude Code",
                                    appName: "curl", bundleID: "curl", host: "rule.example", ip: "", port: 443,
                                    rule: "Block rule")
        ruleReplay.deliverySession = blockSession
        ruleReplay.deliverySequence = 3
        XCTAssertEqual(try db.recordBlockEvents([ruleReplay]), [ruleReplay])
        XCTAssertTrue(try db.recordBlockEvents([ruleReplay]).isEmpty,
                      "ordinary-rule block alerts share the same replay receipt")

        let attempts = try db.blockedAttempts(from: from, to: from.addingTimeInterval(60))

        XCTAssertEqual(attempts.reduce(Int64(0)) { $0 + $1.count }, 5)
        XCTAssertEqual(Set(attempts.map(\.destination)),
                       ["www.google-analytics.com", "telemetry.example", "uploads.example"])
        XCTAssertFalse(attempts.contains { $0.destination == "analytics.google.com" })
        XCTAssertFalse(attempts.contains { $0.destination == "outside.example" })
        XCTAssertFalse(attempts.contains { $0.destination == "duplicate.example" })
        XCTAssertTrue(attempts.contains { $0.source == "managed-pack:official.privacy" && $0.count == 3 })
        XCTAssertTrue(attempts.contains {
            $0.source == "agent-allowlist" && $0.bundleID == "curl" && $0.agentKey == "claude"
                && $0.destination == "uploads.example" && $0.count == 1
        })

        try db.pruneRuleEvents(before: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try db.raw("SELECT COUNT(*) FROM block_event_receipts", map: { $0.int(0) }).first, 0)
        XCTAssertEqual(
            try db.raw("SELECT COUNT(*) FROM durable_event_watermarks WHERE channel = 'blocks'",
                       map: { $0.int(0) }).first,
            1,
            "current refusal traffic keeps one session watermark regardless of event volume"
        )
        XCTAssertTrue(try db.recordBlockEvents([replayed, ruleReplay]).isEmpty)
    }

    func testBlockEvidenceCanCommitInsideTheAlertTransaction() throws {
        let session = UUID()
        var event = BlockEvent(at: 1_700_000_030, agentKey: "claude", agentName: "Claude Code",
                               appName: "curl", bundleID: "curl", host: "uploads.example", ip: "", port: 443)
        event.deliverySession = session
        event.deliverySequence = 1

        try db.withTransaction {
            let accepted = try db.recordBlockEventsInTransaction([event])
            XCTAssertEqual(accepted, [event])
            _ = try db.addAlert(kind: AnomalyEngine.Kind.blockedConnection.rawValue,
                                bundleID: event.agentKey, appName: event.agentName,
                                detail: "Blocked curl", severity: 3,
                                at: Date(timeIntervalSince1970: TimeInterval(event.at)),
                                allowPattern: event.host)
        }

        XCTAssertEqual(try db.alerts().count, 1)
        XCTAssertEqual(try db.blockedAttempts(
            from: Date(timeIntervalSince1970: TimeInterval(event.at - 1)),
            to: Date(timeIntervalSince1970: TimeInterval(event.at + 1))
        ).map(\.destination), [event.host])
        XCTAssertTrue(try db.recordBlockEvents([event]).isEmpty,
                      "the atomic commit advances the replay watermark")
    }

    func testRuleDecisionReplayIsIdempotentAcrossHistoryPruning() throws {
        var rule = Rule(action: .allow, app: "com.browser", destination: "analytics.example")
        rule.maxHits = 3
        try db.saveRule(rule)
        let session = UUID()
        var event = RuleEvent(at: 1_700_000_010, ruleID: rule.id, action: .allow, engine: .flow,
                              agentKey: "", agentName: "", appName: "Browser", bundleID: "com.browser",
                              host: "analytics.example", ip: "", port: 443)
        event.deliverySession = session
        event.deliverySequence = 1
        XCTAssertEqual(try db.recordRuleEvents([event], durableReplay: true), [event])
        XCTAssertTrue(try db.recordRuleEvents([event], durableReplay: true).isEmpty)
        XCTAssertEqual(try XCTUnwrap(db.loadRules().first { $0.id == rule.id }).hits, 1,
                       "a retry must not spend the same rule decision twice")

        try db.pruneRuleEvents(before: Date(timeIntervalSince1970: 1_700_000_011))
        XCTAssertTrue(try db.recordRuleEvents([event], durableReplay: true).isEmpty,
                      "a redelivery after visible history expires must not recreate the decision")
        XCTAssertEqual(
            try db.raw("SELECT COUNT(*) FROM durable_event_watermarks WHERE channel = 'rules'",
                       map: { $0.int(0) }).first,
            1,
            "current retries use one compact session watermark rather than one receipt per event"
        )
        XCTAssertEqual(
            try db.raw("SELECT COUNT(*) FROM rule_event_receipts", map: { $0.int(0) }).first,
            0
        )
        XCTAssertEqual(try XCTUnwrap(db.loadRules().first { $0.id == rule.id }).hits, 1)
    }

    func testOrdinaryRuleEditPreservesNewerDurableActivity() throws {
        var stored = Rule(action: .allow, app: "com.browser", destination: "analytics.example")
        stored.maxHits = 1
        stored.hits = 1
        stored.lastHit = Date(timeIntervalSince1970: 1_700_000_010)
        try db.saveRule(stored)

        var edited = stored
        edited.name = "Edited"
        edited.hits = 0
        edited.lastHit = Date(timeIntervalSince1970: 1_700_000_000)
        try db.saveRule(edited, preservingActivity: true)

        let loaded = try XCTUnwrap(db.loadRules().first { $0.id == stored.id })
        XCTAssertEqual(loaded.name, "Edited")
        XCTAssertEqual(loaded.hits, 1)
        XCTAssertEqual(loaded.lastHit, stored.lastHit)
    }

    func testDurableEventWatermarksStayBoundedAcrossExtensionSessions() throws {
        let rule = Rule(action: .allow, app: "com.browser", destination: "analytics.example")
        try db.saveRule(rule)
        var latest: RuleEvent?
        for sequence in 1...100 {
            var event = RuleEvent(at: Int64(sequence), ruleID: rule.id, action: .allow, engine: .flow,
                                  agentKey: "", agentName: "", appName: "Browser", bundleID: "com.browser",
                                  host: "analytics.example", ip: "", port: 443)
            event.deliverySession = UUID()
            event.deliverySequence = 1
            _ = try db.recordRuleEvents([event], durableReplay: true)
            latest = event
        }
        XCTAssertTrue(try db.recordRuleEvents([XCTUnwrap(latest)], durableReplay: true).isEmpty,
                      "the most recently committed session must survive same-second retention pruning")
        XCTAssertEqual(
            try db.raw("SELECT COUNT(*) FROM durable_event_watermarks WHERE channel = 'rules'",
                       map: { $0.int(0) }).first,
            64
        )
        XCTAssertEqual(
            try db.raw("SELECT COUNT(*) FROM rule_event_receipts", map: { $0.int(0) }).first,
            0
        )
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

    func testTrafficVisualizationProjectionPreservesProtocolAndChannelScope() throws {
        let t0: Int64 = 1_700_000_000
        var https = key("com.example", "api.example.com", ip: "203.0.113.8")
        https.channel = .ip
        var quicTunnel = https
        quicTunnel.appProtocol = "quic"
        quicTunnel.transport = .udp
        quicTunnel.channel = .tunnel
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: https, counters: FlowCounters(bytesIn: 10, flows: 1)),
            TrafficRecord(key: quicTunnel, counters: FlowCounters(bytesOut: 20, flows: 1))
        ])])

        let from = Date(timeIntervalSince1970: TimeInterval(t0))
        let to = Date(timeIntervalSince1970: TimeInterval(t0 + 1))
        let rows = try db.appDestinationRows(.second, from: from, to: to)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.protocols)), ["https", "quic"])
        XCTAssertEqual(Set(rows.map(\.channel)), [.ip, .tunnel])
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.counters.total }, 30)
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
        var attributedQUIC = attributed
        attributedQUIC.appProtocol = "quic"
        attributedQUIC.transport = .udp
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: attributed, counters: FlowCounters(bytesIn: 20, bytesOut: 10, flows: 1)),
            TrafficRecord(key: attributedQUIC, counters: FlowCounters(bytesIn: 5, bytesOut: 5, flows: 1)),
            TrafficRecord(key: key("other", "example.com"), counters: FlowCounters(bytesIn: 99, bytesOut: 0, flows: 1)),
        ])])

        let from = Date(timeIntervalSince1970: TimeInterval(t0))
        let to = Date(timeIntervalSince1970: TimeInterval(t0 + 1))
        let rows = try db.aiVisualizationRows(.second, from: from, to: to,
                                               filter: TrafficFilter(focus: FocusScope(bundleIDs: ["node"])))

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.bundleID == "node" })
        XCTAssertTrue(rows.allSatisfy { $0.appPath == "/usr/local/bin/node" })
        XCTAssertTrue(rows.allSatisfy { $0.parentAgent == "claude" })
        XCTAssertTrue(rows.allSatisfy { $0.parentAgentName == "Claude Code" })
        XCTAssertTrue(rows.allSatisfy { $0.mcpServer == "github" })
        XCTAssertTrue(rows.allSatisfy { $0.channel == .tunnel })
        XCTAssertEqual(Set(rows.map(\.protocols)), ["https", "quic"])
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.counters.total }, 40)
        XCTAssertTrue(try db.aiVisualizationRows(.second, from: to, to: to.addingTimeInterval(1)).isEmpty,
                      "the projection keeps the database's half-open time window")
        let parentFocus = try db.aiVisualizationRows(.second, from: from, to: to,
                                                      filter: TrafficFilter(focus: FocusScope(bundleIDs: ["claude"])))
        XCTAssertEqual(parentFocus.map(\.bundleID), ["node", "node"],
                       "focusing an AI root retains traffic from its attributed children")

        let exactChild = TrafficFilter(
            bundleID: "node",
            agentParent: "claude",
            mcpServer: "github",
            domain: "api.github.com",
            remoteIP: "203.0.113.9",
            appProtocol: "https",
            channel: .tunnel,
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
        XCTAssertNil(decoded[0].records[0].key.launcherBundleID)
        XCTAssertNil(decoded[0].records[0].key.routeProxyBundleID)
    }

    func testVisualizationProvenanceRoundTripsThroughRollups() throws {
        let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 3600)
        var routed = key("claude", "api.anthropic.com", ip: "203.0.113.8")
        routed.launcherBundleID = "com.mitchellh.ghostty"
        routed.launcherName = "Ghostty"
        routed.launcherPath = "/Applications/Ghostty.app"
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        routed.routeProxyPath = "/Applications/Flowlight.app"
        try db.insert([TrafficBatch(timestamp: t0, records: [
            TrafficRecord(key: routed, counters: FlowCounters(bytesIn: 10, bytesOut: 20, flows: 1))
        ])])
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(t0 + 3_700)),
                      timeZone: TimeZone(secondsFromGMT: 0)!)

        for granularity in [Granularity.second, .minute, .hour] {
            let rows = try db.appDestinationRows(
                granularity,
                from: Date(timeIntervalSince1970: TimeInterval(t0)),
                to: Date(timeIntervalSince1970: TimeInterval(t0 + 3_600))
            )
            XCTAssertEqual(rows.first?.launcherBundleID, "com.mitchellh.ghostty")
            XCTAssertEqual(rows.first?.routeProxyBundleID, "com.flowlight.app")
            XCTAssertEqual(rows.first?.counters, FlowCounters(bytesIn: 10, bytesOut: 20, flows: 1))
        }
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

    func testReportsContributorFilterIncludesFocusScope() {
        let filter = TrafficFilter(bundleID: "com.visible")
        let focus = FocusScope(hosts: ["example.com"])

        let scoped = ReportsView.effectiveFilter(filter, focus: focus)

        XCTAssertEqual(scoped.bundleID, "com.visible")
        XCTAssertEqual(scoped.focus, focus, "hover contributors must use the same Focus scope as the visible chart")
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
