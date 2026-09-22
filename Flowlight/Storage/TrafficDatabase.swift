import Foundation
import os.log
import Security

let appLog = Logger(subsystem: FlowlightConstants.hostBundleIdentifier, category: "app")

enum Granularity: String, CaseIterable, Identifiable, Sendable {
    case second, minute, hour, day, week, month, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Source table for the granularity; week/month/year are bucketed from daily rows.
    var table: String {
        switch self {
        case .second: return "flows_1s"
        case .minute: return "agg_1m"
        case .hour: return "agg_1h"
        case .day, .week, .month, .year: return "agg_1d"
        }
    }

    /// Default window shown for the granularity.
    var defaultWindow: TimeInterval {
        switch self {
        case .second: return 5 * 60
        case .minute: return 3 * 3600
        case .hour: return 3 * 86400
        case .day: return 30 * 86400
        case .week: return 26 * 7 * 86400
        case .month: return 365 * 86400
        case .year: return 5 * 365 * 86400
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .second: return .second
        case .minute: return .minute
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

struct TrafficFilter: Equatable, Sendable {
    var bundleID: String?
    var domain: String?
    var remoteIP: String?
    /// Network owner (AS name) for traffic without a hostname.
    var owner: String?
    /// Registrable domain: matches the domain itself and every subdomain (e.g. google.com, *.google.com).
    var domainSuffix: String?
    var appProtocol: String?

    static let none = TrafficFilter()
    var isEmpty: Bool {
        bundleID == nil && domain == nil && remoteIP == nil && owner == nil && domainSuffix == nil && appProtocol == nil
    }
    /// True when the filter pins a destination (hostname, domain, owner or IP).
    var pinsDestination: Bool { domain != nil || domainSuffix != nil || owner != nil || remoteIP != nil }
}

struct SeriesPoint: Identifiable, Sendable, Equatable {
    var date: Date
    var bytesIn: Int64
    var bytesOut: Int64
    var flows: Int64
    var id: Date { date }
    var total: Int64 { bytesIn + bytesOut }
}

struct BreakdownRow: Sendable {
    var bundleID: String
    var appName: String
    var appPath: String
    var domain: String
    var remoteIP: String
    var ports: String
    var protocols: String
    var counters: FlowCounters
    /// AS owner of `remoteIP` when known (e.g. "Cloudflare, Inc."), empty otherwise.
    var owner: String = ""
    var asn: Int = 0
}

/// Raw keys that make up a chart's leading entities, so trend queries only touch those rows.
struct TrendSelector: Sendable, Equatable {
    var bundleIDs: [String] = []
    var domains: [String] = []        // full hostnames grouped under a registrable domain
    var hostlessIPs: [String] = []    // IPs of owner/unknown entities (rows without a hostname)
    var ips: [String] = []
    var protocols: [String] = []
    var isEmpty: Bool { bundleIDs.isEmpty && domains.isEmpty && hostlessIPs.isEmpty && ips.isEmpty && protocols.isEmpty }
}

struct DimensionRow: Sendable {
    var ts: Int64
    var bundleID: String
    var appName: String
    var appPath: String
    var domain: String
    var owner: String
    var remoteIP: String
    var appProtocol: String
    var bytesIn: Int64
    var bytesOut: Int64
}

/// An app's share of one chart bucket, with where most of its bytes went.
struct BucketContributor: Identifiable, Sendable, Equatable {
    var bundleID: String
    var appName: String
    var appPath: String
    var counters: FlowCounters
    var topDestination: String
    var id: String { bundleID }
}

/// The leading apps of one bucket plus whatever the rest adds up to.
struct BucketContributors: Sendable, Equatable {
    var top: [BucketContributor]
    var remainingApps: Int
    var remaining: FlowCounters
}

struct AlertRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var timestamp: Date
    var kind: String
    var bundleID: String
    var appName: String
    var detail: String
    var severity: Int
    var acknowledged: Bool
}

/// SQLite store (App Group container) with tiered rollups:
/// flows_1s → agg_1m (complete minutes) → agg_1h / agg_1d (folded from immutable minute rows).
final class TrafficDatabase: @unchecked Sendable {
    static let tables = ["flows_1s", "agg_1m", "agg_1h", "agg_1d"]
    let queue = DispatchQueue(label: "flowlight.db", qos: .userInitiated)
    private let conn: SQLiteConnection
    let url: URL

    /// The App Group container when this build is entitled for it (shared with the extension),
    /// otherwise Application Support. Touching an un-entitled group container can trigger a
    /// "would like to access data from other apps" privacy prompt on recent macOS.
    static func defaultURL() -> URL {
        let fm = FileManager.default
        let groupURL = hasAppGroupEntitlement
            ? fm.containerURL(forSecurityApplicationGroupIdentifier: FlowlightConstants.appGroupIdentifier) : nil
        let base = groupURL
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flowlight")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("traffic.sqlite")
    }

    let isReadOnly: Bool

    /// Opens the store. Use one writer (ingest, rollups, analytics) and a separate read-only
    /// instance for UI queries so reports never stall ingest (WAL allows concurrent readers).
    private static var hasAppGroupEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String]
        else { return false }
        return groups.contains(FlowlightConstants.appGroupIdentifier)
    }

    init(url: URL = TrafficDatabase.defaultURL(), readOnly: Bool = false) throws {
        self.url = url
        isReadOnly = readOnly
        conn = try SQLiteConnection(path: url.path, readOnly: readOnly)
        if !readOnly { try migrate() }
    }

    private func migrate() throws {
        for table in Self.tables {
            try conn.execute("""
            CREATE TABLE IF NOT EXISTS \(table) (
                ts INTEGER NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                app_path TEXT NOT NULL, remote_ip TEXT NOT NULL, domain TEXT NOT NULL, port INTEGER NOT NULL,
                transport TEXT NOT NULL, protocol TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0, flows INTEGER NOT NULL DEFAULT 0);
            CREATE UNIQUE INDEX IF NOT EXISTS \(table)_key ON \(table)(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol);
            CREATE INDEX IF NOT EXISTS \(table)_app ON \(table)(bundle_id, ts);
            """)
        }
        try conn.execute("""
        CREATE TABLE IF NOT EXISTS rollup_state (tier TEXT PRIMARY KEY, watermark INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS seen_destinations (bundle_id TEXT NOT NULL, domain TEXT NOT NULL, first_seen INTEGER NOT NULL,
            PRIMARY KEY (bundle_id, domain));
        CREATE TABLE IF NOT EXISTS seen_ports (bundle_id TEXT NOT NULL, port INTEGER NOT NULL, first_seen INTEGER NOT NULL,
            PRIMARY KEY (bundle_id, port));
        CREATE TABLE IF NOT EXISTS apps (bundle_id TEXT PRIMARY KEY, first_seen INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS baselines (bundle_id TEXT NOT NULL, metric TEXT NOT NULL, mean REAL NOT NULL,
            variance REAL NOT NULL, samples INTEGER NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY (bundle_id, metric));
        CREATE TABLE IF NOT EXISTS alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL,
            bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, detail TEXT NOT NULL, severity INTEGER NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS alerts_ts ON alerts(ts);
        CREATE TABLE IF NOT EXISTS ip_owners (ip TEXT PRIMARY KEY, asn INTEGER NOT NULL, owner TEXT NOT NULL, updated INTEGER NOT NULL);
        """)
    }

    // MARK: Ingest

    func insert(_ batches: [TrafficBatch]) throws {
        let sql = """
        INSERT INTO flows_1s (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out, flows = flows + excluded.flows
        """
        try conn.transaction {
            for batch in batches {
                for r in batch.records {
                    let k = r.key
                    try conn.run(sql, [.int(batch.timestamp), .int(Int64(k.pid)), .text(k.bundleID), .text(k.appName),
                                       .text(k.appPath), .text(k.remoteIP), .text(k.domain), .int(Int64(k.port)),
                                       .text(k.transport.rawValue), .text(k.appProtocol), .int(r.counters.bytesIn),
                                       .int(r.counters.bytesOut), .int(r.counters.flows)])
                }
            }
        }
    }

    /// Writes pre-aggregated rows straight into a tier (demo data and imports). Callers own consistency.
    func insertAggregates(_ table: String, _ rows: [(ts: Int64, key: FlowKey, counters: FlowCounters)]) throws {
        precondition(Self.tables.contains(table))
        let sql = """
        INSERT INTO \(table) (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out, flows = flows + excluded.flows
        """
        try conn.transaction {
            for r in rows {
                let k = r.key
                try conn.run(sql, [.int(r.ts), .int(Int64(k.pid)), .text(k.bundleID), .text(k.appName), .text(k.appPath),
                                   .text(k.remoteIP), .text(k.domain), .int(Int64(k.port)), .text(k.transport.rawValue),
                                   .text(k.appProtocol), .int(r.counters.bytesIn), .int(r.counters.bytesOut), .int(r.counters.flows)])
            }
        }
    }

    /// Marks every tier as rolled up to `ts`, so seeded history isn't folded again.
    func setRollupWatermarks(_ ts: Int64) throws {
        for tier in ["1m", "1h", "1d"] { try setWatermark(tier, ts) }
    }

    // MARK: Rollups

    struct Retention {
        var seconds: TimeInterval = 6 * 3600
        var minutes: TimeInterval = 14 * 86400
        var hours: TimeInterval = 400 * 86400
        var alerts: TimeInterval = 90 * 86400
    }

    private func watermark(_ tier: String) throws -> Int64 {
        try conn.query("SELECT watermark FROM rollup_state WHERE tier = ?", [.text(tier)]) { $0.int(0) }.first ?? 0
    }

    private func setWatermark(_ tier: String, _ value: Int64) throws {
        try conn.run("INSERT INTO rollup_state (tier, watermark) VALUES (?, ?) ON CONFLICT(tier) DO UPDATE SET watermark = excluded.watermark",
                     [.text(tier), .int(value)])
    }

    private func fold(from source: String, into target: String, bucket: String, lower: Int64, upper: Int64) throws {
        try conn.run("""
        INSERT INTO \(target) (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows)
        SELECT \(bucket), pid, bundle_id, MAX(app_name), MAX(app_path), remote_ip, domain, port, transport, protocol,
               SUM(bytes_in), SUM(bytes_out), SUM(flows)
        FROM \(source) WHERE ts >= ? AND ts < ?
        GROUP BY 1, pid, bundle_id, remote_ip, domain, port, transport, protocol
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out, flows = flows + excluded.flows
        """, [.int(lower), .int(upper)])
    }

    /// Folds each tier into the next and prunes expired rows. Returns the hour/day boundaries that completed.
    @discardableResult
    func rollup(now: Date = Date(), retention: Retention = Retention(), timeZone: TimeZone = .current) throws -> (completedHours: [Int64], completedDays: [Int64]) {
        let nowTs = Int64(now.timeIntervalSince1970)
        // Leave a few seconds for late batches before closing a minute.
        let minuteCutoff = ((nowTs - 5) / 60) * 60
        let offset = Int64(timeZone.secondsFromGMT(for: now))
        var completedHours: [Int64] = []
        var completedDays: [Int64] = []

        try conn.transaction {
            let w1m = try watermark("1m")
            if minuteCutoff > w1m {
                try fold(from: "flows_1s", into: "agg_1m", bucket: "(ts / 60) * 60", lower: w1m, upper: minuteCutoff)
                try setWatermark("1m", minuteCutoff)
            }
            let w1h = try watermark("1h")
            if minuteCutoff > w1h {
                try fold(from: "agg_1m", into: "agg_1h", bucket: "(ts / 3600) * 3600", lower: w1h, upper: minuteCutoff)
                try setWatermark("1h", minuteCutoff)
                if w1h > 0 {
                    var hour = (w1h / 3600) * 3600
                    while hour + 3600 <= minuteCutoff { if hour + 3600 > w1h { completedHours.append(hour) }; hour += 3600 }
                }
            }
            let w1d = try watermark("1d")
            if minuteCutoff > w1d {
                try fold(from: "agg_1m", into: "agg_1d", bucket: "((ts + \(offset)) / 86400) * 86400 - \(offset)", lower: w1d, upper: minuteCutoff)
                try setWatermark("1d", minuteCutoff)
                if w1d > 0 {
                    var day = ((w1d + offset) / 86400) * 86400 - offset
                    while day + 86400 <= minuteCutoff { if day + 86400 > w1d { completedDays.append(day) }; day += 86400 }
                }
            }
            try conn.run("DELETE FROM flows_1s WHERE ts < ? AND ts < ?", [.int(nowTs - Int64(retention.seconds)), .int(minuteCutoff)])
            try conn.run("DELETE FROM agg_1m WHERE ts < ?", [.int(nowTs - Int64(retention.minutes))])
            try conn.run("DELETE FROM agg_1h WHERE ts < ?", [.int(nowTs - Int64(retention.hours))])
            try conn.run("DELETE FROM alerts WHERE ts < ?", [.int(nowTs - Int64(retention.alerts))])
        }
        return (completedHours, completedDays)
    }

    // MARK: Queries

    private func whereClause(from: Date, to: Date, filter: TrafficFilter) -> (String, [SQLValue]) {
        var clauses = ["ts >= ?", "ts < ?"]
        var values: [SQLValue] = [.int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970))]
        if let v = filter.bundleID { clauses.append("bundle_id = ?"); values.append(.text(v)) }
        if let v = filter.domain { clauses.append("domain = ?"); values.append(.text(v)) }
        if let v = filter.remoteIP { clauses.append("remote_ip = ?"); values.append(.text(v)) }
        if let v = filter.owner { clauses.append("remote_ip IN (SELECT ip FROM ip_owners WHERE owner = ?)"); values.append(.text(v)) }
        if let v = filter.domainSuffix {
            clauses.append("(domain = ? OR domain LIKE ?)")
            values.append(.text(v)); values.append(.text("%." + v))
        }
        if let v = filter.appProtocol { clauses.append("protocol = ?"); values.append(.text(v)) }
        return (clauses.joined(separator: " AND "), values)
    }

    /// Time series at the requested granularity; empty buckets are filled with zeros.
    func series(_ granularity: Granularity, from: Date, to: Date, filter: TrafficFilter = .none,
                calendar: Calendar = .current) throws -> [SeriesPoint] {
        let (clause, values) = whereClause(from: from, to: to, filter: filter)
        let rows = try conn.query("""
            SELECT ts, SUM(bytes_in), SUM(bytes_out), SUM(flows) FROM \(granularity.table) WHERE \(clause) GROUP BY ts ORDER BY ts
            """, values) { row in
            SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(row.int(0))), bytesIn: row.int(1), bytesOut: row.int(2), flows: row.int(3))
        }
        return Self.bucket(rows, granularity: granularity, from: from, to: to, calendar: calendar)
    }

    static func bucket(_ rows: [SeriesPoint], granularity: Granularity, from: Date, to: Date, calendar: Calendar) -> [SeriesPoint] {
        let component = granularity.calendarComponent
        func start(_ date: Date) -> Date { calendar.dateInterval(of: component, for: date)?.start ?? date }
        var buckets: [Date: SeriesPoint] = [:]
        for row in rows {
            let key = start(row.date)
            var point = buckets[key] ?? SeriesPoint(date: key, bytesIn: 0, bytesOut: 0, flows: 0)
            point.bytesIn += row.bytesIn
            point.bytesOut += row.bytesOut
            point.flows += row.flows
            buckets[key] = point
        }
        var result: [SeriesPoint] = []
        var cursor = start(from)
        while cursor < to, result.count < 10_000 {
            result.append(buckets[cursor] ?? SeriesPoint(date: cursor, bytesIn: 0, bytesOut: 0, flows: 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    /// Per app × domain × IP totals for the window.
    static let breakdownLimit = 10_000

    func breakdown(_ granularity: Granularity, from: Date, to: Date, filter: TrafficFilter = .none,
                   limit: Int = TrafficDatabase.breakdownLimit) throws -> [BreakdownRow] {
        let (clause, values) = whereClause(from: from, to: to, filter: filter)
        return try conn.query("""
            SELECT t.*, COALESCE(o.owner, ''), COALESCE(o.asn, 0) FROM (
                SELECT bundle_id, MAX(app_name), MAX(app_path), domain, remote_ip,
                       GROUP_CONCAT(DISTINCT port), GROUP_CONCAT(DISTINCT protocol),
                       SUM(bytes_in) AS bin, SUM(bytes_out) AS bout, SUM(flows)
                FROM \(granularity.table) WHERE \(clause)
                GROUP BY bundle_id, domain, remote_ip
                ORDER BY bin + bout DESC LIMIT \(limit)
            ) t LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { row in
            BreakdownRow(bundleID: row.text(0), appName: row.text(1), appPath: row.text(2), domain: row.text(3),
                         remoteIP: row.text(4), ports: row.text(5), protocols: row.text(6),
                         counters: FlowCounters(bytesIn: row.int(7), bytesOut: row.int(8), flows: row.int(9)),
                         owner: row.text(10), asn: Int(row.int(11)))
        }
    }

    /// Per-dimension totals aggregated in SQL (no row cap needed: one row per distinct key).
    /// Destinations come back per (hostname, IP) so hostname-less traffic can fall back to its owner.
    func dimensionTotals(_ dimension: InsightDimension, _ granularity: Granularity, from: Date, to: Date,
                         filter: TrafficFilter = .none) throws -> [DimensionRow] {
        let (clause, values) = whereClause(from: from, to: to, filter: filter)
        let groupColumns: String
        switch dimension {
        case .app: groupColumns = "bundle_id"
        case .destination: groupColumns = "domain, remote_ip"
        case .ip: groupColumns = "remote_ip"
        case .appProtocol: groupColumns = "protocol"
        }
        return try conn.query("""
            SELECT t.bundle_id, t.app_name, t.app_path, t.domain, COALESCE(o.owner, ''), t.remote_ip, t.protocol, t.bin, t.bout
            FROM (SELECT MAX(bundle_id) AS bundle_id, MAX(app_name) AS app_name, MAX(app_path) AS app_path,
                         MAX(domain) AS domain, MAX(remote_ip) AS remote_ip, MAX(protocol) AS protocol,
                         SUM(bytes_in) AS bin, SUM(bytes_out) AS bout
                  FROM \(granularity.table) WHERE \(clause) GROUP BY \(groupColumns)) t
            LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { r in
            DimensionRow(ts: 0, bundleID: r.text(0), appName: r.text(1), appPath: r.text(2), domain: r.text(3), owner: r.text(4),
                         remoteIP: r.text(5), appProtocol: r.text(6), bytesIn: r.int(7), bytesOut: r.int(8))
        }
    }

    /// Per-bucket rows restricted to the chart's leading entities (see `TrendSelector`).
    func dimensionTrendRows(_ selector: TrendSelector, _ granularity: Granularity, from: Date, to: Date,
                            filter: TrafficFilter = .none) throws -> [DimensionRow] {
        guard !selector.isEmpty else { return [] }
        var (clause, values) = whereClause(from: from, to: to, filter: filter)
        var parts: [String] = []
        func list(_ column: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            parts.append("\(column) IN (\(Array(repeating: "?", count: items.count).joined(separator: ",")))")
            values += items.map { SQLValue.text($0) }
        }
        list("bundle_id", selector.bundleIDs)
        list("domain", selector.domains)
        list("protocol", selector.protocols)
        list("remote_ip", selector.ips)
        if !selector.hostlessIPs.isEmpty {
            parts.append("(domain = '' AND remote_ip IN (\(Array(repeating: "?", count: selector.hostlessIPs.count).joined(separator: ","))))")
            values += selector.hostlessIPs.map { SQLValue.text($0) }
        }
        clause += " AND (" + parts.joined(separator: " OR ") + ")"
        return try conn.query("""
            SELECT t.ts, t.bundle_id, t.app_name, t.app_path, t.domain, COALESCE(o.owner, ''), t.remote_ip, t.protocol, t.bin, t.bout
            FROM (SELECT ts, bundle_id, MAX(app_name) AS app_name, MAX(app_path) AS app_path, domain, remote_ip, protocol,
                         SUM(bytes_in) AS bin, SUM(bytes_out) AS bout
                  FROM \(granularity.table) WHERE \(clause)
                  GROUP BY ts, bundle_id, domain, remote_ip, protocol) t
            LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { r in
            DimensionRow(ts: r.int(0), bundleID: r.text(1), appName: r.text(2), appPath: r.text(3), domain: r.text(4),
                         owner: r.text(5), remoteIP: r.text(6), appProtocol: r.text(7), bytesIn: r.int(8), bytesOut: r.int(9))
        }
    }

    /// Top apps in one time bucket (for chart tooltips), each with its busiest destination.
    func contributors(_ granularity: Granularity, from: Date, to: Date, filter: TrafficFilter = .none, limit: Int = 3) throws -> BucketContributors {
        let (clause, values) = whereClause(from: from, to: to, filter: filter)
        let all = try conn.query("""
            SELECT bundle_id, MAX(app_name), MAX(app_path), SUM(bytes_in), SUM(bytes_out), SUM(flows)
            FROM \(granularity.table) WHERE \(clause)
            GROUP BY bundle_id HAVING SUM(bytes_in) + SUM(bytes_out) > 0
            ORDER BY SUM(bytes_in) + SUM(bytes_out) DESC
            """, values) { row in
            BucketContributor(bundleID: row.text(0), appName: row.text(1), appPath: row.text(2),
                              counters: FlowCounters(bytesIn: row.int(3), bytesOut: row.int(4), flows: row.int(5)), topDestination: "")
        }
        var apps = Array(all.prefix(limit))
        var remaining = FlowCounters()
        all.dropFirst(limit).forEach { remaining += $0.counters }
        for index in apps.indices {
            var appFilter = filter
            appFilter.bundleID = apps[index].bundleID
            let (appClause, appValues) = whereClause(from: from, to: to, filter: appFilter)
            apps[index].topDestination = try conn.query("""
                SELECT CASE WHEN t.domain != '' THEN t.domain
                            WHEN o.owner IS NOT NULL THEN o.owner || ' · ' || t.remote_ip
                            ELSE t.remote_ip END
                FROM (SELECT domain, remote_ip, SUM(bytes_in) + SUM(bytes_out) AS total
                      FROM \(granularity.table) WHERE \(appClause) GROUP BY domain, remote_ip ORDER BY total DESC LIMIT 1) t
                LEFT JOIN ip_owners o ON o.ip = t.remote_ip
                """, appValues) { $0.text(0) }.first ?? ""
        }
        return BucketContributors(top: apps, remainingApps: max(0, all.count - limit), remaining: remaining)
    }

    // MARK: Analytics support

    /// Hourly totals per app for one hour bucket.
    func appTotals(table: String, at ts: Int64) throws -> [String: (name: String, counters: FlowCounters, destinations: Int)] {
        let rows = try conn.query("""
            SELECT bundle_id, MAX(app_name), SUM(bytes_in), SUM(bytes_out), SUM(flows),
                   COUNT(DISTINCT CASE WHEN domain != '' THEN domain ELSE remote_ip END)
            FROM \(table) WHERE ts = ? GROUP BY bundle_id
            """, [.int(ts)]) { row in
            (row.text(0), row.text(1), FlowCounters(bytesIn: row.int(2), bytesOut: row.int(3), flows: row.int(4)), Int(row.int(5)))
        }
        return Dictionary(rows.map { ($0.0, (name: $0.1, counters: $0.2, destinations: $0.3)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Historical hourly upload volumes for an app (hours with traffic only).
    func hourlyUploads(bundleID: String, since: Int64, before: Int64) throws -> [Int64] {
        try conn.query("""
            SELECT SUM(bytes_out) FROM agg_1h WHERE bundle_id = ? AND ts >= ? AND ts < ? GROUP BY ts
            """, [.text(bundleID), .int(since), .int(before)]) { $0.int(0) }
    }

    struct Baseline { var mean: Double; var variance: Double; var samples: Int }

    func baselines(metric: String) throws -> [String: Baseline] {
        let rows = try conn.query("SELECT bundle_id, mean, variance, samples FROM baselines WHERE metric = ?", [.text(metric)]) {
            ($0.text(0), Baseline(mean: $0.double(1), variance: $0.double(2), samples: Int($0.int(3))))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    func saveBaseline(bundleID: String, metric: String, _ b: Baseline) throws {
        try conn.run("""
            INSERT INTO baselines (bundle_id, metric, mean, variance, samples, updated) VALUES (?,?,?,?,?,?)
            ON CONFLICT(bundle_id, metric) DO UPDATE SET mean = excluded.mean, variance = excluded.variance,
                samples = excluded.samples, updated = excluded.updated
            """, [.text(bundleID), .text(metric), .double(b.mean), .double(b.variance), .int(Int64(b.samples)),
                  .int(Int64(Date().timeIntervalSince1970))])
    }

    func loadSeen() throws -> (destinations: Set<String>, ports: Set<String>, apps: [String: Int64]) {
        let d = try conn.query("SELECT bundle_id || '|' || domain FROM seen_destinations") { $0.text(0) }
        let p = try conn.query("SELECT bundle_id || '|' || port FROM seen_ports") { $0.text(0) }
        let a = try conn.query("SELECT bundle_id, first_seen FROM apps") { ($0.text(0), $0.int(1)) }
        return (Set(d), Set(p), Dictionary(a, uniquingKeysWith: { a, _ in a }))
    }

    func markSeen(destinations: [(String, String)], ports: [(String, UInt16)], apps: [String], at ts: Int64) throws {
        try conn.transaction {
            for (bundle, domain) in destinations {
                try conn.run("INSERT OR IGNORE INTO seen_destinations VALUES (?,?,?)", [.text(bundle), .text(domain), .int(ts)])
            }
            for (bundle, port) in ports {
                try conn.run("INSERT OR IGNORE INTO seen_ports VALUES (?,?,?)", [.text(bundle), .int(Int64(port)), .int(ts)])
            }
            for bundle in apps { try conn.run("INSERT OR IGNORE INTO apps VALUES (?,?)", [.text(bundle), .int(ts)]) }
        }
    }

    // MARK: IP owners

    func saveOwner(ip: String, _ owner: IPOwner) throws {
        try conn.run("""
            INSERT INTO ip_owners (ip, asn, owner, updated) VALUES (?,?,?,?)
            ON CONFLICT(ip) DO UPDATE SET asn = excluded.asn, owner = excluded.owner, updated = excluded.updated
            """, [.text(ip), .int(Int64(owner.asn)), .text(owner.name), .int(Int64(Date().timeIntervalSince1970))])
    }

    /// Owners younger than `maxAge`; ownership changes rarely, so a month is plenty.
    func loadOwners(maxAge: TimeInterval = 30 * 86400) throws -> [String: IPOwner] {
        let cutoff = Int64(Date().timeIntervalSince1970 - maxAge)
        let rows = try conn.query("SELECT ip, asn, owner FROM ip_owners WHERE updated >= ?", [.int(cutoff)]) {
            ($0.text(0), IPOwner(asn: Int($0.int(1)), name: $0.text(2)))
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    /// Distinct (app, hostname, owner) seen since `since`, for re-discovering AI agents at launch.
    func appDestinations(since: Date) throws -> [(bundleID: String, domain: String, owner: String)] {
        try conn.query("""
            SELECT DISTINCT t.bundle_id, t.domain, COALESCE(o.owner, '') FROM
              (SELECT DISTINCT bundle_id, domain, remote_ip FROM agg_1h WHERE ts >= ?) t
            LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, [.int(Int64(since.timeIntervalSince1970))]) { ($0.text(0), $0.text(1), $0.text(2)) }
    }

    /// Hostname-less IPs seen recently that have no owner yet (to backfill after an upgrade or restart).
    func unownedIPs(since: Date, limit: Int = 500) throws -> [String] {
        try conn.query("""
            SELECT DISTINCT remote_ip FROM agg_1m WHERE ts >= ? AND domain = '' AND remote_ip != '(unconnected)'
              AND remote_ip NOT IN (SELECT ip FROM ip_owners) LIMIT ?
            """, [.int(Int64(since.timeIntervalSince1970)), .int(Int64(limit))]) { $0.text(0) }
    }

    /// Share of bytes in the window that carry a hostname, and that have at least an owner.
    func coverage(since: Date) throws -> (named: Double, owned: Double) {
        let row = try conn.query("""
            SELECT SUM(bytes_in + bytes_out),
                   SUM(CASE WHEN domain != '' THEN bytes_in + bytes_out ELSE 0 END),
                   SUM(CASE WHEN domain != '' OR o.ip IS NOT NULL THEN bytes_in + bytes_out ELSE 0 END)
            FROM agg_1m LEFT JOIN ip_owners o ON o.ip = agg_1m.remote_ip
            WHERE ts >= ? AND remote_ip != '(unconnected)'
            """, [.int(Int64(since.timeIntervalSince1970))]) { ($0.double(0), $0.double(1), $0.double(2)) }.first
        guard let row, row.0 > 0 else { return (0, 0) }
        return (row.1 / row.0, row.2 / row.0)
    }

    // MARK: Alerts

    @discardableResult
    func addAlert(kind: String, bundleID: String, appName: String, detail: String, severity: Int, at date: Date = Date()) throws -> AlertRecord {
        let ts = Int64(date.timeIntervalSince1970)
        try conn.run("INSERT INTO alerts (ts, kind, bundle_id, app_name, detail, severity) VALUES (?,?,?,?,?,?)",
                     [.int(ts), .text(kind), .text(bundleID), .text(appName), .text(detail), .int(Int64(severity))])
        let id = try conn.query("SELECT last_insert_rowid()") { $0.int(0) }.first ?? 0
        return AlertRecord(id: id, timestamp: date, kind: kind, bundleID: bundleID, appName: appName, detail: detail,
                           severity: severity, acknowledged: false)
    }

    func alerts(limit: Int = 500) throws -> [AlertRecord] {
        try conn.query("SELECT id, ts, kind, bundle_id, app_name, detail, severity, acknowledged FROM alerts ORDER BY ts DESC, id DESC LIMIT ?",
                       [.int(Int64(limit))]) { r in
            AlertRecord(id: r.int(0), timestamp: Date(timeIntervalSince1970: TimeInterval(r.int(1))), kind: r.text(2),
                        bundleID: r.text(3), appName: r.text(4), detail: r.text(5), severity: Int(r.int(6)), acknowledged: r.int(7) != 0)
        }
    }

    func unacknowledgedAlertCount() throws -> Int {
        Int(try conn.query("SELECT COUNT(*) FROM alerts WHERE acknowledged = 0") { $0.int(0) }.first ?? 0)
    }

    func acknowledgeAlerts(ids: [Int64]?) throws {
        if let ids {
            try conn.transaction { for id in ids { try conn.run("UPDATE alerts SET acknowledged = 1 WHERE id = ?", [.int(id)]) } }
        } else {
            try conn.run("UPDATE alerts SET acknowledged = 1")
        }
    }

    func clearAll() throws {
        try conn.transaction {
            for t in Self.tables + ["rollup_state", "seen_destinations", "seen_ports", "apps", "baselines", "alerts"] {
                try conn.run("DELETE FROM \(t)")
            }
        }
    }

    // MARK: Serialized access helpers

    func sync<T>(_ body: (TrafficDatabase) throws -> T) rethrows -> T { try queue.sync { try body(self) } }

    func async(_ body: @escaping (TrafficDatabase) throws -> Void) {
        queue.async {
            do { try body(self) } catch { appLog.error("db error: \(String(describing: error), privacy: .public)") }
        }
    }
}
