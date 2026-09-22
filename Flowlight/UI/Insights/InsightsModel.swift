import AppKit
import SwiftUI

/// What a chart slices traffic by.
enum InsightDimension: String, CaseIterable, Identifiable, Sendable {
    case app, destination, ip, appProtocol
    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "Apps"
        case .destination: return "Destinations"
        case .ip: return "IP addresses"
        case .appProtocol: return "Protocols"
        }
    }

    /// Dimensions worth charting for a filter: anything the filter hasn't already pinned.
    /// IPs only become interesting once a destination is chosen.
    static func available(for filter: TrafficFilter) -> [InsightDimension] {
        var dims: [InsightDimension] = []
        if filter.bundleID == nil { dims.append(.app) }
        if !filter.pinsDestination { dims.append(.destination) }
        if filter.pinsDestination && filter.remoteIP == nil { dims.append(.ip) }
        if filter.appProtocol == nil { dims.append(.appProtocol) }
        return dims
    }
}

enum InsightMetric: String, CaseIterable, Identifiable, Sendable {
    case total, received, sent
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func value(_ c: FlowCounters) -> Int64 {
        switch self {
        case .total: return c.total
        case .received: return c.bytesIn
        case .sent: return c.bytesOut
        }
    }
}

/// One thing traffic can be attributed to (an app, a domain, an owner, an IP, a protocol).
struct InsightEntity: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case app, domain, owner, unknownDestination, ip, appProtocol, other }
    var key: String
    var label: String
    var kind: Kind
    var iconPath: String?
    var id: String { key }

    static let other = InsightEntity(key: "__other__", label: "Other", kind: .other)

    /// The filter that narrows the report to this entity (nil for "Other"/unknown).
    func narrowing(_ filter: TrafficFilter) -> TrafficFilter? {
        var f = filter
        switch kind {
        case .app: f.bundleID = key
        case .domain: f.domainSuffix = label; f.domain = nil; f.owner = nil
        case .owner: f.owner = label; f.domain = ""; f.domainSuffix = nil
        case .ip: f.remoteIP = key
        case .appProtocol: f.appProtocol = key
        case .unknownDestination, .other: return nil
        }
        return f
    }

    static func from(_ row: DimensionRow, _ dimension: InsightDimension) -> InsightEntity {
        switch dimension {
        case .app:
            return InsightEntity(key: row.bundleID, label: row.appName.isEmpty ? row.bundleID : row.appName, kind: .app, iconPath: row.appPath)
        case .destination:
            if !row.domain.isEmpty {
                let registrable = AnomalyEngine.registrableDomain(row.domain)
                return InsightEntity(key: "d:" + registrable, label: registrable, kind: .domain)
            }
            if !row.owner.isEmpty { return InsightEntity(key: "o:" + row.owner, label: row.owner, kind: .owner) }
            return InsightEntity(key: "u:", label: "Unknown", kind: .unknownDestination)
        case .ip:
            return InsightEntity(key: row.remoteIP, label: row.remoteIP, kind: .ip)
        case .appProtocol:
            return InsightEntity(key: row.appProtocol, label: row.appProtocol.isEmpty ? "unknown" : row.appProtocol, kind: .appProtocol)
        }
    }
}

struct InsightSlice: Identifiable, Sendable, Equatable {
    var entity: InsightEntity
    var counters: FlowCounters
    var share: Double
    var id: String { entity.key }
}

struct InsightTrend: Identifiable, Sendable {
    var entity: InsightEntity
    var points: [SeriesPoint]
    var id: String { entity.key }
}

/// Everything one dimension's cards need: ranked shares and per-bucket trends for the leaders.
struct DimensionInsight: Identifiable, Sendable {
    var dimension: InsightDimension
    var slices: [InsightSlice]          // top entities + "Other", by the chosen metric
    var ranked: [InsightSlice]          // every entity, for the full list behind "Other" (capped)
    var entityCount: Int                // distinct entities with traffic, before any cap
    var trends: [InsightTrend]          // leaders, plus an "Other" line when the rest carries traffic
    var total: FlowCounters
    var id: InsightDimension { dimension }

    var hiddenCount: Int { max(0, entityCount - InsightsBuilder.maxSlices) }
    var leaderTrends: [InsightTrend] { trends.filter { $0.entity.kind != .other } }
}

struct InsightsSnapshot: Sendable {
    var dimensions: [DimensionInsight]
    var total: FlowCounters
    var direction: [SeriesPoint]        // received vs sent per bucket
    static let empty = InsightsSnapshot(dimensions: [], total: FlowCounters(), direction: [])
}

/// Builds chart data in two passes that stay cheap however many apps/domains/IPs exist:
/// 1. per-dimension totals aggregated in SQL → rank, top 5 + "Other";
/// 2. per-bucket rows only for the top 4 → trend lines, with "Other" = overall series − leaders.
enum InsightsBuilder {
    static let maxSlices = 5   // + "Other" → at most 6 donut segments
    static let maxTrends = 4   // lines stay direct-labelable
    static let maxListed = 1000

    typealias Ranked = (entity: InsightEntity, counters: FlowCounters)

    /// Ranks entities from dimension totals (rows may be per raw key; they are merged per entity).
    static func rank(_ rows: [DimensionRow], _ dimension: InsightDimension, metric: InsightMetric) -> [Ranked] {
        var totals: [String: Ranked] = [:]
        for row in rows {
            let entity = InsightEntity.from(row, dimension)
            var entry = totals[entity.key] ?? (entity, FlowCounters())
            entry.counters += FlowCounters(bytesIn: row.bytesIn, bytesOut: row.bytesOut, flows: 0)
            totals[entity.key] = entry
        }
        return totals.values
            .filter { metric.value($0.counters) > 0 }
            .sorted { metric.value($0.counters) != metric.value($1.counters)
                ? metric.value($0.counters) > metric.value($1.counters) : $0.entity.label < $1.entity.label }
    }

    /// The raw keys behind the leading entities, so the trend query touches only their rows.
    static func selector(for leaders: [Ranked], dimension: InsightDimension, totals: [DimensionRow]) -> TrendSelector {
        let keys = Set(leaders.map(\.entity.key))
        var selector = TrendSelector()
        switch dimension {
        case .app: selector.bundleIDs = leaders.map(\.entity.key)
        case .ip: selector.ips = leaders.map(\.entity.key)
        case .appProtocol: selector.protocols = leaders.map(\.entity.key)
        case .destination:
            var domains = Set<String>(), ips = Set<String>()
            for row in totals where keys.contains(InsightEntity.from(row, .destination).key) {
                if row.domain.isEmpty { ips.insert(row.remoteIP) } else { domains.insert(row.domain) }
            }
            selector.domains = domains.sorted()
            selector.hostlessIPs = ips.sorted()
        }
        return selector
    }

    static func insight(dimension: InsightDimension, ranked: [Ranked], trendRows: [DimensionRow], series: [SeriesPoint],
                        metric: InsightMetric, granularity: Granularity, from: Date, to: Date, calendar: Calendar) -> DimensionInsight {
        var total = FlowCounters()
        series.forEach { total += FlowCounters(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, flows: 0) }
        let grand = Double(max(1, metric.value(total)))
        let all = ranked.prefix(maxListed).map {
            InsightSlice(entity: $0.entity, counters: $0.counters, share: Double(metric.value($0.counters)) / grand)
        }
        var slices = Array(all.prefix(maxSlices))
        let rest = ranked.dropFirst(maxSlices)
        if !rest.isEmpty {
            var other = FlowCounters()
            rest.forEach { other += $0.counters }
            slices.append(InsightSlice(entity: .other, counters: other, share: Double(metric.value(other)) / grand))
        }

        let leaders = ranked.prefix(maxTrends)
        let leaderKeys = Set(leaders.map(\.entity.key))
        var perEntity: [String: [SeriesPoint]] = [:]
        for row in trendRows {
            let key = InsightEntity.from(row, dimension).key
            guard leaderKeys.contains(key) else { continue }
            perEntity[key, default: []].append(SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(row.ts)),
                                                            bytesIn: row.bytesIn, bytesOut: row.bytesOut, flows: 0))
        }
        var trends = leaders.map { entry in
            InsightTrend(entity: entry.entity,
                         points: TrafficDatabase.bucket(perEntity[entry.entity.key] ?? [], granularity: granularity,
                                                        from: from, to: to, calendar: calendar))
        }
        // "Other" line: everything the leaders don't explain, so a long tail can't hide.
        if ranked.count > maxTrends, let reference = trends.first {
            let points = reference.points.indices.map { i -> SeriesPoint in
                let date = reference.points[i].date
                let overall = series.first { $0.date == date }
                let leadersIn = trends.reduce(Int64(0)) { $0 + $1.points[i].bytesIn }
                let leadersOut = trends.reduce(Int64(0)) { $0 + $1.points[i].bytesOut }
                return SeriesPoint(date: date, bytesIn: max(0, (overall?.bytesIn ?? 0) - leadersIn),
                                   bytesOut: max(0, (overall?.bytesOut ?? 0) - leadersOut), flows: 0)
            }
            if points.contains(where: { metric.value(FlowCounters(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, flows: 0)) > 0 }) {
                trends.append(InsightTrend(entity: .other, points: points))
            }
        }
        trends = trimmed(trends, granularity: granularity, to: to, calendar: calendar)
        return DimensionInsight(dimension: dimension, slices: slices, ranked: all, entityCount: ranked.count,
                                trends: trends, total: total)
    }

    /// Starts near the first data and drops the still-filling bucket that contains `to`.
    static func trimmed(_ trends: [InsightTrend], granularity: Granularity, to: Date, calendar: Calendar) -> [InsightTrend] {
        var trends = trends
        let activeStarts: [Int] = trends.compactMap { trend -> Int? in trend.points.firstIndex(where: { $0.total > 0 }) }
        let firstActive: Int = activeStarts.min() ?? 0
        let length = trends.first?.points.count ?? 0
        let start = max(0, min(firstActive - 1, length - 12))
        if start > 0 { trends = trends.map { InsightTrend(entity: $0.entity, points: Array($0.points[start...])) } }
        if let last = trends.first?.points.last,
           let end = calendar.date(byAdding: granularity.calendarComponent, value: 1, to: last.date), end > to,
           (trends.first?.points.count ?? 0) > 1 {
            trends = trends.map { InsightTrend(entity: $0.entity, points: Array($0.points.dropLast())) }
        }
        return trends
    }

    /// Full pipeline against the database (used by Reports).
    static func load(db: TrafficDatabase, dimensions: [InsightDimension], series: [SeriesPoint], metric: InsightMetric,
                     granularity: Granularity, from: Date, to: Date, filter: TrafficFilter,
                     calendar: Calendar = .current) throws -> InsightsSnapshot {
        var total = FlowCounters()
        series.forEach { total += FlowCounters(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, flows: 0) }
        let insights = try dimensions.map { dimension -> DimensionInsight in
            let totals = try db.dimensionTotals(dimension, granularity, from: from, to: to, filter: filter)
            let ranked = rank(totals, dimension, metric: metric)
            let selector = selector(for: Array(ranked.prefix(maxTrends)), dimension: dimension, totals: totals)
            let trendRows = try db.dimensionTrendRows(selector, granularity, from: from, to: to, filter: filter)
            return insight(dimension: dimension, ranked: ranked, trendRows: trendRows, series: series, metric: metric,
                           granularity: granularity, from: from, to: to, calendar: calendar)
        }
        return InsightsSnapshot(dimensions: insights, total: total, direction: series)
    }

    /// In-memory equivalent of `load` for raw rows (tests and small data sets).
    static func build(rows: [DimensionRow], dimensions: [InsightDimension], metric: InsightMetric,
                      granularity: Granularity, from: Date, to: Date, calendar: Calendar = .current) -> InsightsSnapshot {
        let points = rows.map { SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, flows: 0) }
        let series = TrafficDatabase.bucket(points, granularity: granularity, from: from, to: to, calendar: calendar)
        var total = FlowCounters()
        series.forEach { total += FlowCounters(bytesIn: $0.bytesIn, bytesOut: $0.bytesOut, flows: 0) }
        let insights = dimensions.map { dimension in
            insight(dimension: dimension, ranked: rank(rows, dimension, metric: metric), trendRows: rows, series: series,
                    metric: metric, granularity: granularity, from: from, to: to, calendar: calendar)
        }
        return InsightsSnapshot(dimensions: insights, total: total, direction: series)
    }
}

// MARK: - Color

/// Categorical palette for entities. Blue/orange are reserved for received/sent, so entities use the
/// other five hues, in an order validated for color-vision deficiency on both surfaces (adjacent
/// pairs and the donut's wrap-around pair: ΔE ≥ 9.1 light, ≥ 8.4 dark).
enum InsightPalette {
    private static let light: [NSColor] = [0x4A3AA7, 0x1BAF7A, 0xEDA100, 0xE87BA4, 0x008300].map(NSColor.init(hex:))
    private static let dark: [NSColor] = [0x9085E9, 0x199E70, 0xC98500, 0xD55181, 0x008300].map(NSColor.init(hex:))
    static let slotCount = 5

    static func color(slot: Int) -> Color {
        let index = slot % slotCount
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[index] : light[index]
        })
    }

    static let other = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x5B5A56) : NSColor(hex: 0xB8B7B1)
    })
}

/// Keeps an entity's color stable while it stays on screen: survivors never get repainted when the
/// window or filter changes; newcomers take the lowest free slot.
struct ColorRegistry {
    private var slots: [String: Int] = [:]

    mutating func assign(visible keys: [String]) {
        let visible = Set(keys)
        slots = slots.filter { visible.contains($0.key) }
        var used = Set(slots.values)
        for key in keys where slots[key] == nil {
            let free = (0..<InsightPalette.slotCount).first { !used.contains($0) } ?? (used.count % InsightPalette.slotCount)
            slots[key] = free
            used.insert(free)
        }
    }

    func slot(for key: String) -> Int? { slots[key] }

    func color(for entity: InsightEntity) -> Color {
        guard entity.kind != .other, let slot = slots[entity.key] else { return InsightPalette.other }
        return InsightPalette.color(slot: slot)
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
