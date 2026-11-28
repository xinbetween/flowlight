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
    struct Endpoint: Hashable, Sendable {
        var ip: String
        var isProvider: Bool
    }
    /// Hostname groups can contain several addresses or both provider and non-provider traffic.
    var endpoints: Set<Endpoint> = []
    var representedEndpoints: Set<Endpoint> {
        endpoints.isEmpty ? [Endpoint(ip: ip, isProvider: provider != nil)] : endpoints
    }
    var id: String { policyKey }
    var policyKey: String { hasHostname ? label : "\u{0}" + ip }
    var policyHost: String { hasHostname ? label : "" }

    /// The domain or address added by the destination row's Allow action.
    var allowPattern: String { hasHostname ? AnomalyEngine.registrableDomain(label) : ip }

    var isProviderOnly: Bool { provider != nil && !endpoints.contains { !$0.isProvider } }
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
    var local = FlowCounters()
    var omittedRelationships = 0
    var id: String { bundleID }

    var total: FlowCounters { var c = ai; c += egress; c += local; return c }
    var otherDestinations: [AgentDestination] { destinations.filter { !$0.isProviderOnly } }
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

    static func == (a: AgentSummary, b: AgentSummary) -> Bool {
        a.bundleID == b.bundleID && a.name == b.name && a.vendor == b.vendor && a.isKnown == b.isKnown
            && a.appPath == b.appPath && a.ai == b.ai && a.egress == b.egress && a.local == b.local
            && a.providers.elementsEqual(b.providers, by: ==) && a.destinations == b.destinations
            && a.alerts == b.alerts && a.tools == b.tools && a.omittedRelationships == b.omittedRelationships
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

struct AgentRootProof: Sendable {
    var bundleID: String
    var name: String
    var path: String
    var known: KnownAgent?

    static func identify(bundleID: String, rows: [BreakdownRow]) -> AgentRootProof? {
        let ownRows = rows.filter { $0.bundleID == bundleID }
        let parentName = rows.first { !$0.parentAgentName.isEmpty }?.parentAgentName ?? ""
        let hasParentEvidence = rows.contains { $0.parentAgent == bundleID }
        let appName = ownRows.first { !$0.appName.isEmpty }?.appName ?? parentName
        let usesAI = rows.contains {
            AgentCatalog.provider(domain: $0.domain, owner: $0.owner) != nil && !$0.counters.isEmpty
        }
        let proof = AgentRootProof(bundleID: bundleID, appName: appName, parentName: parentName,
                                   path: ownRows.first { !$0.appPath.isEmpty }?.appPath ?? "")
        return proof.known != nil || hasParentEvidence || (usesAI && !AgentCatalog.isBrowser(bundleID)) ? proof : nil
    }

    init(bundleID: String, appName: String, parentName: String, path: String) {
        self.bundleID = bundleID
        self.known = AgentCatalog.knownAgent(bundleID: bundleID, appName: appName)
        self.name = known?.name ?? parentName.nilIfEmpty ?? appName.nilIfEmpty ?? bundleID
        self.path = path
    }
}

enum AgentsModel {
    /// Legacy complete rows used by Ask and other non-UI callers. The Agents page uses the bounded projection below.
    static func rows(from database: TrafficDatabase, granularity: Granularity,
                     from: Date, to: Date, focus: FocusScope) throws -> [BreakdownRow] {
        try database.aiVisualizationRows(
            granularity, from: from, to: to,
            filter: TrafficFilter(focus: focus)
        )
    }

    static func projection(from database: TrafficDatabase, granularity: Granularity,
                          from: Date, to: Date, focus: FocusScope,
                          limit: Int = 128, includePolicyEvidence: Bool = true) throws -> AgentTrafficProjection {
        try database.agentTrafficProjection(
            granularity, from: from, to: to, filter: TrafficFilter(focus: focus),
            limit: limit, includePolicyEvidence: includePolicyEvidence
        )
    }

    static func build(projection: AgentTrafficProjection, cancellation: TrafficReadCancellation) throws -> [AgentSummary] {
        let sampled = Dictionary(grouping: projection.rows) { $0.parentAgent.nilIfEmpty ?? $0.bundleID }
        let summaries = try projection.roots.map { bundleID, evidence in
            try cancellation.check()
            let root = AgentRootProof(bundleID: bundleID, appName: evidence.appName,
                                      parentName: evidence.parentName, path: evidence.appPath)
            let rows = sampled[bundleID] ?? []
            var summary = summarize(rows, root: root, alerts: 0)
            summary.isKnown = root.known != nil || evidence.hasExactChildren
            summary.ai = evidence.ai
            summary.egress = evidence.egress
            summary.local = evidence.local
            summary.providers = sortedProviders(evidence.providers)
            summary.omittedRelationships = evidence.relationshipCount - rows.count
            return summary
        }
        return summaries.sorted { $0.total.total > $1.total.total }
    }

    private static func sortedProviders(_ providers: [String: FlowCounters]) -> [(name: String, counters: FlowCounters)] {
        providers.sorted { $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total }
            .map { ($0.key, $0.value) }
    }

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
            guard let root = AgentRootProof.identify(bundleID: bundleID, rows: appRows) else { return nil }
            var summary = summarize(appRows, root: root, alerts: alertCounts[bundleID] ?? 0)
            summary.isKnown = root.known != nil || appRows.contains { $0.parentAgent == bundleID }
            return summary
        }
        .sorted { $0.total.total > $1.total.total }
    }

    private static func summarize(_ appRows: [BreakdownRow], root: AgentRootProof, alerts: Int) -> AgentSummary {
            let bundleID = root.bundleID
            let providerOf: (BreakdownRow) -> String? = { AgentCatalog.provider(domain: $0.domain, owner: $0.owner) }
            var tools: [String: AgentTool] = [:]
            var toolDestinations: [String: Set<String>] = [:]

            var ai = FlowCounters(), egress = FlowCounters()
            var providers: [String: FlowCounters] = [:]
            var destinations: [String: AgentDestination] = [:]
            var protocolsByDestination: [String: Set<String>] = [:]
            var portsByDestination: [String: Set<String>] = [:]
            for row in appRows {
                let provider = providerOf(row)
                if let provider { ai += row.counters; providers[provider, default: FlowCounters()] += row.counters }
                else if !IPOwnerLookup.isLocalNetwork(row.remoteIP) { egress += row.counters }
                let label = !row.domain.isEmpty ? row.domain : (!row.owner.isEmpty ? row.owner : row.remoteIP)
                let key = row.domain.isEmpty ? "\u{0}" + row.remoteIP : row.domain
                var entry = destinations.removeValue(forKey: key) ?? AgentDestination(
                    label: label, ip: row.remoteIP, provider: provider, protocols: [],
                    ports: "", counters: FlowCounters(), hasHostname: !row.domain.isEmpty
                )
                entry.endpoints.insert(.init(ip: row.remoteIP, isProvider: provider != nil))
                if entry.provider == nil { entry.provider = provider }
                entry.counters += row.counters
                let protos = row.protocols.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                protocolsByDestination[key, default: []].formUnion(protos)
                portsByDestination[key, default: []].formUnion(row.ports.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty })
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
            for key in destinations.keys {
                guard var entry = destinations[key] else { continue }
                entry.protocols = protocolsByDestination[key, default: []].sorted()
                entry.ports = portsByDestination[key, default: []].sorted {
                    $0.count == $1.count ? $0 < $1 : $0.count < $1.count
                }.joined(separator: ", ")
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
            return AgentSummary(bundleID: bundleID, name: root.name, vendor: root.known?.vendor,
                                isKnown: root.known != nil, appPath: root.path, ai: ai, egress: egress,
                                providers: sortedProviders(providers), destinations: sortedDestinations,
                                tools: toolList, alerts: alerts)
    }
}

struct AgentDataCoverage: Sendable, Equatable {
    var relationshipsShown: Int = 0
    var relationshipsTotal: Int = 0
    var inspectionExchangesLimited = false

    var isIncomplete: Bool {
        inspectionExchangesLimited || relationshipsTotal > relationshipsShown
    }
}

struct AgentsLoadInput: Sendable {
    var installedApps: [InstalledApps.App]
    var scanInstalledApps: Bool
    var workspaces: [AgentWorkspace]
    var monitoredAgentNames: Set<String>
    var inspection: AgentInspectionDiagnostics
    var guardrailAgentIDs: [String]
}

struct AgentsReadSnapshot: Sendable {
    var projection: AgentTrafficProjection
    var policies: [String: AgentPolicy]
    var openAlerts: [AgentOpenAlertCount]
    var exchangePage: AgentExchangePage
    var inspectedAgents: Set<String>
    var watermark: Date?
}

struct AgentsViewSnapshot: Sendable {
    var inventory: [AgentInventoryItem] = []
    var installedApps: [InstalledApps.App] = []
    var workspaces: [AgentWorkspace] = []
    var policies: [String: AgentPolicy] = [:]
    var inspection = AgentsInspectionDerived()
    var coverage = AgentDataCoverage()
    var monitorCandidates: [AlwaysMonitorBanner.Candidate] = []
    var linkedDemoCalls = 0
    var watermark: Date?
}

/// Preserve the last confirmed edit until a policy snapshot that started after its commit can replace it.
struct AgentPolicyEdits {
    private struct Entry {
        var pending: (token: UUID, policy: AgentPolicy)?
        var committed: (revision: Int, policy: AgentPolicy)?
        var policy: AgentPolicy? { pending?.policy ?? committed?.policy }
    }

    private var entries: [String: Entry] = [:]

    func hasOverlay(for agentID: String) -> Bool { entries[key(for: agentID)] != nil }
    func isSaving(_ agentID: String) -> Bool { entries[key(for: agentID)]?.pending != nil }

    func resolved(over policies: [String: AgentPolicy], identities: [String]) -> AgentPolicy? {
        if entries.isEmpty { return AgentPolicy.resolve(policies.values, identities: identities) }
        let unedited = policies.values.filter { !hasOverlay(for: $0.agentID) }
        return AgentPolicy.resolve(unedited + entries.values.compactMap(\.policy), identities: identities)
    }

    mutating func begin(_ policy: AgentPolicy) -> UUID? {
        let key = key(for: policy.agentID)
        guard entries[key]?.pending == nil else { return nil }
        let token = UUID()
        entries[key, default: Entry()].pending = (token, policy)
        return token
    }

    mutating func finish(_ result: AgentPolicySaveResult, agentID: String, token: UUID) {
        let key = key(for: agentID)
        guard var entry = entries[key], let pending = entry.pending, pending.token == token else { return }
        entry.pending = nil
        switch result {
        case .writeFailed: break
        case .committed(let revision), .committedReloadFailed(let revision):
            entry.committed = (revision, pending.policy)
        }
        entries[key] = entry.policy == nil ? nil : entry
    }

    mutating func reconcile(snapshotRevision: Int) {
        for key in Array(entries.keys) {
            guard var entry = entries[key], let committed = entry.committed,
                  committed.revision <= snapshotRevision else { continue }
            entry.committed = nil
            entries[key] = entry.policy == nil ? nil : entry
        }
    }

    private func key(for agentID: String) -> String { AgentCatalog.identityComparisonKey(agentID) }
}

/// Run one request at a time. Same-scope refreshes replace a single pending request without cancelling useful work.
@MainActor
final class AgentsReloadCoordinator<Scope: Equatable> {
    typealias Work = @MainActor (TrafficReadCancellation) async -> Void

    private var active: (scope: Scope, cancellation: TrafficReadCancellation)?
    private var pending: (scope: Scope, work: Work)?

    func submit(scope: Scope, work: @escaping Work) {
        pending = (scope, work)
        if let active {
            if active.scope != scope { active.cancellation.cancel() }
        } else {
            startPending()
        }
    }

    func cancel() {
        pending = nil
        active?.cancellation.cancel()
    }

    private func startPending() {
        guard let next = pending else { return }
        pending = nil
        let cancellation = TrafficReadCancellation()
        active = (next.scope, cancellation)
        Task { @MainActor in
            if !cancellation.isCancelled { await next.work(cancellation) }
            active = nil
            startPending()
        }
    }
}

struct AgentsInspectionDerived: Sendable {
    var activity: [String: [ToolActivity]] = [:]
    var toolUsage: [String: [ToolUsage]] = [:]
    var mcpServers: [String: [MCPServerSummary]] = [:]
    var profiles: [String: AgentProfile] = [:]
    var inspectedAgents: Set<String> = []
}

extension AgentsModel {
    static func read(_ db: TrafficDatabase, granularity: Granularity, from: Date, to: Date, focus: FocusScope,
                     stress: Bool = false, cancellation: TrafficReadCancellation) throws -> AgentsReadSnapshot {
        try db.readSnapshot(cancellation: cancellation) {
            let policies = try db.loadPolicies()
            let projection = try projection(from: db, granularity: granularity, from: from, to: to, focus: focus,
                                            includePolicyEvidence: policies.values.contains(where: \.enabled))
            try cancellation.check()
            let openAlerts = try db.openAlertCounts(since: from, until: to, focus: focus)
            let exchangePage = try db.agentInspectionExchanges(since: from, until: to, focus: focus)
            try cancellation.check()
            let inspectedAgents = try db.inspectedAgentIDs(since: from, until: to, focus: focus)
            return AgentsReadSnapshot(projection: projection, policies: policies, openAlerts: openAlerts,
                                      exchangePage: exchangePage, inspectedAgents: inspectedAgents,
                                      watermark: stress ? try db.rollupWatermark(for: granularity) : nil)
        }
    }

    static func derive(_ read: AgentsReadSnapshot, input: AgentsLoadInput, stress: Bool,
                       cancellation: TrafficReadCancellation) throws -> AgentsViewSnapshot {
        try cancellation.check()
        let apps = input.scanInstalledApps ? InstalledApps.all() : input.installedApps
        try cancellation.check()
        let traffic = try build(projection: read.projection, cancellation: cancellation)
        let inspectedKeys = Set(read.inspectedAgents.map(AgentCatalog.identityComparisonKey))
        let requestedRoute: AgentRouteState = input.inspection.setupFailed ? .failed
            : (input.inspection.enabled && input.inspection.running ? .stale : .configured)
        var routes = Dictionary(uniqueKeysWithValues: input.monitoredAgentNames.map { ($0, requestedRoute) })
        var candidates: [String: Bool] = [:]
        for agent in traffic {
            let known = AgentCatalog.knownAgent(bundleID: agent.bundleID, appName: agent.name)
            let routed = [agent.bundleID, agent.name].contains {
                inspectedKeys.contains(AgentCatalog.identityComparisonKey($0))
            }
            if routed { routes[known?.name ?? agent.bundleID] = .observed }
            if let known, known.configRecipe != nil, !agent.providers.isEmpty {
                candidates[known.name] = (candidates[known.name] ?? false) || routed
            }
        }
        try cancellation.check()
        let inventory = AgentInventoryBuilder.build(AgentInventoryInput(
            installedApps: apps, traffic: traffic, workspaces: input.workspaces,
            monitoredAgentNames: input.monitoredAgentNames, routes: routes, inspection: input.inspection,
            policies: read.policies, guardrailAgentIDs: input.guardrailAgentIDs, openAlertCounts: read.openAlerts,
            policyEndpoints: read.projection.hasFullPolicyEvidence ? read.projection.policyEndpoints : nil,
            cancellation: cancellation
        ))
        try cancellation.check()
        var canonical: [String: String] = [:]
        // Use stored identifiers to avoid joining unrelated agents that share a display name.
        for item in inventory {
            for identity in item.trafficIdentities {
                let key = AgentCatalog.identityComparisonKey(identity)
                if canonical[key] == nil { canonical[key] = item.id }
            }
        }
        let inspection = try deriveInspection(exchanges: read.exchangePage.exchanges, configuredMCP: read.projection.configuredMCP,
                                              canonicalByIdentity: canonical, inspectedAgents: read.inspectedAgents,
                                              cancellation: cancellation)
        try cancellation.check()
        let linkedDemoCalls = stress ? inspection.activity.values.reduce(into: 0) { total, activities in
            total += activities.filter { $0.requests.contains { $0.host == "paste.example" } }.count
        } : 0
        return AgentsViewSnapshot(
            inventory: inventory, installedApps: apps, workspaces: input.workspaces, policies: read.policies,
            inspection: inspection,
            coverage: AgentDataCoverage(relationshipsShown: read.projection.returnedRelationshipCount,
                                        relationshipsTotal: read.projection.totalRelationshipCount,
                                        inspectionExchangesLimited: read.exchangePage.hasMore),
            monitorCandidates: candidates.keys.sorted().map { .init(name: $0, routed: candidates[$0] == true) },
            linkedDemoCalls: linkedDemoCalls, watermark: read.watermark
        )
    }

    static func deriveInspection(exchanges: [HTTPExchange], configuredMCP: [String: [String]],
                                 canonicalByIdentity: [String: String], inspectedAgents: Set<String>,
                                 cancellation: TrafficReadCancellation) throws -> AgentsInspectionDerived {
        let canonicalExchanges = exchanges.map { exchange -> HTTPExchange in
            var exchange = exchange
            if let agent = exchange.agent,
               let canonical = canonicalByIdentity[AgentCatalog.identityComparisonKey(agent)] {
                if exchange.bundleID == agent { exchange.bundleID = canonical }
                exchange.agent = canonical
            }
            return exchange
        }
        try cancellation.check()
        let activity = ToolActivityBuilder.activities(canonicalExchanges)
        try cancellation.check()
        var configured: [String: Set<String>] = [:]
        for (root, servers) in configuredMCP {
            configured[canonicalByIdentity[AgentCatalog.identityComparisonKey(root)] ?? root, default: []].formUnion(servers)
        }
        let resolvedInspected = Set(inspectedAgents.map {
            canonicalByIdentity[AgentCatalog.identityComparisonKey($0)] ?? $0
        })
        let servers = ToolActivityBuilder.servers(canonicalExchanges, activities: activity,
                                                  configured: configured.mapValues { $0.sorted() })
        try cancellation.check()
        let profiles = ToolActivityBuilder.profiles(canonicalExchanges, activities: activity)
        return AgentsInspectionDerived(activity: activity, toolUsage: ToolUsage.build(activity),
                                       mcpServers: servers, profiles: profiles, inspectedAgents: resolvedInspected)
    }
}
