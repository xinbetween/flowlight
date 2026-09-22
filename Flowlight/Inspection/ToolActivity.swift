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
/// (`mcp__server__tool`), and JSON-RPC traffic to remote servers.
struct MCPServerSummary: Identifiable, Equatable {
    var name: String
    var version: String?
    var endpoint: String?
    var tools: [String] = []
    var calls = 0
    var errors = 0
    var lastUsed: Date?
    var id: String { name.lowercased() }
    var isRemote: Bool { endpoint != nil }
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
        return byAgent.mapValues { $0.sorted { $0.at > $1.at } }
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
                    s.endpoint = activity.endpoint
                    if let v = activity.version { s.version = v }
                    if let tools = activity.tools { s.tools = Array(Set(s.tools).union(tools)).sorted() }
                }
            }
        }
        for (agent, list) in activities {
            for activity in list {
                guard let server = activity.call.mcpServer else { continue }
                update(agent, server) { s in
                    s.calls += 1
                    if activity.outcome == .error { s.errors += 1 }
                    s.lastUsed = max(s.lastUsed ?? .distantPast, activity.at)
                    if !s.tools.contains(activity.call.name) && s.endpoint == nil { s.tools.append(activity.call.name) }
                }
            }
        }
        for (agent, names) in configured {
            for name in names { update(agent, name) { _ in } }
        }
        return byAgent.mapValues { $0.values.sorted { ($0.calls, $0.lastUsed ?? .distantPast) > ($1.calls, $1.lastUsed ?? .distantPast) } }
    }
}
