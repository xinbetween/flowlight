import Foundation

struct TrafficGraphNodeID: Hashable, Sendable, Comparable {
    var rawValue: String

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TrafficGraphEdgeID: Hashable, Sendable, Comparable {
    var rawValue: String

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TrafficGraphRoleEvidence: Sendable, Equatable {
    var relationship: TrafficGraphRelationship
    var detail: String
    var configuration: TrafficGraphConfiguration? = nil
}

struct TrafficGraphNode: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case app
        case agent
        case destination
        case service
        case tool
        case mcp
        case launcher
        case proxy
    }

    var id: TrafficGraphNodeID
    var kind: Kind
    var title: String
    var detail: String
    var appPath: String
    var filter: TrafficFilter
    var counters: FlowCounters
    var members: [TrafficGraphMember] = []
    var roleEvidence: [TrafficGraphRoleEvidence] = []
    var isFilterExact = true
    /// Exact semantic node IDs represented by this collapsed Map group. Exact nodes leave this empty.
    var collapsedNodeIDs: [TrafficGraphNodeID] = []

    var isCollapsedGroup: Bool { !collapsedNodeIDs.isEmpty }
    var representedNodeIDs: Set<TrafficGraphNodeID> {
        isCollapsedGroup ? Set(collapsedNodeIDs) : [id]
    }
}

enum TrafficGraphRelationship: String, Sendable, Hashable {
    case observed
    case runs
    case launched
    case configuredGateway
    case routedThrough
    case blocked
    case invoked
}

struct TrafficGraphEnforcement: Sendable, Hashable {
    var count: Int64
    var category: String
    var source: String
    var detail: String
}

struct TrafficGraphConfiguration: Sendable, Hashable {
    var endpoint: String
    var source: String
    var sourceKey: String
}

struct TrafficGraphMember: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var detail: String
    var filter: TrafficFilter
    var counters: FlowCounters
    var protocols: String
    var channel: NetworkChannel
}

struct TrafficGraphEdge: Identifiable, Sendable {
    var id: TrafficGraphEdgeID
    var source: TrafficGraphNodeID
    var target: TrafficGraphNodeID
    var counters: FlowCounters
    var filter: TrafficFilter
    var relationship: TrafficGraphRelationship = .observed
    var members: [TrafficGraphMember] = []
    var enforcement: TrafficGraphEnforcement? = nil
    var configuration: TrafficGraphConfiguration? = nil
    /// Captured bytes represented by this route segment when `counters` must remain zero to avoid counting one flow
    /// more than once in snapshot totals. Configured-only relationships never carry this value.
    var trafficVolume: FlowCounters? = nil
    /// Exact semantic edge IDs represented by this collapsed Map relationship. Exact edges leave this empty.
    var collapsedEdgeIDs: [TrafficGraphEdgeID] = []

    var displayedCounters: FlowCounters { trafficVolume ?? counters }
    var isTrafficRibbon: Bool { relationship == .observed || trafficVolume != nil }
    var isCollapsedGroup: Bool { !collapsedEdgeIDs.isEmpty }
    var representedEdgeIDs: Set<TrafficGraphEdgeID> {
        isCollapsedGroup ? Set(collapsedEdgeIDs) : [id]
    }
}

extension FlowCounters {
    func subtractingFloorZero(_ other: FlowCounters) -> FlowCounters {
        FlowCounters(
            bytesIn: max(0, bytesIn - other.bytesIn),
            bytesOut: max(0, bytesOut - other.bytesOut),
            flows: max(0, flows - other.flows)
        )
    }
}

struct TrafficGraphHidden: Equatable, Sendable {
    var nodeCount = 0
    var edgeCount = 0
    var counters = FlowCounters()

    static let none = TrafficGraphHidden()
    var hasOmissions: Bool { nodeCount > 0 || edgeCount > 0 }
}

struct TrafficGraphSnapshot: Sendable {
    var nodes: [TrafficGraphNode]
    var edges: [TrafficGraphEdge]
    var total: FlowCounters
    var hidden: TrafficGraphHidden

    static let empty = TrafficGraphSnapshot(nodes: [], edges: [], total: FlowCounters(), hidden: .none)

    var visibleTotal: FlowCounters {
        edges.lazy.filter { $0.relationship == .observed }
            .reduce(into: FlowCounters()) { $0 += $1.counters }
    }

    var representedNodeIDs: Set<TrafficGraphNodeID> {
        nodes.reduce(into: Set<TrafficGraphNodeID>()) { $0.formUnion($1.representedNodeIDs) }
    }

    var representedEdgeIDs: Set<TrafficGraphEdgeID> {
        edges.reduce(into: Set<TrafficGraphEdgeID>()) { $0.formUnion($1.representedEdgeIDs) }
    }
}

struct TrafficGraphBuild: Sendable {
    var complete: TrafficGraphSnapshot
    var map: TrafficGraphSnapshot
}

struct TrafficGraphRoleListItem: Identifiable, Sendable {
    var node: TrafficGraphNode
    var evidence: TrafficGraphRoleEvidence
    var index: Int

    var id: String {
        node.id.rawValue + "|role|" + evidence.relationship.rawValue + "|\(index)"
    }
}

struct TrafficGraphListPage: Sendable {
    var edges: [TrafficGraphEdge]
    var roleItems: [TrafficGraphRoleListItem]
    var shownCount: Int
    var totalCount: Int
    var remainingCount: Int

    var hasMore: Bool { remainingCount > 0 }
}

enum TrafficGraphListPager {
    static let pageSize = 25

    private static func roleItems(in complete: TrafficGraphSnapshot) -> [TrafficGraphRoleListItem] {
        complete.nodes.flatMap { node in
            node.roleEvidence.enumerated().compactMap { index, evidence -> TrafficGraphRoleListItem? in
                let survivesAsEdge = complete.edges.contains { edge in
                    edge.relationship == evidence.relationship
                        && (edge.source == node.id || edge.target == node.id)
                        && edge.configuration == evidence.configuration
                }
                guard !survivesAsEdge else { return nil }
                return TrafficGraphRoleListItem(node: node, evidence: evidence, index: index)
            }
        }
    }

    static func totalCount(in complete: TrafficGraphSnapshot) -> Int {
        complete.edges.count + roleItems(in: complete).count
    }

    static func clampedVisibleCount(current: Int, in complete: TrafficGraphSnapshot) -> Int {
        min(max(pageSize, current), totalCount(in: complete))
    }

    static func page(in complete: TrafficGraphSnapshot, visibleCount: Int) -> TrafficGraphListPage {
        let roleItems = roleItems(in: complete)
        let total = complete.edges.count + roleItems.count
        let shown = min(max(0, visibleCount), total)
        let shownEdgeCount = min(shown, complete.edges.count)
        let shownRoleCount = max(0, shown - shownEdgeCount)
        return TrafficGraphListPage(
            edges: Array(complete.edges.prefix(shownEdgeCount)),
            roleItems: Array(roleItems.prefix(shownRoleCount)),
            shownCount: shown,
            totalCount: total,
            remainingCount: total - shown
        )
    }

    static func nextVisibleCount(current: Int, total: Int) -> Int {
        min(max(0, total), max(0, current) + pageSize)
    }
}

extension TrafficGraphHidden {
    static func exactDifference(
        complete: TrafficGraphSnapshot,
        projected: TrafficGraphSnapshot
    ) -> TrafficGraphHidden {
        let projectedNodeIDs = Set(projected.nodes.map(\.id))
        let projectedEdgeIDs = Set(projected.edges.map(\.id))
        let omittedObserved = complete.edges.lazy.filter {
            $0.relationship == .observed && !projectedEdgeIDs.contains($0.id)
        }
        return TrafficGraphHidden(
            nodeCount: complete.nodes.lazy.filter { !projectedNodeIDs.contains($0.id) }.count,
            edgeCount: complete.edges.lazy.filter { !projectedEdgeIDs.contains($0.id) }.count,
            counters: omittedObserved.reduce(into: FlowCounters()) { $0 += $1.counters }
        )
    }
}

enum TrafficGraphMapProjector {
    private struct Limits {
        var roots: Int
        var tools: Int
        var destinations: Int
        var observedEdges: Int
        var blockedEdges: Int
        var launchers: Int
        var relays: Int
        var recalculateSourceCounters: Bool
        var blockedRootReserve: Int
        var blockedDestinationReserve: Int?
    }

    static func project(
        _ complete: TrafficGraphSnapshot,
        limits: TrafficGraphLimits
    ) -> TrafficGraphSnapshot {
        project(
            complete,
            limits: Limits(
                roots: limits.maxApps,
                tools: 0,
                destinations: limits.maxDestinations,
                observedEdges: limits.maxEdges,
                blockedEdges: limits.maxBlockedEdges,
                launchers: 0,
                relays: limits.maxRelays,
                recalculateSourceCounters: false,
                blockedRootReserve: 0,
                blockedDestinationReserve: min(
                    5,
                    max(0, limits.maxBlockedEdges),
                    max(0, limits.maxDestinations) / 2
                )
            )
        )
    }

    static func project(
        _ complete: TrafficGraphSnapshot,
        limits: AITrafficGraphLimits
    ) -> TrafficGraphSnapshot {
        project(
            complete,
            limits: Limits(
                roots: limits.maxAgents,
                tools: limits.maxTools,
                destinations: limits.maxDestinations,
                observedEdges: limits.maxObservedEdges,
                blockedEdges: limits.maxBlockedEdges,
                launchers: limits.maxLaunchers,
                relays: .max,
                recalculateSourceCounters: true,
                blockedRootReserve: min(
                    max(0, limits.maxAgents),
                    max(1, max(0, limits.maxAgents) / 3)
                ),
                blockedDestinationReserve: nil
            )
        )
    }

    private static func project(
        _ complete: TrafficGraphSnapshot,
        limits: Limits
    ) -> TrafficGraphSnapshot {
        let nodesByID = Dictionary(uniqueKeysWithValues: complete.nodes.map { ($0.id, $0) })
        let supportEdges = complete.edges.filter {
            $0.relationship != .observed && $0.relationship != .blocked
        }
        let incomingSupport = Dictionary(grouping: supportEdges, by: \.target)

        func rootIDs(for nodeID: TrafficGraphNodeID) -> Set<TrafficGraphNodeID> {
            guard let node = nodesByID[nodeID] else { return [] }
            switch node.kind {
            case .app, .agent:
                return [nodeID]
            case .tool, .mcp:
                let roots = (incomingSupport[nodeID] ?? [])
                    .filter { $0.relationship == .runs || $0.relationship == .invoked }
                    .flatMap { rootIDs(for: $0.source) }
                return roots.isEmpty ? [nodeID] : Set(roots)
            case .proxy:
                let roots = (incomingSupport[nodeID] ?? [])
                    .filter {
                        $0.relationship == .routedThrough
                            || $0.relationship == .configuredGateway
                    }
                    .flatMap { rootIDs(for: $0.source) }
                return roots.isEmpty ? [nodeID] : Set(roots)
            case .launcher, .destination, .service:
                return []
            }
        }

        let rootNodesByBundleID: [String: Set<TrafficGraphNodeID>] = complete.nodes.reduce(into: [:]) {
            result, node in
            guard node.kind == .app || node.kind == .agent else { return }
            let bundleIDs = Set(node.filter.bundleIDs)
                .union(node.filter.bundleID.map { [$0] } ?? [])
            for bundleID in bundleIDs where !bundleID.isEmpty {
                result[bundleID.lowercased(), default: []].insert(node.id)
            }
        }

        func roots(for edge: TrafficGraphEdge) -> Set<TrafficGraphNodeID> {
            if edge.relationship == .observed {
                let memberRoots = edge.members.reduce(into: Set<TrafficGraphNodeID>()) { result, member in
                    let identity = member.filter.agentParent ?? member.filter.bundleID
                    guard let identity else { return }
                    result.formUnion(rootNodesByBundleID[identity.lowercased()] ?? [])
                }
                if !memberRoots.isEmpty { return memberRoots }
            }
            let sourceRoots = rootIDs(for: edge.source)
            return sourceRoots.isEmpty ? rootIDs(for: edge.target) : sourceRoots
        }

        var selectedNodeIDs: Set<TrafficGraphNodeID> = []
        var selectedEdgeIDs: Set<TrafficGraphEdgeID> = []
        var selectedRoots: Set<TrafficGraphNodeID> = []
        var selectedTools: Set<TrafficGraphNodeID> = []
        var selectedDestinations: Set<TrafficGraphNodeID> = []
        var selectedRelays: Set<TrafficGraphNodeID> = []

        func classified(_ ids: Set<TrafficGraphNodeID>) -> (
            roots: Set<TrafficGraphNodeID>,
            tools: Set<TrafficGraphNodeID>,
            destinations: Set<TrafficGraphNodeID>,
            relays: Set<TrafficGraphNodeID>
        ) {
            var roots: Set<TrafficGraphNodeID> = []
            var tools: Set<TrafficGraphNodeID> = []
            var destinations: Set<TrafficGraphNodeID> = []
            var relays: Set<TrafficGraphNodeID> = []
            for id in ids {
                guard let node = nodesByID[id] else { continue }
                switch node.kind {
                case .app, .agent: roots.insert(id)
                case .tool, .mcp: tools.insert(id)
                case .destination, .service: destinations.insert(id)
                case .proxy: relays.insert(id)
                case .launcher: break
                }
            }
            return (roots, tools, destinations, relays)
        }

        func relayIDs(
            for edge: TrafficGraphEdge,
            endpointKinds: (
                roots: Set<TrafficGraphNodeID>,
                tools: Set<TrafficGraphNodeID>,
                destinations: Set<TrafficGraphNodeID>,
                relays: Set<TrafficGraphNodeID>
            )
        ) -> Set<TrafficGraphNodeID> {
            var relays = endpointKinds.relays
            let endpoints: Set<TrafficGraphNodeID> = [edge.source, edge.target]
            let roleEndpoints = endpoints.filter { id in
                nodesByID[id]?.roleEvidence.contains(where: {
                    $0.relationship == .routedThrough || $0.relationship == .configuredGateway
                }) == true
            }
            if edge.relationship == .routedThrough || edge.relationship == .configuredGateway {
                relays.formUnion(roleEndpoints)
            } else if edge.relationship == .observed,
                      !roots(for: edge).isSubset(of: endpointKinds.roots) {
                relays.formUnion(roleEndpoints)
            }
            return relays
        }

        func rootsToAdmit(
            for edge: TrafficGraphEdge,
            limit: Int
        ) -> Set<TrafficGraphNodeID> {
            let kinds = classified([edge.source, edge.target])
            let semanticRoots = roots(for: edge).union(kinds.roots)
            let existing = semanticRoots.intersection(selectedRoots)
            var available = max(0, max(0, limit) - selectedRoots.count)
            let required = kinds.roots.subtracting(selectedRoots).sorted()
            let admittedRequired = Set(required.prefix(available))
            available -= admittedRequired.count
            let optional = semanticRoots
                .subtracting(selectedRoots)
                .subtracting(admittedRequired)
                .sorted()
            return existing.union(admittedRequired).union(optional.prefix(available))
        }

        func canSelect(
            _ edge: TrafficGraphEdge,
            rootLimit: Int? = nil,
            destinationLimit: Int? = nil
        ) -> Bool {
            let endpoints: Set<TrafficGraphNodeID> = [edge.source, edge.target]
            let kinds = classified(endpoints)
            let semanticRoots = roots(for: edge).union(kinds.roots)
            let admittedRoots = rootsToAdmit(
                for: edge,
                limit: rootLimit ?? limits.roots
            )
            let rootsAfterSelection = selectedRoots.union(admittedRoots)
            return (semanticRoots.isEmpty || !admittedRoots.isEmpty)
                && (kinds.roots.isEmpty || semanticRoots.isSubset(of: rootsAfterSelection))
                && selectedTools.union(kinds.tools).count <= max(0, limits.tools)
                && selectedDestinations.union(kinds.destinations).count
                    <= max(0, destinationLimit ?? limits.destinations)
                && selectedRelays.union(relayIDs(for: edge, endpointKinds: kinds)).count
                    <= max(0, limits.relays)
        }

        func select(_ edge: TrafficGraphEdge, rootLimit: Int? = nil) {
            selectedEdgeIDs.insert(edge.id)
            selectedNodeIDs.insert(edge.source)
            selectedNodeIDs.insert(edge.target)
            let kinds = classified([edge.source, edge.target])
            selectedRoots.formUnion(rootsToAdmit(for: edge, limit: rootLimit ?? limits.roots))
            selectedTools.formUnion(kinds.tools)
            selectedDestinations.formUnion(kinds.destinations)
            selectedRelays.formUnion(relayIDs(for: edge, endpointKinds: kinds))
        }

        let rankedBlocked = complete.edges
            .filter { $0.relationship == .blocked }
            .sorted {
                let left = $0.enforcement?.count ?? 0
                let right = $1.enforcement?.count ?? 0
                return left == right ? $0.id < $1.id : left > right
            }
        let blockedReserve = limits.blockedDestinationReserve ?? limits.destinations
        var blockedCount = 0
        for edge in rankedBlocked
        where blockedCount < max(0, limits.blockedEdges) {
            guard canSelect(
                edge,
                rootLimit: limits.blockedRootReserve,
                destinationLimit: blockedReserve
            ) else { continue }
            select(edge, rootLimit: limits.blockedRootReserve)
            blockedCount += 1
        }

        let rankedObserved = complete.edges
            .filter { $0.relationship == .observed }
            .sorted {
                if $0.counters.total != $1.counters.total {
                    return $0.counters.total > $1.counters.total
                }
                return $0.id < $1.id
            }
        var representedRoots = selectedRoots
        var observedCount = 0
        for edge in rankedObserved {
            let edgeRoots = roots(for: edge)
            guard !edgeRoots.isSubset(of: representedRoots),
                  observedCount < max(0, limits.observedEdges),
                  canSelect(edge) else { continue }
            select(edge)
            representedRoots.formUnion(selectedRoots)
            observedCount += 1
        }
        for edge in rankedObserved
        where observedCount < max(0, limits.observedEdges) {
            guard !selectedEdgeIDs.contains(edge.id), canSelect(edge) else { continue }
            select(edge)
            observedCount += 1
        }

        for edge in rankedBlocked
        where blockedCount < max(0, limits.blockedEdges) {
            guard !selectedEdgeIDs.contains(edge.id), canSelect(edge) else { continue }
            select(edge)
            blockedCount += 1
        }

        for edge in supportEdges
        where edge.relationship == .configuredGateway
            && !selectedEdgeIDs.contains(edge.id) {
            guard canSelect(edge) else { continue }
            select(edge)
        }
        for node in complete.nodes
        where !node.roleEvidence.isEmpty && !selectedNodeIDs.contains(node.id) {
            let roots = rootIDs(for: node.id)
            let available = max(0, max(0, limits.roots) - selectedRoots.count)
            let admitted = roots.intersection(selectedRoots).union(
                roots.subtracting(selectedRoots).sorted().prefix(available)
            )
            guard roots.isEmpty || !admitted.isEmpty else { continue }
            selectedNodeIDs.insert(node.id)
            selectedRoots.formUnion(admitted)
        }

        var selectedLaunchers: Set<TrafficGraphNodeID> = []
        var changed = true
        while changed {
            changed = false
            for edge in supportEdges where !selectedEdgeIDs.contains(edge.id) {
                let required: Bool
                switch edge.relationship {
                case .runs, .routedThrough:
                    required = selectedNodeIDs.contains(edge.target)
                case .configuredGateway:
                    required = selectedNodeIDs.contains(edge.source)
                        || selectedNodeIDs.contains(edge.target)
                case .launched:
                    required = selectedNodeIDs.contains(edge.target)
                case .invoked:
                    required = selectedNodeIDs.contains(edge.source)
                        && selectedNodeIDs.contains(edge.target)
                case .observed, .blocked:
                    required = false
                }
                guard required else { continue }
                if edge.relationship == .launched {
                    guard selectedLaunchers.contains(edge.source)
                        || selectedLaunchers.count < max(0, limits.launchers)
                    else { continue }
                }
                guard canSelect(edge) else { continue }
                select(edge)
                if edge.relationship == .launched { selectedLaunchers.insert(edge.source) }
                changed = true
            }
        }

        let projectedEdges = complete.edges.filter { selectedEdgeIDs.contains($0.id) }
        var sourceCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        var destinationCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        var destinationMembers: [TrafficGraphNodeID: [String: TrafficGraphMember]] = [:]
        for edge in projectedEdges where edge.relationship == .observed {
            sourceCounters[edge.source, default: FlowCounters()] += edge.counters
            destinationCounters[edge.target, default: FlowCounters()] += edge.counters
            for member in edge.members {
                let identity = member.filter.agentParent ?? member.filter.bundleID
                if let identity {
                    for rootID in rootNodesByBundleID[identity.lowercased()] ?? []
                    where selectedRoots.contains(rootID) && rootID != edge.source {
                        sourceCounters[rootID, default: FlowCounters()] += member.counters
                    }
                }
                if var existing = destinationMembers[edge.target]?[member.id] {
                    existing.counters += member.counters
                    destinationMembers[edge.target]?[member.id] = existing
                } else {
                    destinationMembers[edge.target, default: [:]][member.id] = member
                }
            }
        }
        let projectedNodes = complete.nodes.filter { selectedNodeIDs.contains($0.id) }.map { node in
            var projectedNode = node
            if node.kind == .destination || node.kind == .service {
                projectedNode.counters = destinationCounters[node.id] ?? FlowCounters()
                projectedNode.members = (destinationMembers[node.id] ?? [:]).values.sorted { $0.id < $1.id }
            } else if limits.recalculateSourceCounters,
                      node.kind != .launcher {
                projectedNode.counters = sourceCounters[node.id] ?? FlowCounters()
            }
            return projectedNode
        }
        var projected = TrafficGraphSnapshot(
            nodes: projectedNodes,
            edges: projectedEdges,
            total: complete.total,
            hidden: .none
        )
        projected.hidden = .exactDifference(complete: complete, projected: projected)
        return projected
    }
}

enum TrafficGraphMapGrouping {
    static let groupThreshold = 12

    private struct AlphabetBucket: Hashable {
        var id: String
        var title: String
    }

    static func project(
        _ complete: TrafficGraphSnapshot,
        expandedGroupIDs: Set<TrafficGraphNodeID> = [],
        expandedEdgeGroupIDs: Set<TrafficGraphEdgeID> = []
    ) -> TrafficGraphSnapshot {
        let nodesByKind = Dictionary(grouping: complete.nodes, by: { $0.kind.rawValue })
        var projectedNodes: [TrafficGraphNode] = []
        var representativeByID: [TrafficGraphNodeID: TrafficGraphNodeID] = [:]

        for kindKey in nodesByKind.keys.sorted() {
            guard let kindNodes = nodesByKind[kindKey]?.sorted(by: { $0.id < $1.id }) else { continue }
            guard kindNodes.count > groupThreshold else {
                projectedNodes.append(contentsOf: kindNodes)
                for node in kindNodes { representativeByID[node.id] = node.id }
                continue
            }

            let buckets = Dictionary(grouping: kindNodes, by: { alphabetBucket(for: $0.title) })
            for bucket in buckets.keys.sorted(by: { $0.id < $1.id }) {
                guard let members = buckets[bucket]?.sorted(by: { $0.id < $1.id }),
                      let first = members.first else { continue }
                let groupID = TrafficGraphNodeID(
                    rawValue: stableID(["map-group", first.kind.rawValue, bucket.id])
                )
                if members.count == 1 || expandedGroupIDs.contains(groupID) {
                    projectedNodes.append(contentsOf: members)
                    for node in members { representativeByID[node.id] = node.id }
                    continue
                }

                let counters = members.reduce(into: FlowCounters()) { $0 += $1.counters }
                let group = TrafficGraphNode(
                    id: groupID,
                    kind: first.kind,
                    title: "\(kindTitle(first.kind)) \(bucket.title)",
                    detail: L("%lld exact items", Int64(members.count)),
                    appPath: "",
                    filter: .none,
                    counters: counters,
                    isFilterExact: false,
                    collapsedNodeIDs: members.map(\.id)
                )
                projectedNodes.append(group)
                for node in members { representativeByID[node.id] = groupID }
            }
        }

        let edgeGroups = Dictionary(grouping: complete.edges) { edge in
            let source = representativeByID[edge.source] ?? edge.source
            let target = representativeByID[edge.target] ?? edge.target
            let groupID = TrafficGraphEdgeID(rawValue: stableID([
                "map-edge",
                source.rawValue,
                edge.relationship.rawValue,
                target.rawValue,
            ]))
            if expandedEdgeGroupIDs.contains(groupID) {
                return stableID(["map-exact-edge", edge.id.rawValue])
            }
            return groupID.rawValue
        }

        let projectedEdges = edgeGroups.keys.sorted().compactMap { key -> TrafficGraphEdge? in
            guard let edges = edgeGroups[key]?.sorted(by: { $0.id < $1.id }),
                  let first = edges.first else { return nil }
            let source = representativeByID[first.source] ?? first.source
            let target = representativeByID[first.target] ?? first.target
            let groupID = TrafficGraphEdgeID(rawValue: stableID([
                "map-edge",
                source.rawValue,
                first.relationship.rawValue,
                target.rawValue,
            ]))
            if edges.count == 1, expandedEdgeGroupIDs.contains(groupID) {
                var exact = first
                exact.source = source
                exact.target = target
                exact.collapsedEdgeIDs = []
                return exact
            }
            if edges.count == 1, source == first.source, target == first.target {
                return first
            }

            let counters = edges.reduce(into: FlowCounters()) { $0 += $1.counters }
            var trafficVolume: FlowCounters?
            var membersByID: [String: TrafficGraphMember] = [:]
            for edge in edges {
                if let volume = edge.trafficVolume {
                    if trafficVolume == nil { trafficVolume = FlowCounters() }
                    trafficVolume? += volume
                }
                for member in edge.members {
                    if var existing = membersByID[member.id] {
                        existing.counters += member.counters
                        membersByID[member.id] = existing
                    } else {
                        membersByID[member.id] = member
                    }
                }
            }
            let enforcementValues = edges.compactMap(\.enforcement)
            let enforcement = enforcementValues.isEmpty ? nil : TrafficGraphEnforcement(
                count: enforcementValues.reduce(Int64(0)) { $0 + $1.count },
                category: Set(enforcementValues.map(\.category)).sorted().joined(separator: ", "),
                source: Set(enforcementValues.map(\.source)).sorted().joined(separator: ", "),
                detail: Set(enforcementValues.map(\.detail)).sorted().joined(separator: ", ")
            )
            let filter = edges.dropFirst().allSatisfy { $0.filter == first.filter }
                ? first.filter
                : .none
            let configuration = edges.dropFirst().allSatisfy { $0.configuration == first.configuration }
                ? first.configuration
                : nil
            return TrafficGraphEdge(
                id: groupID,
                source: source,
                target: target,
                counters: counters,
                filter: filter,
                relationship: first.relationship,
                members: membersByID.values.sorted { $0.id < $1.id },
                enforcement: enforcement,
                configuration: configuration,
                trafficVolume: trafficVolume,
                collapsedEdgeIDs: edges.flatMap { $0.representedEdgeIDs }.sorted()
            )
        }

        return TrafficGraphSnapshot(
            nodes: projectedNodes.sorted { $0.id < $1.id },
            edges: projectedEdges,
            total: complete.total,
            hidden: .none
        )
    }

    private static func alphabetBucket(for title: String) -> AlphabetBucket {
        let folded = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard let scalar = folded.lowercased().unicodeScalars.first else {
            return AlphabetBucket(id: "other", title: "#")
        }
        switch scalar.value {
        case 97...100: return AlphabetBucket(id: "a-d", title: "A–D")
        case 101...104: return AlphabetBucket(id: "e-h", title: "E–H")
        case 105...108: return AlphabetBucket(id: "i-l", title: "I–L")
        case 109...112: return AlphabetBucket(id: "m-p", title: "M–P")
        case 113...116: return AlphabetBucket(id: "q-t", title: "Q–T")
        case 117...122: return AlphabetBucket(id: "u-z", title: "U–Z")
        case 48...57: return AlphabetBucket(id: "0-9", title: "0–9")
        default: return AlphabetBucket(id: "other", title: "#")
        }
    }

    private static func kindTitle(_ kind: TrafficGraphNode.Kind) -> String {
        switch kind {
        case .app: return L("Applications")
        case .agent: return L("Agents")
        case .destination: return L("Destinations")
        case .service: return L("Services")
        case .tool: return L("Tools")
        case .mcp: return L("MCP services")
        case .launcher: return L("Launchers")
        case .proxy: return L("Proxies")
        }
    }

    private static func stableID(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum TrafficGraphSelection {
    static func isRelated(
        _ edge: TrafficGraphEdge,
        selectedNode: TrafficGraphNodeID?,
        selectedEdge: TrafficGraphEdgeID?
    ) -> Bool {
        if selectedNode == nil, selectedEdge == nil { return true }
        return selectedEdge == edge.id || selectedNode == edge.source || selectedNode == edge.target
    }

    static func emphasizes(
        _ edge: TrafficGraphEdge,
        selectedNode: TrafficGraphNodeID?,
        selectedEdge: TrafficGraphEdgeID?,
        hoveredEdge: TrafficGraphEdgeID?
    ) -> Bool {
        if selectedEdge == edge.id { return true }
        return hoveredEdge == edge.id && isRelated(
            edge,
            selectedNode: selectedNode,
            selectedEdge: selectedEdge
        )
    }
}

struct TrafficGraphLimits: Equatable, Sendable {
    var maxApps: Int
    var maxDestinations: Int
    var maxEdges: Int
    var maxBlockedEdges: Int = 12
    var maxRelays: Int = 6

    static let standard = TrafficGraphLimits(maxApps: 8, maxDestinations: 13, maxEdges: 28,
                                              maxBlockedEdges: 12, maxRelays: 8)
    static let unbounded = TrafficGraphLimits(maxApps: .max, maxDestinations: .max, maxEdges: .max,
                                               maxBlockedEdges: .max, maxRelays: .max)
}

enum VisualizationDomainFamily {
    /// These suffixes assign independent hostnames to unrelated customers. Keep one tenant label instead of
    /// collapsing every customer into the hosting provider's shared suffix.
    private static let tenantSuffixes: Set<String> = [
        "appspot.com", "azurewebsites.net", "firebaseapp.com", "github.io", "herokuapp.com",
        "netlify.app", "pages.dev", "vercel.app", "web.app"
    ]

    static func group(_ host: String) -> String {
        let canonical = host.lowercased()
        for suffix in tenantSuffixes where canonical == suffix || canonical.hasSuffix("." + suffix) {
            let labels = canonical.split(separator: ".")
            let suffixLabels = suffix.split(separator: ".").count
            guard labels.count > suffixLabels else { return canonical }
            return labels.suffix(suffixLabels + 1).joined(separator: ".")
        }
        return AnomalyEngine.registrableDomain(canonical)
    }
}

struct CanonicalVisualizationDestination {
    var domain: String? = nil
    var address: String? = nil
}

enum VisualizationDestinationCanonicalizer {
    static func parse(_ value: String) -> CanonicalVisualizationDestination {
        guard let canonical = HostCanonicalizer.host(value) else {
            let fallback = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return fallback.isEmpty
                ? CanonicalVisualizationDestination()
                : CanonicalVisualizationDestination(domain: fallback)
        }
        if let address = HostCanonicalizer.address(canonical) {
            return CanonicalVisualizationDestination(address: address)
        }
        return CanonicalVisualizationDestination(domain: canonical)
    }

    static func identity(_ value: String) -> String? {
        let exact = parse(value)
        return exact.address ?? exact.domain
    }
}

enum TrafficGraphBuilder {
    private struct AppIdentity: Hashable {
        var bundleID: String
    }

    private struct AppMetadata {
        var name: String
        var path: String
        var weight: Int64
    }

    private struct DestinationIdentity: Hashable {
        var domain: String
        var remoteIP: String
        var owner: String
        var asn: Int
    }

    private struct RelayIdentity: Hashable {
        var bundleID: String
    }

    private struct RelayMetadata {
        var name: String
        var path: String
        var weight: Int64
    }

    private struct Relationship: Hashable {
        var app: AppIdentity
        var destination: DestinationIdentity
        var relay: RelayIdentity?
    }

    private struct RouteIdentity: Hashable {
        var app: AppIdentity
        var relay: RelayIdentity
    }

    private struct BlockedIdentity: Hashable {
        var app: AppIdentity
        var destination: String
        var port: UInt16
    }

    private struct BlockedValue {
        var appName: String
        var count: Int64 = 0
        var categories: Set<String> = []
        var sources: Set<String> = []
        var details: Set<String> = []
    }

    private struct ExactMemberIdentity: Hashable {
        var app: AppIdentity
        var domain: String
        var remoteIP: String
        var protocols: String
        var channel: NetworkChannel
    }

    private struct MemberValue {
        var identity: ExactMemberIdentity
        var owner: String
        var asn: Int
        var counters = FlowCounters()
    }

    static func build<Rows: Sequence>(rows: Rows, blockedAttempts: [BlockedAttemptRow] = [],
                                      limits: TrafficGraphLimits = .standard) -> TrafficGraphSnapshot
    where Rows.Element == BreakdownRow {
        var relationships: [Relationship: FlowCounters] = [:]
        var relationshipMembers: [Relationship: [ExactMemberIdentity: MemberValue]] = [:]
        var appMetadata: [AppIdentity: AppMetadata] = [:]
        var relayMetadata: [RelayIdentity: RelayMetadata] = [:]
        var blocked: [BlockedIdentity: BlockedValue] = [:]
        var total = FlowCounters()

        for row in rows where !row.counters.isEmpty {
            let app = AppIdentity(bundleID: row.bundleID)
            let current = appMetadata[app]
            let candidate = AppMetadata(name: row.appName, path: row.appPath, weight: row.counters.total)
            if current == nil || prefersMetadata(candidate, over: current!) {
                appMetadata[app] = candidate
            }
            let groupedDomain = row.domain.isEmpty ? "" : VisualizationDomainFamily.group(row.domain)
            let destination = DestinationIdentity(
                domain: groupedDomain,
                remoteIP: groupedDomain.isEmpty ? row.remoteIP : "",
                owner: "",
                asn: 0
            )
            let relay = row.routeProxyBundleID.isEmpty ? nil : RelayIdentity(
                bundleID: row.routeProxyBundleID
            )
            if let relay {
                let current = relayMetadata[relay]
                let candidate = RelayMetadata(
                    name: row.routeProxyName,
                    path: row.routeProxyPath,
                    weight: row.counters.total
                )
                if current == nil || prefersMetadata(candidate, over: current!) {
                    relayMetadata[relay] = candidate
                }
            }
            let relationship = Relationship(app: app, destination: destination, relay: relay)
            relationships[relationship, default: FlowCounters()] += row.counters
            let memberIdentity = ExactMemberIdentity(app: app, domain: row.domain, remoteIP: row.remoteIP,
                                                     protocols: row.protocols, channel: row.channel)
            var member = relationshipMembers[relationship]?[memberIdentity]
                ?? MemberValue(identity: memberIdentity, owner: row.owner, asn: row.asn)
            member.counters += row.counters
            relationshipMembers[relationship, default: [:]][memberIdentity] = member
            total += row.counters
        }
        for attempt in blockedAttempts where attempt.count > 0 && !attempt.destination.isEmpty {
            let app = AppIdentity(bundleID: attempt.bundleID.isEmpty ? attempt.agentKey : attempt.bundleID)
            guard !app.bundleID.isEmpty else { continue }
            guard let destination = VisualizationDestinationCanonicalizer.identity(attempt.destination) else { continue }
            let identity = BlockedIdentity(app: app, destination: destination, port: attempt.port)
            var value = blocked[identity] ?? BlockedValue(appName: attempt.appName)
            value.count += attempt.count
            if !attempt.category.isEmpty { value.categories.insert(attempt.category) }
            if !attempt.source.isEmpty { value.sources.insert(attempt.source) }
            if !attempt.detail.isEmpty { value.details.insert(attempt.detail) }
            blocked[identity] = value
            if appMetadata[app] == nil {
                appMetadata[app] = AppMetadata(
                    name: attempt.appName.isEmpty ? attempt.agentName : attempt.appName,
                    path: "",
                    weight: 0
                )
            }
        }

        var appTotals: [AppIdentity: FlowCounters] = [:]
        var destinationTotals: [DestinationIdentity: FlowCounters] = [:]
        for (relationship, counters) in relationships {
            appTotals[relationship.app, default: FlowCounters()] += counters
            destinationTotals[relationship.destination, default: FlowCounters()] += counters
        }

        let rankedRelationships = relationships.sorted { left, right in
            if left.value.total != right.value.total { return left.value.total > right.value.total }
            return relationshipID(left.key).rawValue < relationshipID(right.key).rawValue
        }
        let rankedBlocked = blocked.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return blockedID($0.key) < blockedID($1.key)
        }
        let rankedApps = appTotals.sorted { left, right in
            if left.value.total != right.value.total { return left.value.total > right.value.total }
            return appID(left.key) < appID(right.key)
        }
        let rankedObservedApps = rankedApps.prefix(max(0, limits.maxApps)).map(\.key)
        let observedAppCandidates = Set(rankedObservedApps)
        var visibleDestinations: Set<DestinationIdentity> = []
        var selectedBlocked: [(key: BlockedIdentity, value: BlockedValue)] = []
        let blockedDestinationReserve = min(
            5,
            max(0, limits.maxBlockedEdges),
            max(0, limits.maxDestinations) / 2
        )
        for entry in rankedBlocked where observedAppCandidates.contains(entry.key.app) {
            let destination = blockedDestination(entry.key)
            let addsDestination = !visibleDestinations.contains(destination)
            guard (!addsDestination || visibleDestinations.count < blockedDestinationReserve),
                  selectedBlocked.count < max(0, limits.maxBlockedEdges) else { continue }
            selectedBlocked.append(entry)
            visibleDestinations.insert(destination)
        }
        var relayCandidates: Set<RelayIdentity> = []
        var selectedRelationships: [(key: Relationship, value: FlowCounters)] = []
        var selectedRelationshipKeys: Set<Relationship> = []
        // Reports ranks whole applications, so admit the same aggregate leaders and give each one a representative
        // relationship before spending the remaining edge and destination capacity on additional busy relationships.
        // Enforcement keeps its existing reserved destination slice so traffic cannot crowd severe evidence out.
        if let representatives = representativeRelationships(
            for: rankedObservedApps,
            from: rankedRelationships,
            existingDestinations: visibleDestinations,
            limits: limits
        ) {
            for relationship in representatives {
                selectedRelationships.append(relationship)
                selectedRelationshipKeys.insert(relationship.key)
                visibleDestinations.insert(relationship.key.destination)
                if let relay = relationship.key.relay { relayCandidates.insert(relay) }
            }
        } else {
            for app in rankedObservedApps {
                for relationship in rankedRelationships where relationship.key.app == app {
                    let addsDestination = !visibleDestinations.contains(relationship.key.destination)
                    let addsRelay = relationship.key.relay.map { !relayCandidates.contains($0) } ?? false
                    guard (!addsDestination || visibleDestinations.count < max(0, limits.maxDestinations)),
                          (!addsRelay || relayCandidates.count < max(0, limits.maxRelays)),
                          selectedRelationships.count < max(0, limits.maxEdges) else { continue }
                    selectedRelationships.append(relationship)
                    selectedRelationshipKeys.insert(relationship.key)
                    visibleDestinations.insert(relationship.key.destination)
                    if let relay = relationship.key.relay { relayCandidates.insert(relay) }
                    break
                }
            }
        }
        for relationship in rankedRelationships where !selectedRelationshipKeys.contains(relationship.key) {
            let addsDestination = !visibleDestinations.contains(relationship.key.destination)
            let addsRelay = relationship.key.relay.map { !relayCandidates.contains($0) } ?? false
            guard observedAppCandidates.contains(relationship.key.app),
                  (!addsRelay || relayCandidates.count < max(0, limits.maxRelays)),
                  (!addsDestination || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedRelationships.count < max(0, limits.maxEdges) else { continue }
            selectedRelationships.append(relationship)
            selectedRelationshipKeys.insert(relationship.key)
            visibleDestinations.insert(relationship.key.destination)
            if let relay = relationship.key.relay { relayCandidates.insert(relay) }
        }
        var visibleApps = Set(selectedRelationships.map { $0.key.app })
        let visibleRelays = Set(selectedRelationships.compactMap { $0.key.relay })
        visibleApps.formUnion(selectedBlocked.map { $0.key.app })
        let alreadyBlocked = Set(selectedBlocked.map(\.key))
        for entry in rankedBlocked where !alreadyBlocked.contains(entry.key) {
            let destination = blockedDestination(entry.key)
            let addsApp = !visibleApps.contains(entry.key.app)
            let addsDestination = !visibleDestinations.contains(destination)
            guard (!addsApp || visibleApps.count < max(0, limits.maxApps)),
                  (!addsDestination || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedBlocked.count < max(0, limits.maxBlockedEdges) else { continue }
            selectedBlocked.append(entry)
            visibleApps.insert(entry.key.app)
            visibleDestinations.insert(destination)
        }
        var edges = selectedRelationships.map { relationship, counters in
            let members = makeMembers(relationshipMembers[relationship]?.values ?? [:].values)
            return TrafficGraphEdge(
                id: relationshipID(relationship),
                source: relationship.relay.map(relayID) ?? appID(relationship.app),
                target: destinationID(relationship.destination),
                counters: counters,
                filter: relationshipFilter(relationship, members: members),
                members: members
            )
        }
        let visibleRoutes = Dictionary(grouping: selectedRelationships.compactMap { entry -> (RouteIdentity, FlowCounters)? in
            guard let relay = entry.key.relay else { return nil }
            return (RouteIdentity(app: entry.key.app, relay: relay), entry.value)
        }, by: \.0).mapValues { values in
            values.reduce(into: FlowCounters()) { $0 += $1.1 }
        }
        for (route, volume) in visibleRoutes {
            edges.append(TrafficGraphEdge(
                id: routeID(route), source: appID(route.app), target: relayID(route.relay),
                counters: FlowCounters(), filter: TrafficFilter(bundleID: route.app.bundleID),
                relationship: .routedThrough, trafficVolume: volume
            ))
        }
        for (identity, value) in selectedBlocked {
            let exactDestination = VisualizationDestinationCanonicalizer.parse(identity.destination)
            let destination = blockedDestination(identity)
            let target = destinationID(destination)
            visibleApps.insert(identity.app)
            visibleDestinations.insert(destination)
            edges.append(TrafficGraphEdge(
                id: blockedID(identity), source: appID(identity.app), target: target,
                counters: FlowCounters(),
                filter: TrafficFilter(
                    bundleID: identity.app.bundleID,
                    domain: exactDestination.domain,
                    remoteIP: exactDestination.address
                ),
                relationship: .blocked,
                enforcement: TrafficGraphEnforcement(
                    count: value.count,
                    category: value.categories.sorted().joined(separator: ", "),
                    source: value.sources.sorted().joined(separator: ", "),
                    detail: (["Port \(identity.port)"] + value.details.sorted()).joined(separator: ", ")
                )
            ))
        }
        edges.sort { $0.id < $1.id }

        var visibleNodeCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        var visibleDestinationMembers: [TrafficGraphNodeID: [TrafficGraphMember]] = [:]
        for edge in edges where edge.relationship == .observed {
            visibleNodeCounters[edge.source, default: FlowCounters()] += edge.counters
            visibleNodeCounters[edge.target, default: FlowCounters()] += edge.counters
            visibleDestinationMembers[edge.target, default: []] += edge.members
        }

        var nodes: [TrafficGraphNode] = []
        for app in visibleApps.sorted(by: { appID($0) < appID($1) }) {
            let id = appID(app)
            let counters = appTotals[app] ?? FlowCounters()
            let metadata = appMetadata[app] ?? AppMetadata(name: "", path: "", weight: 0)
            nodes.append(TrafficGraphNode(
                id: id,
                kind: .app,
                title: metadata.name.isEmpty ? app.bundleID : metadata.name,
                detail: app.bundleID,
                appPath: metadata.path,
                filter: TrafficFilter(bundleID: app.bundleID),
                counters: counters
            ))
        }
        for relay in visibleRelays.sorted(by: { relayID($0) < relayID($1) }) {
            let id = relayID(relay)
            let metadata = relayMetadata[relay] ?? RelayMetadata(name: "", path: "", weight: 0)
            let counters = selectedRelationships.reduce(into: FlowCounters()) { result, entry in
                if entry.key.relay == relay { result += entry.value }
            }
            nodes.append(TrafficGraphNode(
                id: id, kind: .proxy, title: metadata.name.isEmpty ? relay.bundleID : metadata.name,
                detail: L("Observed route"), appPath: metadata.path,
                filter: TrafficFilter(bundleID: relay.bundleID), counters: counters
            ))
        }
        for destination in visibleDestinations.sorted(by: { destinationID($0) < destinationID($1) }) {
            let id = destinationID(destination)
            let counters = visibleNodeCounters[id] ?? FlowCounters()
            let members = mergedMembers(visibleDestinationMembers[id] ?? [])
            nodes.append(TrafficGraphNode(
                id: id,
                kind: .destination,
                title: destinationTitle(destination),
                detail: destinationDetail(destination, memberCount: members.count),
                appPath: "",
                filter: destinationFilter(destination),
                counters: counters,
                members: members
            ))
        }
        nodes.sort { $0.id < $1.id }

        let visibleTotal = edges.filter { $0.relationship == .observed }
            .reduce(into: FlowCounters()) { $0 += $1.counters }
        let hidden = TrafficGraphHidden(
            nodeCount: max(
                0,
                Set(appTotals.keys).union(blocked.keys.map(\.app)).count
                    + Set(destinationTotals.keys).union(blocked.keys.map(blockedDestination)).count
                    - visibleApps.count - visibleDestinations.count
            ),
            edgeCount: max(
                0,
                relationships.count + blocked.count - selectedRelationships.count - selectedBlocked.count
            ),
            counters: total.subtractingFloorZero(visibleTotal)
        )
        let coalesced = TrafficGraphApplicationCoalescer.coalesce(nodes: nodes, edges: edges)
        return TrafficGraphSnapshot(
            nodes: coalesced.nodes,
            edges: coalesced.edges,
            total: total,
            hidden: hidden
        )
    }

    static func buildForPresentation<Rows: Sequence>(
        rows sourceRows: Rows,
        blockedAttempts: [BlockedAttemptRow] = [],
        mapLimits: TrafficGraphLimits = .standard,
        expandedGroupIDs: Set<TrafficGraphNodeID> = [],
        expandedEdgeGroupIDs: Set<TrafficGraphEdgeID> = []
    ) -> TrafficGraphBuild where Rows.Element == BreakdownRow {
        let rows = Array(sourceRows)
        var complete = build(rows: rows, blockedAttempts: blockedAttempts, limits: .unbounded)
        complete.hidden = .none
        guard mapLimits != .unbounded else {
            return TrafficGraphBuild(complete: complete, map: complete)
        }
        let map = mapLimits == .standard
            ? TrafficGraphMapGrouping.project(
                complete,
                expandedGroupIDs: expandedGroupIDs,
                expandedEdgeGroupIDs: expandedEdgeGroupIDs
            )
            : TrafficGraphMapProjector.project(complete, limits: mapLimits)
        return TrafficGraphBuild(complete: complete, map: map)
    }

    private struct RepresentativeResource: Hashable {
        var destination: DestinationIdentity
        var relay: RelayIdentity?
    }

    private static func representativeRelationships(
        for apps: [AppIdentity],
        from rankedRelationships: [(key: Relationship, value: FlowCounters)],
        existingDestinations: Set<DestinationIdentity>,
        limits: TrafficGraphLimits
    ) -> [(key: Relationship, value: FlowCounters)]? {
        guard apps.count <= max(0, limits.maxEdges) else { return nil }

        let appSet = Set(apps)
        var choices: [AppIdentity: [(key: Relationship, value: FlowCounters)]] = [:]
        var seen: [AppIdentity: Set<RepresentativeResource>] = [:]
        for relationship in rankedRelationships where appSet.contains(relationship.key.app) {
            let resource = RepresentativeResource(
                destination: relationship.key.destination,
                relay: relationship.key.relay
            )
            if seen[relationship.key.app, default: []].insert(resource).inserted {
                choices[relationship.key.app, default: []].append(relationship)
            }
        }

        struct SearchState: Hashable {
            var index: Int
            var destinations: Set<DestinationIdentity>
            var relays: Set<RelayIdentity>
        }
        var failedStates: Set<SearchState> = []
        func search(
            index: Int,
            destinations: Set<DestinationIdentity>,
            relays: Set<RelayIdentity>
        ) -> [(key: Relationship, value: FlowCounters)]? {
            guard index < apps.count else { return [] }
            guard failedStates.insert(SearchState(
                index: index,
                destinations: destinations,
                relays: relays
            )).inserted else { return nil }

            for relationship in choices[apps[index]] ?? [] {
                var nextDestinations = destinations
                nextDestinations.insert(relationship.key.destination)
                guard nextDestinations.count <= max(0, limits.maxDestinations) else { continue }

                var nextRelays = relays
                if let relay = relationship.key.relay { nextRelays.insert(relay) }
                guard nextRelays.count <= max(0, limits.maxRelays) else { continue }

                if let tail = search(
                    index: index + 1,
                    destinations: nextDestinations,
                    relays: nextRelays
                ) {
                    return [relationship] + tail
                }
            }
            return nil
        }

        return search(index: 0, destinations: existingDestinations, relays: [])
    }

    private static func ranked<Key: Hashable>(_ totals: [Key: FlowCounters]) -> [(Key, FlowCounters)] {
        totals.sorted { left, right in
            if left.value.total != right.value.total { return left.value.total > right.value.total }
            return String(reflecting: left.key) < String(reflecting: right.key)
        }
    }

    private static func appID(_ app: AppIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "app:" + component(app.bundleID))
    }

    private static func relayID(_ relay: RelayIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "proxy:" + component(relay.bundleID))
    }

    private static func routeID(_ route: RouteIdentity) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: appID(route.app).rawValue + "→route→" + relayID(route.relay).rawValue)
    }

    private static func blockedDestination(_ blocked: BlockedIdentity) -> DestinationIdentity {
        let exact = VisualizationDestinationCanonicalizer.parse(blocked.destination)
        return DestinationIdentity(
            domain: exact.domain.map(VisualizationDomainFamily.group) ?? "",
            remoteIP: exact.address ?? "",
            owner: "",
            asn: 0
        )
    }

    private static func blockedID(_ blocked: BlockedIdentity) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(
            rawValue: appID(blocked.app).rawValue + "→blocked→" + component(blocked.destination)
                + "→port→\(blocked.port)"
        )
    }

    private static func destinationID(_ destination: DestinationIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "destination:" + component(destination.domain) + component(destination.remoteIP))
    }

    private static func relationshipID(_ relationship: Relationship) -> TrafficGraphEdgeID {
        let source = relationship.relay.map(relayID) ?? appID(relationship.app)
        let appScope = relationship.relay == nil ? "" : "→for→" + appID(relationship.app).rawValue
        return TrafficGraphEdgeID(
            rawValue: source.rawValue + appScope + "→" + destinationID(relationship.destination).rawValue
        )
    }

    private static func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    private static func prefersMetadata(_ candidate: AppMetadata, over current: AppMetadata) -> Bool {
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

    private static func relationshipFilter(_ relationship: Relationship,
                                           members: [TrafficGraphMember]) -> TrafficFilter {
        if members.count == 1 { return members[0].filter }
        if !relationship.destination.domain.isEmpty {
            return TrafficFilter(bundleID: relationship.app.bundleID,
                                 domainSuffix: relationship.destination.domain)
        }
        return TrafficFilter(bundleID: relationship.app.bundleID,
                             remoteIP: relationship.destination.remoteIP)
    }

    private static func destinationFilter(_ destination: DestinationIdentity) -> TrafficFilter {
        if !destination.domain.isEmpty { return TrafficFilter(domainSuffix: destination.domain) }
        return TrafficFilter(remoteIP: destination.remoteIP)
    }

    private static func makeMembers<S: Sequence>(_ values: S) -> [TrafficGraphMember]
    where S.Element == MemberValue {
        values.map { value in
            let destination = DestinationIdentity(domain: value.identity.domain, remoteIP: value.identity.remoteIP,
                                                  owner: value.owner, asn: value.asn)
            return TrafficGraphMember(
                id: component(value.identity.app.bundleID) + component(value.identity.domain)
                    + component(value.identity.remoteIP) + component(value.identity.protocols)
                    + component(value.identity.channel.rawValue),
                title: destinationTitle(destination), detail: destinationDetail(destination, memberCount: 1),
                filter: TrafficFilter(bundleID: value.identity.app.bundleID,
                                      domain: value.identity.domain.isEmpty ? nil : value.identity.domain,
                                      remoteIP: value.identity.remoteIP.isEmpty ? nil : value.identity.remoteIP,
                                      appProtocol: value.identity.protocols.isEmpty ? nil : value.identity.protocols,
                                      channel: value.identity.channel),
                counters: value.counters, protocols: value.identity.protocols, channel: value.identity.channel
            )
        }.sorted { $0.id < $1.id }
    }

    private static func mergedMembers(_ members: [TrafficGraphMember]) -> [TrafficGraphMember] {
        Dictionary(grouping: members, by: \.id).values.map { duplicates in
            var member = duplicates[0]
            member.counters = duplicates.dropFirst().reduce(member.counters) { counters, duplicate in
                var result = counters
                result += duplicate.counters
                return result
            }
            return member
        }.sorted { $0.id < $1.id }
    }

    private static func destinationTitle(_ destination: DestinationIdentity) -> String {
        if !destination.domain.isEmpty { return destination.domain }
        if !destination.owner.isEmpty { return destination.owner }
        return destination.remoteIP.isEmpty ? L("Unknown destination") : destination.remoteIP
    }

    private static func destinationDetail(_ destination: DestinationIdentity, memberCount: Int) -> String {
        if !destination.domain.isEmpty {
            return memberCount > 1 ? L("%lld exact destinations", Int64(memberCount)) : destination.remoteIP
        }
        if !destination.owner.isEmpty, destination.asn > 0 { return "AS\(destination.asn) · \(destination.remoteIP)" }
        return ""
    }
}
