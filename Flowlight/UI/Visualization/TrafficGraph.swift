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
        case destination
        case service
        case tool
    }

    var id: TrafficGraphNodeID
    var kind: Kind
    var title: String
    var detail: String
    var appPath: String
    var filter: TrafficFilter
    var counters: FlowCounters
}

struct TrafficGraphEdge: Identifiable, Sendable {
    var id: TrafficGraphEdgeID
    var source: TrafficGraphNodeID
    var target: TrafficGraphNodeID
    var counters: FlowCounters
    var filter: TrafficFilter
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

    static func build<Rows: Sequence>(rows: Rows, limits: TrafficGraphLimits = .standard) -> TrafficGraphSnapshot
    where Rows.Element == BreakdownRow {
        var relationships: [Relationship: FlowCounters] = [:]
        var appMetadata: [AppIdentity: AppMetadata] = [:]
        var total = FlowCounters()

        for row in rows where !row.counters.isEmpty {
            let app = AppIdentity(bundleID: row.bundleID)
            let current = appMetadata[app]
            if current == nil || row.counters.total > current!.weight
                || row.counters.total == current!.weight && metadata(row.appName, row.appPath) > metadata(current!.name, current!.path) {
                appMetadata[app] = AppMetadata(name: row.appName, path: row.appPath, weight: row.counters.total)
            }
            let destination = DestinationIdentity(domain: row.domain, remoteIP: row.remoteIP, owner: row.owner, asn: row.asn)
            relationships[Relationship(app: app, destination: destination), default: FlowCounters()] += row.counters
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
            TrafficGraphEdge(
                id: relationshipID(relationship),
                source: appID(relationship.app),
                target: destinationID(relationship.destination),
                counters: counters,
                filter: TrafficFilter(
                    bundleID: relationship.app.bundleID,
                    domain: relationship.destination.domain,
                    remoteIP: relationship.destination.remoteIP
                )
            )
        }.sorted { $0.id < $1.id }

        var visibleNodeCounters: [TrafficGraphNodeID: FlowCounters] = [:]
        for edge in edges {
            visibleNodeCounters[edge.source, default: FlowCounters()] += edge.counters
            visibleNodeCounters[edge.target, default: FlowCounters()] += edge.counters
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
            nodes.append(TrafficGraphNode(
                id: id,
                kind: .destination,
                title: destinationTitle(destination),
                detail: destinationDetail(destination),
                appPath: "",
                filter: TrafficFilter(domain: destination.domain, remoteIP: destination.remoteIP),
                counters: counters
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
    private static func metadata(_ name: String, _ path: String) -> String { "\(path.isEmpty ? 0 : 1)|\(name)|\(path)" }

    private static func destinationTitle(_ destination: DestinationIdentity) -> String {
        if !destination.domain.isEmpty { return destination.domain }
        if !destination.owner.isEmpty { return destination.owner }
        return destination.remoteIP.isEmpty ? L("Unknown destination") : destination.remoteIP
    }

    private static func destinationDetail(_ destination: DestinationIdentity) -> String {
        if !destination.domain.isEmpty { return destination.remoteIP }
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
