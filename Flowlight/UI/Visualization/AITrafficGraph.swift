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
        var relay: RelayIdentity?
    }

    private struct RelayIdentity: Hashable {
        var bundleID: String
    }

    private struct RelayMetadata {
        var name: String
        var path: String
        var weight: Int64
    }

    private struct ConfiguredGatewayRelationship: Hashable {
        var agent: AgentIdentity
        var gateway: RelayIdentity
        var declaration: String
    }

    private struct ResolvedGateway {
        var config: AgentGatewayConfig
        var identity: AgentGatewayIdentity?
        var agent: AgentIdentity
        var relay: RelayIdentity
    }

    private struct ObservedRouteIdentity: Hashable {
        var source: TrafficGraphNodeID
        var relay: RelayIdentity
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
                                      gateways: [AgentGatewayConfig] = [],
                                      resolveGateway: @Sendable (AgentGatewayConfig.Endpoint) -> AgentGatewayIdentity? = {
                                          LocalGatewayResolver.resolve($0)
                                      },
                                      includeConfiguredOnlyAgents: Bool = true,
                                      limits: AITrafficGraphLimits = .standard) -> TrafficGraphSnapshot
    where Rows.Element == BreakdownRow {
        let sourceRows = sourceRows.filter { !$0.counters.isEmpty }
        let rows = (visibleRows ?? sourceRows).filter { !$0.counters.isEmpty }
        let gatewayConfigs = gateways.map { ($0, resolveGateway($0.endpoint)) }
        let gatewayRelayBundleIDs = Set(gatewayConfigs.compactMap { $0.1?.bundleID })
        let isObservedGatewayRow: (BreakdownRow) -> Bool = { row in
            gatewayRelayBundleIDs.contains(row.bundleID) && !row.routeProxyBundleID.isEmpty
        }
        let proofRows = sourceRows.filter { !isObservedGatewayRow($0) }
        let visibleProofRows = rows.filter { !isObservedGatewayRow($0) }
        let proofGroups = Dictionary(grouping: proofRows) { row in
            AgentIdentity(bundleID: row.parentAgent.isEmpty ? row.bundleID : row.parentAgent)
        }
        let grouped = Dictionary(grouping: visibleProofRows) { row in
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
        let existingCandidates = Set(grouped.keys).union(refusalNames.keys)
        let configuredGatewayAgents = gatewayConfigs.map { config, identity in
            let agent = existingCandidates.sorted { left, right in
                let leftExact = left.bundleID.caseInsensitiveCompare(config.agent) == .orderedSame
                let rightExact = right.bundleID.caseInsensitiveCompare(config.agent) == .orderedSame
                if leftExact != rightExact { return leftExact }
                return agentID(left) < agentID(right)
            }.first { gatewayMatches(config, candidate: $0, rows: proofGroups[$0] ?? []) }
                ?? (includeConfiguredOnlyAgents ? AgentIdentity(bundleID: config.agent) : nil)
            return (config: config, identity: identity, agent: agent)
        }
        let configuredAgents = Set(configuredGatewayAgents.compactMap(\.agent))
        let candidateAgents = existingCandidates.union(configuredAgents)
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
            } else if configuredAgents.contains(agent) {
                let known = AgentCatalog.knownAgent(bundleID: agent.bundleID, appName: agent.bundleID)
                included.append((agent, agentRows, AgentMetadata(name: known?.name ?? agent.bundleID, path: "",
                                                                 known: known, weight: 0)))
            }
        }
        included.sort {
            if $0.metadata.weight != $1.metadata.weight { return $0.metadata.weight > $1.metadata.weight }
            return agentID($0.agent) < agentID($1.agent)
        }
        let semanticAgentIdentity: [TrafficGraphNodeID: String] = Dictionary(
            uniqueKeysWithValues: included.map {
                (
                    agentID($0.agent),
                    TrafficGraphApplicationCoalescer.canonicalApplicationIdentity(
                        bundleID: $0.agent.bundleID,
                        title: $0.metadata.name
                    )
                )
            }
        )
        let resolvedGateways = configuredGatewayAgents.compactMap { configured -> ResolvedGateway? in
            guard let agent = configured.agent,
                  included.contains(where: { $0.agent == agent }) else { return nil }
            let relay = RelayIdentity(
                bundleID: configured.identity?.bundleID
                    ?? "endpoint:\(configured.config.endpoint.description)"
            )
            return ResolvedGateway(
                config: configured.config,
                identity: configured.identity,
                agent: agent,
                relay: relay
            )
        }

        var allNodes: [TrafficGraphNodeID: TrafficGraphNode] = [:]
        var observedCounters: [ObservedRelationship: FlowCounters] = [:]
        var observedMembers: [ObservedRelationship: [ExactMemberIdentity: MemberValue]] = [:]
        var blocked: [BlockedRelationship: BlockedValue] = [:]
        var toolMetadata: [ToolIdentity: ToolMetadata] = [:]
        var relayMetadata: [RelayIdentity: RelayMetadata] = [:]
        var configuredGateways: [ConfiguredGatewayRelationship: AgentGatewayConfig] = [:]
        var total = FlowCounters()

        for row in rows where isObservedGatewayRow(row) {
            total += row.counters
            let relay = row.routeProxyBundleID.isEmpty ? nil : RelayIdentity(bundleID: row.routeProxyBundleID)
            if let relay {
                let candidate = RelayMetadata(name: row.routeProxyName, path: row.routeProxyPath,
                                              weight: row.counters.total)
                let current = relayMetadata[relay]
                if current == nil || prefersMetadata(candidate, over: current!) { relayMetadata[relay] = candidate }
            }
            let provider = AgentCatalog.provider(domain: row.domain, owner: row.owner) ?? ""
            let groupedDomain = row.domain.isEmpty ? "" : VisualizationDomainFamily.group(row.domain)
            let destination = DestinationIdentity(
                provider: provider, domain: provider.isEmpty ? groupedDomain : "",
                remoteIP: provider.isEmpty && groupedDomain.isEmpty ? row.remoteIP : "",
                owner: provider.isEmpty && groupedDomain.isEmpty ? row.owner : "",
                asn: provider.isEmpty && groupedDomain.isEmpty ? row.asn : 0
            )
            let sourceID = gatewayID(bundleID: row.bundleID)
            let relationship = ObservedRelationship(source: sourceID, destination: destination, relay: relay)
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
                let relay = row.routeProxyBundleID.isEmpty ? nil : RelayIdentity(bundleID: row.routeProxyBundleID)
                if let relay {
                    let candidate = RelayMetadata(name: row.routeProxyName, path: row.routeProxyPath,
                                                  weight: row.counters.total)
                    let current = relayMetadata[relay]
                    if current == nil || prefersMetadata(candidate, over: current!) {
                        relayMetadata[relay] = candidate
                    }
                }
                let relationship = ObservedRelationship(source: sourceID, destination: destination, relay: relay)
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
            guard let destination = VisualizationDestinationCanonicalizer.identity(attempt.destination) else { continue }
            let relationship = BlockedRelationship(source: sourceID, agent: agent,
                                                   destination: destination, port: attempt.port)
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
        for resolved in resolvedGateways {
            let declaration = "\(resolved.config.endpoint.description)|\(resolved.config.source)|\(resolved.config.sourceKey)"
            configuredGateways[ConfiguredGatewayRelationship(agent: resolved.agent, gateway: resolved.relay,
                                                               declaration: declaration)] = resolved.config
            let candidate = RelayMetadata(name: resolved.identity?.name ?? resolved.config.endpoint.description,
                                          path: resolved.identity?.path ?? "", weight: 0)
            let current = relayMetadata[resolved.relay]
            if current == nil || prefersMetadata(candidate, over: current!) { relayMetadata[resolved.relay] = candidate }
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
        var visibleAgents: Set<TrafficGraphNodeID> = []
        func semanticAgentKey(_ id: TrafficGraphNodeID) -> String {
            semanticAgentIdentity[id] ?? id.rawValue
        }
        func canAdmitAgent(_ id: TrafficGraphNodeID) -> Bool {
            let visibleSemanticAgents = Set(visibleAgents.map(semanticAgentKey))
            return visibleAgents.contains(id)
                || visibleSemanticAgents.contains(semanticAgentKey(id))
                || visibleSemanticAgents.count < max(0, limits.maxAgents)
        }
        for (agent, _) in rankedBlockedAgents.prefix(blockedAgentReserve) {
            let id = agentID(agent)
            if canAdmitAgent(id) { visibleAgents.insert(id) }
        }
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
            let destinationNodeID = destinationID(relationship.destination)
            let sourceIsGateway = relationship.source.rawValue.hasPrefix("proxy:")
            if sourceIsGateway {
                guard (visibleDestinations.contains(destinationNodeID)
                        || visibleDestinations.count < max(0, limits.maxDestinations)),
                      selectedObserved.count < max(0, limits.maxObservedEdges) else { continue }
                selectedObserved.append((relationship, counters))
                visibleDestinations.insert(destinationNodeID)
                continue
            }
            let sourceAgent = owningAgent(of: relationship.source, included: included.map(\.agent))
            let agentNodeID = agentID(sourceAgent)
            let sourceIsTool = relationship.source != agentNodeID
            guard canAdmitAgent(agentNodeID),
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
        // Configuration is relationship evidence in its own right. Admit configured agents within the same agent cap;
        // settings never manufacture counters or an observed route.
        for relationship in configuredGateways.keys.sorted(by: { configuredGatewayID($0) < configuredGatewayID($1) }) {
            let id = agentID(relationship.agent)
            if canAdmitAgent(id) { visibleAgents.insert(id) }
        }
        // The first refusal pass reserves capacity before observed traffic. Once observed traffic has admitted its
        // agents, use every remaining agent slot and blocked-edge slot rather than treating the reserve as a cap.
        for (agent, _) in rankedBlockedAgents {
            let id = agentID(agent)
            if canAdmitAgent(id) { visibleAgents.insert(id) }
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

        var visibleRelayCounters: [RelayIdentity: FlowCounters] = [:]
        for (relationship, counters) in selectedObserved {
            guard let relay = relationship.relay else { continue }
            visibleRelayCounters[relay, default: FlowCounters()] += counters
        }
        for (relay, counters) in visibleRelayCounters {
            let metadata = relayMetadata[relay] ?? RelayMetadata(name: relay.bundleID, path: "", weight: 0)
            allNodes[relayID(relay)] = TrafficGraphNode(
                id: relayID(relay), kind: .proxy,
                title: metadata.name.isEmpty ? relay.bundleID : metadata.name,
                detail: L("Observed route"), appPath: metadata.path,
                filter: TrafficFilter(bundleID: relay.bundleID), counters: counters
            )
        }
        let visibleGatewaySources = Set(selectedObserved.map(\.0.source)).filter { $0.rawValue.hasPrefix("proxy:") }
        for gatewaySource in visibleGatewaySources where allNodes[gatewaySource] == nil {
            guard let gateway = resolvedGateways.first(where: { relayID($0.relay) == gatewaySource }) else { continue }
            let counters = selectedObserved.reduce(into: FlowCounters()) { result, entry in
                if entry.0.source == gatewaySource { result += entry.1 }
            }
            allNodes[gatewaySource] = TrafficGraphNode(
                id: gatewaySource, kind: .proxy,
                title: gateway.identity?.name ?? gateway.config.endpoint.description,
                detail: L("Configured gateway"), appPath: gateway.identity?.path ?? "",
                filter: gateway.identity.map { TrafficFilter(bundleID: $0.bundleID) } ?? .none,
                counters: counters
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
                id: observedID(relationship), source: relationship.relay.map(relayID) ?? relationship.source,
                target: destinationID(relationship.destination), counters: counters,
                filter: members.count == 1 ? members[0].filter : sourceFilter(relationship.source, nodes: allNodes),
                relationship: .observed, members: members
            )
        }
        let visibleObservedRoutes = Set(selectedObserved.compactMap { relationship, _ -> ObservedRouteIdentity? in
            relationship.relay.map { ObservedRouteIdentity(source: relationship.source, relay: $0) }
        })
        for route in visibleObservedRoutes.sorted(by: { observedRouteID($0) < observedRouteID($1) }) {
            let volume = selectedObserved.reduce(into: FlowCounters()) { result, entry in
                if entry.0.source == route.source, entry.0.relay == route.relay { result += entry.1 }
            }
            edges.append(TrafficGraphEdge(
                id: observedRouteID(route), source: route.source, target: relayID(route.relay),
                counters: FlowCounters(), filter: sourceFilter(route.source, nodes: allNodes),
                relationship: .routedThrough, trafficVolume: volume
            ))
        }
        for (relationship, config) in configuredGateways where visibleAgents.contains(agentID(relationship.agent)) {
            let metadata = relayMetadata[relationship.gateway]
                ?? RelayMetadata(name: relationship.gateway.bundleID, path: "", weight: 0)
            let nodeID = relayID(relationship.gateway)
            if allNodes[nodeID] == nil {
                allNodes[nodeID] = TrafficGraphNode(
                    id: nodeID, kind: .proxy,
                    title: metadata.name.isEmpty ? relationship.gateway.bundleID : metadata.name,
                    detail: L("Configured gateway"), appPath: metadata.path,
                    filter: TrafficFilter(bundleID: relationship.gateway.bundleID), counters: FlowCounters()
                )
            }
            edges.append(TrafficGraphEdge(
                id: configuredGatewayID(relationship), source: agentID(relationship.agent), target: nodeID,
                counters: FlowCounters(), filter: allNodes[agentID(relationship.agent)]?.filter ?? .none,
                relationship: .configuredGateway,
                configuration: TrafficGraphConfiguration(endpoint: config.endpoint.description,
                                                        source: config.source, sourceKey: config.sourceKey)
            ))
        }
        for (relationship, value) in selectedBlocked {
            let exactDestination = VisualizationDestinationCanonicalizer.parse(relationship.destination)
            let destination = blockedDestination(relationship)
            edges.append(TrafficGraphEdge(
                id: blockedID(relationship), source: relationship.source, target: destinationID(destination),
                counters: FlowCounters(),
                filter: TrafficFilter(
                    bundleID: relationship.source == agentID(relationship.agent)
                        ? relationship.agent.bundleID : allNodes[relationship.source]?.filter.bundleID,
                    agentParent: relationship.source == agentID(relationship.agent)
                        ? nil : relationship.agent.bundleID,
                    domain: exactDestination.domain,
                    remoteIP: exactDestination.address
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
        var launcherTraffic: [TrafficGraphNodeID: Int64] = [:]
        for entry in included where visibleAgents.contains(agentID(entry.agent)) {
            for row in proofGroups[entry.agent] ?? [] where !row.launcherBundleID.isEmpty {
                let launcher = LauncherIdentity(agent: entry.agent, bundleID: row.launcherBundleID)
                let nodeID = launcherID(bundleID: row.launcherBundleID)
                launcherTraffic[nodeID, default: 0] += row.counters.total
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
            let leftTraffic = launcherTraffic[$0.key, default: 0]
            let rightTraffic = launcherTraffic[$1.key, default: 0]
            if leftTraffic != rightTraffic { return leftTraffic > rightTraffic }
            return $0.key < $1.key
        }
        let visibleLaunchers = Set(rankedLaunchers.prefix(max(0, limits.maxLaunchers)).map(\.key))
        for (launcherNodeID, metadata) in nodeMetadata where visibleLaunchers.contains(launcherNodeID) {
            allNodes[launcherNodeID] = TrafficGraphNode(
                id: launcherNodeID, kind: .launcher,
                title: metadata.name.isEmpty ? launcherNodeID.rawValue : metadata.name,
                detail: L("Started agent"), appPath: metadata.path,
                filter: TrafficFilter(
                    bundleID: launcherMetadata.keys.first {
                        launcherID(bundleID: $0.bundleID) == launcherNodeID
                    }?.bundleID
                ),
                counters: FlowCounters()
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

        let visibleRelays = Set(selectedObserved.compactMap { $0.0.relay.map(relayID) })
            .union(selectedObserved.map(\.0.source).filter { $0.rawValue.hasPrefix("proxy:") })
            .union(configuredGateways.keys.compactMap {
                visibleAgents.contains(agentID($0.agent)) ? relayID($0.gateway) : nil
            })
        let visibleIDs = visibleAgents.union(visibleTools).union(visibleDestinations)
            .union(visibleLaunchers).union(visibleRelays)
        let nodes = visibleIDs.compactMap { allNodes[$0] }.sorted { $0.id < $1.id }
        let coalesced = TrafficGraphApplicationCoalescer.coalesce(nodes: nodes, edges: edges)
        let visibleTotal = selectedObserved.reduce(into: FlowCounters()) { $0 += $1.1 }
        let allDestinationCount = Set(observedCounters.keys.map { destinationID($0.destination) })
            .union(blocked.keys.map { destinationID(blockedDestination($0)) }).count
        let lineageCount = toolMetadata.values.filter(\.hasLineage).count
        let allLauncherNodes = Set(launcherMetadata.keys.map { launcherID(bundleID: $0.bundleID) }).count
        let allLauncherEdges = launcherMetadata.count
        let allObservedGatewayNodeIDs = Set(observedCounters.keys.map(\.source).filter {
            $0.rawValue.hasPrefix("proxy:")
        })
        let allRelayNodeIDs = Set(observedCounters.keys.compactMap { $0.relay.map(relayID) })
            .union(allObservedGatewayNodeIDs)
            .union(configuredGateways.keys.map { relayID($0.gateway) })
        let allRelayNodes = allRelayNodeIDs.count
        let allObservedRoutes = Set(observedCounters.keys.compactMap { relationship in
            relationship.relay.map { ObservedRouteIdentity(source: relationship.source, relay: $0) }
        }).count
        let hidden = TrafficGraphHidden(
            nodeCount: max(0, included.count + toolMetadata.count + allDestinationCount + allLauncherNodes + allRelayNodes
                           - visibleIDs.count),
            edgeCount: max(0, observedCounters.count + blocked.count + lineageCount + allLauncherEdges
                           + allObservedRoutes + configuredGateways.count - edges.count),
            counters: total.subtractingFloorZero(visibleTotal)
        )
        return TrafficGraphSnapshot(nodes: coalesced.nodes, edges: coalesced.edges, total: total, hidden: hidden)
    }

    static func buildForPresentation<Rows: Sequence>(
        rows sourceRows: Rows,
        visibleRows: [BreakdownRow]? = nil,
        blockedAttempts: [BlockedAttemptRow] = [],
        gateways: [AgentGatewayConfig] = [],
        resolveGateway: @Sendable (AgentGatewayConfig.Endpoint) -> AgentGatewayIdentity? = {
            LocalGatewayResolver.resolve($0)
        },
        includeConfiguredOnlyAgents: Bool = true,
        mapLimits: AITrafficGraphLimits = .standard,
        endpointQuery: TrafficGraphEndpointQuery = .init(),
        expandedGroupIDs: Set<TrafficGraphNodeID> = [],
        expandedEdgeGroupIDs: Set<TrafficGraphEdgeID> = []
    ) -> TrafficGraphBuild where Rows.Element == BreakdownRow {
        let rows = Array(sourceRows)
        var evidence = build(
            rows: rows,
            visibleRows: visibleRows,
            blockedAttempts: blockedAttempts,
            gateways: gateways,
            resolveGateway: resolveGateway,
            includeConfiguredOnlyAgents: includeConfiguredOnlyAgents,
            limits: .unbounded
        )
        evidence.hidden = .none
        let sourceOptions = TrafficGraphEndpointProjector.sourceOptions(
            in: evidence,
            matchingDestination: endpointQuery.destination
        )
        let destinationOptions = TrafficGraphEndpointProjector.destinationOptions(
            in: evidence,
            matchingSource: endpointQuery.source
        )
        let complete = TrafficGraphEndpointProjector.scope(evidence, query: endpointQuery)
        let map: TrafficGraphSnapshot
        if mapLimits == .unbounded {
            map = complete
        } else if endpointQuery.isFocused {
            map = TrafficGraphEndpointProjector.focusedMap(
                complete,
                expandedGroupIDs: expandedGroupIDs,
                expandedEdgeGroupIDs: expandedEdgeGroupIDs
            )
        } else if mapLimits == .standard {
            map = TrafficGraphEndpointProjector.defaultMap(complete)
        } else {
            map = TrafficGraphMapProjector.project(complete, limits: mapLimits)
        }
        return TrafficGraphBuild(
            complete: complete,
            map: map,
            sourceOptions: sourceOptions,
            destinationOptions: destinationOptions
        )
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
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

    private static func prefersMetadata(_ candidate: LauncherMetadata, over current: LauncherMetadata) -> Bool {
        if candidate.path.isEmpty != current.path.isEmpty { return !candidate.path.isEmpty }
        if candidate.name.isEmpty != current.name.isEmpty { return !candidate.name.isEmpty }
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

    private static func prefersMetadata(_ candidate: RelayMetadata, over current: RelayMetadata) -> Bool {
        if candidate.path.isEmpty != current.path.isEmpty { return !candidate.path.isEmpty }
        if candidate.name.isEmpty != current.name.isEmpty { return !candidate.name.isEmpty }
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

}

enum TrafficGraphApplicationCoalescer {
    static func coalesce(
        nodes: [TrafficGraphNode],
        edges: [TrafficGraphEdge]
    ) -> (nodes: [TrafficGraphNode], edges: [TrafficGraphEdge]) {
        let candidates = nodes.filter { node in
            switch node.kind {
            case .app, .agent, .tool, .launcher, .proxy: return node.filter.bundleID?.isEmpty == false
            default: return false
            }
        }
        let grouped = Dictionary(grouping: candidates) {
            canonicalApplicationIdentity(bundleID: $0.filter.bundleID ?? "", title: $0.title)
        }
        var replacements: [TrafficGraphNodeID: TrafficGraphNodeID] = [:]
        var mergedNodes: [TrafficGraphNodeID: TrafficGraphNode] = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0) }
        )
        let configuredAgentIDs = Set(
            edges.lazy
                .filter { $0.relationship == .configuredGateway }
                .map(\.source)
        )

        for duplicates in grouped.values where duplicates.count > 1 {
            let survivor = duplicates.sorted {
                prefersApplicationNode(
                    $0,
                    over: $1,
                    configuredAgentIDs: configuredAgentIDs
                )
            }.first!
            var merged = survivor
            if let metadata = duplicates.sorted(by: prefersDisplayMetadata).first {
                if merged.appPath.isEmpty, !metadata.appPath.isEmpty {
                    merged.appPath = metadata.appPath
                    if !metadata.title.isEmpty { merged.title = metadata.title }
                    if !metadata.detail.isEmpty { merged.detail = metadata.detail }
                } else {
                    if merged.title.isEmpty { merged.title = metadata.title }
                    if merged.detail.isEmpty { merged.detail = metadata.detail }
                }
            }
            let exactBundleIDs = Set(duplicates.compactMap { $0.filter.bundleID })
            let normalizedBundleIDs = Set(exactBundleIDs.map { $0.lowercased() })
            let includeAttributedChildren = duplicates.contains { $0.filter.includeAttributedChildren }
            let focusIncludesAttributedParents = duplicates.contains {
                $0.filter.agentParent != nil || $0.filter.focusIncludesAttributedParents
            }
            let duplicateRoleIDs = Set(duplicates.map(\.id))
            let mergesAppAndRole = duplicates.contains { $0.kind == .app }
            var exactMembers: [String: TrafficGraphMember] = [:]
            var applicationVisible = FlowCounters()
            for edge in edges where edge.relationship == .observed {
                for member in edge.members {
                    let matchesApplication = normalizedBundleIDs.contains(
                        member.filter.bundleID?.lowercased() ?? ""
                    )
                    let matchesAttributedChild = includeAttributedChildren && normalizedBundleIDs.contains(
                        member.filter.agentParent?.lowercased() ?? ""
                    )
                    let belongsToMergedRole = mergesAppAndRole && duplicateRoleIDs.contains(edge.source)
                    guard matchesApplication || matchesAttributedChild || belongsToMergedRole else { continue }
                    if matchesApplication || matchesAttributedChild {
                        applicationVisible += member.counters
                    }
                    if var current = exactMembers[member.id] {
                        current.counters += member.counters
                        exactMembers[member.id] = current
                    } else {
                        exactMembers[member.id] = member
                    }
                }
            }
            var mergedCounters = exactMembers.values.reduce(into: FlowCounters()) { $0 += $1.counters }
            if survivor.kind == .app {
                mergedCounters += survivor.counters.subtractingFloorZero(applicationVisible)
            }
            merged.counters = mergedCounters
            let routedBundleIDs = Set(exactMembers.values.compactMap { $0.filter.bundleID })
            merged.isFilterExact = !mergesAppAndRole || routedBundleIDs.isSubset(of: exactBundleIDs)
            merged.filter = exactBundleIDs.count == 1
                ? TrafficFilter(
                    bundleID: exactBundleIDs.first,
                    includeAttributedChildren: includeAttributedChildren,
                    focusIncludesAttributedParents: focusIncludesAttributedParents
                )
                : TrafficFilter(
                    bundleIDs: exactBundleIDs.sorted(),
                    includeAttributedChildren: includeAttributedChildren,
                    focusIncludesAttributedParents: focusIncludesAttributedParents
                )
            let removedIDs = Set(duplicates.filter { $0.id != survivor.id }.map(\.id))
            let collapsedEvidence = edges.compactMap { edge -> TrafficGraphRoleEvidence? in
                guard removedIDs.contains(edge.source) || removedIDs.contains(edge.target),
                      edge.relationship != .observed,
                      edge.relationship != .blocked,
                      edge.relationship != .invoked else { return nil }
                return TrafficGraphRoleEvidence(
                    relationship: edge.relationship,
                    detail: roleEvidenceDetail(edge.relationship),
                    configuration: edge.configuration
                )
            }
            merged.roleEvidence = (duplicates.flatMap(\.roleEvidence) + collapsedEvidence)
                .reduce(into: [TrafficGraphRoleEvidence]()) { result, evidence in
                    guard !result.contains(evidence) else { return }
                    result.append(evidence)
                }
            for node in duplicates where node.id != survivor.id {
                replacements[node.id] = survivor.id
                mergedNodes.removeValue(forKey: node.id)
            }
            mergedNodes[survivor.id] = merged
        }

        guard !replacements.isEmpty else {
            return (nodes.sorted { $0.id < $1.id }, edges.sorted { $0.id < $1.id })
        }

        struct EdgeKey: Hashable {
            var source: TrafficGraphNodeID
            var relationship: TrafficGraphRelationship
            var target: TrafficGraphNodeID
            var configuration: TrafficGraphConfiguration?
            var enforcementCategory: String?
            var enforcementSource: String?
            var enforcementDetail: String?
            var blockedFilter: String?
        }
        var remappedEdges: [EdgeKey: TrafficGraphEdge] = [:]
        for original in edges {
            var edge = original
            edge.source = replacements[edge.source] ?? edge.source
            edge.target = replacements[edge.target] ?? edge.target
            guard edge.source != edge.target else { continue }
            let key = EdgeKey(
                source: edge.source,
                relationship: edge.relationship,
                target: edge.target,
                configuration: edge.configuration,
                enforcementCategory: edge.enforcement?.category,
                enforcementSource: edge.enforcement?.source,
                enforcementDetail: edge.enforcement?.detail,
                blockedFilter: edge.relationship == .blocked ? blockedFilterIdentity(edge.filter) : nil
            )
            if var current = remappedEdges[key] {
                current.counters += edge.counters
                if let count = edge.enforcement?.count { current.enforcement?.count += count }
                if let volume = edge.trafficVolume {
                    var combined = current.trafficVolume ?? FlowCounters()
                    combined += volume
                    current.trafficVolume = combined
                }
                current.members = (current.members + edge.members)
                    .reduce(into: [TrafficGraphMember]()) { result, member in
                        if let index = result.firstIndex(where: { $0.id == member.id }) {
                            result[index].counters += member.counters
                        } else {
                            result.append(member)
                        }
                    }
                    .sorted { $0.id < $1.id }
                remappedEdges[key] = current
            } else {
                var rawID = edge.source.rawValue + "→" + edge.relationship.rawValue + "→" + edge.target.rawValue
                if let configuration = edge.configuration {
                    rawID += "→configuration→" + component(configuration.endpoint)
                        + component(configuration.source)
                        + component(configuration.sourceKey)
                }
                if let enforcement = edge.enforcement {
                    rawID += "→enforcement→" + component(enforcement.source)
                        + component(enforcement.category)
                        + component(enforcement.detail)
                }
                if edge.relationship == .blocked {
                    rawID += "→filter→" + blockedFilterIdentity(edge.filter)
                }
                edge.id = TrafficGraphEdgeID(rawValue: rawID)
                remappedEdges[key] = edge
            }
        }
        let normalizedEdges = remappedEdges.values.map { value in
            var edge = value
            guard edge.relationship == .observed, edge.members.count > 1 else { return edge }
            let bundleIDs = Set(edge.members.compactMap { $0.filter.bundleID })
            edge.filter = bundleIDs.count == 1
                ? TrafficFilter(bundleID: bundleIDs.first)
                : TrafficFilter(bundleIDs: bundleIDs.sorted())
            return edge
        }
        return (
            mergedNodes.values.sorted { $0.id < $1.id },
            normalizedEdges.sorted { $0.id < $1.id }
        )
    }

    private static func blockedFilterIdentity(_ filter: TrafficFilter) -> String {
        [
            filter.bundleID ?? "",
            filter.bundleIDs.sorted().joined(separator: "\u{1F}"),
            filter.agentParent ?? "",
            filter.mcpServer ?? "",
            filter.domain ?? "",
            filter.remoteIP ?? "",
            filter.owner ?? "",
            filter.domainSuffix ?? "",
            filter.appProtocol ?? "",
            filter.channel.map { String(describing: $0) } ?? ""
        ].map(component).joined()
    }

    private static func roleEvidenceDetail(_ relationship: TrafficGraphRelationship) -> String {
        switch relationship {
        case .runs: return L("Runs")
        case .launched: return L("Started")
        case .configuredGateway: return L("Configured gateway")
        case .routedThrough: return L("Observed route")
        case .observed: return L("Observed")
        case .blocked: return L("Blocked")
        case .invoked: return L("Invoked")
        }
    }

    static func canonicalApplicationIdentity(bundleID: String, title: String) -> String {
        if let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: title) {
            return "known:" + known.name.lowercased()
        }
        return "app:" + bundleID.lowercased()
    }

    private static func prefersDisplayMetadata(_ left: TrafficGraphNode, _ right: TrafficGraphNode) -> Bool {
        if left.appPath.isEmpty != right.appPath.isEmpty { return !left.appPath.isEmpty }
        if left.title.isEmpty != right.title.isEmpty { return !left.title.isEmpty }
        if left.detail.isEmpty != right.detail.isEmpty { return !left.detail.isEmpty }
        if left.counters.total != right.counters.total { return left.counters.total > right.counters.total }
        return left.id < right.id
    }

    private static func prefersApplicationNode(
        _ left: TrafficGraphNode,
        over right: TrafficGraphNode,
        configuredAgentIDs: Set<TrafficGraphNodeID>
    ) -> Bool {
        func priority(_ kind: TrafficGraphNode.Kind) -> Int {
            switch kind {
            case .app: return 0
            case .agent: return 1
            case .tool: return 2
            case .proxy: return 3
            case .launcher: return 4
            default: return 5
            }
        }
        let leftIsConfigured = configuredAgentIDs.contains(left.id)
        let rightIsConfigured = configuredAgentIDs.contains(right.id)
        if leftIsConfigured != rightIsConfigured { return leftIsConfigured }
        let leftPriority = priority(left.kind)
        let rightPriority = priority(right.kind)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        if left.counters.total != right.counters.total { return left.counters.total > right.counters.total }
        return left.id < right.id
    }

    private static func component(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

extension AITrafficGraphBuilder {
    private static func gatewayMatches(_ config: AgentGatewayConfig, candidate: AgentIdentity,
                                       rows: [BreakdownRow]) -> Bool {
        let key = config.agent.lowercased()
        if candidate.bundleID.lowercased() == key { return true }
        let names = rows.flatMap { [$0.appName, $0.parentAgentName] }.map { $0.lowercased() }
        if names.contains(key) { return true }
        return AgentCatalog.knownAgent(bundleID: candidate.bundleID, appName: names.first ?? candidate.bundleID)
            .map { $0.processNames.contains(key) || $0.bundleIDs.contains(config.agent) } ?? false
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
        let exact = VisualizationDestinationCanonicalizer.parse(relationship.destination)
        let provider = exact.domain.flatMap { AgentCatalog.provider(domain: $0, owner: "") } ?? ""
        return DestinationIdentity(
            provider: provider,
            domain: provider.isEmpty ? exact.domain.map(VisualizationDomainFamily.group) ?? "" : "",
            remoteIP: provider.isEmpty ? exact.address ?? "" : "",
            owner: "",
            asn: 0
        )
    }

    private static func blockedID(_ relationship: BlockedRelationship) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: relationship.source.rawValue + "→blocked→"
                           + component(relationship.destination) + "→port→\(relationship.port)")
    }

    private static func gatewayID(bundleID: String) -> TrafficGraphNodeID {
        relayID(RelayIdentity(bundleID: bundleID))
    }

    private static func relayID(_ relay: RelayIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "proxy:" + component(relay.bundleID))
    }

    private static func configuredGatewayID(_ relationship: ConfiguredGatewayRelationship) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: agentID(relationship.agent).rawValue + "→configured-gateway→"
                           + relayID(relationship.gateway).rawValue + "→declaration→"
                           + component(relationship.declaration))
    }

    private static func observedRouteID(_ route: ObservedRouteIdentity) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: route.source.rawValue + "→routed-through→" + relayID(route.relay).rawValue)
    }

    private static func observedID(_ relationship: ObservedRelationship) -> TrafficGraphEdgeID {
        let source = relationship.relay.map(relayID) ?? relationship.source
        return TrafficGraphEdgeID(rawValue: source.rawValue + "→observed→"
                                  + destinationID(relationship.destination).rawValue
                                  + "→origin→" + relationship.source.rawValue)
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
}
