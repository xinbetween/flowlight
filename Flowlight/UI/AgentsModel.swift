import Foundation

/// Where an agent's traffic went, split into AI API calls and everything else.
struct AgentDestination: Identifiable, Sendable, Equatable {
    var label: String
    var ip: String
    var provider: String?
    var protocols: [String]
    var ports: String
    var counters: FlowCounters
    /// False when no hostname was seen (the label is an owner name or the bare IP).
    var hasHostname = true
    /// The agent's tools or MCP servers that used this destination ("curl", "github MCP"); empty for the agent itself.
    var via: [String] = []
    var id: String { label + "|" + ip }

    var categories: Set<ProtocolCategory> { Set(protocols.map(ProtocolCatalog.category(of:))) }
    var isSensitive: Bool { categories.contains { $0.isSensitiveEgress } }
    var isUnnamed: Bool { !hasHostname }
}

struct AgentSummary: Identifiable, Sendable, Equatable {
    var bundleID: String
    var name: String
    var vendor: String?
    var isKnown: Bool
    var appPath: String
    var ai: FlowCounters
    var egress: FlowCounters
    var providers: [(name: String, counters: FlowCounters)]
    var destinations: [AgentDestination]    // everything, AI providers first
    /// Processes the agent started (shell tools, MCP servers) and their traffic.
    var tools: [AgentTool] = []
    var alerts: Int
    var id: String { bundleID }

    var total: FlowCounters { var c = ai; c += egress; return c }
    var otherDestinations: [AgentDestination] { destinations.filter { $0.provider == nil } }
    var sensitiveProtocols: [String] {
        Array(Set(otherDestinations.filter(\.isSensitive).flatMap { $0.protocols.filter { ProtocolCatalog.category(of: $0).isSensitiveEgress } })).sorted()
    }
    /// Share of the agent's uploads that went somewhere other than an AI API.
    var egressShare: Double { total.bytesOut == 0 ? 0 : Double(egress.bytesOut) / Double(total.bytesOut) }

    // Sortable projections for the table.
    var aiTotal: Int64 { ai.total }
    var egressOut: Int64 { egress.bytesOut }
    var otherCount: Int { otherDestinations.count }
    static let largeUploadBytes: Int64 = 50_000_000
    var hasLargeUpload: Bool { egress.bytesOut >= Self.largeUploadBytes }
    var hasUnnamedHost: Bool { otherDestinations.contains { $0.isUnnamed && !IPOwnerLookup.isLocalNetwork($0.ip) } }
    var riskScore: Int { sensitiveProtocols.count * 10 + alerts + (hasUnnamedHost ? 3 : 0) + (hasLargeUpload ? 5 : 0) }

    static func == (a: AgentSummary, b: AgentSummary) -> Bool {
        a.bundleID == b.bundleID && a.ai == b.ai && a.egress == b.egress && a.alerts == b.alerts && a.tools == b.tools
    }
}

/// A process working for an agent: an MCP server, or a tool such as curl, git or npm.
struct AgentTool: Identifiable, Sendable, Equatable {
    var label: String            // "github" or "curl"
    var isMCP: Bool
    var counters: FlowCounters
    var destinations: Int
    var id: String { (isMCP ? "mcp:" : "tool:") + label }
    var displayName: String { isMCP ? "\(label) MCP" : label }
}

enum AgentsModel {
    private static func mergedPorts(_ a: String, _ b: String) -> String {
        var ports = Set<String>()
        for part in (a + "," + b).split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { ports.insert(trimmed) }
        }
        let ordered: [String] = ports.sorted { x, y in x.count == y.count ? x < y : x.count < y.count }
        return ordered.joined(separator: ", ")
    }

    /// Finds agents in breakdown rows: known agents, plus any non-browser app that called an LLM API.
    static func build(rows: [BreakdownRow], alerts: [AlertRecord]) -> [AgentSummary] {
        // Tools and MCP servers an agent started fold into that agent.
        let byApp = Dictionary(grouping: TrafficNode.backfilled(rows)) { $0.parentAgent.isEmpty ? $0.bundleID : $0.parentAgent }
        let alertCounts = Dictionary(grouping: alerts, by: \.bundleID).mapValues(\.count)
        return byApp.compactMap { bundleID, appRows -> AgentSummary? in
            let ownRows = appRows.filter { $0.bundleID == bundleID }
            let parentName = appRows.first { !$0.parentAgentName.isEmpty }?.parentAgentName
            let appName = ownRows.first { !$0.appName.isEmpty }?.appName ?? parentName ?? bundleID
            let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: appName)
            let providerOf: (BreakdownRow) -> String? = { AgentCatalog.provider(domain: $0.domain, owner: $0.owner) }
            let usesAI = appRows.contains { providerOf($0) != nil && $0.counters.total > 0 }
            guard known != nil || parentName != nil || (usesAI && !AgentCatalog.isBrowser(bundleID)) else { return nil }
            var tools: [String: AgentTool] = [:]
            var toolDestinations: [String: Set<String>] = [:]

            var ai = FlowCounters(), egress = FlowCounters()
            var providers: [String: FlowCounters] = [:]
            var destinations: [String: AgentDestination] = [:]
            for row in appRows {
                let provider = providerOf(row)
                if let provider { ai += row.counters; providers[provider, default: FlowCounters()] += row.counters }
                else if !IPOwnerLookup.isLocalNetwork(row.remoteIP) { egress += row.counters }
                let label = !row.domain.isEmpty ? row.domain : (!row.owner.isEmpty ? row.owner : row.remoteIP)
                let key = label + "|" + (row.domain.isEmpty ? row.remoteIP : "")
                var entry = destinations[key] ?? AgentDestination(label: label, ip: row.remoteIP, provider: provider, protocols: [],
                                                                  ports: "", counters: FlowCounters(), hasHostname: !row.domain.isEmpty)
                entry.counters += row.counters
                let protos = row.protocols.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                entry.protocols = Array(Set(entry.protocols + protos)).sorted()
                entry.ports = mergedPorts(entry.ports, row.ports)
                if row.bundleID != bundleID || !row.mcpServer.isEmpty {
                    let isMCP = !row.mcpServer.isEmpty
                    let label = isMCP ? row.mcpServer : row.appName
                    var tool = tools[(isMCP ? "mcp:" : "tool:") + label] ?? AgentTool(label: label, isMCP: isMCP, counters: FlowCounters(), destinations: 0)
                    tool.counters += row.counters
                    tools[tool.id] = tool
                    toolDestinations[tool.id, default: []].insert(label + "|" + key)
                    if !entry.via.contains(tool.displayName) { entry.via.append(tool.displayName) }
                }
                destinations[key] = entry
            }
            let sortedDestinations: [AgentDestination] = destinations.values.sorted { x, y in
                let xAI = x.provider != nil, yAI = y.provider != nil
                if xAI != yAI { return xAI }
                return x.counters.total > y.counters.total
            }
            let toolList = tools.values.map { tool -> AgentTool in
                var t = tool; t.destinations = toolDestinations[tool.id]?.count ?? 0; return t
            }.sorted { $0.counters.total > $1.counters.total }
            return AgentSummary(bundleID: bundleID, name: known?.name ?? parentName ?? appName, vendor: known?.vendor,
                                isKnown: known != nil || parentName != nil,
                                appPath: ownRows.first { !$0.appPath.isEmpty }?.appPath ?? "", ai: ai, egress: egress,
                                providers: providers.sorted { $0.value.total > $1.value.total }.map { ($0.key, $0.value) },
                                destinations: sortedDestinations, tools: toolList, alerts: alertCounts[bundleID] ?? 0)
        }
        .sorted { $0.total.total > $1.total.total }
    }
}
