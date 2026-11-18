import CoreGraphics
import XCTest
@testable import Flowlight

@MainActor
final class PerformanceBudgetTests: XCTestCase {
    private let clock = ContinuousClock()

    func testLaunchStartupBudget() async throws {
        let recordCount = 10_001
        let url = temporaryDatabaseURL("launch")
        defer { removeTemporaryDatabase(url) }
        let db = try TrafficDatabase(url: url)
        try db.insert([TrafficBatch(timestamp: fixedTimestamp, records: trafficRecords(count: recordCount))])
        let source = BudgetTrafficSource()

        let monitor: TrafficMonitor = try await assertBudget(
            "launch startup", fixture: "\(recordCount) retained traffic rows + 84,892 catalog entries",
            budgetMilliseconds: 4_000
        ) {
            let monitor = TrafficMonitor(databaseURL: url, trafficSourceFactory: { source })
            monitor.start()
            for _ in 0..<10_000 {
                if source.started { return monitor }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("launch startup fixture never started its traffic source")
            return monitor
        }
        XCTAssertTrue(source.started)
        XCTAssertFalse(monitor.rulePacks.definitions.isEmpty)
    }

    func testLargeGraphLayoutBudget() throws {
        let edgeCount = 600
        let rows = (0..<edgeCount).map { index in
            BreakdownRow(
                bundleID: "app.\(index % 60)", appName: "App \(index % 60)", appPath: "",
                domain: "host\(index).example", remoteIP: "203.0.\(index / 256).\(index % 256)",
                ports: "443", protocols: "https",
                counters: FlowCounters(bytesIn: Int64(index + 1), flows: 1)
            )
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        XCTAssertEqual(snapshot.edges.count, edgeCount)
        let bounds = CGRect(
            x: 0, y: 0,
            width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
            height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        )
        _ = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)

        let layout = assertBudget(
            "large graph layout", fixture: "\(edgeCount) edges",
            budgetMilliseconds: 4_000
        ) {
            TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)
        }
        XCTAssertEqual(layout.nodeFrames.count, snapshot.nodes.count)
        XCTAssertEqual(layout.topologyEdgeIDs, Set(snapshot.edges.map(\.id)))
        XCTAssertEqual(layout.edgeCurves.count + layout.omittedEdgeIDs.count, snapshot.edges.count)
    }

    func testHistoryQueryBudget() throws {
        let recordCount = TrafficDatabase.breakdownLimit + 1
        let url = temporaryDatabaseURL("history")
        defer { removeTemporaryDatabase(url) }
        let db = try TrafficDatabase(url: url)
        try db.insert([TrafficBatch(timestamp: fixedTimestamp, records: trafficRecords(count: recordCount))])
        let from = Date(timeIntervalSince1970: TimeInterval(fixedTimestamp))
        let to = Date(timeIntervalSince1970: TimeInterval(fixedTimestamp + 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        _ = try historyProjection(db: db, from: from, to: to, calendar: calendar)
        let projection = try assertBudget(
            "History query", fixture: "\(recordCount) one-second traffic rows",
            budgetMilliseconds: 500
        ) {
            try historyProjection(db: db, from: from, to: to, calendar: calendar)
        }
        XCTAssertEqual(projection.series.count, 1)
        XCTAssertEqual(projection.breakdown.rows.count, TrafficDatabase.breakdownLimit)
        XCTAssertTrue(projection.breakdown.isTruncated)
    }

    func testAlertsQueryBudget() throws {
        let alertCount = 10_000
        let appCount = 100
        let url = temporaryDatabaseURL("alerts")
        defer { removeTemporaryDatabase(url) }
        let db = try TrafficDatabase(url: url)
        var byState: [AlertTriageState: [Int64]] = [:]
        let states = AlertTriageState.allCases
        for index in 0..<alertCount {
            let alert = try db.addAlert(
                kind: "Budget alert", bundleID: "agent.\(index % appCount)", appName: "Agent \(index % appCount)",
                detail: "Deterministic performance fixture", severity: 2,
                at: Date(timeIntervalSince1970: TimeInterval(fixedTimestamp + Int64(index)))
            )
            byState[states[(index / appCount) % states.count], default: []].append(alert.id)
        }
        for state in states where state != .new {
            try db.setAlertTriageState(state, ids: byState[state] ?? [])
        }
        let focus = FocusScope(bundleIDs: ["agent.42"])

        _ = try db.alerts(limit: 500, focus: focus, triageFilter: .open)
        let alerts = try assertBudget(
            "Alerts query", fixture: "\(alertCount) alerts, \(appCount) apps, focused open filter",
            budgetMilliseconds: 100
        ) {
            try db.alerts(limit: 500, focus: focus, triageFilter: .open)
        }
        XCTAssertEqual(alerts.count, 60)
        XCTAssertTrue(alerts.allSatisfy { $0.bundleID == "agent.42" && !$0.state.isClosed })
    }

    func testAgentInventoryBudget() throws {
        let agentCount = 1_000
        let alertCount = 2_000
        let traffic = (0..<agentCount).map { inventorySummary(index: $0) }
        let routes = Dictionary(uniqueKeysWithValues: (0..<agentCount).map { ("worker.\($0)", AgentRouteState.observed) })
        let policies = Dictionary(uniqueKeysWithValues: (0..<agentCount).map {
            ("worker.\($0)", AgentPolicy(agentID: "worker.\($0)", enabled: true,
                                         patterns: ["api.provider.test"], enforce: true))
        })
        let alerts = (0..<alertCount).map { index in
            AlertRecord(
                id: Int64(index + 1), timestamp: Date(timeIntervalSince1970: TimeInterval(fixedTimestamp + Int64(index))),
                kind: "budget", bundleID: "worker.\(index % agentCount)", appName: "Worker \(index % agentCount)",
                detail: "Deterministic performance fixture", severity: 2,
                state: index.isMultiple(of: 3) ? .resolved : .investigating
            )
        }
        let input = AgentInventoryInput(
            traffic: traffic,
            routes: routes,
            inspection: AgentInspectionDiagnostics(
                available: true, enabled: true, running: true, certificateTrusted: true, setupFailed: false
            ),
            policies: policies,
            alerts: alerts
        )
        _ = AgentInventoryBuilder.build(input)

        let inventory = assertBudget(
            "agent inventory", fixture: "\(agentCount) agents, \(agentCount) routes/policies, \(alertCount) alerts",
            budgetMilliseconds: 2_000
        ) {
            AgentInventoryBuilder.build(input)
        }
        XCTAssertEqual(inventory.count, agentCount)
    }

    func testBuiltInPluginEvaluationBudget() throws {
        let evaluationCount = 5_000
        let exchange = pluginExchange()
        let manifests = PluginEngine.builtInManifests
        _ = PluginEngine.evaluateBuiltIns(exchange, manifests: manifests)

        let findingCount = assertBudget(
            "built-in plugin evaluation", fixture: "\(evaluationCount) exchanges × \(manifests.count) plugins",
            budgetMilliseconds: 1_500
        ) {
            var count = 0
            for _ in 0..<evaluationCount {
                count += PluginEngine.evaluateBuiltIns(exchange, manifests: manifests).count
            }
            return count
        }
        XCTAssertGreaterThan(findingCount, evaluationCount)
    }

    func testGeneratedAdvertisingCatalogBudgets() throws {
        let testBundle = Bundle(for: Self.self)
        let sourceURL = try XCTUnwrap(
            testBundle.url(forResource: "official-source", withExtension: "json"),
            "the generated catalog fixture must be copied into the test bundle"
        )
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        XCTAssertLessThanOrEqual(source.count, RulePackCatalogVerifier.maximumDataBytes)

        let signedURL = try XCTUnwrap(
            Bundle.main.url(forResource: "official", withExtension: "json"),
            "the signed production catalog must be copied into the app test host"
        )
        let signedSource = try Data(contentsOf: signedURL, options: .mappedIfSafe)
        try assertBudget(
            "rule-pack strict JSON scan",
            fixture: "\(signedSource.count) signed JSON bytes",
            budgetMilliseconds: 2_000
        ) {
            try RulePackCatalogVerifier.validateStrictJSONSyntax(signedSource)
        }
        let verified = try assertBudget(
            "rule-pack signed verification",
            fixture: "\(signedSource.count) signed JSON bytes",
            budgetMilliseconds: 4_000
        ) {
            try RulePackCatalogVerifier.verify(
                data: signedSource,
                now: 1_800_000_000,
                currentAppVersion: "0.18.6"
            )
        }
        XCTAssertEqual(verified.sequence, 4)
        XCTAssertEqual(verified.signerKeyID, "flowlight-rule-packs-2026-11")

        let envelope: RulePackCatalogEnvelope = try assertBudget(
            "rule-pack catalog decode",
            fixture: "\(source.count) JSON bytes",
            budgetMilliseconds: 2_000
        ) {
            try JSONDecoder().decode(RulePackCatalogEnvelope.self, from: source)
        }
        let totalEntries = envelope.payload.packs.reduce(0) { $0 + $1.entries.count }
        XCTAssertEqual(totalEntries, 84_895)

        let canonical = try assertBudget(
            "rule-pack canonicalization",
            fixture: "\(totalEntries) entries",
            budgetMilliseconds: 2_000
        ) {
            try RulePackCatalogVerifier.canonicalPayload(for: envelope)
        }
        XCTAssertLessThanOrEqual(canonical.count, RulePackCatalogVerifier.maximumDataBytes)

        let definitions = envelope.payload.packs.map(rulePackDefinition)
        let activeDefinitions = definitions.filter { $0.id != AdvertisingPackTierPolicy.balancedID }
        let configurations = activeDefinitions.map { definition in
            RulePackConfiguration(
                packID: definition.id,
                enabled: true,
                consentedVersion: definition.manifest.version,
                consentedContentSHA256: definition.manifest.contentSHA256
            )
        }
        let snapshot = RulePackSnapshot.make(
            definitions: activeDefinitions,
            configurations: configurations,
            overrides: []
        )
        let matcher = try assertBudget(
            "rule-pack trie construction",
            fixture: "\(activeDefinitions.reduce(0) { $0 + $1.entries.count }) active entries",
            budgetMilliseconds: 4_000
        ) {
            try RulePackMatcher(snapshot: snapshot)
        }
        XCTAssertEqual(matcher.matches(host: "cdn.pubadx.one", bundleID: "com.example.app").first?.entry.id, 15)

        let encoded = assertBudget(
            "rule-pack snapshot encoding",
            fixture: "\(snapshot.definitions.count) packs",
            budgetMilliseconds: 4_000
        ) {
            BlockCoding.encode(snapshot)
        }
        XCTAssertFalse(encoded.isEmpty)
        XCTAssertLessThanOrEqual(encoded.count, 32 * 1_024 * 1_024)
        let decoded: RulePackSnapshot? = assertBudget(
            "rule-pack snapshot decoding",
            fixture: "\(encoded.count) binary plist bytes",
            budgetMilliseconds: 4_000
        ) {
            BlockCoding.decode(RulePackSnapshot.self, from: encoded)
        }
        XCTAssertEqual(decoded?.digest, snapshot.digest)

        let chunkSize = 64 * 1_024
        let chunks = stride(from: 0, to: encoded.count, by: chunkSize).map {
            encoded.subdata(in: $0..<min(encoded.count, $0 + chunkSize))
        }
        let header = RulePackTransferHeader(
            protocolVersion: RulePackSnapshot.protocolVersion,
            generation: snapshot.generation,
            digest: snapshot.digest,
            totalBytes: encoded.count,
            chunks: chunks.count,
            expectedActiveGeneration: nil
        )
        let active = RulePackHandshake(
            protocolVersion: RulePackSnapshot.protocolVersion,
            activeGeneration: nil,
            activeDigest: ""
        )
        var transfer = RulePackTransferBuffer()
        XCTAssertEqual(transfer.begin(header, active: active).status, .accepted)
        let reassembled: Data = assertBudget(
            "rule-pack IPC assembly",
            fixture: "\(chunks.count) chunks",
            budgetMilliseconds: 1_000
        ) {
            for (index, chunk) in chunks.enumerated() {
                XCTAssertTrue(transfer.append(
                    generation: snapshot.generation.uuidString,
                    index: index,
                    payload: chunk
                ))
            }
            guard case .payload(let data, _) = transfer.commit(
                generation: snapshot.generation.uuidString,
                active: active
            ) else {
                XCTFail("the generated snapshot transfer must commit")
                return Data()
            }
            return data
        }
        XCTAssertEqual(reassembled, encoded)
    }

    func testBudgetGateRejectsDeliberateRegression() {
        let failure = budgetFailure(
            name: "deliberate regression", fixture: "42 generated records",
            observedMilliseconds: 101, budgetMilliseconds: 100
        )
        XCTAssertEqual(
            failure,
            "deliberate regression: fixture=42 generated records observed=101.000ms budget=100.000ms"
        )
        XCTAssertNil(budgetFailure(
            name: "passing fixture", fixture: "42 generated records",
            observedMilliseconds: 99, budgetMilliseconds: 100
        ))
    }

    private func rulePackDefinition(_ pack: RulePackCatalogWirePack) -> RulePackDefinition {
        RulePackDefinition(
            manifest: RulePackManifest(
                id: pack.manifest.id,
                version: pack.manifest.version,
                generatedAt: Date(timeIntervalSince1970: TimeInterval(pack.manifest.generatedAt)),
                entryCount: Int(pack.manifest.entryCount),
                contentSHA256: pack.manifest.contentSHA256,
                minimumAppVersion: pack.manifest.minimumAppVersion,
                minimumExtensionProtocol: pack.manifest.minimumExtensionProtocol,
                titleKey: pack.manifest.titleKey,
                summaryKey: pack.manifest.summaryKey,
                caveatKey: pack.manifest.caveatKey,
                source: pack.manifest.source,
                license: pack.manifest.license,
                format: pack.manifest.format
            ),
            entries: pack.entries
        )
    }

    private var fixedTimestamp: Int64 { 1_700_000_000 }

    private func assertBudget<T>(
        _ name: String,
        fixture: String,
        budgetMilliseconds: Double,
        operation: () throws -> T
    ) rethrows -> T {
        let started = clock.now
        let result = try operation()
        let observed = milliseconds(clock.now - started)
        print(String(format: "PERF_BUDGET %@ fixture=%@ observed=%.3fms budget=%.3fms", name, fixture,
                     observed, budgetMilliseconds))
        if let failure = budgetFailure(
            name: name, fixture: fixture,
            observedMilliseconds: observed, budgetMilliseconds: budgetMilliseconds
        ) {
            XCTFail(failure)
        }
        return result
    }

    private func assertBudget<T>(
        _ name: String,
        fixture: String,
        budgetMilliseconds: Double,
        operation: () async throws -> T
    ) async rethrows -> T {
        let started = clock.now
        let result = try await operation()
        let observed = milliseconds(clock.now - started)
        print(String(format: "PERF_BUDGET %@ fixture=%@ observed=%.3fms budget=%.3fms", name, fixture,
                     observed, budgetMilliseconds))
        if let failure = budgetFailure(
            name: name, fixture: fixture,
            observedMilliseconds: observed, budgetMilliseconds: budgetMilliseconds
        ) {
            XCTFail(failure)
        }
        return result
    }

    private func budgetFailure(
        name: String,
        fixture: String,
        observedMilliseconds: Double,
        budgetMilliseconds: Double
    ) -> String? {
        guard observedMilliseconds > budgetMilliseconds else { return nil }
        return String(
            format: "%@: fixture=%@ observed=%.3fms budget=%.3fms",
            name, fixture, observedMilliseconds, budgetMilliseconds
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    private func trafficRecords(count: Int) -> [TrafficRecord] {
        (0..<count).map { index in
            TrafficRecord(
                key: FlowKey(
                    pid: Int32(index % 1_000 + 1), bundleID: "app.\(index % 100)",
                    appName: "App \(index % 100)", appPath: "", remoteIP: "203.0.\(index / 256).\(index % 256)",
                    domain: "host-\(index).example", port: 443, transport: .tcp, appProtocol: "https"
                ),
                counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1)
            )
        }
    }

    private func historyProjection(
        db: TrafficDatabase,
        from: Date,
        to: Date,
        calendar: Calendar
    ) throws -> (series: [SeriesPoint], breakdown: ReportsBreakdown) {
        try db.readSnapshot {
            (
                try db.series(.second, from: from, to: to, calendar: calendar),
                try db.reportsBreakdown(.second, from: from, to: to)
            )
        }
    }

    private func inventorySummary(index: Int) -> AgentSummary {
        let counters = FlowCounters(bytesIn: 400, bytesOut: 100, flows: 1)
        return AgentSummary(
            bundleID: "worker.\(index)", name: "Worker \(index)", vendor: nil, isKnown: false, appPath: "",
            ai: counters, egress: FlowCounters(), providers: [("OpenAI", counters)],
            destinations: [
                AgentDestination(
                    label: "api.provider.test", ip: "203.0.113.10", provider: "OpenAI",
                    protocols: ["https"], ports: "443", counters: counters
                )
            ],
            alerts: 0
        )
    }

    private func pluginExchange() -> HTTPExchange {
        HTTPExchange(
            id: nil, started: Date(timeIntervalSince1970: TimeInterval(fixedTimestamp)), duration: 0.2,
            scheme: "https", host: "api.example.test", port: 443, method: "DELETE",
            path: "/admin/delete?token=redacted",
            status: 200,
            requestHeaders: [
                HTTPHeader(name: "Authorization", value: "Bearer redacted"),
                HTTPHeader(name: "X-API-Key", value: "redacted"),
            ],
            requestBody: Data("{\"value\":\"redacted\"}".utf8), requestSize: 700_000, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent",
            agent: "agent", agentName: "Agent", mcpServer: nil,
            toolCalls: [], toolResults: [], mcp: [], llm: nil, note: nil, mockRule: nil, guardrail: nil
        )
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-performance-\(name)-\(UUID().uuidString).sqlite")
    }

    private func removeTemporaryDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private final class BudgetTrafficSource: TrafficSource {
    let displayName = "Performance budget source"
    private(set) var started = false

    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void) {
        started = true
        status("ready")
    }

    func stop() {}
    func setRulePacks(_ snapshot: RulePackSnapshot?) {}
}
