import Foundation

/// How the Breakdown table nests its rows.
enum BreakdownGrouping: String, CaseIterable, Identifiable {
    case app, destination, ip
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .destination: return "Destination"
        case .ip: return "IP address"
        }
    }

    /// Header of the first column, e.g. "Destination › App › Host · IP".
    var columnTitle: String {
        levels.map(\.title).joined(separator: " › ")
    }

    var levels: [TreeLevel] {
        switch self {
        case .app: return [.app, .hostname, .ip]
        case .destination: return [.registrableDomain, .app, .hostAndIP]
        case .ip: return [.ip, .app]
        }
    }
}

/// One level of nesting: how rows are keyed, labelled and narrowed at that depth.
enum TreeLevel {
    case app, hostname, registrableDomain, ip, hostAndIP

    var title: String {
        switch self {
        case .app: return "App"
        case .hostname: return "Domain"
        case .registrableDomain: return "Destination"
        case .ip: return "IP"
        case .hostAndIP: return "IP"
        }
    }

    /// Word for collapsed siblings in "Show more" rows.
    var plural: String {
        switch self {
        case .app: return "apps"
        case .hostname, .registrableDomain: return "destinations"
        case .ip, .hostAndIP: return "addresses"
        }
    }

    struct Key {
        var id: String
        var title: String
        var detail: String
        var kind: TrafficNode.Kind
        var narrow: (inout TrafficFilter) -> Void
    }

    func key(for row: BreakdownRow) -> Key {
        switch self {
        case .app:
            let detail = row.parentAgentName.isEmpty ? ""
                : row.mcpServer.isEmpty ? "via \(row.parentAgentName)" : "\(row.mcpServer) MCP · \(row.parentAgentName)"
            return Key(id: "a:" + row.bundleID, title: row.appName.isEmpty ? row.bundleID : row.appName, detail: detail, kind: .app) {
                $0.bundleID = row.bundleID
            }
        case .hostname:
            if !row.domain.isEmpty {
                return Key(id: "h:" + row.domain, title: row.domain, detail: "", kind: .domain) { $0.domain = row.domain }
            }
            return Self.hostless(row)
        case .registrableDomain:
            if !row.domain.isEmpty {
                let registrable = AnomalyEngine.registrableDomain(row.domain)
                return Key(id: "r:" + registrable, title: registrable, detail: "", kind: .domain) { $0.domainSuffix = registrable }
            }
            return Self.hostless(row)
        case .ip:
            let detail = !row.domain.isEmpty ? row.domain : row.owner
            return Key(id: "i:" + row.remoteIP, title: row.remoteIP, detail: detail, kind: .ip) { $0.remoteIP = row.remoteIP }
        case .hostAndIP:
            return Key(id: "hi:" + row.domain + "|" + row.remoteIP, title: row.remoteIP, detail: row.domain, kind: .ip) {
                $0.domain = row.domain
                $0.remoteIP = row.remoteIP
            }
        }
    }

    /// Traffic with no hostname groups under its network owner, or "(no domain)".
    private static func hostless(_ row: BreakdownRow) -> Key {
        if !row.owner.isEmpty {
            let title = row.owner == IPOwner.localNetwork.name ? "Local network" : "\(row.owner) · AS\(row.asn)"
            return Key(id: "o:" + row.owner, title: title, detail: "", kind: .owner) {
                $0.domain = ""
                $0.owner = row.owner
            }
        }
        return Key(id: "u:", title: "(no domain)", detail: "", kind: .unknown) { $0.domain = "" }
    }
}

/// A row of the Breakdown table. Every node carries the filter that selects exactly its traffic,
/// so "Show only this" works the same whichever grouping built the tree.
struct TrafficNode: Identifiable, Hashable {
    enum Kind: Hashable { case app, domain, owner, unknown, ip, more }

    var id: String
    var kind: Kind
    var title: String
    /// Secondary text, e.g. the hostname next to an IP.
    var detail: String = ""
    /// App context: the app itself, or the app this row belongs to (nil above the app level).
    var bundleID: String?
    var appName: String?
    var appPath: String = ""
    var filter: TrafficFilter
    var ports: String = ""
    var protocols: String = ""
    var counters = FlowCounters()
    var children: [TrafficNode]?
    /// > 0 for the synthetic "Show more" row that stands in for collapsed siblings.
    var moreCount: Int = 0

    var bytesIn: Int64 { counters.bytesIn }
    var bytesOut: Int64 { counters.bytesOut }
    var total: Int64 { counters.total }
    var flows: Int64 { counters.flows }
    var domain: String? { filter.domain }
    var remoteIP: String? { filter.remoteIP }
    var owner: String? { filter.owner }

    static func == (a: TrafficNode, b: TrafficNode) -> Bool { a.id == b.id && a.counters == b.counters }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: Building

    static func tree(from rows: [BreakdownRow], grouping: BreakdownGrouping = .app, base: TrafficFilter = .none) -> [TrafficNode] {
        build(backfilled(rows), levels: grouping.levels[...], parentID: "", filter: base, app: nil)
    }

    /// Rows whose hostname was unknown when recorded (reverse DNS resolves a moment after a
    /// connection starts) inherit the hostname seen for the same IP.
    static func backfilled(_ rows: [BreakdownRow]) -> [BreakdownRow] {
        var knownDomain: [String: (domain: String, bytes: Int64)] = [:]
        for r in rows where !r.domain.isEmpty && r.counters.total > (knownDomain[r.remoteIP]?.bytes ?? -1) {
            knownDomain[r.remoteIP] = (r.domain, r.counters.total)
        }
        return rows.map { row in
            var row = row
            if row.domain.isEmpty, let known = knownDomain[row.remoteIP] { row.domain = known.domain }
            return row
        }
    }

    private static func build(_ rows: [BreakdownRow], levels: ArraySlice<TreeLevel>, parentID: String,
                              filter: TrafficFilter, app: (id: String, name: String, path: String)?) -> [TrafficNode] {
        guard let level = levels.first else { return [] }
        var groups: [String: (key: TreeLevel.Key, rows: [BreakdownRow])] = [:]
        for row in rows {
            let key = level.key(for: row)
            groups[key.id, default: (key, [])].rows.append(row)
        }
        return groups.values.map { group in
            let id = parentID.isEmpty ? group.key.id : parentID + "|" + group.key.id
            var narrowed = filter
            group.key.narrow(&narrowed)
            let first = group.rows[0]
            let appContext = level == .app
                ? (id: first.bundleID, name: group.key.title, path: first.appPath)
                : app
            var detail = group.key.detail
            if level == .ip { detail = mostCommonDetail(group.rows) }
            let node = TrafficNode(id: id, kind: group.key.kind, title: group.key.title, detail: detail,
                                   bundleID: appContext?.id, appName: appContext?.name,
                                   appPath: level == .app ? first.appPath : (appContext?.path ?? ""),
                                   filter: narrowed)
            if levels.count == 1 {
                var leaf = node
                group.rows.forEach { leaf.counters += $0.counters }
                leaf.ports = joined(group.rows.map(\.ports))
                leaf.protocols = joined(group.rows.map(\.protocols))
                return leaf
            }
            let children = build(group.rows, levels: levels.dropFirst(), parentID: id, filter: narrowed, app: appContext)
            return node.withChildren(children)
        }
    }

    /// For IP rows: the hostname (or owner) carrying the most bytes to that address.
    private static func mostCommonDetail(_ rows: [BreakdownRow]) -> String {
        var weights: [String: Int64] = [:]
        for row in rows {
            let label = !row.domain.isEmpty ? row.domain : row.owner
            if !label.isEmpty { weights[label, default: 0] += row.counters.total }
        }
        return weights.max { $0.value < $1.value }?.key ?? ""
    }

    private static func joined(_ values: [String]) -> String {
        var unique = Set<String>()
        for value in values {
            for part in value.split(separator: ",") { unique.insert(part.trimmingCharacters(in: .whitespaces)) }
        }
        let ordered: [String] = unique.sorted { a, b in a.count == b.count ? a < b : a.count < b.count }
        return ordered.prefix(6).joined(separator: ", ")
    }

    /// Replaces children and recomputes totals, ports and protocols from them.
    func withChildren(_ children: [TrafficNode]) -> TrafficNode {
        var copy = self
        var c = FlowCounters(); children.forEach { c += $0.counters }
        copy.counters = c
        copy.children = children
        copy.ports = Self.joined(children.map(\.ports))
        copy.protocols = Self.joined(children.map(\.protocols))
        return copy
    }

    // MARK: Search, sort, cap

    func matches(_ query: String) -> Bool {
        [title, detail, bundleID ?? "", protocols, ports].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Keeps nodes that match, or that have matching descendants (with totals narrowed to those).
    static func filter(_ nodes: [TrafficNode], query: String) -> [TrafficNode] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.matches(q) { return node }
            guard let children = node.children else { return nil }
            let kept = filter(children, query: q)
            return kept.isEmpty ? nil : node.withChildren(kept)
        }
    }

    func sorted(using comparators: [KeyPathComparator<TrafficNode>]) -> TrafficNode {
        var copy = self
        copy.children = children?.sorted(using: comparators).map { $0.sorted(using: comparators) }
        return copy
    }

    static let pageSize = 25
    static let rootPageSize = 100
    static let moreSuffix = "|__more__"

    /// Collapses long child lists to the first `limit` (per parent, grown by "Show more") plus one
    /// summary row, so a node with hundreds of children doesn't bury everything else.
    static func capped(_ nodes: [TrafficNode], parentID: String, parent: TrafficNode?, limits: [String: Int],
                       levels: [TreeLevel] = BreakdownGrouping.app.levels, depth: Int = 0) -> [TrafficNode] {
        let limit = limits[parentID] ?? (parent == nil ? rootPageSize : pageSize)
        var kept = nodes.prefix(limit).map { node -> TrafficNode in
            var copy = node
            if let children = node.children {
                copy.children = capped(children, parentID: node.id, parent: node, limits: limits, levels: levels, depth: depth + 1)
            }
            return copy
        }
        let rest = nodes.dropFirst(limit)
        if !rest.isEmpty {
            var c = FlowCounters(); rest.forEach { c += $0.counters }
            let noun = depth < levels.count ? levels[depth].plural : "items"
            kept.append(TrafficNode(id: parentID + moreSuffix, kind: .more,
                                    title: "Show \(min(pageSize, rest.count)) more · \(rest.count.formatted()) \(noun) not shown",
                                    bundleID: parent?.bundleID, appName: parent?.appName,
                                    filter: parent?.filter ?? .none, counters: c, moreCount: rest.count))
        }
        return kept
    }
}

extension TreeLevel: Equatable {}

enum CSVExport {
    private static func escape(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func series(_ series: [SeriesPoint], granularity: Granularity) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["bucket_start,granularity,bytes_in,bytes_out,total,flows"]
        for p in series {
            lines.append("\(iso.string(from: p.date)),\(granularity.rawValue),\(p.bytesIn),\(p.bytesOut),\(p.total),\(p.flows)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Flat rows (one per app × destination × IP), independent of how the table is grouped.
    static func breakdown(_ rows: [BreakdownRow], query: String = "") -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        var lines = ["app,bundle_id,domain,network_owner,remote_ip,protocols,ports,channel,bytes_in,bytes_out,total,flows"]
        for r in TrafficNode.backfilled(rows).sorted(by: { $0.counters.total > $1.counters.total }) {
            let fields = [r.appName, r.bundleID, r.domain, r.owner, r.remoteIP, r.protocols, r.ports, r.channel.title]
            if !q.isEmpty && !fields.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { continue }
            lines.append((fields + ["\(r.counters.bytesIn)", "\(r.counters.bytesOut)", "\(r.counters.total)", "\(r.counters.flows)"])
                .map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
