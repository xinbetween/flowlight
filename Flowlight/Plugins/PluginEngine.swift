import Foundation

protocol InspectionPluginRule: Sendable {
    var manifest: PluginManifest { get }
    func evaluate(_ context: PluginContext) -> [PluginFindingDraft]
}

struct PluginContext: Sendable {
    var exchange: HTTPExchange
    var requestHeaderNames: Set<String>
    var responseHeaderNames: Set<String>
    var pathWithoutQuery: String

    init(exchange: HTTPExchange) {
        self.exchange = exchange
        requestHeaderNames = Set(exchange.requestHeaders.map { $0.name.lowercased() })
        responseHeaderNames = Set(exchange.responseHeaders.map { $0.name.lowercased() })
        pathWithoutQuery = exchange.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? exchange.path
    }

    var agentLabel: String { exchange.agentName ?? exchange.agent ?? exchange.appName }
    var isLLMOrMCP: Bool { exchange.llm != nil || !exchange.toolCalls.isEmpty || !exchange.mcp.isEmpty || exchange.mcpServer != nil }
}

enum PluginEngine {
    static let builtInRules: [any InspectionPluginRule] = [
        LargeUploadRule(),
        RiskyMethodRule(),
        SensitiveHeaderRule(),
        MCPOverHTTPRule(),
        ProviderConnectorRule(),
        HighRiskToolRule(),
    ]

    static var builtInManifests: [PluginManifest] { builtInRules.map(\.manifest) }

    static func evaluate(_ exchange: HTTPExchange, manifests: [PluginManifest]) -> [PluginFindingDraft] {
        evaluateBuiltIns(exchange, manifests: manifests) + PluginScriptRunner.shared.evaluate(exchange: exchange, manifests: manifests)
    }

    static func evaluateBuiltIns(_ exchange: HTTPExchange, manifests: [PluginManifest]) -> [PluginFindingDraft] {
        let enabled = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0.enabled) })
        let context = PluginContext(exchange: exchange)
        return builtInRules.flatMap { rule -> [PluginFindingDraft] in
            guard enabled[rule.manifest.id] == true else { return [] }
            return rule.evaluate(context)
        }
    }

    static func mergedManifests(_ stored: [PluginManifest]) -> [PluginManifest] {
        var byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for builtIn in builtInManifests {
            if var existing = byID[builtIn.id] {
                let enabled = existing.enabled
                let configuration = existing.configuration
                existing = builtIn
                existing.enabled = enabled
                existing.configuration = configuration
                byID[builtIn.id] = existing
            } else {
                byID[builtIn.id] = builtIn
            }
        }
        return byID.values.sorted { $0.name < $1.name }
    }
}

private extension InspectionPluginRule {
    func finding(_ severity: PluginFinding.Severity, _ title: String, _ summary: String,
                 _ evidence: [PluginEvidence], suggestedGuardrail: Guardrail? = nil) -> PluginFindingDraft {
        PluginFindingDraft(pluginID: manifest.id, pluginVersion: manifest.version, kind: manifest.kind, severity: severity,
                           title: title, summary: summary, evidence: evidence, suggestedGuardrail: suggestedGuardrail)
    }
}

private struct LargeUploadRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "traffic.large-upload", name: "Large uploads", version: "1.0.0", kind: .traffic,
        description: L("Flags inspected requests that upload unusually large payloads."),
        privacySummary: L("Uses request size, method, app and host metadata only."))

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        guard context.exchange.requestSize >= 512 * 1024 else { return [] }
        return [finding(.medium, L("Large upload"),
                        L("%@ sent %@ in one inspected %@ request.", context.exchange.appName, ByteCountFormatter.string(fromByteCount: Int64(context.exchange.requestSize), countStyle: .file), context.exchange.method),
                        [PluginEvidence(L("Host"), context.exchange.host), PluginEvidence(L("Method"), context.exchange.method),
                         PluginEvidence(L("Request size"), ByteCountFormatter.string(fromByteCount: Int64(context.exchange.requestSize), countStyle: .file))])]
    }
}

private struct RiskyMethodRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "traffic.risky-method", name: "Risky HTTP methods", version: "1.0.0", kind: .traffic,
        description: L("Highlights destructive-looking HTTP requests."),
        privacySummary: L("Uses method, redacted path shape and host metadata only."))

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        let method = context.exchange.method.uppercased()
        guard ["DELETE", "PATCH", "PUT"].contains(method) else { return [] }
        let path = context.pathWithoutQuery.lowercased()
        let interesting = ["/admin", "/delete", "/destroy", "/token", "/key", "/secret", "/user"].contains { path.contains($0) }
        guard interesting || method == "DELETE" else { return [] }
        return [finding(method == "DELETE" ? .medium : .low, L("Destructive-looking request"),
                        L("%@ made a %@ request to a sensitive-looking path on %@.", context.exchange.appName, method, context.exchange.host),
                        [PluginEvidence(L("Host"), context.exchange.host), PluginEvidence(L("Method"), method),
                         PluginEvidence(L("Path"), context.pathWithoutQuery, limit: 160)])]
    }
}

private struct SensitiveHeaderRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "traffic.sensitive-headers", name: "Sensitive header names", version: "1.0.0", kind: .traffic,
        description: L("Notes requests carrying credential-like header names."),
        privacySummary: L("Reads header names only; values are never exposed."))

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        let sensitive = context.requestHeaderNames.filter { name in
            name == "authorization" || name == "cookie" || name.contains("api-key") || name.contains("token") || name.contains("secret")
        }.sorted()
        guard !sensitive.isEmpty else { return [] }
        return [finding(.info, L("Credential-like headers present"),
                        L("This request included credential-like header names. Values remain redacted."),
                        [PluginEvidence(L("Header names"), sensitive.joined(separator: ", "))])]
    }
}

private struct MCPOverHTTPRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "llm-mcp.http-mcp", name: "HTTP MCP activity", version: "1.0.0", kind: .llmMCP,
        description: L("Surfaces direct MCP activity observed over inspected HTTP."),
        privacySummary: L("Uses MCP method, server and tool names only."))

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        guard !context.exchange.mcp.isEmpty else { return [] }
        let methods = Set(context.exchange.mcp.map(\.method)).sorted().joined(separator: ", ")
        return [finding(.info, L("MCP over HTTP observed"),
                        L("%@ used MCP over inspected HTTP with %@.", context.agentLabel, context.exchange.host),
                        [PluginEvidence(L("Methods"), methods), PluginEvidence(L("Host"), context.exchange.host)])]
    }
}

private struct ProviderConnectorRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "llm-mcp.provider-connectors", name: "Provider-run MCP connectors", version: "1.0.0", kind: .llmMCP,
        description: L("Explains MCP connectors that run on the model provider side."),
        privacySummary: L("Uses connector labels, provider names and approval metadata only."))

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        guard let llm = context.exchange.llm, !llm.connectors.isEmpty else { return [] }
        return llm.connectors.map { connector in
            var evidence = [PluginEvidence(L("Provider"), connector.provider), PluginEvidence(L("Connector"), connector.label)]
            if let approval = connector.approval { evidence.append(PluginEvidence(L("Approval"), approval)) }
            if connector.authorized { evidence.append(PluginEvidence(L("Authorization"), L("configured"))) }
            let severity: PluginFinding.Severity = connector.authorized ? .medium : .low
            return finding(severity, L("Provider-run MCP connector"),
                           L("%@ offered %@ through %@. Its network calls run outside this Mac, so local network rules may not see them.",
                             context.agentLabel, connector.label, connector.provider), evidence)
        }
    }
}

private struct HighRiskToolRule: InspectionPluginRule {
    let manifest = PluginManifest(
        id: "llm-mcp.high-risk-tools", name: "High-risk tools", version: "1.0.0", kind: .llmMCP,
        description: L("Suggests guardrails for declared or used tools with write, shell or delete capability."),
        privacySummary: L("Uses tool and MCP server names only, not tool arguments."), capabilities: [.annotate, .suggestGuardrail])

    private let patterns = ["bash", "shell", "exec", "terminal", "write", "edit", "delete", "remove", "create", "update", "patch", "apply"]

    func evaluate(_ context: PluginContext) -> [PluginFindingDraft] {
        var tools: [(name: String, server: String?)] = []
        if let llm = context.exchange.llm {
            tools += llm.declaredTools.compactMap { tool in
                guard tool.kind == .function else { return nil }
                return (tool.name, tool.server)
            }
        }
        tools += context.exchange.toolCalls.map { ($0.name, $0.mcpServer) }
        var seen = Set<String>()
        return tools.compactMap { tool in
            let key = [tool.server ?? "", tool.name].joined(separator: "/")
            guard seen.insert(key).inserted else { return nil }
            let lower = tool.name.lowercased()
            guard patterns.contains(where: { lower.contains($0) }) else { return nil }
            var guardrail = Guardrail(agent: context.exchange.agent ?? "", server: tool.server ?? "", tool: tool.name, origin: .observed)
            guardrail.name = L("Review %@", tool.server.map { "\($0) › \(tool.name)" } ?? tool.name)
            return finding(.medium, L("High-risk tool available"),
                           L("%@ declared or used %@. Add a guardrail if this tool should be refused.", context.agentLabel, tool.server.map { "\($0) › \(tool.name)" } ?? tool.name),
                           [PluginEvidence(L("Tool"), tool.name), PluginEvidence(L("Server"), tool.server ?? L("agent tool"))],
                           suggestedGuardrail: guardrail)
        }
    }
}
