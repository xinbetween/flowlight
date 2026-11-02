import Foundation

struct TrafficGraphNodeID: Hashable, Sendable, Comparable {
    var rawValue: String

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TrafficGraphEdgeID: Hashable, Sendable, Comparable {
    var rawValue: String

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
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
}

enum TrafficGraphRelationship: String, Sendable {
    case observed
    case runs
    case launched
    case configuredGateway
    case routedThrough
    case blocked
    case invoked
}

struct TrafficGraphEnforcement: Sendable, Equatable {
    var count: Int64
    var category: String
    var source: String
    var detail: String
}

struct TrafficGraphConfiguration: Sendable, Equatable {
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

    var displayedCounters: FlowCounters { trafficVolume ?? counters }
    var isTrafficRibbon: Bool { relationship == .observed || trafficVolume != nil }
}

struct TrafficGraphHidden: Equatable, Sendable {
    var nodeCount = 0
    var edgeCount = 0
    var counters = FlowCounters()

    static let none = TrafficGraphHidden()
}

struct TrafficGraphSnapshot: Sendable {
    var nodes: [TrafficGraphNode]
    var edges: [TrafficGraphEdge]
    var total: FlowCounters
    var hidden: TrafficGraphHidden

    static let empty = TrafficGraphSnapshot(nodes: [], edges: [], total: FlowCounters(), hidden: .none)

    var visibleTotal: FlowCounters {
        edges.reduce(into: FlowCounters()) { $0 += $1.counters }
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

    static let standard = TrafficGraphLimits(maxApps: 8, maxDestinations: 10, maxEdges: 28,
                                              maxBlockedEdges: 12, maxRelays: 6)
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
                owner: groupedDomain.isEmpty ? row.owner : "",
                asn: groupedDomain.isEmpty ? row.asn : 0
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
            let identity = BlockedIdentity(app: app, destination: attempt.destination.lowercased(), port: attempt.port)
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
        var observedAppCandidates: Set<AppIdentity> = []
        var visibleDestinations: Set<DestinationIdentity> = []
        var relayCandidates: Set<RelayIdentity> = []
        // Pick source applications from byte-bearing relationships first, so low-volume enforcement evidence cannot
        // evict a busy app. Reserve a small destination slice for blocked evidence on those selected apps, then fill
        // the rest with the busiest traffic and finally admit blocked-only apps into any capacity left over.
        for relationship in rankedRelationships {
            let addsApp = !observedAppCandidates.contains(relationship.key.app)
            guard !addsApp || observedAppCandidates.count < max(0, limits.maxApps) else { continue }
            observedAppCandidates.insert(relationship.key.app)
        }
        for relationship in rankedRelationships where observedAppCandidates.contains(relationship.key.app) {
            guard let relay = relationship.key.relay, !relayCandidates.contains(relay),
                  relayCandidates.count < max(0, limits.maxRelays) else { continue }
            relayCandidates.insert(relay)
        }
        var selectedBlocked: [(key: BlockedIdentity, value: BlockedValue)] = []
        let blockedDestinationReserve = min(max(0, limits.maxBlockedEdges), max(0, limits.maxDestinations) / 2)
        for entry in rankedBlocked where observedAppCandidates.contains(entry.key.app) {
            let destination = blockedDestination(entry.key)
            let addsDestination = !visibleDestinations.contains(destination)
            guard (!addsDestination || visibleDestinations.count < blockedDestinationReserve),
                  selectedBlocked.count < max(0, limits.maxBlockedEdges) else { continue }
            selectedBlocked.append(entry)
            visibleDestinations.insert(destination)
        }
        var selectedRelationships: [(key: Relationship, value: FlowCounters)] = []
        for relationship in rankedRelationships {
            let addsDestination = !visibleDestinations.contains(relationship.key.destination)
            guard observedAppCandidates.contains(relationship.key.app),
                  relationship.key.relay.map({ relayCandidates.contains($0) }) ?? true,
                  (!addsDestination || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedRelationships.count < max(0, limits.maxEdges) else { continue }
            selectedRelationships.append(relationship)
            visibleDestinations.insert(relationship.key.destination)
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
            let exactHost = HostCanonicalizer.host(identity.destination)
            let destination = blockedDestination(identity)
            let target = destinationID(destination)
            visibleApps.insert(identity.app)
            visibleDestinations.insert(destination)
            edges.append(TrafficGraphEdge(
                id: blockedID(identity), source: appID(identity.app), target: target,
                counters: FlowCounters(),
                filter: TrafficFilter(
                    bundleID: identity.app.bundleID,
                    domain: exactHost,
                    remoteIP: destination.remoteIP.isEmpty ? nil : destination.remoteIP
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
        for (relationship, counters) in selectedRelationships {
            visibleNodeCounters[appID(relationship.app), default: FlowCounters()] += counters
        }

        var nodes: [TrafficGraphNode] = []
        for app in visibleApps.sorted(by: { appID($0) < appID($1) }) {
            let id = appID(app)
            let counters = visibleNodeCounters[id] ?? FlowCounters()
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
                filter: TrafficFilter(), counters: counters
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
            counters: subtract(total, visibleTotal)
        )
        return TrafficGraphSnapshot(nodes: nodes, edges: edges, total: total, hidden: hidden)
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
        let exactHost = HostCanonicalizer.host(blocked.destination)
        return DestinationIdentity(
            domain: exactHost.map(VisualizationDomainFamily.group) ?? "",
            remoteIP: HostCanonicalizer.address(blocked.destination) ?? "",
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
        if candidate.weight != current.weight { return candidate.weight > current.weight }
        if candidate.name != current.name { return candidate.name < current.name }
        return candidate.path < current.path
    }

    private static func prefersMetadata(_ candidate: RelayMetadata, over current: RelayMetadata) -> Bool {
        if candidate.path.isEmpty != current.path.isEmpty { return !candidate.path.isEmpty }
        if candidate.name.isEmpty != current.name.isEmpty { return !candidate.name.isEmpty }
        if candidate.weight != current.weight { return candidate.weight > current.weight }
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

    private static func subtract(_ lhs: FlowCounters, _ rhs: FlowCounters) -> FlowCounters {
        FlowCounters(
            bytesIn: max(0, lhs.bytesIn - rhs.bytesIn),
            bytesOut: max(0, lhs.bytesOut - rhs.bytesOut),
            flows: max(0, lhs.flows - rhs.flows)
        )
    }
}
