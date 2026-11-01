import Foundation

struct AITrafficGraphLimits: Equatable, Sendable {
    var maxAgents: Int
    var maxTools: Int
    var maxDestinations: Int
    var maxObservedEdges: Int
    var maxLaunchers: Int = 6
    var maxBlockedEdges: Int = 12

    static let standard = AITrafficGraphLimits(maxAgents: 6, maxTools: 8, maxDestinations: 10,
                                                maxObservedEdges: 28, maxLaunchers: 6, maxBlockedEdges: 12)
    static let unbounded = AITrafficGraphLimits(maxAgents: .max, maxTools: .max,
                                                maxDestinations: .max, maxObservedEdges: .max,
                                                maxLaunchers: .max, maxBlockedEdges: .max)
}

enum AITrafficGraphBuilder {
    private struct AgentIdentity: Hashable {
        var bundleID: String
    }

    private struct ToolIdentity: Hashable {
        var agent: AgentIdentity
        var bundleID: String
        var mcpServer: String
    }

    private struct DestinationIdentity: Hashable {
        var provider: String
        var domain: String
        var remoteIP: String
        var owner: String
        var asn: Int

        var isProvider: Bool { !provider.isEmpty }
    }

    private struct ObservedRelationship: Hashable {
        var source: TrafficGraphNodeID
        var destination: DestinationIdentity
    }

    private struct BlockedRelationship: Hashable {
        var source: TrafficGraphNodeID
        var agent: AgentIdentity
        var destination: String
        var port: UInt16
    }

    private struct BlockedValue {
        var count: Int64 = 0
        var categories: Set<String> = []
        var sources: Set<String> = []
        var details: Set<String> = []
    }

    private struct ExactMemberIdentity: Hashable {
        var source: TrafficGraphNodeID
        var bundleID: String
        var agentParent: String
        var mcpServer: String
        var domain: String
        var remoteIP: String
        var protocols: String
        var channel: NetworkChannel
    }

    private struct AgentMetadata {
        var name: String
        var path: String
        var known: KnownAgent?
        var weight: Int64
    }

    private struct LauncherIdentity: Hashable {
        var agent: AgentIdentity
        var bundleID: String
    }

    private struct LauncherMetadata {
        var name: String
        var path: String
        var weight: Int64
    }

    private struct ToolMetadata {
        var name: String
        var path: String
        var hasLineage: Bool
        var weight: Int64
        var counters = FlowCounters()
    }

    private struct MemberValue {
        var identity: ExactMemberIdentity
        var owner: String
        var asn: Int
        var counters = FlowCounters()
    }

    static func build<Rows: Sequence>(rows sourceRows: Rows,
                                      visibleRows: [BreakdownRow]? = nil,
                                      blockedAttempts: [BlockedAttemptRow] = [],
                                      limits: AITrafficGraphLimits = .standard) -> TrafficGraphSnapshot
    where Rows.Element == BreakdownRow {
        let sourceRows = sourceRows.filter { !$0.counters.isEmpty }
        let rows = (visibleRows ?? sourceRows).filter { !$0.counters.isEmpty }
        let proofGroups = Dictionary(grouping: sourceRows) { row in
            AgentIdentity(bundleID: row.parentAgent.isEmpty ? row.bundleID : row.parentAgent)
        }
        let grouped = Dictionary(grouping: rows) { row in
            AgentIdentity(bundleID: row.parentAgent.isEmpty ? row.bundleID : row.parentAgent)
        }

        var included: [(agent: AgentIdentity, rows: [BreakdownRow], metadata: AgentMetadata)] = []
        var refusalNames: [AgentIdentity: String] = [:]
        for attempt in blockedAttempts where refusalProvesAgent(attempt) {
            let agent = AgentIdentity(bundleID: attempt.agentKey)
            if refusalNames[agent]?.isEmpty != false, !attempt.agentName.isEmpty {
                refusalNames[agent] = attempt.agentName
            } else if refusalNames[agent] == nil {
                refusalNames[agent] = attempt.agentKey
            }
        }
        let candidateAgents = Set(grouped.keys).union(refusalNames.keys)
        for agent in candidateAgents {
            let agentRows = grouped[agent] ?? []
            let weight = agentRows.reduce(Int64(0)) { $0 + $1.counters.total }
            if let proofRows = proofGroups[agent],
               let root = AgentRootProof.identify(bundleID: agent.bundleID, rows: proofRows) {
                included.append((agent, agentRows, AgentMetadata(name: root.name, path: root.path,
                                                                 known: root.known, weight: weight)))
            } else if let refusalName = refusalNames[agent] {
                let known = AgentCatalog.knownAgent(bundleID: agent.bundleID, appName: refusalName)
                included.append((agent, agentRows, AgentMetadata(name: known?.name ?? refusalName, path: "",
                                                                 known: known, weight: 0)))
            }
        }
        included.sort {
            if $0.metadata.weight != $1.metadata.weight { return $0.metadata.weight > $1.metadata.weight }
            return agentID($0.agent) < agentID($1.agent)
        }

        var allNodes: [TrafficGraphNodeID: TrafficGraphNode] = [:]
        var observedCounters: [ObservedRelationship: FlowCounters] = [:]
        var observedMembers: [ObservedRelationship: [ExactMemberIdentity: MemberValue]] = [:]
        var blocked: [BlockedRelationship: BlockedValue] = [:]
        var toolMetadata: [ToolIdentity: ToolMetadata] = [:]
        var total = FlowCounters()

        for entry in included {
            let agentNodeID = agentID(entry.agent)
            var agentCounters = FlowCounters()
            for row in entry.rows {
                total += row.counters
                agentCounters += row.counters
                let tool = toolIdentity(row, agent: entry.agent)
                let sourceID: TrafficGraphNodeID
                if let tool {
                    sourceID = toolID(tool)
                    let candidate = ToolMetadata(
                        name: tool.mcpServer.isEmpty ? displayName(row) : tool.mcpServer,
                        path: row.appPath,
                        hasLineage: !row.parentAgent.isEmpty,
                        weight: row.counters.total,
                        counters: row.counters
                    )
                    let current = toolMetadata[tool]
                    var metadata = current ?? candidate
                    if let current, prefersMetadata(candidate, over: current) {
                        metadata.name = candidate.name
                        metadata.path = candidate.path
                        metadata.weight = candidate.weight
                    }
                    metadata.hasLineage = metadata.hasLineage || candidate.hasLineage
                    if current != nil { metadata.counters += row.counters }
                    toolMetadata[tool] = metadata
                } else {
                    sourceID = agentNodeID
                }

                let provider = AgentCatalog.provider(domain: row.domain, owner: row.owner) ?? ""
                let groupedDomain = row.domain.isEmpty ? "" : VisualizationDomainFamily.group(row.domain)
                let destination = DestinationIdentity(
                    provider: provider,
                    domain: provider.isEmpty ? groupedDomain : "",
                    remoteIP: provider.isEmpty && groupedDomain.isEmpty ? row.remoteIP : "",
                    owner: provider.isEmpty && groupedDomain.isEmpty ? row.owner : "",
                    asn: provider.isEmpty && groupedDomain.isEmpty ? row.asn : 0
                )
                let relationship = ObservedRelationship(source: sourceID, destination: destination)
                observedCounters[relationship, default: FlowCounters()] += row.counters
                let memberIdentity = ExactMemberIdentity(source: sourceID, bundleID: row.bundleID,
                                                         agentParent: row.parentAgent, mcpServer: row.mcpServer,
                                                         domain: row.domain, remoteIP: row.remoteIP,
                                                         protocols: row.protocols, channel: row.channel)
                var member = observedMembers[relationship]?[memberIdentity]
                    ?? MemberValue(identity: memberIdentity, owner: row.owner, asn: row.asn)
                member.counters += row.counters
                observedMembers[relationship, default: [:]][memberIdentity] = member
            }
            allNodes[agentNodeID] = TrafficGraphNode(
                id: agentNodeID, kind: .agent, title: entry.metadata.name,
                detail: entry.metadata.known?.vendor ?? entry.agent.bundleID,
                appPath: entry.metadata.path,
                filter: TrafficFilter(bundleID: entry.agent.bundleID, includeAttributedChildren: true),
                counters: agentCounters
            )
        }

        let provedAgents = Set(included.map(\.agent))
        for attempt in blockedAttempts where attempt.count > 0 && !attempt.destination.isEmpty
            && !attempt.agentKey.isEmpty {
            let agent = AgentIdentity(bundleID: attempt.agentKey)
            guard provedAgents.contains(agent) else { continue }
            let sourceID: TrafficGraphNodeID
            if !attempt.bundleID.isEmpty && attempt.bundleID != attempt.agentKey {
                let tool = ToolIdentity(agent: agent, bundleID: attempt.bundleID, mcpServer: "")
                sourceID = toolID(tool)
                let candidate = ToolMetadata(
                    name: attempt.appName.isEmpty ? attempt.bundleID : attempt.appName,
                    path: "",
                    hasLineage: true,
                    weight: 0
                )
                if toolMetadata[tool] == nil { toolMetadata[tool] = candidate }
            } else {
                sourceID = agentID(agent)
            }
            let relationship = BlockedRelationship(source: sourceID, agent: agent,
                                                   destination: attempt.destination.lowercased(), port: attempt.port)
            var value = blocked[relationship] ?? BlockedValue()
            value.count += attempt.count
            if !attempt.category.isEmpty { value.categories.insert(attempt.category) }
            if !attempt.source.isEmpty { value.sources.insert(attempt.source) }
            if !attempt.detail.isEmpty { value.details.insert(attempt.detail) }
            blocked[relationship] = value
        }

        for (tool, metadata) in toolMetadata {
            let id = toolID(tool)
            allNodes[id] = TrafficGraphNode(
                id: id, kind: tool.mcpServer.isEmpty ? .tool : .mcp,
                title: tool.mcpServer.isEmpty ? metadata.name : "\(metadata.name) MCP",
                detail: tool.mcpServer.isEmpty ? L("Run by %@", allNodes[agentID(tool.agent)]?.title ?? tool.agent.bundleID)
                    : L("MCP service for %@", allNodes[agentID(tool.agent)]?.title ?? tool.agent.bundleID),
                appPath: metadata.path,
                filter: TrafficFilter(bundleID: tool.bundleID,
                                      agentParent: metadata.hasLineage ? tool.agent.bundleID : nil,
                                      mcpServer: tool.mcpServer.isEmpty ? nil : tool.mcpServer),
                counters: metadata.counters
            )
        }

        let rankedObserved = observedCounters.sorted { left, right in
            if left.value.total != right.value.total { return left.value.total > right.value.total }
            return observedID(left.key) < observedID(right.key)
        }
        let rankedBlocked = blocked.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return blockedID($0.key) < blockedID($1.key)
        }
        let blockedAgentReserve = min(max(0, limits.maxAgents), max(1, max(0, limits.maxAgents) / 3))
        var blockedAgentTotals: [AgentIdentity: Int64] = [:]
        for (relationship, value) in blocked {
            let current = blockedAgentTotals[relationship.agent, default: 0]
            let (sum, overflow) = current.addingReportingOverflow(value.count)
            blockedAgentTotals[relationship.agent] = overflow ? Int64.max : sum
        }
        let rankedBlockedAgents = blockedAgentTotals.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return agentID($0.key) < agentID($1.key)
        }
        var visibleAgents = Set(rankedBlockedAgents.prefix(blockedAgentReserve).map { agentID($0.key) })
        var visibleTools: Set<TrafficGraphNodeID> = []
        var visibleDestinations: Set<TrafficGraphNodeID> = []
        // Refusals reserve scarce tool and destination slots before normal traffic. Otherwise a handful of low-value
        // observed rows can hide the highest-severity evidence even while the independent blocked-edge budget is free.
        var selectedBlocked: [(BlockedRelationship, BlockedValue)] = []
        for (relationship, value) in rankedBlocked {
            let agentNodeID = agentID(relationship.agent)
            let sourceIsTool = relationship.source != agentNodeID
            let destinationNodeID = destinationID(blockedDestination(relationship))
            guard visibleAgents.contains(agentNodeID),
                  (!sourceIsTool || visibleTools.contains(relationship.source)
                    || visibleTools.count < max(0, limits.maxTools)),
                  (visibleDestinations.contains(destinationNodeID)
                    || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedBlocked.count < max(0, limits.maxBlockedEdges) else { continue }
            selectedBlocked.append((relationship, value))
            if sourceIsTool { visibleTools.insert(relationship.source) }
            visibleDestinations.insert(destinationNodeID)
        }
        var selectedObserved: [(ObservedRelationship, FlowCounters)] = []
        for (relationship, counters) in rankedObserved {
            let sourceAgent = owningAgent(of: relationship.source, included: included.map(\.agent))
            let agentNodeID = agentID(sourceAgent)
            let destinationNodeID = destinationID(relationship.destination)
            let sourceIsTool = relationship.source != agentNodeID
            guard (visibleAgents.contains(agentNodeID) || visibleAgents.count < max(0, limits.maxAgents)),
                  (!sourceIsTool || visibleTools.contains(relationship.source)
                    || visibleTools.count < max(0, limits.maxTools)),
                  (visibleDestinations.contains(destinationNodeID)
                    || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedObserved.count < max(0, limits.maxObservedEdges) else { continue }
            selectedObserved.append((relationship, counters))
            visibleAgents.insert(agentNodeID)
            if sourceIsTool { visibleTools.insert(relationship.source) }
            visibleDestinations.insert(destinationNodeID)
        }
        // The first refusal pass reserves capacity before observed traffic. Once observed traffic has admitted its
        // agents, use every remaining agent slot and blocked-edge slot rather than treating the reserve as a cap.
        for (agent, _) in rankedBlockedAgents where visibleAgents.count < max(0, limits.maxAgents) {
            visibleAgents.insert(agentID(agent))
        }
        let alreadySelected = Set(selectedBlocked.map(\.0))
        for (relationship, value) in rankedBlocked where !alreadySelected.contains(relationship) {
            let agentNodeID = agentID(relationship.agent)
            let sourceIsTool = relationship.source != agentNodeID
            let destinationNodeID = destinationID(blockedDestination(relationship))
            guard visibleAgents.contains(agentNodeID),
                  (!sourceIsTool || visibleTools.contains(relationship.source)
                    || visibleTools.count < max(0, limits.maxTools)),
                  (visibleDestinations.contains(destinationNodeID)
                    || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedBlocked.count < max(0, limits.maxBlockedEdges) else { continue }
            selectedBlocked.append((relationship, value))
            if sourceIsTool { visibleTools.insert(relationship.source) }
            visibleDestinations.insert(destinationNodeID)
        }

        var visibleDestinationCounters: [DestinationIdentity: FlowCounters] = [:]
        var visibleDestinationMembers: [DestinationIdentity: [ExactMemberIdentity: MemberValue]] = [:]
        for (relationship, counters) in selectedObserved {
            visibleDestinationCounters[relationship.destination, default: FlowCounters()] += counters
            for (identity, value) in observedMembers[relationship] ?? [:] {
                var combined = visibleDestinationMembers[relationship.destination]?[identity]
                    ?? MemberValue(identity: identity, owner: value.owner, asn: value.asn)
                combined.counters += value.counters
                visibleDestinationMembers[relationship.destination, default: [:]][identity] = combined
            }
        }
        for (destination, counters) in visibleDestinationCounters {
            let id = destinationID(destination)
            let members = makeMembers(visibleDestinationMembers[destination]?.values ?? [:].values)
            allNodes[id] = TrafficGraphNode(
                id: id, kind: destination.isProvider ? .service : .destination,
                title: destinationTitle(destination), detail: destinationDetail(destination), appPath: "",
                filter: destinationFilter(destination, members: members),
                counters: counters, members: members
            )
        }
        for (relationship, _) in selectedBlocked {
            let destination = blockedDestination(relationship)
            let id = destinationID(destination)
            guard allNodes[id] == nil else { continue }
            allNodes[id] = TrafficGraphNode(
                id: id, kind: destination.isProvider ? .service : .destination,
                title: destinationTitle(destination), detail: destinationDetail(destination), appPath: "",
                filter: destinationFilter(destination, members: []), counters: FlowCounters()
            )
        }

        var visibleSourceCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        for (relationship, counters) in selectedObserved {
            visibleSourceCounters[relationship.source, default: FlowCounters()] += counters
        }
        for (id, counters) in visibleSourceCounters {
            allNodes[id]?.counters = counters
        }
        let includedAgents = included.map(\.agent)
        for agentNodeID in visibleAgents {
            let agent = owningAgent(of: agentNodeID, included: includedAgents)
            var counters = visibleSourceCounters[agentNodeID] ?? FlowCounters()
            for toolNodeID in visibleTools where owningAgent(of: toolNodeID, included: includedAgents) == agent {
                counters += visibleSourceCounters[toolNodeID] ?? FlowCounters()
            }
            allNodes[agentNodeID]?.counters = counters
        }

        var edges = selectedObserved.map { relationship, counters in
            let values = Array(observedMembers[relationship]?.values ?? [:].values)
            let members = makeMembers(values)
            return TrafficGraphEdge(
                id: observedID(relationship), source: relationship.source,
                target: destinationID(relationship.destination), counters: counters,
                filter: members.count == 1 ? members[0].filter : sourceFilter(relationship.source, nodes: allNodes),
                relationship: .observed, members: members
            )
        }
        for (relationship, value) in selectedBlocked {
            let destination = blockedDestination(relationship)
            edges.append(TrafficGraphEdge(
                id: blockedID(relationship), source: relationship.source, target: destinationID(destination),
                counters: FlowCounters(),
                filter: TrafficFilter(
                    bundleID: relationship.source == agentID(relationship.agent)
                        ? relationship.agent.bundleID : allNodes[relationship.source]?.filter.bundleID,
                    agentParent: relationship.source == agentID(relationship.agent)
                        ? nil : relationship.agent.bundleID,
                    domain: HostCanonicalizer.host(relationship.destination),
                    remoteIP: HostCanonicalizer.address(relationship.destination)
                ),
                relationship: .blocked,
                enforcement: TrafficGraphEnforcement(
                    count: value.count,
                    category: value.categories.sorted().joined(separator: ", "),
                    source: value.sources.sorted().joined(separator: ", "),
                    detail: (["Port \(relationship.port)"] + value.details.sorted()).joined(separator: ", ")
                )
            ))
        }
        var launcherMetadata: [LauncherIdentity: LauncherMetadata] = [:]
        for entry in included where visibleAgents.contains(agentID(entry.agent)) {
            for row in proofGroups[entry.agent] ?? [] where !row.launcherBundleID.isEmpty {
                let launcher = LauncherIdentity(agent: entry.agent, bundleID: row.launcherBundleID)
                let candidate = LauncherMetadata(
                    name: row.launcherName,
                    path: row.launcherPath,
                    weight: row.counters.total
                )
                let current = launcherMetadata[launcher]
                if current == nil || prefersMetadata(candidate, over: current!) {
                    launcherMetadata[launcher] = candidate
                }
            }
        }
        var nodeMetadata: [TrafficGraphNodeID: LauncherMetadata] = [:]
        for (launcher, metadata) in launcherMetadata {
            let nodeID = launcherID(bundleID: launcher.bundleID)
            let current = nodeMetadata[nodeID]
            if current == nil || prefersMetadata(metadata, over: current!) { nodeMetadata[nodeID] = metadata }
        }
        let rankedLaunchers = nodeMetadata.sorted {
            if $0.value.weight != $1.value.weight { return $0.value.weight > $1.value.weight }
            return $0.key < $1.key
        }
        let visibleLaunchers = Set(rankedLaunchers.prefix(max(0, limits.maxLaunchers)).map(\.key))
        for (launcherNodeID, metadata) in nodeMetadata where visibleLaunchers.contains(launcherNodeID) {
            allNodes[launcherNodeID] = TrafficGraphNode(
                id: launcherNodeID, kind: .launcher,
                title: metadata.name.isEmpty ? launcherNodeID.rawValue : metadata.name,
                detail: L("Started agent"), appPath: metadata.path,
                filter: .none, counters: FlowCounters()
            )
        }
        let visibleLauncherEdges = launcherMetadata.keys.sorted {
            let left = launcherID(bundleID: $0.bundleID)
            let right = launcherID(bundleID: $1.bundleID)
            if left != right { return left < right }
            return agentID($0.agent) < agentID($1.agent)
        }.filter { visibleLaunchers.contains(launcherID(bundleID: $0.bundleID)) }
        for launcher in visibleLauncherEdges {
            let launcherNodeID = launcherID(bundleID: launcher.bundleID)
            let agentNodeID = agentID(launcher.agent)
            edges.append(TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: launcherNodeID.rawValue + "→launched→" + agentNodeID.rawValue),
                source: launcherNodeID, target: agentNodeID, counters: FlowCounters(),
                filter: allNodes[agentNodeID]?.filter ?? .none, relationship: .launched
            ))
        }
        for toolNodeID in visibleTools.sorted() {
            guard let tool = toolMetadata.keys.first(where: { toolID($0) == toolNodeID }),
                  toolMetadata[tool]?.hasLineage == true
            else { continue }
            let agent = tool.agent
            edges.append(TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: agentID(agent).rawValue + "→runs→" + toolNodeID.rawValue),
                source: agentID(agent), target: toolNodeID, counters: FlowCounters(),
                filter: allNodes[toolNodeID]?.filter ?? .none, relationship: .runs
            ))
        }
        edges.sort { $0.id < $1.id }

        let visibleIDs = visibleAgents.union(visibleTools).union(visibleDestinations).union(visibleLaunchers)
        let nodes = visibleIDs.compactMap { allNodes[$0] }.sorted { $0.id < $1.id }
        let visibleTotal = selectedObserved.reduce(into: FlowCounters()) { $0 += $1.1 }
        let allDestinationCount = Set(observedCounters.keys.map { destinationID($0.destination) })
            .union(blocked.keys.map { destinationID(blockedDestination($0)) }).count
        let lineageCount = toolMetadata.values.filter(\.hasLineage).count
        let allLauncherNodes = Set(launcherMetadata.keys.map { launcherID(bundleID: $0.bundleID) }).count
        let allLauncherEdges = launcherMetadata.count
        let hidden = TrafficGraphHidden(
            nodeCount: max(0, included.count + toolMetadata.count + allDestinationCount + allLauncherNodes
                           - visibleIDs.count),
            edgeCount: max(0, observedCounters.count + blocked.count + lineageCount + allLauncherEdges - edges.count),
            counters: subtract(total, visibleTotal)
        )
        return TrafficGraphSnapshot(nodes: nodes, edges: edges, total: total, hidden: hidden)
    }

    private static func toolIdentity(_ row: BreakdownRow, agent: AgentIdentity) -> ToolIdentity? {
        guard !row.parentAgent.isEmpty || !row.mcpServer.isEmpty else { return nil }
        return ToolIdentity(agent: agent, bundleID: row.bundleID, mcpServer: row.mcpServer)
    }

    private static func displayName(_ row: BreakdownRow) -> String {
        !row.appName.isEmpty ? row.appName : row.bundleID
    }

    private static func prefersMetadata(_ candidate: ToolMetadata, over current: ToolMetadata) -> Bool {
        if candidate.path.isEmpty != current.path.isEmpty { return !candidate.path.isEmpty }
        if candidate.name.isEmpty != current.name.isEmpty { return !candidate.name.isEmpty }
        if candidate.weight != current.weight { return candidate.weight > current.weight }
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

    private static func prefersMetadata(_ candidate: LauncherMetadata, over current: LauncherMetadata) -> Bool {
        if candidate.path.isEmpty != current.path.isEmpty { return !candidate.path.isEmpty }
        if candidate.name.isEmpty != current.name.isEmpty { return !candidate.name.isEmpty }
        if candidate.weight != current.weight { return candidate.weight > current.weight }
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

    private static func launcherID(bundleID: String) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "launcher:" + component(bundleID))
    }

    private static func refusalProvesAgent(_ attempt: BlockedAttemptRow) -> Bool {
        guard !attempt.agentKey.isEmpty else { return false }
        if attempt.source == "agent-allowlist" || attempt.agentKey != attempt.bundleID { return true }
        return AgentCatalog.knownAgent(bundleID: attempt.agentKey, appName: attempt.agentName) != nil
    }

    private static func agentID(_ agent: AgentIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "agent:" + component(agent.bundleID))
    }

    private static func toolPrefix(_ agent: AgentIdentity) -> String {
        "tool:" + component(agent.bundleID)
    }

    private static func toolID(_ tool: ToolIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: toolPrefix(tool.agent) + component(tool.bundleID)
                           + component(tool.mcpServer))
    }

    private static func destinationID(_ destination: DestinationIdentity) -> TrafficGraphNodeID {
        if destination.isProvider {
            return TrafficGraphNodeID(rawValue: "service:" + component(destination.provider))
        }
        return TrafficGraphNodeID(rawValue: "destination:" + component(destination.domain)
                                  + component(destination.remoteIP))
    }

    private static func blockedDestination(_ relationship: BlockedRelationship) -> DestinationIdentity {
        let host = HostCanonicalizer.host(relationship.destination) ?? ""
        let provider = AgentCatalog.provider(domain: host, owner: "") ?? ""
        return DestinationIdentity(
            provider: provider,
            domain: provider.isEmpty ? VisualizationDomainFamily.group(host) : "",
            remoteIP: provider.isEmpty ? HostCanonicalizer.address(relationship.destination) ?? "" : "",
            owner: "",
            asn: 0
        )
    }

    private static func blockedID(_ relationship: BlockedRelationship) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: relationship.source.rawValue + "→blocked→"
                           + component(relationship.destination) + "→port→\(relationship.port)")
    }

    private static func observedID(_ relationship: ObservedRelationship) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: relationship.source.rawValue + "→observed→"
                           + destinationID(relationship.destination).rawValue)
    }

    private static func owningAgent(of source: TrafficGraphNodeID,
                                    included: [AgentIdentity]) -> AgentIdentity {
        included.first { source == agentID($0) || source.rawValue.hasPrefix(toolPrefix($0)) }
            ?? AgentIdentity(bundleID: "")
    }

    private static func sourceFilter(_ source: TrafficGraphNodeID,
                                     nodes: [TrafficGraphNodeID: TrafficGraphNode]) -> TrafficFilter {
        nodes[source]?.filter ?? .none
    }

    private static func destinationFilter(_ destination: DestinationIdentity,
                                          members: [TrafficGraphMember]) -> TrafficFilter {
        guard !destination.isProvider else {
            return members.count == 1 ? members[0].filter : .none
        }
        if !destination.domain.isEmpty { return TrafficFilter(domainSuffix: destination.domain) }
        return TrafficFilter(remoteIP: destination.remoteIP.isEmpty ? nil : destination.remoteIP)
    }

    private static func makeMembers<S: Sequence>(_ values: S) -> [TrafficGraphMember]
    where S.Element == MemberValue {
        values.map { value in
            let destination = DestinationIdentity(provider: "", domain: value.identity.domain,
                                                  remoteIP: value.identity.remoteIP,
                                                  owner: value.owner, asn: value.asn)
            return TrafficGraphMember(
                id: component(value.identity.source.rawValue) + component(value.identity.bundleID)
                    + component(value.identity.agentParent) + component(value.identity.mcpServer)
                    + component(value.identity.domain) + component(value.identity.remoteIP)
                    + component(value.identity.protocols) + component(value.identity.channel.rawValue),
                title: destinationTitle(destination), detail: destinationDetail(destination),
                filter: TrafficFilter(bundleID: value.identity.bundleID,
                                      agentParent: value.identity.agentParent.isEmpty ? nil : value.identity.agentParent,
                                      mcpServer: value.identity.mcpServer.isEmpty ? nil : value.identity.mcpServer,
                                      domain: value.identity.domain, remoteIP: value.identity.remoteIP,
                                      appProtocol: value.identity.protocols.isEmpty ? nil : value.identity.protocols,
                                      channel: value.identity.channel),
                counters: value.counters, protocols: value.identity.protocols, channel: value.identity.channel
            )
        }.sorted { $0.id < $1.id }
    }

    private static func destinationTitle(_ destination: DestinationIdentity) -> String {
        if destination.isProvider { return destination.provider }
        if !destination.domain.isEmpty { return destination.domain }
        if !destination.owner.isEmpty { return destination.owner }
        return destination.remoteIP.isEmpty ? L("Unknown destination") : destination.remoteIP
    }

    private static func destinationDetail(_ destination: DestinationIdentity) -> String {
        if destination.isProvider { return L("LLM service") }
        if !destination.domain.isEmpty { return destination.remoteIP }
        if !destination.owner.isEmpty, destination.asn > 0 { return "AS\(destination.asn) · \(destination.remoteIP)" }
        return ""
    }

    private static func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }

    private static func subtract(_ lhs: FlowCounters, _ rhs: FlowCounters) -> FlowCounters {
        FlowCounters(bytesIn: max(0, lhs.bytesIn - rhs.bytesIn),
                     bytesOut: max(0, lhs.bytesOut - rhs.bytesOut),
                     flows: max(0, lhs.flows - rhs.flows))
    }
}
