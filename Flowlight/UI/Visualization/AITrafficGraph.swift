import Foundation

struct AITrafficGraphLimits: Equatable, Sendable {
    var maxAgents: Int
    var maxTools: Int
    var maxDestinations: Int
    var maxObservedEdges: Int

    static let standard = AITrafficGraphLimits(maxAgents: 6, maxTools: 8, maxDestinations: 10, maxObservedEdges: 28)
    static let unbounded = AITrafficGraphLimits(maxAgents: .max, maxTools: .max,
                                                maxDestinations: .max, maxObservedEdges: .max)
}

enum AITrafficGraphBuilder {
    private struct AgentIdentity: Hashable {
        var bundleID: String
    }

    private struct ToolIdentity: Hashable {
        var agent: AgentIdentity
        var bundleID: String
        var name: String
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

    private struct ToolMetadata {
        var name: String
        var path: String
        var hasLineage: Bool
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
        for (agent, agentRows) in grouped {
            guard let root = AgentRootProof.identify(bundleID: agent.bundleID,
                                                     rows: proofGroups[agent] ?? agentRows) else { continue }
            let weight = agentRows.reduce(Int64(0)) { $0 + $1.counters.total }
            included.append((agent, agentRows, AgentMetadata(name: root.name, path: root.path,
                                                             known: root.known, weight: weight)))
        }
        included.sort {
            if $0.metadata.weight != $1.metadata.weight { return $0.metadata.weight > $1.metadata.weight }
            return agentID($0.agent) < agentID($1.agent)
        }

        var allNodes: [TrafficGraphNodeID: TrafficGraphNode] = [:]
        var observedCounters: [ObservedRelationship: FlowCounters] = [:]
        var observedMembers: [ObservedRelationship: [ExactMemberIdentity: MemberValue]] = [:]
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
                    var metadata = toolMetadata[tool] ?? ToolMetadata(
                        name: tool.mcpServer.isEmpty ? displayName(row) : tool.mcpServer,
                        path: row.appPath,
                        hasLineage: !row.parentAgent.isEmpty
                    )
                    metadata.counters += row.counters
                    if metadata.path.isEmpty { metadata.path = row.appPath }
                    toolMetadata[tool] = metadata
                } else {
                    sourceID = agentNodeID
                }

                let provider = AgentCatalog.provider(domain: row.domain, owner: row.owner) ?? ""
                let destination = DestinationIdentity(provider: provider,
                                                      domain: provider.isEmpty ? row.domain : "",
                                                      remoteIP: provider.isEmpty ? row.remoteIP : "",
                                                      owner: provider.isEmpty ? row.owner : "",
                                                      asn: provider.isEmpty ? row.asn : 0)
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

        for (tool, metadata) in toolMetadata {
            let id = toolID(tool)
            allNodes[id] = TrafficGraphNode(
                id: id, kind: tool.mcpServer.isEmpty ? .tool : .mcp,
                title: tool.mcpServer.isEmpty ? metadata.name : "\(metadata.name) MCP",
                detail: tool.mcpServer.isEmpty ? L("Works for %@", allNodes[agentID(tool.agent)]?.title ?? tool.agent.bundleID)
                    : L("MCP service for %@", allNodes[agentID(tool.agent)]?.title ?? tool.agent.bundleID),
                appPath: metadata.path,
                filter: TrafficFilter(bundleID: tool.bundleID, agentParent: tool.agent.bundleID,
                                      mcpServer: tool.mcpServer.isEmpty ? nil : tool.mcpServer),
                counters: metadata.counters
            )
        }

        let rankedObserved = observedCounters.sorted { left, right in
            if left.value.total != right.value.total { return left.value.total > right.value.total }
            return observedID(left.key) < observedID(right.key)
        }
        var visibleAgents: Set<TrafficGraphNodeID> = []
        var visibleTools: Set<TrafficGraphNodeID> = []
        var visibleDestinations: Set<TrafficGraphNodeID> = []
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
                filter: members.count == 1 ? members[0].filter : TrafficFilter.none,
                counters: counters, members: members
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
        for toolNodeID in visibleTools.sorted() {
            guard let tool = toolMetadata.keys.first(where: { toolID($0) == toolNodeID }),
                  toolMetadata[tool]?.hasLineage == true
            else { continue }
            let agent = tool.agent
            edges.append(TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: agentID(agent).rawValue + "→works-for→" + toolNodeID.rawValue),
                source: toolNodeID, target: agentID(agent), counters: FlowCounters(),
                filter: allNodes[toolNodeID]?.filter ?? .none, relationship: .worksFor
            ))
        }
        edges.sort { $0.id < $1.id }

        let visibleIDs = visibleAgents.union(visibleTools).union(visibleDestinations)
        let nodes = visibleIDs.compactMap { allNodes[$0] }.sorted { $0.id < $1.id }
        let visibleTotal = selectedObserved.reduce(into: FlowCounters()) { $0 += $1.1 }
        let allDestinationCount = Set(observedCounters.keys.map(\.destination)).count
        let lineageCount = toolMetadata.values.filter(\.hasLineage).count
        let hidden = TrafficGraphHidden(
            nodeCount: max(0, included.count + toolMetadata.count + allDestinationCount - nodes.count),
            edgeCount: max(0, observedCounters.count + lineageCount - edges.count),
            counters: subtract(total, visibleTotal)
        )
        return TrafficGraphSnapshot(nodes: nodes, edges: edges, total: total, hidden: hidden)
    }

    private static func toolIdentity(_ row: BreakdownRow, agent: AgentIdentity) -> ToolIdentity? {
        guard !row.parentAgent.isEmpty || !row.mcpServer.isEmpty else { return nil }
        return ToolIdentity(agent: agent, bundleID: row.bundleID, name: displayName(row), mcpServer: row.mcpServer)
    }

    private static func displayName(_ row: BreakdownRow) -> String {
        !row.appName.isEmpty ? row.appName : row.bundleID
    }

    private static func agentID(_ agent: AgentIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "agent:" + component(agent.bundleID))
    }

    private static func toolPrefix(_ agent: AgentIdentity) -> String {
        "tool:" + component(agent.bundleID)
    }

    private static func toolID(_ tool: ToolIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: toolPrefix(tool.agent) + component(tool.bundleID)
                           + component(tool.name) + component(tool.mcpServer))
    }

    private static func destinationID(_ destination: DestinationIdentity) -> TrafficGraphNodeID {
        if destination.isProvider {
            return TrafficGraphNodeID(rawValue: "service:" + component(destination.provider))
        }
        return TrafficGraphNodeID(rawValue: "destination:" + component(destination.domain)
                                  + component(destination.remoteIP))
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
