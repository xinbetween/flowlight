import XCTest
@testable import Flowlight

final class AgentAdvisoryAnalysisTests: XCTestCase {
    func testDefaultAnalysisModeIsAppleOnDevice() {
        XCTAssertEqual(AgentAdvisoryAnalysisMode.defaultMode, .appleOnDevice)
    }

    func testPromptUsesAggregateEvidenceAndNeverPassesFindingTextOrPaths() {
        let input = AgentAdvisoryAnalysisInput(result: fixture())
        XCTAssertEqual(input.evidence.count, 1)
        XCTAssertEqual(input.evidence.first?.category, .hooks)
        XCTAssertEqual(input.evidence.first?.count, 24, "count includes rows omitted by the display cap")
        XCTAssertEqual(input.settingsInspected, 1)
        XCTAssertTrue(input.prompt.contains("category=hooks count=24 severity=3"))
        for forbidden in ["SECRET", "/private", "https://", "hint-to-model"] {
            XCTAssertFalse(input.prompt.contains(forbidden))
        }
    }

    func testModelSummaryRejectsUnknownRepeatedOrMalformedEvidenceReferences() throws {
        let input = AgentAdvisoryAnalysisInput(result: fixture())
        let evidence = try XCTUnwrap(input.evidence.first)
        for invalid in ["", "unobserved", "\(evidence.id),\(evidence.id)", "\(evidence.id),"] {
            XCTAssertNil(AgentAdvisoryAnalysisSummary(text: "Review the observed hooks.", references: invalid, input: input))
        }
        XCTAssertNil(AgentAdvisoryAnalysisSummary(text: String(repeating: "x", count: 1_201),
                                                 references: evidence.id, input: input))
        XCTAssertEqual(AgentAdvisoryAnalysisSummary(text: "Review the observed hooks.", references: evidence.id, input: input)?.categories,
                       [.hooks])
    }

    @MainActor
    func testUnavailableAndFailedModelKeepDeterministicReport() async throws {
        let inventory = fixture()
        for outcome in [AgentAdvisoryAnalysisState.unavailable("Unavailable in fixture"), .failed] {
            let model = AgentAdvisoryModel(analyzer: FixedAnalyzer(result: outcome), additionalRoots: [])
            let task = try XCTUnwrap(model.startAnalysis(inventory))
            await task.value
            XCTAssertEqual(model.analysis, outcome)
            // Analysis takes a value-only evidence projection. It cannot replace the scanned findings.
            XCTAssertEqual(inventory.totalFindingCount, 24)
        }
    }

    @MainActor
    func testSwitchingToInventoryDiscardsAnInFlightModelResult() async throws {
        let fake = DelayedAnalyzer()
        let model = AgentAdvisoryModel(analyzer: fake, additionalRoots: [])
        let task = try XCTUnwrap(model.startAnalysis(fixture()))
        let started = await fake.started()
        XCTAssertEqual(started.evidence.count, 1)
        model.selectAnalysisMode(.inventoryOnly)
        await fake.complete(with: .failed)
        await task.value
        XCTAssertEqual(model.analysis, .idle)
        XCTAssertNil(model.startAnalysis(fixture()))
    }

    private func fixture() -> AgentAdvisoryScanResult {
        var source = AgentAdvisorySourceResult(root: "/private/home", status: .complete,
                                              directoriesVisited: 1, candidateFiles: 1, filesRead: 1,
                                              bytesRead: 10, findings: 1, reasons: [])
        source.settingsInspected = 1
        source.omittedFindings = 23
        let finding = AgentAdvisoryFinding(id: "hint-to-model:/private/settings.json", agent: "SECRET agent",
                                          category: .hooks, severity: .high, surface: .internalThreat,
                                          source: "/private/settings.json", title: "SECRET credentials",
                                          explanation: "https://private.example", remediation: "SECRET command",
                                          hasPrivateDataAccess: false, hasUntrustedContent: true, hasExternalEgress: false)
        var result = AgentAdvisoryScanResult(findings: [finding], sources: [source], privateDataAccess: false,
                                             untrustedContent: true, externalEgress: false)
        result.observedEvidence = [.init(category: .hooks, severity: .high, count: 24,
                                         hasPrivateDataAccess: false, hasUntrustedContent: true, hasExternalEgress: false)]
        return result
    }

    private struct FixedAnalyzer: AgentAdvisoryAnalyzing {
        let result: AgentAdvisoryAnalysisState
        func analyze(_ input: AgentAdvisoryAnalysisInput) async -> AgentAdvisoryAnalysisState { result }
    }

    private actor DelayedAnalyzer: AgentAdvisoryAnalyzing {
        private var input: AgentAdvisoryAnalysisInput?
        private var pendingStart: CheckedContinuation<AgentAdvisoryAnalysisInput, Never>?
        private var pendingResult: CheckedContinuation<AgentAdvisoryAnalysisState, Never>?

        func analyze(_ input: AgentAdvisoryAnalysisInput) async -> AgentAdvisoryAnalysisState {
            self.input = input
            pendingStart?.resume(returning: input)
            pendingStart = nil
            return await withCheckedContinuation { pendingResult = $0 }
        }

        func started() async -> AgentAdvisoryAnalysisInput {
            if let input { return input }
            return await withCheckedContinuation { pendingStart = $0 }
        }

        func complete(with result: AgentAdvisoryAnalysisState) {
            pendingResult?.resume(returning: result)
            pendingResult = nil
        }
    }
}
