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
                          responseBytes: Int = 1_000, tools: [ToolCall] = []) -> HTTPExchange {
        HTTPExchange(id: nil, started: Date(), duration: 0.1, scheme: "https", host: host, port: 443, method: "POST", path: path,
                     status: 200,
                     requestHeaders: [HTTPHeader(name: "Authorization", value: "Bearer very-secret-token"),
                                      HTTPHeader(name: "Cookie", value: "session=secret"), HTTPHeader(name: "Content-Type", value: "application/json")],
                     requestBody: Data("{\"token\":\"do-not-leak\"}".utf8), requestSize: requestBytes, requestTruncated: false,
                     responseHeaders: [], responseBody: Data(), responseSize: responseBytes, responseTruncated: false,
                     contentType: "application/json", pid: 1, bundleID: "agent", appName: "Agent", agent: "agent", agentName: "Agent",
                     mcpServer: nil, toolCalls: tools, toolResults: [], mcp: [], llm: nil, note: nil, mockRule: nil, guardrail: nil)
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
