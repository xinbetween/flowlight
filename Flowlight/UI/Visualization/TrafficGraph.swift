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
    case worksFor
    case invoked
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

struct TrafficGraphLimits: Equatable, Sendable {
    var maxApps: Int
    var maxDestinations: Int
    var maxEdges: Int

    static let standard = TrafficGraphLimits(maxApps: 8, maxDestinations: 10, maxEdges: 28)
    static let unbounded = TrafficGraphLimits(maxApps: .max, maxDestinations: .max, maxEdges: .max)
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

    private struct Relationship: Hashable {
        var app: AppIdentity
        var destination: DestinationIdentity
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

    static func build<Rows: Sequence>(rows: Rows, limits: TrafficGraphLimits = .standard) -> TrafficGraphSnapshot
    where Rows.Element == BreakdownRow {
        var relationships: [Relationship: FlowCounters] = [:]
        var relationshipMembers: [Relationship: [ExactMemberIdentity: MemberValue]] = [:]
        var appMetadata: [AppIdentity: AppMetadata] = [:]
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
            let relationship = Relationship(app: app, destination: destination)
            relationships[relationship, default: FlowCounters()] += row.counters
            let memberIdentity = ExactMemberIdentity(app: app, domain: row.domain, remoteIP: row.remoteIP,
                                                     protocols: row.protocols, channel: row.channel)
            var member = relationshipMembers[relationship]?[memberIdentity]
                ?? MemberValue(identity: memberIdentity, owner: row.owner, asn: row.asn)
            member.counters += row.counters
            relationshipMembers[relationship, default: [:]][memberIdentity] = member
            total += row.counters
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
        var visibleApps: Set<AppIdentity> = []
        var visibleDestinations: Set<DestinationIdentity> = []
        var selectedRelationships: [(key: Relationship, value: FlowCounters)] = []
        for relationship in rankedRelationships {
            let addsApp = !visibleApps.contains(relationship.key.app)
            let addsDestination = !visibleDestinations.contains(relationship.key.destination)
            guard (!addsApp || visibleApps.count < max(0, limits.maxApps)),
                  (!addsDestination || visibleDestinations.count < max(0, limits.maxDestinations)),
                  selectedRelationships.count < max(0, limits.maxEdges) else { continue }
            selectedRelationships.append(relationship)
            visibleApps.insert(relationship.key.app)
            visibleDestinations.insert(relationship.key.destination)
        }
        let rankedApps = ranked(appTotals).map(\.0).filter { visibleApps.contains($0) }
        let rankedDestinations = ranked(destinationTotals).map(\.0).filter { visibleDestinations.contains($0) }

        let edges = selectedRelationships.map { relationship, counters in
            let members = makeMembers(relationshipMembers[relationship]?.values ?? [:].values)
            return TrafficGraphEdge(
                id: relationshipID(relationship),
                source: appID(relationship.app),
                target: destinationID(relationship.destination),
                counters: counters,
                filter: relationshipFilter(relationship, members: members),
                members: members
            )
        }.sorted { $0.id < $1.id }

        var visibleNodeCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        var visibleDestinationMembers: [TrafficGraphNodeID: [TrafficGraphMember]] = [:]
        for edge in edges {
            visibleNodeCounters[edge.source, default: FlowCounters()] += edge.counters
            visibleNodeCounters[edge.target, default: FlowCounters()] += edge.counters
            visibleDestinationMembers[edge.target, default: []] += edge.members
        }

        var nodes: [TrafficGraphNode] = []
        for app in rankedApps {
            let id = appID(app)
            guard let counters = visibleNodeCounters[id] else { continue }
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
        for destination in rankedDestinations {
            let id = destinationID(destination)
            guard let counters = visibleNodeCounters[id] else { continue }
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

        let visibleTotal = edges.reduce(into: FlowCounters()) { $0 += $1.counters }
        let hidden = TrafficGraphHidden(
            nodeCount: appTotals.count + destinationTotals.count - nodes.count,
            edgeCount: relationships.count - edges.count,
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

    private static func destinationID(_ destination: DestinationIdentity) -> TrafficGraphNodeID {
        TrafficGraphNodeID(rawValue: "destination:" + component(destination.domain) + component(destination.remoteIP))
    }

    private static func relationshipID(_ relationship: Relationship) -> TrafficGraphEdgeID {
        TrafficGraphEdgeID(rawValue: appID(relationship.app).rawValue + "→" + destinationID(relationship.destination).rawValue)
    }

    private static func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    private static func prefersMetadata(_ candidate: AppMetadata, over current: AppMetadata) -> Bool {
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
