import XCTest
@testable import Flowlight

final class LocalRiskAnalysisTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("local-risk-\(UUID()).sqlite")
        // Storage tests exercise durable opt-in behavior independently from whatever Foundation Models availability
        // the CI runner happens to report.
        UserDefaults.standard.set(true, forKey: LocalRiskSettings.Keys.enabled)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: LocalRiskSettings.Keys.enabled)
        super.tearDown()
    }

    private func database() throws -> TrafficDatabase { try TrafficDatabase(url: url) }

    private func exchange(host: String = "127.0.0.1", path: String = "/admin/config", requestBytes: Int = 600_000,
                          responseBytes: Int = 1_000, tools: [ToolCall] = [], bundleID: String = "agent",
                          agent: String? = "agent", mcpServer: String? = nil,
                          started: Date = Date()) -> HTTPExchange {
        HTTPExchange(id: nil, started: started, duration: 0.1, scheme: "https", host: host, port: 443, method: "POST", path: path,
                     status: 200,
                     requestHeaders: [HTTPHeader(name: "Authorization", value: "Bearer very-secret-token"),
                                      HTTPHeader(name: "Cookie", value: "session=secret"), HTTPHeader(name: "Content-Type", value: "application/json")],
                     requestBody: Data("{\"token\":\"do-not-leak\"}".utf8), requestSize: requestBytes, requestTruncated: false,
                     responseHeaders: [], responseBody: Data(), responseSize: responseBytes, responseTruncated: false,
                     contentType: "application/json", pid: 1, bundleID: bundleID, appName: bundleID,
                     agent: agent, agentName: agent, mcpServer: mcpServer, toolCalls: tools,
                     toolResults: [], mcp: [], llm: nil, note: nil, mockRule: nil, guardrail: nil)
    }

    func testTriageNeedsIndependentEvidenceAndNeverIncludesSecretValues() throws {
        let tool = ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "curl secret", summary: "curl secret")
        let candidate = try XCTUnwrap(LocalRiskTriage.candidate(for: exchange(tools: [tool])))
        XCTAssertTrue(candidate.evidence.contains { $0.id == "private-admin-target" })
        XCTAssertTrue(candidate.evidence.contains { $0.id == "large-upload" })
        XCTAssertTrue(candidate.evidence.contains { $0.id == "sensitive-tool-context" })
        XCTAssertFalse(candidate.safeHeaderNames.contains { $0.contains("authorization") || $0.contains("cookie") })
        XCTAssertFalse(candidate.modelContext.contains("very-secret-token"))
        XCTAssertFalse(candidate.modelContext.contains("do-not-leak"))
        XCTAssertFalse(candidate.modelContext.contains("curl secret"))

        XCTAssertNil(LocalRiskTriage.candidate(for: exchange(host: "ordinary.example", path: "/api", requestBytes: 1_000,
                                                             responseBytes: 2_000, tools: [])),
                     "A named host and ordinary request shape cannot become a harm claim by themselves")
    }

    func testRawInsertAndDerivedCandidateAreAtomicAndIdempotent() throws {
        let db = try database()
        UserDefaults.standard.set(true, forKey: LocalRiskSettings.Keys.enabled)
        let id = try db.insertExchange(exchange(tools: [ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "", summary: nil)]),
                                       enqueueLocalRisk: true)
        XCTAssertGreaterThan(id, 0)
        let found = try db.exchanges(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(found.count, 1, "Capture commits independently of later model work")
        let assessment = try XCTUnwrap(db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id])
        XCTAssertEqual(assessment.state, .pending)
        XCTAssertEqual(assessment.candidate.exchangeID, id)

        let claimed = try XCTUnwrap(db.claimNextLocalRiskAssessment())
        XCTAssertEqual(claimed.exchangeID, id)
        XCTAssertEqual(try db.claimNextLocalRiskAssessment(), nil, "Only one consumer can claim an assessment")
    }

    func testValidationRejectsInventedEvidenceAndClearKeepsRawExchange() throws {
        let db = try database()
        UserDefaults.standard.set(true, forKey: LocalRiskSettings.Keys.enabled)
        let id = try db.insertExchange(exchange(tools: [ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "", summary: nil)]),
                                       enqueueLocalRisk: true)
        _ = try db.claimNextLocalRiskAssessment()
        try db.completeLocalRiskAssessment(exchangeID: id, result: .scored(.init(severity: "high", confidence: 0.9,
                                                                                  summary: "bad", evidenceIDs: ["invented"])))
        XCTAssertEqual(try db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id]?.state, .failed)
        try db.clearLocalRiskAssessments()
        XCTAssertNil(try db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id])
        XCTAssertEqual(try db.exchangeBodies(id: id)?.request, Data("{\"token\":\"do-not-leak\"}".utf8))
    }

    func testDisablingHidesButRetainsAndPruningDeletesDerivedRows() throws {
        let db = try database()
        UserDefaults.standard.set(true, forKey: LocalRiskSettings.Keys.enabled)
        let id = try db.insertExchange(exchange(tools: [ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "", summary: nil)]),
                                       enqueueLocalRisk: true)
        XCTAssertNotNil(try db.localRiskAssessments(exchangeIDs: [id]))
        UserDefaults.standard.set(false, forKey: LocalRiskSettings.Keys.enabled)
        XCTAssertTrue(try db.localRiskAssessments(exchangeIDs: [id]).isEmpty)
        XCTAssertNotNil(try db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id])
        try db.pruneExchanges(olderThan: Date().addingTimeInterval(60))
        XCTAssertNil(try db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id])
    }

    func testRiskCountsHonorAgentChildAndMCPScopes() throws {
        let db = try database()
        let tool = ToolCall(source: .anthropic, callID: "risk", name: "Bash", mcpServer: nil,
                            input: "", summary: nil)
        for exchange in [
            exchange(host: "api.github.com", tools: [tool], bundleID: "node", agent: "claude", mcpServer: "github"),
            exchange(host: "api.github.com", tools: [tool], bundleID: "node", agent: "cursor", mcpServer: "github"),
            exchange(host: "api.github.com", tools: [tool], bundleID: "node", agent: "claude", mcpServer: "filesystem"),
            exchange(host: "api.anthropic.com", tools: [tool], bundleID: "claude", agent: "claude")
        ] {
            _ = try db.insertExchange(exchange, enqueueLocalRisk: true)
        }
        let since = Date().addingTimeInterval(-60)

        let root = try db.localRiskCounts(
            since: since,
            filter: TrafficFilter(bundleID: "claude", includeAttributedChildren: true),
            visibleOnly: false
        )
        XCTAssertEqual(root.unassessed, 3, "the root and both Claude-attributed children belong to the agent scope")

        let exact = try db.localRiskCounts(
            since: since,
            filter: TrafficFilter(bundleID: "node", agentParent: "claude", mcpServer: "github"),
            visibleOnly: false
        )
        XCTAssertEqual(exact.unassessed, 1, "other agents and MCP servers must stay outside the visible exact scope")

        let focused = try db.localRiskCounts(
            since: since,
            filter: TrafficFilter(
                bundleID: "node",
                agentParent: "claude",
                mcpServer: "github",
                domain: "api.github.com",
                focus: FocusScope(bundleIDs: ["claude"])
            ),
            visibleOnly: false
        )
        XCTAssertEqual(focused.unassessed, 1, "Focus on the parent agent must retain the visible attributed child")
    }

    func testRiskCountsHonorIntrinsicAliasScopeAndGlobalFocus() throws {
        let db = try database()
        let tool = ToolCall(source: .anthropic, callID: "risk", name: "Bash", mcpServer: nil,
                            input: "", summary: nil)
        for exchange in [
            exchange(host: "api.anthropic.com", tools: [tool], bundleID: "claude", agent: "claude"),
            exchange(host: "api.anthropic.com", tools: [tool], bundleID: "claude-code", agent: "claude-code"),
            exchange(host: "other.example", tools: [tool], bundleID: "claude", agent: "claude"),
            exchange(host: "api.anthropic.com", tools: [tool], bundleID: "other", agent: "other")
        ] {
            _ = try db.insertExchange(exchange, enqueueLocalRisk: true)
        }

        let counts = try db.localRiskCounts(
            since: Date().addingTimeInterval(-60),
            filter: TrafficFilter(
                bundleIDs: ["claude", "claude-code"],
                focus: FocusScope(hosts: ["api.anthropic.com"])
            ),
            visibleOnly: false
        )

        XCTAssertEqual(counts.unassessed, 2,
                       "risk counts must intersect the alias card with global Focus")
    }

    func testRiskCountsRefuseUnsupportedTrafficDimensionsAndUseHalfOpenWindow() throws {
        let db = try database()
        let tool = ToolCall(source: .anthropic, callID: "risk", name: "Bash", mcpServer: nil,
                            input: "", summary: nil)
        let start = Date()
        _ = try db.insertExchange(
            exchange(host: "api.github.com", tools: [tool], started: start),
            enqueueLocalRisk: true
        )
        _ = try db.insertExchange(
            exchange(host: "api.github.com", tools: [tool], started: start.addingTimeInterval(10)),
            enqueueLocalRisk: true
        )

        let unsupported = [
            TrafficFilter(owner: "Example Network"),
            TrafficFilter(appProtocol: "quic"),
            TrafficFilter(channel: .tunnel),
            TrafficFilter(remoteIP: "203.0.113.9"),
            TrafficFilter(domain: "api.github.com", remoteIP: "203.0.113.9")
        ]
        for filter in unsupported {
            XCTAssertEqual(
                try db.localRiskCounts(since: start.addingTimeInterval(-1), filter: filter, visibleOnly: false),
                RiskAssessmentCounts(),
                "unsupported exchange dimensions must not silently widen Potential harm"
            )
        }

        let bounded = try db.localRiskCounts(
            since: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(10),
            visibleOnly: false
        )
        XCTAssertEqual(bounded.unassessed, 1,
                       "the report window is half-open and excludes an exchange exactly at endDate")
    }

    func testRiskCountsKeepExactHostSeparateFromSubdomains() throws {
        let db = try database()
        let tool = ToolCall(source: .anthropic, callID: "risk", name: "Bash", mcpServer: nil,
                            input: "", summary: nil)
        for host in ["api.github.com", "child.api.github.com"] {
            _ = try db.insertExchange(exchange(host: host, tools: [tool]), enqueueLocalRisk: true)
        }

        let exact = try db.localRiskCounts(
            since: Date().addingTimeInterval(-60),
            filter: TrafficFilter(domain: "api.github.com"),
            visibleOnly: false
        )
        XCTAssertEqual(exact.unassessed, 1, "an exact traffic hostname must not include subdomain assessments")
    }

    func testPotentialHarmFilterRunsBeforeExchangeLimit() throws {
        let db = try database()
        let oldest = Date().addingTimeInterval(-1_000)
        let harmfulID = try db.insertExchange(
            exchange(tools: [ToolCall(source: .anthropic, callID: "risk", name: "Bash",
                                      mcpServer: nil, input: "", summary: nil)], started: oldest),
            enqueueLocalRisk: true
        )
        let claimed = try XCTUnwrap(db.claimNextLocalRiskAssessment())
        XCTAssertEqual(claimed.exchangeID, harmfulID)
        try db.completeLocalRiskAssessment(
            exchangeID: harmfulID,
            result: .scored(.init(severity: "high", confidence: 0.9, summary: "Review this request.",
                                  evidenceIDs: claimed.evidence.map(\.id)))
        )

        for offset in 1...500 {
            _ = try db.insertExchange(
                exchange(host: "ordinary.example", path: "/api", requestBytes: 1_000,
                         responseBytes: 2_000, tools: [], started: oldest.addingTimeInterval(Double(offset)))
            )
        }

        XCTAssertFalse(try db.exchanges(since: .distantPast).contains { $0.id == harmfulID },
                       "precondition: the ordinary 500-row query truncates the older request")
        let harmful = try db.exchanges(since: .distantPast, potentialHarmOnly: true)
        XCTAssertEqual(harmful.map(\.id), [harmfulID],
                       "risk filtering must happen before LIMIT so an older harmful request remains visible")
    }

    func testCoordinatorDoesNotClaimWhenAvailabilityGateIsOff() async throws {
        let db = try database()
        let id = try db.insertExchange(exchange(tools: [ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "", summary: nil)]),
                                       enqueueLocalRisk: true)
        let worker = LocalRiskCoordinator(db: db, provider: FakeProvider(), isAvailable: { false }) {}
        await worker.wake()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try db.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id]?.state, .pending)
    }

    func testCoordinatorScoresOnePersistedCandidate() async throws {
        let db = try database()
        UserDefaults.standard.set(true, forKey: LocalRiskSettings.Keys.enabled)
        let id = try db.sync { try $0.insertExchange(self.exchange(tools: [ToolCall(source: .anthropic, callID: "1", name: "Bash", mcpServer: nil, input: "", summary: nil)]),
                                                       enqueueLocalRisk: true) }
        let provider = FakeProvider()
        let done = expectation(description: "assessment persisted")
        let worker = LocalRiskCoordinator(db: db, provider: provider, isAvailable: { true }) { done.fulfill() }
        await worker.wake()
        await fulfillment(of: [done], timeout: 2)
        let assessment = try db.sync { try $0.localRiskAssessments(exchangeIDs: [id], visibleOnly: false)[id] }
        XCTAssertEqual(assessment?.state, .scored)
        XCTAssertEqual(assessment?.severity, .medium)
    }
}

private actor FakeProvider: LocalRiskProviding {
    func assess(_ candidate: RiskCandidate) async -> LocalRiskProviderResult {
        .scored(.init(severity: "medium", confidence: 0.8, summary: "Independent captured signals justify review.",
                      evidenceIDs: candidate.evidence.filter { $0.weight > 0 }.map(\.id)))
    }
}
