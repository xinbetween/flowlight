import Foundation

/// Local, advisory assessment of an inspected request. This is intentionally separate from both raw capture and
/// anomaly alerts: a score is a private, versioned interpretation of a request, not a network enforcement decision.
enum RiskSeverity: String, Codable, CaseIterable, Sendable, Comparable {
    case none, low, medium, high

    private var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (lhs: RiskSeverity, rhs: RiskSeverity) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .none: return L("No concerns found")
        case .low: return L("Low")
        case .medium: return L("Medium")
        case .high: return L("High")
        }
    }

    var symbol: String {
        switch self {
        case .none: return "checkmark.circle"
        case .low: return "exclamationmark.circle"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.octagon.fill"
        }
    }
}

enum RiskAssessmentState: String, Codable, CaseIterable, Sendable {
    case pending, processing, deferred, scored, unavailable, failed
}

struct RiskEvidence: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var detail: String
    var weight: Int
}

/// The redacted, bounded description a model may receive. It deliberately has no request or response body, header
/// values, host name, query values, cookies, credentials or tool arguments.
struct RiskCandidate: Codable, Equatable, Sendable {
    static let analyzerVersion = 1

    var exchangeID: Int64
    var analyzerVersion: Int
    var method: String
    var destinationClass: String
    var pathCategory: String
    var contentTypeCategory: String
    var requestBytes: Int
    var responseBytes: Int
    var requestTruncated: Bool
    var responseTruncated: Bool
    var appKind: String
    var hasAgent: Bool
    var hasMCP: Bool
    var toolNames: [String]
    var safeHeaderNames: [String]
    var evidence: [RiskEvidence]

    /// The compact, stable prompt input. It is plain text because it is also useful when auditing a persisted job.
    var modelContext: String {
        let evidenceText = evidence.map { "- [\($0.id)] \($0.detail)" }.joined(separator: "\n")
        return """
        Request facts (redacted and local):
        method: \(method)
        destination class: \(destinationClass)
        path category: \(pathCategory)
        content type category: \(contentTypeCategory)
        request bytes: \(requestBytes)\(requestTruncated ? " (captured portion truncated)" : "")
        response bytes: \(responseBytes)\(responseTruncated ? " (captured portion truncated)" : "")
        application kind: \(appKind)
        agent attribution: \(hasAgent ? "present" : "absent")
        MCP attribution: \(hasMCP ? "present" : "absent")
        tool names: \(toolNames.isEmpty ? "none" : toolNames.joined(separator: ", "))
        non-sensitive header names: \(safeHeaderNames.isEmpty ? "none" : safeHeaderNames.joined(separator: ", "))
        Deterministic signals:
        \(evidenceText)
        """
    }
}

struct RiskAssessment: Codable, Equatable, Sendable, Identifiable {
    var exchangeID: Int64
    var analyzerVersion: Int
    var state: RiskAssessmentState
    var severity: RiskSeverity?
    var confidence: Double?
    var summary: String?
    var evidence: [RiskEvidence]
    var modelEvidenceIDs: [String]
    var createdAt: Date
    var scoredAt: Date?
    var candidate: RiskCandidate

    var id: Int64 { exchangeID }
    var isPotentialHarm: Bool { state == .scored && (severity == .medium || severity == .high) }
}

struct RiskAssessmentCounts: Equatable, Sendable {
    var medium = 0
    var high = 0
    var unassessed = 0

    var totalPotentialHarm: Int { medium + high }
}

/// A result returned from the model boundary before Flowlight validates and persists it.
struct RiskModelVerdict: Equatable, Sendable {
    var severity: String
    var confidence: Double
    var summary: String
    var evidenceIDs: [String]
}

enum LocalRiskProviderResult: Sendable {
    case scored(RiskModelVerdict)
    case unavailable(String)
    case deferred(String)
    case failed(String)
}

protocol LocalRiskProviding: Sendable {
    func assess(_ candidate: RiskCandidate) async -> LocalRiskProviderResult
}

struct UnavailableLocalRiskProvider: LocalRiskProviding {
    let reason: String

    func assess(_ candidate: RiskCandidate) async -> LocalRiskProviderResult { .unavailable(reason) }
}

/// Persistent, shared user choice. The switch is opt-in because inspected traffic can be sensitive even when the
/// model never sends it off the Mac.
enum LocalRiskSettings {
    enum Keys {
        static let enabled = "localRiskAnalysis.enabled"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Keys.enabled: false])
    }

    /// The person's saved opt-in preference. Keep it intact if they temporarily open the database on a Mac without
    /// Apple Intelligence, so a model download or returning to their capable Mac does not silently discard it.
    static var preferenceEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// Whether Flowlight should durably queue an eligible post-capture candidate. A temporary unavailable model
    /// leaves this intent alone so the candidate can resume only after the local model becomes ready.
    static var enabled: Bool { preferenceEnabled }

    static var readiness: OnDeviceAsk.Readiness { OnDeviceAsk.readiness }
    static var canAnalyze: Bool { readiness == .ready }
    /// What screens expose. On a Mac without the model, retained analysis stays invisible and the switch is shown
    /// disabled and off rather than looking like a working choice.
    static var isActive: Bool { preferenceEnabled && canAnalyze }
}

/// Pure, conservative triage. It produces only evidence supported by captured metadata, never a conclusion that a
/// hostname is malicious. A candidate needs independent context before it is sent to the local language model.
enum LocalRiskTriage {
    static func candidate(for exchange: HTTPExchange) -> RiskCandidate? {
        guard exchange.note == nil, !exchange.host.isEmpty, exchange.scheme == "http" || exchange.scheme == "https" else { return nil }
        let destination = destinationClass(exchange.host)
        let path = pathCategory(exchange.path)
        let content = contentTypeCategory(exchange.contentType)
        // Multipart and opaque/binary uploads have no safe preview in the initial release. Metadata alone is not
        // enough contextual evidence to justify model work, so leave them unassessed rather than guessing.
        guard content != "multipart", content != "other" else { return nil }
        let tools = Array(Set(exchange.toolCalls.map(\.name).filter { !$0.isEmpty }.map(normalizeToolName))).sorted()
        let headers = exchange.requestHeaders.map(\.name).filter(isSafeHeaderName).map { $0.lowercased() }.sorted()
        var evidence: [RiskEvidence] = []

        let adminPath = ["admin", "control", "metadata", "credentials", "config"].contains(path)
        if ["loopback", "private-network"].contains(destination), adminPath {
            evidence.append(.init(id: "private-admin-target", detail: L("The request targets a private or local service through an administrative-looking route."), weight: 3))
        } else if ["loopback", "private-network"].contains(destination) {
            evidence.append(.init(id: "private-target", detail: L("The request targets a private or local service."), weight: 1))
        }

        let likelyUpload = exchange.requestSize >= 256_000 && exchange.requestSize > max(4_096, exchange.responseSize * 3)
        if likelyUpload {
            evidence.append(.init(id: "large-upload", detail: L("The request uploads substantially more data than it receives."), weight: 2))
        }

        let riskyTools = tools.filter { isSensitiveTool($0) }
        if !riskyTools.isEmpty {
            evidence.append(.init(id: "sensitive-tool-context", detail: L("The request is associated with a tool that can act on files, commands, credentials, or remote services."), weight: 2))
        }

        if exchange.mcp.contains(where: { $0.method == "tools/call" }), !exchange.mcp.isEmpty {
            evidence.append(.init(id: "mcp-tool-call", detail: L("The request is part of an MCP tool call."), weight: 1))
        }

        if exchange.guardrail != nil {
            evidence.append(.init(id: "guardrail-provenance", detail: L("Flowlight changed this request with a guardrail before it was sent."), weight: 0))
        }
        if exchange.mockRule != nil {
            evidence.append(.init(id: "mock-provenance", detail: L("Flowlight answered this request locally with a mock rule."), weight: 0))
        }

        // A single weak context signal is intentionally not enough. Provenance is useful in an existing finding but
        // cannot make one by itself; routine static assets and ordinary API calls therefore never reach the model.
        let substantive = evidence.filter { $0.weight > 0 }
        let score = substantive.reduce(0) { $0 + $1.weight }
        let independentSignals = substantive.count
        guard score >= 3 && (independentSignals >= 2 || substantive.contains(where: { $0.weight >= 3 })) else { return nil }

        return RiskCandidate(exchangeID: exchange.id ?? 0, analyzerVersion: RiskCandidate.analyzerVersion,
                             method: exchange.method.uppercased(), destinationClass: destination, pathCategory: path,
                             contentTypeCategory: content, requestBytes: exchange.requestSize, responseBytes: exchange.responseSize,
                             requestTruncated: exchange.requestTruncated, responseTruncated: exchange.responseTruncated,
                             appKind: exchange.agent == nil ? "application" : "agent-associated application",
                             hasAgent: exchange.agent != nil, hasMCP: !exchange.mcp.isEmpty || exchange.mcpServer != nil,
                             toolNames: Array(tools.prefix(8)), safeHeaderNames: Array(headers.prefix(16)), evidence: evidence)
    }

    private static func destinationClass(_ host: String) -> String {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasPrefix("127.") { return "loopback" }
        let octets = lower.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4,
           octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1])) { return "private-network" }
        return "named internet service"
    }

    private static func pathCategory(_ path: String) -> String {
        let lower = path.split(separator: "?", maxSplits: 1).first.map(String.init)?.lowercased() ?? "/"
        if lower.contains("metadata") { return "metadata" }
        if lower.contains("credential") || lower.contains("token") || lower.contains("secret") { return "credentials" }
        if lower.contains("admin") || lower.contains("manage") { return "admin" }
        if lower.contains("config") || lower.contains("settings") { return "config" }
        if lower.contains("upload") || lower.contains("import") { return "upload" }
        if lower.contains("api") || lower.hasPrefix("/v") { return "api" }
        return "other"
    }

    private static func contentTypeCategory(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("multipart") { return "multipart" }
        if lower.contains("json") { return "json" }
        if lower.contains("form") { return "form" }
        if lower.hasPrefix("text/") { return "text" }
        if lower.isEmpty { return "unknown" }
        return "other"
    }

    private static func normalizeToolName(_ value: String) -> String {
        String(value.prefix(80)).lowercased()
    }

    private static func isSensitiveTool(_ name: String) -> Bool {
        ["bash", "shell", "terminal", "exec", "command", "curl", "upload", "write", "delete", "ssh", "git", "file"].contains {
            name.localizedCaseInsensitiveContains($0)
        }
    }

    private static func isSafeHeaderName(_ value: String) -> Bool {
        let lower = value.lowercased()
        return !["authorization", "cookie", "set-cookie", "x-api-key", "proxy-authorization", "x-amz-security-token"].contains(lower)
    }
}

/// A one-owner background worker. Its database calls claim and persist tiny rows synchronously from outside the
/// database queue; model inference is never performed in the recorder, database queue, proxy, or Network Extension.
actor LocalRiskCoordinator {
    private let db: TrafficDatabase
    private let provider: any LocalRiskProviding
    private let isAvailable: @Sendable () -> Bool
    private var worker: Task<Void, Never>?
    /// Identifies the current task so a cancelled older run cannot clear a newer worker after a quick off/on.
    private var workerID: UUID?
    private let onChange: @Sendable () -> Void

    init(db: TrafficDatabase, provider: any LocalRiskProviding,
         isAvailable: @escaping @Sendable () -> Bool = { LocalRiskSettings.canAnalyze },
         onChange: @escaping @Sendable () -> Void) {
        self.db = db
        self.provider = provider
        self.isAvailable = isAvailable
        self.onChange = onChange
    }

    func wake() {
        guard LocalRiskSettings.enabled, worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in await self?.drain(id: id) }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        workerID = nil
    }

    func recover() {
        guard LocalRiskSettings.enabled else { return }
        // A maintenance tick must not reclaim this actor's active request: it is already the sole owner. Recovery is
        // for a fresh coordinator after a crash/relaunch, when no in-flight task exists in this process.
        if worker == nil { _ = try? db.sync { try $0.recoverLocalRiskClaims() } }
        wake()
    }

    func backfillRecent() {
        guard LocalRiskSettings.enabled else { return }
        _ = try? db.sync { try $0.enqueueRecentLocalRiskCandidates(limit: 100) }
        onChange()
        wake()
    }

    private func drain(id: UUID) async {
        defer {
            if workerID == id {
                worker = nil
                workerID = nil
            }
        }
        while !Task.isCancelled && LocalRiskSettings.enabled {
            // Do not consume queued work while Apple Intelligence is downloading, disabled, or otherwise not ready.
            // Maintenance will wake this worker again when the exact same readiness gate becomes available.
            guard isAvailable() else { break }
            guard let assessment = try? db.sync({ try $0.claimNextLocalRiskAssessment() }) else { break }
            let result = await provider.assess(assessment.candidate)
            guard !Task.isCancelled, LocalRiskSettings.enabled else {
                _ = try? db.sync { try $0.deferLocalRiskAssessment(exchangeID: assessment.exchangeID) }
                break
            }
            _ = try? db.sync { try $0.completeLocalRiskAssessment(exchangeID: assessment.exchangeID, result: result) }
            onChange()
        }
    }
}
