import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AgentAdvisoryAnalysisMode: String, CaseIterable, Identifiable, Sendable {
    case appleOnDevice, inventoryOnly

    static let preferenceKey = "FLAgentAdvisoryAnalysisMode"
    static let defaultMode: Self = .appleOnDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleOnDevice: return L("Apple on-device model")
        case .inventoryOnly: return L("Inventory only")
        }
    }
}

/// The model boundary accepts fixed category/level values and aggregate counts only.
struct AgentAdvisoryAnalysisInput: Equatable, Sendable {
    struct Evidence: Equatable, Sendable {
        let id: String
        let category: AgentAdvisoryFinding.Category
        let count: Int
        let highestSeverity: AgentAdvisoryFinding.Severity
    }

    var evidence: [Evidence]
    var filesInspected: Int
    var settingsInspected: Int
    var complete: Bool
    var privateDataAccess: Bool
    var untrustedContent: Bool
    var externalEgress: Bool

    init(result: AgentAdvisoryScanResult) {
        evidence = AgentAdvisoryFinding.Category.allCases.enumerated().compactMap { index, category in
            let matches = result.observedEvidence.filter { $0.category == category }
            guard let highest = matches.map(\.severity).max() else { return nil }
            return Evidence(id: "e\(index + 1)", category: category,
                            count: matches.reduce(0) { $0 + $1.count }, highestSeverity: highest)
        }
        filesInspected = result.sources.reduce(0) { $0 + $1.filesRead }
        settingsInspected = result.settingsInspected
        complete = result.complete
        privateDataAccess = result.privateDataAccess
        untrustedContent = result.untrustedContent
        externalEgress = result.externalEgress
    }

    var prompt: String {
        let rows = evidence.map { "\($0.id) category=\($0.category.rawValue) count=\($0.count) severity=\($0.highestSeverity.rawValue)" }
        return ([
            "files_inspected=\(filesInspected) settings_inspected=\(settingsInspected) scan_complete=\(complete)",
            "private_data_access_signal=\(privateDataAccess) untrusted_content_signal=\(untrustedContent) external_egress_signal=\(externalEgress)",
            "Severity scale: 0 informational, 1 low, 2 medium, 3 high, 4 critical."
        ] + rows).joined(separator: "\n")
    }
}

struct AgentAdvisoryAnalysisSummary: Equatable, Sendable {
    let text: String
    let categories: [AgentAdvisoryFinding.Category]

    init?(text: String, references: String, input: AgentAdvisoryAnalysisInput) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_200, references.utf8.count <= 64 else { return nil }
        let ids = references.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...3).contains(ids.count), Set(ids).count == ids.count else { return nil }
        let categories = ids.compactMap { id in input.evidence.first { $0.id == id }?.category }
        guard categories.count == ids.count else { return nil }
        self.text = trimmed
        self.categories = categories
    }
}

enum AgentAdvisoryAnalysisState: Equatable, Sendable {
    case idle, noEvidence, analyzing, unavailable(String), failed, complete(AgentAdvisoryAnalysisSummary)
}

protocol AgentAdvisoryAnalyzing: Sendable {
    func analyze(_ input: AgentAdvisoryAnalysisInput) async -> AgentAdvisoryAnalysisState
}

struct AppleAgentAdvisoryAnalyzer: AgentAdvisoryAnalyzing {
    func analyze(_ input: AgentAdvisoryAnalysisInput) async -> AgentAdvisoryAnalysisState {
        guard !input.evidence.isEmpty else { return .noEvidence }
        switch OnDeviceAsk.readiness {
        case .ready: break
        case .needsNewerMacOS: return .unavailable(L("The on-device model needs macOS 26 or later."))
        case .deviceNotEligible: return .unavailable(L("This Mac can't run the on-device model."))
        case .notEnabled(let reason): return .unavailable(reason)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return await FoundationAgentAdvisoryAnalyzer().analyze(input)
        }
        #endif
        return .unavailable(L("The on-device model isn't available right now."))
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private struct FoundationAgentAdvisoryAnalyzer {
    @Generable
    struct Response {
        @Guide(description: "At most three short sentences describing which observed categories to review first and why. Use only the supplied evidence.")
        var summary: String
        @Guide(description: "One to three of the supplied evidence IDs, separated by commas, most important first.")
        var references: String
    }

    func analyze(_ input: AgentAdvisoryAnalysisInput) async -> AgentAdvisoryAnalysisState {
        let session = LanguageModelSession(instructions: """
            You help a Mac user review a local agent settings inventory. You receive only aggregate metadata signals.
            Prioritize observed categories by severity and relevance to the signals. Describe what the user can review
            in plain language. Never invent file details, permission grants, incidents, or safety guarantees. A signal
            is a reason to review, and absence of a signal is inconclusive. Cite only IDs from the evidence provided.
            """)
        do {
            let response = try await session.respond(to: input.prompt, generating: Response.self)
            try Task.checkCancellation()
            guard let summary = AgentAdvisoryAnalysisSummary(text: response.content.summary,
                                                             references: response.content.references,
                                                             input: input) else { return .failed }
            return .complete(summary)
        } catch is CancellationError {
            return .idle
        } catch {
            return .failed
        }
    }
}
#endif
