import Foundation

/// One tool call with everything known about it: when the model asked for it, what came back, and the network requests
/// its tool made.
struct ToolActivity: Identifiable, Equatable {
    struct Request: Equatable {
        var exchangeID: Int64
        var method: String
        var host: String
        var path: String
        var status: Int?
        var via: String?
    }

    var id: String
    var call: ToolCall
    var at: Date
    var result: ToolResult?
    var requests: [Request]

    enum Outcome { case ok, error, pending }
    var outcome: Outcome { result.map { $0.isError ? .error : .ok } ?? .pending }
}

/// An MCP server an agent used, combined from its MCP config (network attribution), the model's tool calls
/// (`mcp__server__tool`), JSON-RPC traffic to remote servers, and the connectors declared to the provider.
struct MCPServerSummary: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// A process on this Mac, started by the agent.
        case local
        /// This Mac speaks JSON-RPC to it over HTTP.
        case remote
        /// The provider connects to it for the agent; that traffic never touches this Mac.
        case provider
    }

    var name: String
    var kind: Kind = .local
    var version: String?
    /// Endpoint (host + path) or the URL declared to the provider.
    var endpoint: String?
    /// Tools the server offers, from tools/list, mcp_list_tools, or the tools the agent declared.
    var tools: [String] = []
    /// How often each tool was actually called.
    var used: [String: Int] = [:]
    var calls = 0
    var errors = 0
    /// OpenAI's require_approval for a provider connector.
    var approval: String?
    /// Tools the agent allowed from this server, when it restricted them.
    var allowedTools: [String]?
    /// The agent sent the provider a token for this server.
    var authorized = false
    var lastUsed: Date?
    var id: String { name.lowercased() }
    var isRemote: Bool { kind != .local }
}

/// What an agent's inspected LLM calls say about it: models, cost, and the tools it offers the model.
struct AgentProfile: Equatable {
    var requests = 0
    var failures = 0
    var usage = TokenUsage()
    /// Requests per model, busiest first.
    var models: [(name: String, requests: Int)] = []
    /// Every tool the agent declared, with how often the model actually called it.
    var tools: [(tool: DeclaredTool, used: Int)] = []
    var lastSeen: Date?

    var providerName: String? {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openAIChat, .openAIResponses: return "OpenAI"
        case .gemini: return "Gemini"
        case nil: return nil
        }
    }
    var provider: LLMFacts.Provider?

    static func == (a: AgentProfile, b: AgentProfile) -> Bool {
        a.requests == b.requests && a.failures == b.failures && a.usage == b.usage && a.provider == b.provider
            && a.models.map(\.name) == b.models.map(\.name) && a.tools.map(\.tool) == b.tools.map(\.tool)
            && a.tools.map(\.used) == b.tools.map(\.used)
    }
}

enum ToolActivityBuilder {
    /// Agent id → tool calls, newest first.
    static func activities(_ exchanges: [HTTPExchange]) -> [String: [ToolActivity]] {
        var results: [String: ToolResult] = [:]
        for exchange in exchanges {
            for result in exchange.toolResults where results[result.callID] == nil { results[result.callID] = result }
        }
        var requestsByCall: [String: [ToolActivity.Request]] = [:]
        for (exchangeID, link) in ToolCallLinks.link(exchanges) {
            guard let callID = link.call.callID, let e = exchanges.first(where: { $0.id == exchangeID }) else { continue }
            requestsByCall[callID, default: []].append(.init(exchangeID: exchangeID, method: e.method, host: e.host, path: e.path,
                                                             status: e.status, via: e.via))
        }
        var byAgent: [String: [ToolActivity]] = [:]
        var seen = Set<String>()
        for exchange in exchanges {
            guard let agent = exchange.agent else { continue }
            for (index, call) in exchange.toolCalls.enumerated() {
                let id = call.callID ?? "\(exchange.id ?? 0)-\(index)"
                guard seen.insert(id).inserted else { continue }
                let requests = (call.callID.flatMap { requestsByCall[$0] } ?? []).sorted { $0.exchangeID < $1.exchangeID }
                byAgent[agent, default: []].append(ToolActivity(
                    id: id, call: call, at: exchange.started.addingTimeInterval(exchange.duration),
                    result: call.callID.flatMap { results[$0] }, requests: requests))
            }
        }
        return byAgent.mapValues { mergeDirectMCPCalls($0).sorted { $0.at > $1.at } }
    }

    /// When the model calls an MCP tool on a remote server, Flowlight sees it twice: in the model's response, then as
    /// the agent's JSON-RPC call to the server. Keep one entry (the model's), with the server's result if it has none.
    static func mergeDirectMCPCalls(_ list: [ToolActivity]) -> [ToolActivity] {
        var out = list.filter { $0.call.source != .mcp }
        for direct in list where direct.call.source == .mcp {
            if let i = out.lastIndex(where: {
                $0.call.mcpServer?.lowercased() == direct.call.mcpServer?.lowercased() && $0.call.name == direct.call.name
                    && $0.at <= direct.at && direct.at.timeIntervalSince($0.at) < 120
            }) {
                if out[i].result == nil { out[i].result = direct.result }
            } else {
                out.append(direct)
            }
        }
        return out
    }

    /// Agent id → what its inspected LLM calls declared.
    static func profiles(_ exchanges: [HTTPExchange], activities: [String: [ToolActivity]]) -> [String: AgentProfile] {
        var byAgent: [String: AgentProfile] = [:]
        for exchange in exchanges.sorted(by: { $0.started < $1.started }) {
            guard let agent = exchange.agent, let llm = exchange.llm else { continue }
            var profile = byAgent[agent] ?? AgentProfile()
            profile.requests += 1
            profile.provider = llm.provider
            profile.lastSeen = exchange.started
            if llm.errorType != nil || (exchange.status ?? 200) >= 400 { profile.failures += 1 }
            if let usage = llm.usage { profile.usage += usage }
            if let model = llm.model {
                if let index = profile.models.firstIndex(where: { $0.name == model }) { profile.models[index].requests += 1 }
                else { profile.models.append((model, 1)) }
            }
            // Agents declare their tools on every turn; the newest declaration wins.
            if !llm.declaredTools.isEmpty {
                profile.tools = llm.declaredTools.map { ($0, 0) }
            }
            byAgent[agent] = profile
        }
        for (agent, list) in activities {
            var counts: [String: Int] = [:]
            for activity in list {
                counts[activity.call.name, default: 0] += 1
                if let server = activity.call.mcpServer { counts["mcp__\(server)__\(activity.call.name)", default: 0] += 1 }
            }
            guard var profile = byAgent[agent] else { continue }
            profile.tools = profile.tools.map { ($0.tool, counts[$0.tool.name] ?? counts[$0.tool.server ?? ""] ?? 0) }
                .sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
            byAgent[agent] = profile
        }
        return byAgent
    }

    /// Agent id → the MCP servers it used, busiest first. `configured` adds servers seen only as local processes.
    static func servers(_ exchanges: [HTTPExchange], activities: [String: [ToolActivity]],
                        configured: [String: [String]] = [:]) -> [String: [MCPServerSummary]] {
        var byAgent: [String: [String: MCPServerSummary]] = [:]
        func update(_ agent: String, _ name: String, _ body: (inout MCPServerSummary) -> Void) {
            var server = byAgent[agent, default: [:]][name.lowercased()] ?? MCPServerSummary(name: name)
            body(&server)
            byAgent[agent, default: [:]][name.lowercased()] = server
        }
        for exchange in exchanges {
            guard let agent = exchange.agent else { continue }
            for activity in exchange.mcp {
                update(agent, activity.server) { s in
                    s.kind = .remote
                    s.endpoint = activity.endpoint
                    if let v = activity.version { s.version = v }
                    if let tools = activity.tools { s.tools = Array(Set(s.tools).union(tools)).sorted() }
                }
            }
            // Servers the provider connects to for the agent, declared in the request.
            for connector in exchange.llm?.connectors ?? [] {
                update(agent, connector.label) { s in
                    if s.kind != .remote { s.kind = .provider }
                    s.endpoint = connector.url ?? s.endpoint
                    s.approval = connector.approval ?? s.approval
                    s.allowedTools = connector.allowedTools ?? s.allowedTools
                    s.authorized = s.authorized || connector.authorized
                    if let tools = connector.tools { s.tools = Array(Set(s.tools).union(tools)).sorted() }
                }
            }
        }
        for (agent, list) in activities {
            for activity in list {
                guard let server = activity.call.mcpServer else { continue }
                update(agent, server) { s in
                    s.calls += 1
                    s.used[activity.call.name, default: 0] += 1
                    if activity.outcome == .error { s.errors += 1 }
                    s.lastUsed = max(s.lastUsed ?? .distantPast, activity.at)
                    if !s.tools.contains(activity.call.name) { s.tools.append(activity.call.name) }
                }
            }
        }
        for (agent, names) in configured {
            for name in names { update(agent, name) { _ in } }
        }
        return byAgent.mapValues { $0.values.sorted { ($0.calls, $0.lastUsed ?? .distantPast) > ($1.calls, $1.lastUsed ?? .distantPast) } }
    }
}
