import Foundation
import os.log
import Security

let appLog = Logger(subsystem: FlowlightConstants.hostBundleIdentifier, category: "app")

enum Granularity: String, CaseIterable, Identifiable, Sendable {
    case second, minute, hour, day, week, month, year
    var id: String { rawValue }
    /// Spelled out rather than capitalised from the raw value: `rawValue.capitalized` is an English rule, and
    /// these name the Reports picker's buttons.
    var title: String {
        switch self {
        case .second: return L("Second")
        case .minute: return L("Minute")
        case .hour: return L("Hour")
        case .day: return L("Day")
        case .week: return L("Week")
        case .month: return L("Month")
        case .year: return L("Year")
        }
    }

    /// Source table for the granularity; week/month/year are bucketed from daily rows.
    var table: String {
        switch self {
        case .second: return "flows_1s"
        case .minute: return "agg_1m"
        case .hour: return "agg_1h"
        case .day, .week, .month, .year: return "agg_1d"
        }
    }

    /// How the window reads in a sentence, e.g. "the last 3 days".
    var periodName: String {
        switch self {
        case .second: return L("the last 5 minutes")
        case .minute: return L("the last 3 hours")
        case .hour: return L("the last 3 days")
        case .day: return L("the last 30 days")
        case .week: return L("the last 6 months")
        case .month: return L("the last 2 years")
        case .year: return L("this report")
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
    /// Include rows attributed to `bundleID` as children of that agent root.
    var includeAttributedChildren = false
    /// Exact stored process-lineage parent. Unlike `includeAttributedChildren`, this never matches the root process.
    var agentParent: String?
    /// Exact stored MCP attribution.
    var mcpServer: String?
    var domain: String?
    var remoteIP: String?
    /// Network owner (AS name) for traffic without a hostname.
    var owner: String?
    /// Registrable domain: matches the domain itself and every subdomain (e.g. google.com, *.google.com).
    var domainSuffix: String?
    var appProtocol: String?
    /// Narrow to one way out of the Mac — the network, the peer-to-peer radio, this Mac, a tunnel.
    var channel: NetworkChannel?
    /// Focus mode, ANDed in as "and one of these": see `FocusScope`. Empty means no restriction.
    var focus: FocusScope = .none

    static let none = TrafficFilter()
    /// Focus isn't part of this: it's applied to every query rather than chosen on a screen, so a view that asks
    /// "did the user narrow anything?" should get the same answer whether or not Focus happens to be on.
    var isEmpty: Bool {
        bundleID == nil && agentParent == nil && mcpServer == nil && domain == nil && remoteIP == nil
            && owner == nil && domainSuffix == nil && appProtocol == nil && channel == nil
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
    /// Set when this process works for an AI agent (see `FlowKey.parentAgent`).
    var parentAgent: String = ""
    var parentAgentName: String = ""
    var mcpServer: String = ""
    /// Which way these bytes left the Mac. Ordinary network traffic unless something said otherwise.
    var channel: NetworkChannel = .ip
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
    /// What "Allow from now on" would add to `bundleID`'s allowlist, for alerts that come from one. Empty for
    /// every other kind, which is what hides the offer.
    var allowPattern: String = ""
}

/// One decision a rule made, as the violations feed shows it.
struct RuleEventRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var timestamp: Date
    var ruleID: UUID
    var action: Rule.Action
    var engine: Rule.Engine
    var bundleID: String
    var appName: String
    var agentKey: String
    var agentName: String
    var host: String
    var ip: String
    var port: UInt16
    var path: String
    var method: String

    var destination: String { host.isEmpty ? ip : host }
}

/// Aggregated managed-pack activity. One row may represent many matching connections in a minute; pack activity
/// answers what was blocked without turning every ad request into an alert or an unbounded event row.
struct RulePackEventRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var bucket: Date
    var packID: String
    var packVersion: String
    var entryID: UInt32
    var category: RulePackEntry.Category
    var match: RulePackEntry.Match
    var action: RulePackEvent.Action
    var count: Int
    var firstAt: Date
    var lastAt: Date
    var bundleID: String
    var appName: String
    var agentKey: String
    var agentName: String
    var host: String
    var matchedHost: String
    var port: UInt16
}

/// SQLite store (App Group container) with tiered rollups:
/// flows_1s → agg_1m (complete minutes) → agg_1h / agg_1d (folded from immutable minute rows).
final class TrafficDatabase: @unchecked Sendable {
    static let tables = ["flows_1s", "agg_1m", "agg_1h", "agg_1d"]
    private static let rulePackEventKey = [
        "bucket", "pack_id", "pack_version", "entry_id", "category", "match", "action",
        "bundle_id", "app_name", "agent", "agent_name", "host", "matched_host", "port",
    ]
    private static let rulePackEventKeySQL = rulePackEventKey.joined(separator: ", ")
    let queue = DispatchQueue(label: "flowlight.db", qos: .userInitiated)
    private let conn: SQLiteConnection
    let url: URL

    /// Always Application Support, so history survives a build gaining (or losing) the App Group entitlement and
    /// a change of Team ID. The extension never opens the database; it only shares the group for its XPC service.
    /// A database left in the group container by an earlier build is adopted once.
    static func defaultURL() -> URL {
        let fm = FileManager.default
        // Touching an un-entitled group container can trigger a "would like to access data from other apps" prompt.
        #if APP_STORE
        // A Store build's Application Support is inside its sandbox. Do not silently move a direct build's live
        // database—or an old App Group WAL—across channels; a future import must be explicit and transactional.
        let groupURL: URL? = nil
        #else
        let groupURL = hasAppGroupEntitlement
            ? fm.containerURL(forSecurityApplicationGroupIdentifier: FlowlightConstants.appGroupIdentifier) : nil
        #endif
        return resolveURL(appSupport: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], group: groupURL, fm: fm)
    }

    /// `<appSupport>/Flowlight/traffic.sqlite`, moving an older database out of `group` if this is the first run
    /// without one there. Moves the WAL and shared-memory files with it, so no committed data is lost.
    static func resolveURL(appSupport: URL, group: URL?, fm: FileManager = .default) -> URL {
        let base = appSupport.appendingPathComponent("Flowlight")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("traffic.sqlite")
        guard !fm.fileExists(atPath: target.path), let group else { return target }
        let legacy = group.appendingPathComponent("traffic.sqlite")
        guard fm.fileExists(atPath: legacy.path) else { return target }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix), to = URL(fileURLWithPath: target.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do { try fm.moveItem(at: from, to: to) } catch { try? fm.copyItem(at: from, to: to) }
        }
        return target
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

    /// One-time repair: agents that were recorded under a version number instead of their name.
    ///
    /// `proc_pidpath` fails for a process that has already exited, and the fallback is the executable's
    /// filename — which, for an installer that keeps one file per release, is the version. So Claude Code
    /// arrived in the database as `2.1.260`, then `2.1.267`, then `2.1.283`: a fresh identity every update,
    /// each with its own allowlist, its own baselines and its own slice of the history.
    ///
    /// Fixing the naming stops new rows going in wrong. It does nothing for the ones already there, and daily
    /// totals are kept indefinitely — so without this the bug stays on screen forever and reads as unfixed.
    /// A read for tests to check what a migration actually did to the rows. Not part of the app's own surface:
    /// everything the app reads has a named method, so a query written at a call site would be a query nobody
    /// maintains.
    func raw<T>(_ sql: String, _ values: [SQLValue] = [], map: (SQLRow) -> T) throws -> [T] {
        try conn.query(sql, values, map: map)
    }

    /// Internal rather than private so a test can run it against a database it has filled: the repair happens
    /// once, at first open, which leaves no way to exercise it afterwards through the public surface.
    func repairVersionedNames() throws {
        // What each version belongs to, learned from the rows that did keep a path.
        var realName: [String: (id: String, name: String)] = [:]
        for table in Self.tables {
            for (bundleID, path) in try conn.query(
                "SELECT DISTINCT bundle_id, app_path FROM \(table) WHERE app_path <> ''", map: { ($0.text(0), $0.text(1)) }) {
                guard ProcessNaming.isVersion(bundleID) else { continue }
                let derived = ProcessNaming.displayName(path: path)
                guard !derived.isEmpty, !ProcessNaming.isVersion(derived) else { continue }
                realName[bundleID] = (derived, ProcessNaming.friendlyName(executable: derived))
            }
        }
        guard !realName.isEmpty else { return }

        let columns = "ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, " +
                      "bytes_in, bytes_out, flows, agent_parent, agent_parent_name, mcp_server, channel, " +
                      "attribution_exact, attribution_epoch"
        for (version, real) in realName {
            for table in Self.tables {
                // Re-inserted rather than updated, because `bundle_id` is part of the unique key: renaming can
                // collide with a row already under the real name, and the two are the same traffic counted
                // twice. The upsert adds the byte counts together instead of letting one overwrite the other.
                try conn.run("""
                    INSERT INTO \(table) (\(columns))
                    SELECT ts, pid, ?, ?, app_path, remote_ip, domain, port, transport, protocol,
                           bytes_in, bytes_out, flows, agent_parent, agent_parent_name, mcp_server, channel,
                           attribution_exact, attribution_epoch
                    FROM \(table) WHERE bundle_id = ?
                    ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch)
                    DO UPDATE SET bytes_in = bytes_in + excluded.bytes_in,
                                  bytes_out = bytes_out + excluded.bytes_out,
                                  flows = flows + excluded.flows;
                    """, [.text(real.id), .text(real.name), .text(version)])
                try conn.run("DELETE FROM \(table) WHERE bundle_id = ?", [.text(version)])
            }
            // Everything else keyed by the identity follows it, or the agent keeps a split history by another route.
            for (table, column) in [("seen_destinations", "bundle_id"), ("seen_ports", "bundle_id"),
                                    ("baselines", "bundle_id"), ("alerts", "bundle_id"), ("apps", "bundle_id"),
                                    ("agent_policies", "agent_id"), ("http_exchanges", "bundle_id")] {
                try conn.run("UPDATE OR IGNORE \(table) SET \(column) = ? WHERE \(column) = ?",
                                 [.text(real.id), .text(version)])
            }
            try conn.run("UPDATE http_exchanges SET app_name = ? WHERE app_name = ?", [.text(real.name), .text(version)])
            try conn.run("UPDATE alerts SET app_name = ? WHERE app_name = ?", [.text(real.name), .text(version)])
            try conn.run("DELETE FROM apps WHERE bundle_id = ?", [.text(version)])
        }
    }

    private func migrate() throws {
        for table in Self.tables {
            try conn.execute("""
            CREATE TABLE IF NOT EXISTS \(table) (
                ts INTEGER NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
                app_path TEXT NOT NULL, remote_ip TEXT NOT NULL, domain TEXT NOT NULL, port INTEGER NOT NULL,
                transport TEXT NOT NULL, protocol TEXT NOT NULL,
                bytes_in INTEGER NOT NULL DEFAULT 0, bytes_out INTEGER NOT NULL DEFAULT 0, flows INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS \(table)_app ON \(table)(bundle_id, ts);
            """)
            // v0.1.2 added agent attribution. Parent and MCP identity became key parts in 0.16.0 so traffic
            // from one executable working for different agents or MCP services cannot merge before visualization.
            let columns = Set(try conn.query("PRAGMA table_info(\(table))") { $0.text(1) })
            for column in ["agent_parent", "agent_parent_name", "mcp_server"] where !columns.contains(column) {
                try conn.execute("ALTER TABLE \(table) ADD COLUMN \(column) TEXT NOT NULL DEFAULT ''")
            }
            // `_key2` treated attribution as mutable metadata, so one row may already contain bytes from several
            // parents while retaining one arbitrary label. A prerelease `_key3` upgrade could not recover that
            // provenance either. Preserve every field and counter; the epoch below identifies corrected writes.
            if !columns.contains("attribution_exact") {
                try conn.execute("ALTER TABLE \(table) ADD COLUMN attribution_exact INTEGER NOT NULL DEFAULT 0")
            }
            // The first provenance bit existed in prerelease builds that could promote already-merged `_key2`
            // history. Keep every stored field and counter untouched, but require a second epoch bit that only the
            // corrected schema writes. Existing `_key4` rows therefore remain queryable ordinary traffic without
            // being accepted as lineage evidence.
            if !columns.contains("attribution_epoch") {
                try conn.execute("ALTER TABLE \(table) ADD COLUMN attribution_epoch INTEGER NOT NULL DEFAULT 0")
            }
            // v0.4.0: which way the bytes left the Mac. It joins the unique key rather than riding along as an
            // attribute — the same app on the same port over Wi-Fi and over AWDL is two different things, and
            // merging them is exactly how peer-to-peer traffic stayed invisible. Existing rows default to the
            // ordinary network, which is what they were.
            if !columns.contains("channel") {
                try conn.execute("ALTER TABLE \(table) ADD COLUMN channel TEXT NOT NULL DEFAULT ''")
            }
            // Rebuild the unique key as attribution evolves. SQLite cannot alter an index in place.
            try conn.execute("""
            DROP INDEX IF EXISTS \(table)_key;
            DROP INDEX IF EXISTS \(table)_key2;
            DROP INDEX IF EXISTS \(table)_key3;
            DROP INDEX IF EXISTS \(table)_key4;
            CREATE UNIQUE INDEX IF NOT EXISTS \(table)_key5 ON \(table)(
                ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel,
                agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch
            );
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
        CREATE TABLE IF NOT EXISTS agent_policies (agent_id TEXT PRIMARY KEY, policy TEXT NOT NULL, updated INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS http_exchanges (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, duration REAL NOT NULL,
            scheme TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL, status INTEGER,
            req_headers TEXT NOT NULL, req_body BLOB, req_size INTEGER NOT NULL, req_truncated INTEGER NOT NULL,
            resp_headers TEXT NOT NULL, resp_body BLOB, resp_size INTEGER NOT NULL, resp_truncated INTEGER NOT NULL,
            content_type TEXT NOT NULL, pid INTEGER NOT NULL, bundle_id TEXT NOT NULL, app_name TEXT NOT NULL,
            agent TEXT NOT NULL, agent_name TEXT NOT NULL, mcp_server TEXT NOT NULL, tool_calls TEXT NOT NULL, note TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS http_exchanges_ts ON http_exchanges (ts);
        -- Derived, local-only analysis. It intentionally stores a bounded redacted candidate and result instead of
        -- adding interpretation fields to immutable capture rows or re-saving any request/response body.
        CREATE TABLE IF NOT EXISTS local_risk_assessments (
            exchange_id INTEGER PRIMARY KEY,
            analyzer_version INTEGER NOT NULL,
            state TEXT NOT NULL,
            severity TEXT NOT NULL DEFAULT '',
            confidence REAL,
            summary TEXT NOT NULL DEFAULT '',
            evidence TEXT NOT NULL,
            model_evidence_ids TEXT NOT NULL DEFAULT '[]',
            candidate TEXT NOT NULL,
            created_at REAL NOT NULL,
            scored_at REAL
        );
        CREATE INDEX IF NOT EXISTS local_risk_assessments_state_created ON local_risk_assessments (state, created_at);
        CREATE INDEX IF NOT EXISTS local_risk_assessments_severity_created ON local_risk_assessments (severity, created_at);
        CREATE TABLE IF NOT EXISTS plugins (
            id TEXT PRIMARY KEY,
            manifest TEXT NOT NULL,
            enabled INTEGER NOT NULL,
            updated INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS plugin_findings (
            id TEXT PRIMARY KEY,
            exchange_id INTEGER NOT NULL,
            plugin_id TEXT NOT NULL,
            plugin_version TEXT NOT NULL,
            kind TEXT NOT NULL,
            severity TEXT NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            evidence TEXT NOT NULL,
            suggested_guardrail TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            UNIQUE(exchange_id, plugin_id, title)
        );
        CREATE INDEX IF NOT EXISTS plugin_findings_exchange ON plugin_findings (exchange_id);
        CREATE INDEX IF NOT EXISTS plugin_findings_plugin_created ON plugin_findings (plugin_id, created_at);
        """)
        let pluginFindingColumns = Set(try conn.query("PRAGMA table_info(plugin_findings)") { $0.text(1) })
        if !pluginFindingColumns.contains("suggested_rule") {
            try conn.execute("ALTER TABLE plugin_findings ADD COLUMN suggested_rule TEXT NOT NULL DEFAULT ''")
        }
        if !pluginFindingColumns.contains("suggested_actions") {
            try conn.execute("ALTER TABLE plugin_findings ADD COLUMN suggested_actions TEXT NOT NULL DEFAULT ''")
        }
        // Added with blocking: the destination a refused connection was headed for, so its alert can offer to
        // allow it without parsing the sentence back out of `detail`.
        let alertColumns = Set(try conn.query("PRAGMA table_info(alerts)") { $0.text(1) })
        if !alertColumns.contains("allow_pattern") {
            try conn.execute("ALTER TABLE alerts ADD COLUMN allow_pattern TEXT NOT NULL DEFAULT ''")
        }
        // Added in 0.1.5.
        let exchangeColumns = Set(try conn.query("PRAGMA table_info(http_exchanges)") { $0.text(1) })
        for column in ["tool_results", "mcp", "llm"] where !exchangeColumns.contains(column) {
            try conn.execute("ALTER TABLE http_exchanges ADD COLUMN \(column) TEXT NOT NULL DEFAULT ''")
        }
        // Added with mock responses: which rule answered, empty when the host itself did. Its own column rather
        // than a flag in `note`, so an older recording stays what it was — everything in it really happened.
        if !exchangeColumns.contains("mock_rule") {
            try conn.execute("ALTER TABLE http_exchanges ADD COLUMN mock_rule TEXT NOT NULL DEFAULT ''")
        }
        // Added with guardrails: what was taken out of this request before it left.
        if !exchangeColumns.contains("guardrail") {
            try conn.execute("ALTER TABLE http_exchanges ADD COLUMN guardrail TEXT NOT NULL DEFAULT ''")
        }
        // Unlike a mock, this names a response the origin really sent before Flowlight changed it for the client.
        if !exchangeColumns.contains("response_transform") {
            try conn.execute("ALTER TABLE http_exchanges ADD COLUMN response_transform TEXT NOT NULL DEFAULT ''")
        }
        // Added with rules: the rule list itself, and every connection a rule decided. The decisions are their own
        // table rather than only alerts — an alert is a thing that happened once, and a violations feed has to be
        // answerable by rule ("what has this one refused?") as well as by time.
        try conn.execute("""
        CREATE TABLE IF NOT EXISTS rules (id TEXT PRIMARY KEY, rule TEXT NOT NULL, updated INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS guardrails (id TEXT PRIMARY KEY, guardrail TEXT NOT NULL, updated INTEGER NOT NULL);
        -- Channels that aren't the network: what connected, what went away, and when. No byte counts, because
        -- macOS doesn't account for these per app and Flowlight won't invent a number.
        CREATE TABLE IF NOT EXISTS device_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
            kind TEXT NOT NULL, device_id TEXT NOT NULL, name TEXT NOT NULL, detail TEXT NOT NULL, change TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS device_events_ts ON device_events(ts);
        CREATE TABLE IF NOT EXISTS rule_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
            rule_id TEXT NOT NULL, action TEXT NOT NULL, engine TEXT NOT NULL, bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL, agent TEXT NOT NULL, agent_name TEXT NOT NULL, host TEXT NOT NULL,
            ip TEXT NOT NULL, port INTEGER NOT NULL, path TEXT NOT NULL, method TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS rule_events_ts ON rule_events(ts);
        CREATE INDEX IF NOT EXISTS rule_events_rule ON rule_events(rule_id, ts);
        -- Managed packs keep only user state here. The verified entry lists remain in the signed app bundle.
        CREATE TABLE IF NOT EXISTS rule_packs (
            pack_id TEXT PRIMARY KEY, configuration TEXT NOT NULL, updated INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_pack_reviews (
            pack_id TEXT PRIMARY KEY, required INTEGER NOT NULL, updated INTEGER NOT NULL);
        -- The anti-rollback receipt is deliberately independent from the cached bytes. A corrupt or missing cache
        -- must never make a previously accepted sequence disappear and permit the bundled sequence again.
        CREATE TABLE IF NOT EXISTS rule_pack_catalog_receipts (
            catalog_id TEXT PRIMARY KEY, highest_sequence INTEGER NOT NULL,
            canonical_digest TEXT NOT NULL, signer_key_id TEXT NOT NULL, accepted_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_pack_catalog_cache (
            catalog_id TEXT PRIMARY KEY, raw_envelope BLOB NOT NULL, etag TEXT,
            last_modified TEXT, verified_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_pack_catalog_updates (
            catalog_id TEXT PRIMARY KEY, automatic_refresh INTEGER NOT NULL DEFAULT 1,
            last_attempt INTEGER, last_success INTEGER, next_eligible_attempt INTEGER,
            failure_count INTEGER NOT NULL DEFAULT 0, last_status TEXT, last_error TEXT);
        CREATE TABLE IF NOT EXISTS rule_pack_overrides (
            id TEXT PRIMARY KEY, override TEXT NOT NULL, updated INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_pack_event_rollups (
            id INTEGER PRIMARY KEY AUTOINCREMENT, bucket INTEGER NOT NULL, pack_id TEXT NOT NULL,
            pack_version TEXT NOT NULL, entry_id INTEGER NOT NULL, category TEXT NOT NULL,
            match TEXT NOT NULL DEFAULT 'suffix', action TEXT NOT NULL,
            count INTEGER NOT NULL, first_at INTEGER NOT NULL, last_at INTEGER NOT NULL,
            bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, agent TEXT NOT NULL, agent_name TEXT NOT NULL,
            host TEXT NOT NULL, matched_host TEXT NOT NULL, port INTEGER NOT NULL,
            UNIQUE(\(Self.rulePackEventKeySQL)));
        CREATE TABLE IF NOT EXISTS rule_pack_event_watermarks (
            delivery_session TEXT PRIMARY KEY, sequence INTEGER NOT NULL, received INTEGER NOT NULL,
            dropped_hits INTEGER NOT NULL, dropped_keys INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS rule_pack_events_time ON rule_pack_event_rollups(bucket DESC);
        CREATE INDEX IF NOT EXISTS rule_pack_events_pack ON rule_pack_event_rollups(pack_id, bucket DESC);
        """)
        let packEventKeyVersion = try conn.query(
            "SELECT watermark FROM rollup_state WHERE tier = 'schema.rulePackEventKey'",
            map: { $0.int(0) }
        ).first ?? 0
        let packEventIndexes = try conn.query("PRAGMA index_list(rule_pack_event_rollups)") {
            (name: $0.text(1), unique: $0.int(2) == 1, partial: $0.int(4) == 1)
        }
        let hasCurrentPackEventKey = try packEventIndexes
            .filter { $0.unique && !$0.partial }
            .contains { index in
                let quoted = index.name.replacingOccurrences(of: "'", with: "''")
                return try conn.query("PRAGMA index_info('\(quoted)')") { $0.text(2) } == Self.rulePackEventKey
            }
        if packEventKeyVersion < 2 || !hasCurrentPackEventKey {
            let oldPackEventColumns = Set(try conn.query("PRAGMA table_info(rule_pack_event_rollups)") { $0.text(1) })
            let oldMatch = oldPackEventColumns.contains("match") ? "match" : "'suffix'"
            try conn.transaction {
                try conn.execute("""
                CREATE TABLE rule_pack_event_rollups_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, bucket INTEGER NOT NULL, pack_id TEXT NOT NULL,
                    pack_version TEXT NOT NULL, entry_id INTEGER NOT NULL, category TEXT NOT NULL,
                    match TEXT NOT NULL DEFAULT 'suffix', action TEXT NOT NULL,
                    count INTEGER NOT NULL, first_at INTEGER NOT NULL, last_at INTEGER NOT NULL,
                    bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, agent TEXT NOT NULL, agent_name TEXT NOT NULL,
                    host TEXT NOT NULL, matched_host TEXT NOT NULL, port INTEGER NOT NULL,
                    UNIQUE(bucket, pack_id, pack_version, entry_id, category, match, action, bundle_id, app_name,
                           agent, agent_name, host, matched_host, port));
                INSERT INTO rule_pack_event_rollups_v2
                    (id, bucket, pack_id, pack_version, entry_id, category, match, action, count, first_at, last_at,
                     bundle_id, app_name, agent, agent_name, host, matched_host, port)
                    SELECT id, bucket, pack_id, pack_version, entry_id, category, \(oldMatch), action, count, first_at, last_at,
                           bundle_id, app_name, agent, agent_name, host, matched_host, port
                    FROM rule_pack_event_rollups;
                DROP TABLE rule_pack_event_rollups;
                ALTER TABLE rule_pack_event_rollups_v2 RENAME TO rule_pack_event_rollups;
                CREATE INDEX rule_pack_events_time ON rule_pack_event_rollups(bucket DESC);
                CREATE INDEX rule_pack_events_pack ON rule_pack_event_rollups(pack_id, bucket DESC);
                INSERT OR REPLACE INTO rollup_state (tier, watermark) VALUES ('schema.rulePackEventKey', 2);
                """)
            }
        }

        // Runs once. `rollup_state` already exists to remember how far a job has got, so the repair uses it
        // rather than introducing a second way to record the same kind of fact.
        let repaired = try conn.query("SELECT watermark FROM rollup_state WHERE tier = 'repair.versionedNames'",
                                      map: { $0.int(0) }).first
        if repaired == nil {
            try conn.transaction { try repairVersionedNames() }
            try conn.execute("INSERT OR REPLACE INTO rollup_state (tier, watermark) VALUES ('repair.versionedNames', 1)")
        }
    }

    // MARK: Ingest

    func insert(_ batches: [TrafficBatch]) throws {
        let sql = """
        INSERT INTO flows_1s (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows,
                              agent_parent, agent_parent_name, mcp_server, channel,
                              attribution_exact, attribution_epoch)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,1)
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out, flows = flows + excluded.flows,
            agent_parent = CASE WHEN excluded.agent_parent != '' THEN excluded.agent_parent ELSE agent_parent END,
            agent_parent_name = CASE WHEN excluded.agent_parent_name != '' THEN excluded.agent_parent_name ELSE agent_parent_name END,
            mcp_server = CASE WHEN excluded.mcp_server != '' THEN excluded.mcp_server ELSE mcp_server END
        """
        try conn.transaction {
            for batch in batches {
                for r in batch.records {
                    let k = r.key
                    try conn.run(sql, [.int(batch.timestamp), .int(Int64(k.pid)), .text(k.bundleID), .text(k.appName),
                                       .text(k.appPath), .text(k.remoteIP), .text(k.domain), .int(Int64(k.port)),
                                       .text(k.transport.rawValue), .text(k.appProtocol), .int(r.counters.bytesIn),
                                       .int(r.counters.bytesOut), .int(r.counters.flows),
                                       .text(k.parentAgent ?? ""), .text(k.parentAgentName ?? ""), .text(k.mcpServer ?? ""),
                                       .text(k.channel.rawValue)])
                }
            }
        }
    }

    /// Writes pre-aggregated rows straight into a tier (demo data and imports). Callers own consistency.
    ///
    /// `channel` joined the unique key in 0.4.0 and the eight-column index was dropped, but this statement kept
    /// naming it — so it couldn't be prepared at all, and every seeded row was silently lost. Demo mode had no
    /// history from that release on, which is also why the published screenshots stopped being reproducible.
    func insertAggregates(_ table: String, _ rows: [(ts: Int64, key: FlowKey, counters: FlowCounters)]) throws {
        precondition(Self.tables.contains(table))
        let sql = """
        INSERT INTO \(table) (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows,
                              agent_parent, agent_parent_name, mcp_server, channel,
                              attribution_exact, attribution_epoch)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,1)
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch) DO UPDATE SET
            bytes_in = bytes_in + excluded.bytes_in, bytes_out = bytes_out + excluded.bytes_out, flows = flows + excluded.flows,
            agent_parent = CASE WHEN excluded.agent_parent != '' THEN excluded.agent_parent ELSE agent_parent END,
            agent_parent_name = CASE WHEN excluded.agent_parent_name != '' THEN excluded.agent_parent_name ELSE agent_parent_name END,
            mcp_server = CASE WHEN excluded.mcp_server != '' THEN excluded.mcp_server ELSE mcp_server END
        """
        try conn.transaction {
            for r in rows {
                let k = r.key
                try conn.run(sql, [.int(r.ts), .int(Int64(k.pid)), .text(k.bundleID), .text(k.appName), .text(k.appPath),
                                   .text(k.remoteIP), .text(k.domain), .int(Int64(k.port)), .text(k.transport.rawValue),
                                   .text(k.appProtocol), .int(r.counters.bytesIn), .int(r.counters.bytesOut), .int(r.counters.flows),
                                   .text(k.parentAgent ?? ""), .text(k.parentAgentName ?? ""), .text(k.mcpServer ?? ""),
                                   .text(k.channel.rawValue)])
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
        INSERT INTO \(target) (ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol, bytes_in, bytes_out, flows,
                               agent_parent, agent_parent_name, mcp_server, channel,
                               attribution_exact, attribution_epoch)
        SELECT \(bucket), pid, bundle_id, MAX(app_name), MAX(app_path), remote_ip, domain, port, transport, protocol,
               SUM(bytes_in), SUM(bytes_out), SUM(flows), agent_parent, agent_parent_name, mcp_server, channel,
               attribution_exact, attribution_epoch
        FROM \(source) WHERE ts >= ? AND ts < ?
        GROUP BY 1, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel,
                 agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch
        ON CONFLICT(ts, pid, bundle_id, remote_ip, domain, port, transport, protocol, channel, agent_parent, agent_parent_name, mcp_server, attribution_exact, attribution_epoch) DO UPDATE SET
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

    private func whereClause(from: Date, to: Date, filter: TrafficFilter,
                             includeAttributedChildren: Bool = false) -> (String, [SQLValue]) {
        var clauses = ["ts >= ?", "ts < ?"]
        var values: [SQLValue] = [.int(Int64(from.timeIntervalSince1970)), .int(Int64(to.timeIntervalSince1970))]
        let includeChildren = includeAttributedChildren || filter.includeAttributedChildren
        if let v = filter.bundleID {
            clauses.append(includeChildren
                ? "(bundle_id = ? OR (attribution_exact = 1 AND attribution_epoch = 1 AND agent_parent = ?))"
                : "bundle_id = ?")
            values.append(.text(v))
            if includeChildren { values.append(.text(v)) }
        }
        if let v = filter.agentParent {
            clauses.append("attribution_exact = 1 AND attribution_epoch = 1 AND agent_parent = ?")
            values.append(.text(v))
        }
        if let v = filter.mcpServer {
            clauses.append("attribution_exact = 1 AND attribution_epoch = 1 AND mcp_server = ?")
            values.append(.text(v))
        }
        if let v = filter.domain { clauses.append("domain = ?"); values.append(.text(v)) }
        if let v = filter.remoteIP { clauses.append("remote_ip = ?"); values.append(.text(v)) }
        if let v = filter.owner { clauses.append("remote_ip IN (SELECT ip FROM ip_owners WHERE owner = ?)"); values.append(.text(v)) }
        if let v = filter.domainSuffix {
            clauses.append("(domain = ? OR domain LIKE ?)")
            values.append(.text(v)); values.append(.text("%." + v))
        }
        if let v = filter.appProtocol { clauses.append("protocol = ?"); values.append(.text(v)) }
        if let v = filter.channel { clauses.append("channel = ?"); values.append(.text(v.rawValue)) }
        if let (clause, focusValues) = Self.focusClause(
            filter.focus,
            includeAttributedChildren: includeChildren || filter.agentParent != nil || filter.mcpServer != nil
        ) {
            clauses.append(clause)
            values += focusValues
        }
        return (clauses.joined(separator: " AND "), values)
    }

    /// Focus as one OR-group over the flow columns: any listed app, or any listed destination.
    /// Returns nil when nothing is focused, so the caller adds no clause at all.
    static func focusClause(_ focus: FocusScope, bundleColumn: String = "bundle_id",
                            includeAttributedChildren: Bool = false) -> (String, [SQLValue])? {
        guard !focus.isEmpty else { return nil }
        var parts: [String] = []
        var values: [SQLValue] = []
        if !focus.bundleIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: focus.bundleIDs.count).joined(separator: ",")
            parts.append(includeAttributedChildren
                         ? "(\(bundleColumn) IN (\(placeholders)) OR (attribution_exact = 1 AND attribution_epoch = 1 AND agent_parent IN (\(placeholders))))"
                         : "\(bundleColumn) IN (\(placeholders))")
            values += focus.bundleIDs.map { .text($0) }
            if includeAttributedChildren { values += focus.bundleIDs.map { .text($0) } }
        }
        for host in focus.hosts {
            if AgentPolicy.isIPAddress(host) {
                parts.append("remote_ip = ?")
                values.append(.text(host))
            } else {
                parts.append("(domain = ? OR domain LIKE ?)")
                values.append(.text(host))
                values.append(.text("%." + host))
            }
        }
        return ("(" + parts.joined(separator: " OR ") + ")", values)
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
                       SUM(bytes_in) AS bin, SUM(bytes_out) AS bout, SUM(flows),
                       MAX(agent_parent), MAX(agent_parent_name), MAX(mcp_server), channel
                FROM \(granularity.table) WHERE \(clause)
                GROUP BY bundle_id, domain, remote_ip, channel
                ORDER BY bin + bout DESC LIMIT \(limit)
            ) t LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { row in
            BreakdownRow(bundleID: row.text(0), appName: row.text(1), appPath: row.text(2), domain: row.text(3),
                         remoteIP: row.text(4), ports: row.text(5), protocols: row.text(6),
                         counters: FlowCounters(bytesIn: row.int(7), bytesOut: row.int(8), flows: row.int(9)),
                         owner: row.text(14), asn: Int(row.int(15)),
                         parentAgent: row.text(10), parentAgentName: row.text(11), mcpServer: row.text(12),
                         channel: NetworkChannel(rawValue: row.text(13)) ?? .ip)
        }
    }

    /// Every app's destinations, with no row cap.
    ///
    /// `breakdown` stops at `breakdownLimit` because it feeds a table someone scrolls. Anything judging apps
    /// against each other has to see them all, or an app past the cap is quietly never considered — and the cap
    /// is reached exactly on the busy machines where that matters. Grouping by app and destination rather than
    /// by app, domain and IP keeps this far smaller than the breakdown it replaces.
    func appDestinationRows(_ granularity: Granularity, from: Date, to: Date,
                            filter: TrafficFilter = .none) throws -> [BreakdownRow] {
        let (clause, values) = whereClause(from: from, to: to, filter: filter)
        return try conn.query("""
            SELECT t.*, COALESCE(o.owner, ''), COALESCE(o.asn, 0) FROM (
                SELECT bundle_id, MAX(app_name), MAX(app_path), domain, remote_ip,
                       '', GROUP_CONCAT(DISTINCT protocol),
                       SUM(bytes_in) AS bin, SUM(bytes_out) AS bout, SUM(flows)
                FROM \(granularity.table) WHERE \(clause)
                GROUP BY bundle_id, domain, remote_ip
            ) t LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { row in
            BreakdownRow(bundleID: row.text(0), appName: row.text(1), appPath: row.text(2), domain: row.text(3),
                         remoteIP: row.text(4), ports: row.text(5), protocols: row.text(6),
                         counters: FlowCounters(bytesIn: row.int(7), bytesOut: row.int(8), flows: row.int(9)),
                         owner: row.text(10), asn: Int(row.int(11)))
        }
    }

    /// Uncapped rows for the AI topology. Attribution columns are grouping keys rather than `MAX` values so traffic
    /// from an agent and one of its tools cannot be merged before the graph establishes their evidence relationship.
    func aiVisualizationRows(_ granularity: Granularity, from: Date, to: Date,
                             filter: TrafficFilter = .none) throws -> [BreakdownRow] {
        let (clause, values) = whereClause(from: from, to: to, filter: filter,
                                           includeAttributedChildren: true)
        return try conn.query("""
            SELECT t.*, COALESCE(o.owner, ''), COALESCE(o.asn, 0) FROM (
                SELECT bundle_id, MAX(app_name), MAX(app_path), domain, remote_ip,
                       GROUP_CONCAT(DISTINCT port), GROUP_CONCAT(DISTINCT protocol),
                       SUM(bytes_in), SUM(bytes_out), SUM(flows),
                       CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN agent_parent ELSE '' END,
                       CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN agent_parent_name ELSE '' END,
                       CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN mcp_server ELSE '' END,
                       channel
                FROM \(granularity.table) WHERE \(clause)
                GROUP BY bundle_id, domain, remote_ip, attribution_exact, attribution_epoch,
                         CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN agent_parent ELSE '' END,
                         CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN agent_parent_name ELSE '' END,
                         CASE WHEN attribution_exact = 1 AND attribution_epoch = 1 THEN mcp_server ELSE '' END,
                         channel
            ) t LEFT JOIN ip_owners o ON o.ip = t.remote_ip
            """, values) { row in
            BreakdownRow(bundleID: row.text(0), appName: row.text(1), appPath: row.text(2), domain: row.text(3),
                         remoteIP: row.text(4), ports: row.text(5), protocols: row.text(6),
                         counters: FlowCounters(bytesIn: row.int(7), bytesOut: row.int(8), flows: row.int(9)),
                         owner: row.text(14), asn: Int(row.int(15)), parentAgent: row.text(10),
                         parentAgentName: row.text(11), mcpServer: row.text(12),
                         channel: NetworkChannel(rawValue: row.text(13)) ?? .ip)
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

    // MARK: Agent allowlists

    func loadPolicies() throws -> [String: AgentPolicy] {
        let rows = try conn.query("SELECT policy FROM agent_policies") { $0.text(0) }
        let policies = rows.compactMap { try? JSONDecoder().decode(AgentPolicy.self, from: Data($0.utf8)) }
        return Dictionary(policies.map { ($0.agentID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func savePolicy(_ policy: AgentPolicy) throws {
        let json = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
        try conn.run("""
            INSERT INTO agent_policies (agent_id, policy, updated) VALUES (?,?,?)
            ON CONFLICT(agent_id) DO UPDATE SET policy = excluded.policy, updated = excluded.updated
            """, [.text(policy.agentID), .text(json), .int(Int64(Date().timeIntervalSince1970))])
    }

    // MARK: Rules

    func loadRules() throws -> [Rule] {
        let rows = try conn.query("SELECT rule FROM rules ORDER BY updated") { $0.text(0) }
        return rows.compactMap { try? JSONDecoder().decode(Rule.self, from: Data($0.utf8)) }
    }

    func saveRule(_ rule: Rule) throws {
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try conn.run("""
            INSERT INTO rules (id, rule, updated) VALUES (?,?,?)
            ON CONFLICT(id) DO UPDATE SET rule = excluded.rule, updated = excluded.updated
            """, [.text(rule.id.uuidString), .text(json), .int(Int64(Date().timeIntervalSince1970))])
    }

    func deleteRule(_ id: UUID) throws {
        try conn.run("DELETE FROM rules WHERE id = ?", [.text(id.uuidString)])
    }

    func recordRuleEvents(_ events: [RuleEvent]) throws {
        try writeRuleEvents(events)
    }

    /// A bounded proxy decision is not carried out until both its spent count and visible explanation commit. Keeping
    /// them in one transaction prevents a crash between those writes from reopening a one-shot rule without history.
    func recordBoundedRuleDecision(rule: Rule, event: RuleEvent) throws {
        try conn.transaction {
            try saveRule(rule)
            try writeRuleEvents([event])
        }
    }

    private func writeRuleEvents(_ events: [RuleEvent]) throws {
        let sql = """
        INSERT INTO rule_events (ts, rule_id, action, engine, bundle_id, app_name, agent, agent_name, host, ip, port, path, method)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        for event in events {
            try conn.run(sql, [.int(event.at), .text(event.ruleID.uuidString), .text(event.action.rawValue),
                               .text(event.engine.rawValue), .text(event.bundleID), .text(event.appName),
                               .text(event.agentKey), .text(event.agentName), .text(event.host), .text(event.ip),
                               .int(Int64(event.port)), .text(event.path), .text(event.method)])
        }
    }

    /// The violations feed: every decision, newest first, optionally narrowed to one rule.
    func ruleEvents(ruleID: UUID? = nil, limit: Int = 500) throws -> [RuleEventRecord] {
        var sql = """
        SELECT id, ts, rule_id, action, engine, bundle_id, app_name, agent, agent_name, host, ip, port, path, method
        FROM rule_events
        """
        var bindings: [SQLValue] = []
        if let ruleID {
            sql += " WHERE rule_id = ?"
            bindings.append(.text(ruleID.uuidString))
        }
        sql += " ORDER BY ts DESC, id DESC LIMIT \(max(1, limit))"
        return try conn.query(sql, bindings) { row in
            RuleEventRecord(id: row.int(0), timestamp: Date(timeIntervalSince1970: TimeInterval(row.int(1))),
                            ruleID: UUID(uuidString: row.text(2)) ?? UUID(),
                            action: Rule.Action(rawValue: row.text(3)) ?? .block,
                            engine: Rule.Engine(rawValue: row.text(4)) ?? .flow,
                            bundleID: row.text(5), appName: row.text(6), agentKey: row.text(7),
                            agentName: row.text(8), host: row.text(9), ip: row.text(10),
                            port: UInt16(clamping: row.int(11)), path: row.text(12), method: row.text(13))
        }
    }

    /// Keeps the feed from growing without bound. Called with the same retention sweep as everything else.
    func pruneRuleEvents(before date: Date) throws {
        try conn.run("DELETE FROM rule_events WHERE ts < ?", [.int(Int64(date.timeIntervalSince1970))])
    }

    // MARK: Managed rule packs

    func loadRulePackConfigurations() throws -> [RulePackConfiguration] {
        try conn.query("SELECT configuration FROM rule_packs ORDER BY pack_id") { $0.text(0) }.compactMap {
            try? JSONDecoder().decode(RulePackConfiguration.self, from: Data($0.utf8))
        }
    }

    /// Catalog reconciliation is a security boundary. A malformed saved row must roll the transaction back rather
    /// than disappearing through the tolerant loader used by older UI reloads.
    private func loadRulePackConfigurationsStrictly() throws -> [RulePackConfiguration] {
        let rows = try conn.query("SELECT configuration FROM rule_packs ORDER BY pack_id") { $0.text(0) }
        return try rows.map { try JSONDecoder().decode(RulePackConfiguration.self, from: Data($0.utf8)) }
    }

    func saveRulePackConfiguration(_ configuration: RulePackConfiguration) throws {
        try writeRulePackConfiguration(configuration, updatedAt: Date())
    }

    func setRulePackReviewRequired(_ required: Bool, packID: String) throws {
        guard !packID.isEmpty else { throw RulePackCatalogPersistenceError.invalidReceipt }
        if required {
            try conn.run("""
                INSERT INTO rule_pack_reviews (pack_id, required, updated) VALUES (?,1,?)
                ON CONFLICT(pack_id) DO UPDATE SET required = 1, updated = excluded.updated
                """, [.text(packID), .int(Int64(Date().timeIntervalSince1970))])
        } else {
            try conn.run("DELETE FROM rule_pack_reviews WHERE pack_id = ?", [.text(packID)])
        }
    }

    func loadRulePackReviewPackIDs() throws -> Set<String> {
        Set(try conn.query("SELECT pack_id FROM rule_pack_reviews WHERE required = 1 ORDER BY pack_id") { $0.text(0) })
    }

    /// Compare-and-save for an editor that may have remained open across a catalog refresh. A receipt is optional only
    /// for narrowing enforcement. Enabling or acknowledging reviewed content rechecks the durable catalog watermark.
    func saveRulePackConfiguration(_ configuration: RulePackConfiguration,
                                   reviewed receipt: RulePackReviewReceipt?) throws {
        try conn.transaction {
            if let receipt {
                guard receipt.packID == configuration.packID,
                      receipt.version == configuration.consentedVersion,
                      receipt.contentSHA256 == configuration.consentedContentSHA256,
                      let durable = try loadRulePackCatalogReceipt(catalogID: RulePackCatalogVerifier.catalogID),
                      durable.sequence == receipt.catalogSequence,
                      durable.digest == receipt.catalogDigest else {
                    throw RulePackCatalogPersistenceError.staleReview
                }
            } else if configuration.enabled {
                throw RulePackCatalogPersistenceError.staleReview
            }
            try writeRulePackConfiguration(configuration, updatedAt: Date())
            if receipt != nil { try setRulePackReviewRequired(false, packID: configuration.packID) }
        }
    }

    private func writeRulePackConfiguration(_ configuration: RulePackConfiguration, updatedAt: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        try conn.run("""
            INSERT INTO rule_packs (pack_id, configuration, updated) VALUES (?,?,?)
            ON CONFLICT(pack_id) DO UPDATE SET configuration = excluded.configuration, updated = excluded.updated
            """, [.text(configuration.packID), .text(json), .int(Int64(updatedAt.timeIntervalSince1970))])
    }

    func loadRulePackCatalogBootstrap(catalogID: String) throws -> RulePackCatalogAcceptance {
        RulePackCatalogAcceptance(
            state: try loadRulePackCatalogState(catalogID: catalogID),
            configurations: try loadRulePackConfigurationsStrictly(),
            pendingReviewPackIDs: try loadRulePackReviewPackIDs(),
            overrides: try loadRulePackOverrides(),
            events: try rulePackEvents(limit: 300),
            deliveryStats: try rulePackDeliveryStats()
        )
    }

    /// 0.15.4 could leave an omitted downloaded pack enabled because missing definitions were not reconciled. Once
    /// the exact accepted catalog has been reverified, durably stop that unambiguous legacy state before publication.
    /// Disabled stale rows are deliberately left alone: older storage has no provenance that distinguishes a catalog
    /// invalidation from a user turning the pack off before that catalog reached this Mac.
    func reconcileRulePackCatalogBootstrap(
        _ bootstrap: RulePackCatalogAcceptance,
        definitions: [RulePackDefinition]
    ) throws -> RulePackCatalogAcceptance {
        var configurations: [RulePackConfiguration] = []
        try conn.transaction {
            configurations = try reconcileRulePackConfigurations(
                definitions: definitions,
                updatedAt: Date()
            )
        }
        return RulePackCatalogAcceptance(
            state: bootstrap.state,
            configurations: configurations,
            pendingReviewPackIDs: try loadRulePackReviewPackIDs(),
            overrides: try loadRulePackOverrides(),
            events: try rulePackEvents(limit: 300),
            deliveryStats: try rulePackDeliveryStats()
        )
    }

    func loadRulePackCatalogState(catalogID: String) throws -> RulePackCatalogState {
        guard !catalogID.isEmpty else { throw RulePackCatalogPersistenceError.invalidCatalogID }
        let receipt = try loadRulePackCatalogReceipt(catalogID: catalogID)
        let cache = try conn.query("""
            SELECT raw_envelope, etag, last_modified, verified_at
            FROM rule_pack_catalog_cache WHERE catalog_id = ?
            """, [.text(catalogID)]) { row in
                RulePackCatalogCache(
                    catalogID: catalogID,
                    rawEnvelope: row.blob(0),
                    etag: row.isNull(1) ? nil : row.text(1),
                    lastModified: row.isNull(2) ? nil : row.text(2),
                    verifiedAt: Date(timeIntervalSince1970: TimeInterval(row.int(3)))
                )
            }.first
        let update = try conn.query("""
            SELECT automatic_refresh, last_attempt, last_success, next_eligible_attempt,
                   failure_count, last_status, last_error
            FROM rule_pack_catalog_updates WHERE catalog_id = ?
            """, [.text(catalogID)]) { row in
                RulePackCatalogUpdateState(
                    catalogID: catalogID,
                    automaticRefresh: row.int(0) != 0,
                    lastAttempt: row.isNull(1) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int(1))),
                    lastSuccess: row.isNull(2) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int(2))),
                    nextEligibleAttempt: row.isNull(3) ? nil : Date(timeIntervalSince1970: TimeInterval(row.int(3))),
                    failureCount: Int(row.int(4)),
                    lastStatus: row.isNull(5) ? nil : row.text(5),
                    lastError: row.isNull(6) ? nil : row.text(6)
                )
            }.first ?? RulePackCatalogUpdateState(catalogID: catalogID)
        return RulePackCatalogState(receipt: receipt, cache: cache, update: update)
    }

    private func reconcileRulePackConfigurations(
        definitions: [RulePackDefinition],
        updatedAt: Date
    ) throws -> [RulePackConfiguration] {
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let saved = try conn.query(
            "SELECT configuration FROM rule_packs ORDER BY pack_id"
        ) { $0.text(0) }
        var reconciled: [RulePackConfiguration] = []
        for json in saved {
            var configuration = try JSONDecoder().decode(
                RulePackConfiguration.self,
                from: Data(json.utf8)
            )
            let consentIsCurrent = definitionsByID[configuration.packID].map(configuration.isConsented(to:)) == true
            if configuration.enabled && !consentIsCurrent {
                configuration.enabled = false
                try writeRulePackConfiguration(configuration, updatedAt: updatedAt)
                try setRulePackReviewRequired(true, packID: configuration.packID)
            }
            reconciled.append(configuration)
        }
        return reconciled
    }

    /// Atomically rechecks anti-rollback state, saves the exact signed bytes and validators, invalidates stale
    /// consent, and resets refresh backoff. Callers may publish the returned definitions/configurations only after
    /// this method returns successfully.
    func acceptVerifiedRulePackCatalog(_ catalog: VerifiedRulePackCatalog,
                                       catalogID: String = RulePackCatalogVerifier.catalogID,
                                       etag: String? = nil,
                                       lastModified: String? = nil,
                                       checkedAt: Date,
                                       nextEligibleAt: Date) throws -> RulePackCatalogAcceptance {
        guard catalogID == RulePackCatalogVerifier.catalogID else {
            throw RulePackCatalogPersistenceError.invalidCatalogID
        }
        guard catalog.sequence > 0, !catalog.digest.isEmpty, !catalog.signerKeyID.isEmpty,
              !catalog.rawEnvelope.isEmpty else {
            throw RulePackCatalogPersistenceError.invalidReceipt
        }
        var packIDs = Set<String>()
        guard catalog.definitions.allSatisfy({ packIDs.insert($0.id).inserted }) else {
            throw RulePackValidationError.duplicatePack(catalog.definitions.first?.id ?? "")
        }

        var reconciled: [RulePackConfiguration] = []
        try conn.transaction {
            if let prior = try loadRulePackCatalogReceipt(catalogID: catalogID) {
                if catalog.sequence < prior.sequence { throw RulePackCatalogPersistenceError.rollback }
                if catalog.sequence == prior.sequence, catalog.digest != prior.digest {
                    throw RulePackCatalogPersistenceError.equivocation
                }
            }

            let acceptedAt = Int64(checkedAt.timeIntervalSince1970)
            try conn.run("""
                INSERT INTO rule_pack_catalog_receipts
                    (catalog_id, highest_sequence, canonical_digest, signer_key_id, accepted_at)
                VALUES (?,?,?,?,?)
                ON CONFLICT(catalog_id) DO UPDATE SET
                    highest_sequence = excluded.highest_sequence,
                    canonical_digest = excluded.canonical_digest,
                    signer_key_id = excluded.signer_key_id,
                    accepted_at = CASE
                        WHEN rule_pack_catalog_receipts.highest_sequence = excluded.highest_sequence
                         AND rule_pack_catalog_receipts.canonical_digest = excluded.canonical_digest
                        THEN rule_pack_catalog_receipts.accepted_at
                        ELSE excluded.accepted_at
                    END
                """, [.text(catalogID), .int(catalog.sequence), .text(catalog.digest),
                      .text(catalog.signerKeyID), .int(acceptedAt)])
            try conn.run("""
                INSERT INTO rule_pack_catalog_cache
                    (catalog_id, raw_envelope, etag, last_modified, verified_at)
                VALUES (?,?,?,?,?)
                ON CONFLICT(catalog_id) DO UPDATE SET
                    raw_envelope = excluded.raw_envelope, etag = excluded.etag,
                    last_modified = excluded.last_modified, verified_at = excluded.verified_at
                """, [.text(catalogID), .blob(catalog.rawEnvelope), etag.map(SQLValue.text) ?? .null,
                      lastModified.map(SQLValue.text) ?? .null, .int(acceptedAt)])
            try conn.run("""
                INSERT INTO rule_pack_catalog_updates
                    (catalog_id, automatic_refresh, last_attempt, last_success, next_eligible_attempt,
                     failure_count, last_status, last_error)
                VALUES (?,1,?,?,?,0,?,NULL)
                ON CONFLICT(catalog_id) DO UPDATE SET
                    last_attempt = excluded.last_attempt, last_success = excluded.last_success,
                    next_eligible_attempt = excluded.next_eligible_attempt,
                    failure_count = 0, last_status = excluded.last_status, last_error = NULL
                """, [.text(catalogID), .int(acceptedAt), .int(acceptedAt),
                      .int(Int64(nextEligibleAt.timeIntervalSince1970)), .text("accepted")])

            reconciled = try reconcileRulePackConfigurations(
                definitions: catalog.definitions,
                updatedAt: checkedAt
            )
        }

        let state = try loadRulePackCatalogState(catalogID: catalogID)
        return RulePackCatalogAcceptance(
            state: state,
            configurations: reconciled.sorted { $0.packID < $1.packID },
            pendingReviewPackIDs: try loadRulePackReviewPackIDs(),
            overrides: try loadRulePackOverrides(),
            events: try rulePackEvents(limit: 300),
            deliveryStats: try rulePackDeliveryStats()
        )
    }

    /// A 304 is meaningful only after the caller has reverified the cached bytes. The expected receipt makes that
    /// re-verification a compare-and-set instead of allowing stale in-memory state to mark a newer row successful.
    func recordRulePackCatalogNotModified(catalogID: String,
                                          expectedSequence: Int64,
                                          expectedDigest: String,
                                          checkedAt: Date,
                                          nextEligibleAt: Date) throws {
        try conn.transaction {
            guard let receipt = try loadRulePackCatalogReceipt(catalogID: catalogID),
                  receipt.sequence == expectedSequence,
                  receipt.digest == expectedDigest,
                  try conn.query("SELECT 1 FROM rule_pack_catalog_cache WHERE catalog_id = ?",
                                 [.text(catalogID)], map: { $0.int(0) }).first == 1 else {
                throw RulePackCatalogPersistenceError.invalidReceipt
            }
            let checked = Int64(checkedAt.timeIntervalSince1970)
            try conn.run("""
                INSERT INTO rule_pack_catalog_updates
                    (catalog_id, automatic_refresh, last_attempt, last_success, next_eligible_attempt,
                     failure_count, last_status, last_error)
                VALUES (?,1,?,?,?,0,?,NULL)
                ON CONFLICT(catalog_id) DO UPDATE SET
                    last_attempt = excluded.last_attempt, last_success = excluded.last_success,
                    next_eligible_attempt = excluded.next_eligible_attempt,
                    failure_count = 0, last_status = excluded.last_status, last_error = NULL
                """, [.text(catalogID), .int(checked), .int(checked),
                      .int(Int64(nextEligibleAt.timeIntervalSince1970)), .text("not-modified")])
        }
    }

    func setRulePackCatalogAutomaticRefresh(catalogID: String, enabled: Bool) throws {
        guard !catalogID.isEmpty else { throw RulePackCatalogPersistenceError.invalidCatalogID }
        try conn.run("""
            INSERT INTO rule_pack_catalog_updates (catalog_id, automatic_refresh, failure_count)
            VALUES (?,?,0)
            ON CONFLICT(catalog_id) DO UPDATE SET automatic_refresh = excluded.automatic_refresh
            """, [.text(catalogID), .int(enabled ? 1 : 0)])
    }

    func recordRulePackCatalogFailure(catalogID: String,
                                      attemptedAt: Date,
                                      failureCount: Int,
                                      nextEligibleAt: Date,
                                      status: String,
                                      error: String) throws {
        guard !catalogID.isEmpty, failureCount > 0 else {
            throw RulePackCatalogPersistenceError.invalidReceipt
        }
        try conn.run("""
            INSERT INTO rule_pack_catalog_updates
                (catalog_id, automatic_refresh, last_attempt, last_success, next_eligible_attempt,
                 failure_count, last_status, last_error)
            VALUES (?,1,?,NULL,?,?,?,?)
            ON CONFLICT(catalog_id) DO UPDATE SET
                last_attempt = excluded.last_attempt,
                next_eligible_attempt = excluded.next_eligible_attempt,
                failure_count = excluded.failure_count,
                last_status = excluded.last_status, last_error = excluded.last_error
            """, [.text(catalogID), .int(Int64(attemptedAt.timeIntervalSince1970)),
                  .int(Int64(nextEligibleAt.timeIntervalSince1970)), .int(Int64(failureCount)),
                  .text(status), .text(error)])
    }

    private func loadRulePackCatalogReceipt(catalogID: String) throws -> RulePackCatalogReceipt? {
        try conn.query("""
            SELECT highest_sequence, canonical_digest, signer_key_id, accepted_at
            FROM rule_pack_catalog_receipts WHERE catalog_id = ?
            """, [.text(catalogID)]) { row in
                RulePackCatalogReceipt(
                    catalogID: catalogID,
                    sequence: row.int(0),
                    digest: row.text(1),
                    signerKeyID: row.text(2),
                    acceptedAt: Date(timeIntervalSince1970: TimeInterval(row.int(3)))
                )
            }.first
    }

    func loadRulePackOverrides() throws -> [RulePackOverride] {
        try conn.query("SELECT override FROM rule_pack_overrides ORDER BY updated") { $0.text(0) }.compactMap {
            try? JSONDecoder().decode(RulePackOverride.self, from: Data($0.utf8))
        }
    }

    func saveRulePackOverride(_ override: RulePackOverride) throws {
        let json = String(decoding: try JSONEncoder().encode(override), as: UTF8.self)
        try conn.transaction {
            for existing in try loadRulePackOverrides().filter({ $0.id != override.id && $0.hasSameScope(as: override) }) {
                try conn.run("DELETE FROM rule_pack_overrides WHERE id = ?", [.text(existing.id.uuidString)])
            }
            try conn.run("""
                INSERT INTO rule_pack_overrides (id, override, updated) VALUES (?,?,?)
                ON CONFLICT(id) DO UPDATE SET override = excluded.override, updated = excluded.updated
                """, [.text(override.id.uuidString), .text(json), .int(Int64(Date().timeIntervalSince1970))])
        }
    }

    func deleteRulePackOverride(_ override: RulePackOverride) throws {
        try conn.transaction {
            for existing in try loadRulePackOverrides().filter({ $0.hasSameScope(as: override) }) {
                try conn.run("DELETE FROM rule_pack_overrides WHERE id = ?", [.text(existing.id.uuidString)])
            }
        }
    }

    /// Commits a retryable extension delivery exactly once. One monotonic watermark per extension process and the
    /// additive rollups share one transaction, so acknowledging a batch means both are durable and retries are no-ops.
    @discardableResult
    func recordRulePackEventBatch(_ batch: RulePackEventBatch) throws -> Bool {
        var inserted = false
        try conn.transaction {
            if batch.requiresDurableWatermark {
                let session = batch.deliverySession.uuidString
                let watermark = try conn.query(
                    "SELECT sequence FROM rule_pack_event_watermarks WHERE delivery_session = ?",
                    [.text(session)], map: { $0.int(0) }
                ).first ?? 0
                guard batch.sequence > watermark else { return }
                try conn.run("""
                    INSERT INTO rule_pack_event_watermarks
                        (delivery_session, sequence, received, dropped_hits, dropped_keys) VALUES (?,?,?,?,?)
                    ON CONFLICT(delivery_session) DO UPDATE SET
                        sequence = excluded.sequence, received = excluded.received,
                        dropped_hits = dropped_hits + excluded.dropped_hits,
                        dropped_keys = dropped_keys + excluded.dropped_keys
                    """, [.text(session), .int(batch.sequence), .int(Int64(Date().timeIntervalSince1970)),
                          .int(batch.droppedHits), .int(batch.droppedKeys)])
            }
            try recordRulePackEvents(batch.events, inTransaction: true)
            inserted = true
        }
        return inserted
    }

    func recordRulePackEvents(_ events: [RulePackEvent]) throws {
        try recordRulePackEvents(events, inTransaction: false)
    }

    private func recordRulePackEvents(_ events: [RulePackEvent], inTransaction: Bool) throws {
        let sql = """
        INSERT INTO rule_pack_event_rollups
            (bucket, pack_id, pack_version, entry_id, category, match, action, count, first_at, last_at,
             bundle_id, app_name, agent, agent_name, host, matched_host, port)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(\(Self.rulePackEventKeySQL)) DO UPDATE SET
            count = count + excluded.count,
            first_at = MIN(first_at, excluded.first_at),
            last_at = MAX(last_at, excluded.last_at)
        """
        let write = {
            for event in events {
                try self.conn.run(sql, [.int(event.bucket), .text(event.packID), .text(event.packVersion),
                                        .int(Int64(event.entryID)), .text(event.category.rawValue),
                                        .text(event.match.rawValue), .text(event.action.rawValue),
                                        .int(Int64(event.count)), .int(event.firstAt), .int(event.lastAt),
                                        .text(event.bundleID), .text(event.appName), .text(event.agentKey),
                                        .text(event.agentName), .text(event.host), .text(event.matchedHost),
                                        .int(Int64(event.port))])
            }
        }
        if inTransaction { try write() }
        else { try conn.transaction(write) }
    }

    func rulePackDeliveryStats() throws -> RulePackDeliveryStats {
        let row = try conn.query("SELECT COALESCE(SUM(dropped_hits), 0), COALESCE(SUM(dropped_keys), 0) FROM rule_pack_event_watermarks") {
            RulePackDeliveryStats(droppedHits: $0.int(0), droppedKeys: $0.int(1))
        }.first
        return row ?? RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0)
    }

    func rulePackEvents(packID: String? = nil, limit: Int = 300) throws -> [RulePackEventRecord] {
        var sql = """
        SELECT id, bucket, pack_id, pack_version, entry_id, category, match, action, count, first_at, last_at,
               bundle_id, app_name, agent, agent_name, host, matched_host, port
        FROM rule_pack_event_rollups
        """
        var values: [SQLValue] = []
        if let packID { sql += " WHERE pack_id = ?"; values = [.text(packID)] }
        sql += " ORDER BY last_at DESC, id DESC LIMIT \(max(1, limit))"
        return try conn.query(sql, values) { row in
            RulePackEventRecord(id: row.int(0), bucket: Date(timeIntervalSince1970: TimeInterval(row.int(1))),
                                packID: row.text(2), packVersion: row.text(3), entryID: UInt32(clamping: row.int(4)),
                                category: RulePackEntry.Category(rawValue: row.text(5)) ?? .tracking,
                                match: RulePackEntry.Match(rawValue: row.text(6)) ?? .suffix,
                                action: RulePackEvent.Action(rawValue: row.text(7)) ?? .block,
                                count: Int(row.int(8)),
                                firstAt: Date(timeIntervalSince1970: TimeInterval(row.int(9))),
                                lastAt: Date(timeIntervalSince1970: TimeInterval(row.int(10))),
                                bundleID: row.text(11), appName: row.text(12), agentKey: row.text(13),
                                agentName: row.text(14), host: row.text(15), matchedHost: row.text(16),
                                port: UInt16(clamping: row.int(17)))
        }
    }

    func pruneRulePackEvents(before date: Date) throws {
        let cutoff = Int64(date.timeIntervalSince1970)
        try conn.transaction {
            try conn.run("DELETE FROM rule_pack_event_rollups WHERE bucket < ?", [.int(cutoff)])
            // Receipt IDs outlive visible activity: the extension may retry a committed batch after any disconnect.
            // Keep deduplication durable, but stop old overflow counters contributing to the current warning.
            try conn.run("UPDATE rule_pack_event_watermarks SET dropped_hits = 0, dropped_keys = 0 WHERE received < ?",
                         [.int(cutoff)])
        }
    }

    // MARK: Devices on other channels

    func recordDeviceEvents(_ events: [DeviceEvent]) throws {
        for event in events {
            try conn.run("""
                INSERT INTO device_events (ts, kind, device_id, name, detail, change) VALUES (?,?,?,?,?,?)
                """, [.int(Int64(event.at.timeIntervalSince1970)), .text(event.kind.rawValue), .text(event.deviceID),
                      .text(event.name), .text(event.detail), .text(event.change.rawValue)])
        }
    }

    func deviceEvents(limit: Int = 300) throws -> [DeviceEvent] {
        try conn.query("""
            SELECT id, ts, kind, device_id, name, detail, change FROM device_events ORDER BY ts DESC, id DESC LIMIT \(max(1, limit))
            """) { row in
            DeviceEvent(id: row.int(0), at: Date(timeIntervalSince1970: TimeInterval(row.int(1))),
                        kind: PeripheralDevice.Kind(rawValue: row.text(2)) ?? .bluetooth, deviceID: row.text(3),
                        name: row.text(4), detail: row.text(5),
                        change: DeviceEvent.Change(rawValue: row.text(6)) ?? .appeared)
        }
    }

    struct DeviceActivitySummary: Sendable {
        var kind: PeripheralDevice.Kind
        var name: String
        var firstAt: Date
        var lastAt: Date
        var appeared: Int
        var connected: Int
        var disconnected: Int
        var removed: Int
        var started: Int
        var stopped: Int

        var total: Int { appeared + connected + disconnected + removed + started + stopped }
    }

    /// Bounded aggregate history for Ask. Stable device IDs are grouping keys inside SQLite only and never leave
    /// this method; two devices with the same display name remain separate rows without exposing their identities.
    func deviceActivity(from: Date, to: Date, kind: PeripheralDevice.Kind?, limit: Int) throws
        -> [DeviceActivitySummary] {
        var sql = """
            SELECT e.kind, e.device_id,
                   (SELECT latest.name FROM device_events AS latest
                    WHERE latest.kind = e.kind AND latest.device_id = e.device_id
                      AND latest.ts >= ? AND latest.ts < ?
                    ORDER BY latest.ts DESC, latest.id DESC LIMIT 1),
                   MIN(e.ts), MAX(e.ts),
                   SUM(CASE WHEN e.change = 'appeared' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN e.change = 'connected' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN e.change = 'disconnected' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN e.change = 'removed' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN e.change = 'started' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN e.change = 'stopped' THEN 1 ELSE 0 END)
            FROM device_events AS e WHERE e.ts >= ? AND e.ts < ?
            """
        let fromValue = SQLValue.int(Int64(from.timeIntervalSince1970))
        let toValue = SQLValue.int(Int64(to.timeIntervalSince1970))
        var values: [SQLValue] = [fromValue, toValue, fromValue, toValue]
        if let kind {
            sql += " AND e.kind = ?"
            values.append(.text(kind.rawValue))
        }
        sql += " GROUP BY e.kind, e.device_id ORDER BY MAX(e.ts) DESC, name COLLATE NOCASE LIMIT \(max(1, limit))"
        return try conn.query(sql, values) { row in
            DeviceActivitySummary(
                kind: PeripheralDevice.Kind(rawValue: row.text(0)) ?? .bluetooth,
                name: row.text(2),
                firstAt: Date(timeIntervalSince1970: TimeInterval(row.int(3))),
                lastAt: Date(timeIntervalSince1970: TimeInterval(row.int(4))),
                appeared: Int(row.int(5)), connected: Int(row.int(6)), disconnected: Int(row.int(7)),
                removed: Int(row.int(8)), started: Int(row.int(9)), stopped: Int(row.int(10))
            )
        }
    }

    func pruneDeviceEvents(before date: Date) throws {
        try conn.run("DELETE FROM device_events WHERE ts < ?", [.int(Int64(date.timeIntervalSince1970))])
    }

    // MARK: Guardrails

    func loadGuardrails() throws -> [Guardrail] {
        let rows = try conn.query("SELECT guardrail FROM guardrails ORDER BY updated") { $0.text(0) }
        return rows.compactMap { try? JSONDecoder().decode(Guardrail.self, from: Data($0.utf8)) }
    }

    func saveGuardrail(_ guardrail: Guardrail) throws {
        let json = String(decoding: try JSONEncoder().encode(guardrail), as: UTF8.self)
        try conn.run("""
            INSERT INTO guardrails (id, guardrail, updated) VALUES (?,?,?)
            ON CONFLICT(id) DO UPDATE SET guardrail = excluded.guardrail, updated = excluded.updated
            """, [.text(guardrail.id.uuidString), .text(json), .int(Int64(Date().timeIntervalSince1970))])
    }

    func deleteGuardrail(_ id: UUID) throws {
        try conn.run("DELETE FROM guardrails WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: Plugins

    func loadPluginManifests() throws -> [PluginManifest] {
        let rows = try conn.query("SELECT manifest, enabled FROM plugins ORDER BY updated") { ($0.text(0), $0.int(1) != 0) }
        return rows.compactMap { text, enabled in
            guard var manifest = try? JSONDecoder().decode(PluginManifest.self, from: Data(text.utf8)) else { return nil }
            manifest.enabled = enabled
            return manifest
        }
    }

    func savePluginManifest(_ manifest: PluginManifest) throws {
        let json = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        try conn.run("""
            INSERT INTO plugins (id, manifest, enabled, updated) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET manifest = excluded.manifest, enabled = excluded.enabled, updated = excluded.updated
            """, [.text(manifest.id), .text(json), .int(manifest.enabled ? 1 : 0), .int(Int64(Date().timeIntervalSince1970))])
    }

    func setPluginEnabled(id: String, enabled: Bool) throws {
        if var manifest = try loadPluginManifests().first(where: { $0.id == id }) {
            manifest.enabled = enabled
            try savePluginManifest(manifest)
        } else if var manifest = PluginEngine.builtInManifests.first(where: { $0.id == id }) {
            manifest.enabled = enabled
            try savePluginManifest(manifest)
        }
    }

    func updatePluginConfiguration(id: String, configuration: [String: String]) throws {
        guard var manifest = try loadPluginManifests().first(where: { $0.id == id }) else { return }
        manifest.configuration = configuration
        try savePluginManifest(manifest)
    }

    func deleteInstalledPlugin(id: String) throws {
        guard let manifest = try loadPluginManifests().first(where: { $0.id == id }), manifest.source == .installed else { return }
        try conn.transaction {
            try conn.run("DELETE FROM plugin_findings WHERE plugin_id = ?", [.text(id)])
            try conn.run("DELETE FROM plugins WHERE id = ?", [.text(id)])
        }
    }

    @discardableResult
    func backfillPluginFindings(pluginID: String? = nil, since: Date = Date().addingTimeInterval(-14 * 86400), limit: Int = 500) throws -> Int {
        let manifests = PluginEngine.mergedManifests(try loadPluginManifests())
        let active = pluginID.map { id in manifests.filter { $0.id == id } } ?? manifests
        let evaluable = active.filter { $0.source == .builtIn || (!$0.script.isEmpty && $0.source == .installed) }
        guard !evaluable.isEmpty else { return 0 }
        let exchanges = try exchanges(since: since, limit: limit)
        var inserted = 0
        try conn.transaction {
            if let pluginID { try conn.run("DELETE FROM plugin_findings WHERE plugin_id = ?", [.text(pluginID)]) }
            else if !evaluable.isEmpty {
                try conn.run("DELETE FROM plugin_findings WHERE plugin_id IN (\(Array(repeating: "?", count: evaluable.count).joined(separator: ",")))", evaluable.map { .text($0.id) })
            }
            for exchange in exchanges {
                let before = conn.changes
                try insertPluginFindings(PluginEngine.evaluate(exchange, manifests: evaluable), forExchangeID: exchange.id ?? 0)
                inserted += max(0, conn.changes - before)
            }
        }
        return inserted
    }

    func insertPluginFindings(_ findings: [PluginFindingDraft], forExchangeID exchangeID: Int64) throws {
        guard !findings.isEmpty else { return }
        let encoder = JSONEncoder()
        for draft in findings {
            let finding = draft.materialize(exchangeID: exchangeID)
            let evidence = String(decoding: try encoder.encode(finding.evidence), as: UTF8.self)
            let guardrail: String
            if let suggested = finding.suggestedGuardrail {
                guardrail = String(decoding: try encoder.encode(suggested), as: UTF8.self)
            } else {
                guardrail = ""
            }
            let rule: String
            if let suggested = finding.suggestedRule {
                rule = String(decoding: try encoder.encode(suggested), as: UTF8.self)
            } else {
                rule = ""
            }
            let actions = finding.suggestedActions.isEmpty ? "" : String(decoding: try encoder.encode(finding.suggestedActions), as: UTF8.self)
            try conn.run("""
                INSERT OR IGNORE INTO plugin_findings (id, exchange_id, plugin_id, plugin_version, kind, severity, title, summary, evidence, suggested_guardrail, suggested_rule, suggested_actions, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(finding.id), .int(exchangeID), .text(finding.pluginID), .text(finding.pluginVersion), .text(finding.kind.rawValue),
                      .text(finding.severity.rawValue), .text(finding.title), .text(String(finding.summary.prefix(500))), .text(evidence),
                      .text(guardrail), .text(rule), .text(actions), .double(finding.createdAt.timeIntervalSince1970)])
        }
    }

    func pluginFindings(exchangeIDs: [Int64], visibleOnly: Bool = true) throws -> [Int64: [PluginFinding]] {
        guard !exchangeIDs.isEmpty else { return [:] }
        let manifests = try loadPluginManifests()
        let enabled = Dictionary(uniqueKeysWithValues: PluginEngine.mergedManifests(manifests).map { ($0.id, $0.enabled) })
        let marks = Array(repeating: "?", count: exchangeIDs.count).joined(separator: ",")
        let values = exchangeIDs.map(SQLValue.int)
        let rows = try conn.query("""
            SELECT id, exchange_id, plugin_id, plugin_version, kind, severity, title, summary, evidence, suggested_guardrail, suggested_rule, suggested_actions, created_at
            FROM plugin_findings WHERE exchange_id IN (\(marks)) ORDER BY created_at ASC, title ASC
            """, values) { row in decodePluginFinding(row) }
        let visible = visibleOnly ? rows.filter { enabled[$0.pluginID] ?? true } : rows
        return Dictionary(grouping: visible, by: \.exchangeID)
    }

    func clearPluginFindings() throws {
        try conn.run("DELETE FROM plugin_findings")
    }

    private func decodePluginFinding(_ row: SQLRow) -> PluginFinding {
        let decoder = JSONDecoder()
        let evidence = (try? decoder.decode([PluginEvidence].self, from: Data(row.text(8).utf8))) ?? []
        let guardrailText = row.text(9)
        let guardrail = guardrailText.isEmpty ? nil : try? decoder.decode(Guardrail.self, from: Data(guardrailText.utf8))
        let ruleText = row.text(10)
        let rule = ruleText.isEmpty ? nil : try? decoder.decode(Rule.self, from: Data(ruleText.utf8))
        let actionsText = row.text(11)
        let actions = actionsText.isEmpty ? [] : ((try? decoder.decode([PluginSuggestedAction].self, from: Data(actionsText.utf8))) ?? [])
        return PluginFinding(id: row.text(0), exchangeID: row.int(1), pluginID: row.text(2), pluginVersion: row.text(3),
                             kind: PluginManifest.Kind(rawValue: row.text(4)) ?? .traffic,
                             severity: PluginFinding.Severity(rawValue: row.text(5)) ?? .info,
                             title: row.text(6), summary: row.text(7), evidence: evidence,
                             suggestedGuardrail: guardrail, suggestedRule: rule, suggestedActions: actions,
                             createdAt: Date(timeIntervalSince1970: row.double(12)))
    }

    // MARK: Rule simulation

    /// Recorded traffic in the shape the rule engine judges, for answering "what would this rule have done".
    ///
    /// Read from the minute tier rather than the second tier: seconds are kept for hours and simulating against
    /// them would answer for this morning only, while minutes reach back a fortnight. Grouped in SQL because the
    /// interesting number is how many distinct things a rule touches, and a busy agent produces tens of thousands
    /// of rows that collapse to a handful of destinations.
    func flowsForSimulation(since: Date, limit: Int = 20000) throws -> [RuleSimulation.Flow] {
        try conn.query("""
            SELECT MAX(ts), bundle_id, app_name, agent_parent, domain, remote_ip, port,
                   SUM(bytes_in + bytes_out), SUM(flows)
            FROM agg_1m WHERE ts >= ?
            GROUP BY bundle_id, agent_parent, domain, remote_ip, port
            ORDER BY SUM(flows) DESC LIMIT ?
            """, [.int(Int64(since.timeIntervalSince1970)), .int(Int64(limit))]) { row in
            RuleSimulation.Flow(
                when: Date(timeIntervalSince1970: Double(row.int(0))),
                // The agent a flow belongs to is its parent when it has one — a tool an agent ran is the agent's
                // traffic for the purposes of a rule about that agent.
                agentKey: row.text(3).isEmpty ? row.text(1) : row.text(3),
                bundleID: row.text(1), appName: row.text(2), host: row.text(4), ip: row.text(5),
                port: UInt16(clamping: row.int(6)), bytes: row.int(7), connections: Int(row.int(8)))
        }
    }

    // MARK: HTTPS inspection

    /// Inserts raw capture and, when deterministic triage or plugin rules find bounded evidence, creates separate
    /// derived rows in the same transaction. This returns before any model work begins.
    func insertExchange(_ e: HTTPExchange, enqueueLocalRisk: Bool = false) throws -> Int64 {
        var insertedID: Int64 = 0
        try conn.transaction {
            let encoder = JSONEncoder()
            func json<T: Encodable>(_ v: T) -> String { (try? encoder.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "[]" }
            try conn.run("""
                INSERT INTO http_exchanges (ts, duration, scheme, host, port, method, path, status, req_headers, req_body, req_size,
                    req_truncated, resp_headers, resp_body, resp_size, resp_truncated, content_type, pid, bundle_id, app_name, agent,
                    agent_name, mcp_server, tool_calls, note, tool_results, mcp, llm, mock_rule, guardrail, response_transform)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.double(e.started.timeIntervalSince1970), .double(e.duration), .text(e.scheme), .text(e.host), .int(Int64(e.port)),
                      .text(e.method), .text(e.path), e.status.map { .int(Int64($0)) } ?? .null,
                      .text(json(e.requestHeaders)), .blob(e.requestBody), .int(Int64(e.requestSize)), .int(e.requestTruncated ? 1 : 0),
                      .text(json(e.responseHeaders)), .blob(e.responseBody), .int(Int64(e.responseSize)), .int(e.responseTruncated ? 1 : 0),
                      .text(e.contentType), .int(Int64(e.pid)), .text(e.bundleID), .text(e.appName), .text(e.agent ?? ""),
                      .text(e.agentName ?? ""), .text(e.mcpServer ?? ""), .text(e.toolCalls.isEmpty ? "" : json(e.toolCalls)), .text(e.note ?? ""),
                      .text(e.toolResults.isEmpty ? "" : json(e.toolResults)), .text(e.mcp.isEmpty ? "" : json(e.mcp)),
                      .text(e.llm.map(json) ?? ""), .text(e.mockRule ?? ""), .text(e.guardrail ?? ""), .text(e.responseTransform ?? "")])
            insertedID = try conn.query("SELECT last_insert_rowid()", map: { $0.int(0) }).first ?? 0
            var stored = e
            stored.id = insertedID
            if enqueueLocalRisk, LocalRiskSettings.enabled, let candidate = LocalRiskTriage.candidate(for: stored) {
                try enqueueLocalRiskCandidate(candidate)
            }
            do {
                let manifests = PluginEngine.mergedManifests(try loadPluginManifests())
                for manifest in manifests where PluginEngine.builtInManifests.contains(where: { $0.id == manifest.id }) {
                    try savePluginManifest(manifest)
                }
                try insertPluginFindings(PluginEngine.evaluateBuiltIns(stored, manifests: manifests), forExchangeID: insertedID)
            } catch {
                appLog.error("plugin evaluation skipped: \(String(describing: error), privacy: .public)")
            }
        }
        evaluateInstalledPluginScripts(exchangeID: insertedID, exchange: e)
        return insertedID
    }

    private func evaluateInstalledPluginScripts(exchangeID: Int64, exchange: HTTPExchange) {
        do {
            let manifests = PluginEngine.mergedManifests(try loadPluginManifests()).filter { $0.source == .installed && !$0.script.isEmpty }
            guard !manifests.isEmpty else { return }
            var stored = exchange
            stored.id = exchangeID
            try insertPluginFindings(PluginScriptRunner.shared.evaluate(exchange: stored, manifests: manifests), forExchangeID: exchangeID)
        } catch {
            appLog.error("installed plugin evaluation skipped: \(String(describing: error), privacy: .public)")
        }
    }

    private func enqueueLocalRiskCandidate(_ candidate: RiskCandidate) throws {
        // Keep the durable backlog bounded. Capture remains complete either way; an excess candidate simply stays
        // unassessed instead of allowing a long offline session to turn into an unbounded model queue.
        let outstanding = try conn.query("SELECT COUNT(*) FROM local_risk_assessments WHERE state IN ('pending', 'processing', 'deferred')",
                                         map: { $0.int(0) }).first ?? 0
        guard outstanding < 200 else { return }
        let data = try JSONEncoder().encode(candidate)
        let evidence = try JSONEncoder().encode(candidate.evidence)
        let now = Date().timeIntervalSince1970
        try conn.run("""
            INSERT INTO local_risk_assessments (exchange_id, analyzer_version, state, evidence, candidate, created_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(exchange_id) DO UPDATE SET
                analyzer_version = excluded.analyzer_version,
                state = CASE WHEN local_risk_assessments.analyzer_version < excluded.analyzer_version THEN 'pending'
                             ELSE local_risk_assessments.state END,
                evidence = CASE WHEN local_risk_assessments.analyzer_version < excluded.analyzer_version THEN excluded.evidence
                                ELSE local_risk_assessments.evidence END,
                candidate = CASE WHEN local_risk_assessments.analyzer_version < excluded.analyzer_version THEN excluded.candidate
                                 ELSE local_risk_assessments.candidate END
            """, [.int(candidate.exchangeID), .int(Int64(candidate.analyzerVersion)), .text(RiskAssessmentState.pending.rawValue),
                  .text(String(decoding: evidence, as: UTF8.self)), .text(String(decoding: data, as: UTF8.self)), .double(now)])
    }

    func localRiskAssessments(exchangeIDs: [Int64], visibleOnly: Bool = true) throws -> [Int64: RiskAssessment] {
        guard !exchangeIDs.isEmpty, !visibleOnly || LocalRiskSettings.isActive else { return [:] }
        let marks = Array(repeating: "?", count: exchangeIDs.count).joined(separator: ",")
        let values = exchangeIDs.map(SQLValue.int)
        let rows = try conn.query("""
            SELECT exchange_id, analyzer_version, state, severity, confidence, summary, evidence, model_evidence_ids, candidate, created_at, scored_at
            FROM local_risk_assessments WHERE exchange_id IN (\(marks))
            """, values) { row in decodeLocalRiskAssessment(row) }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.exchangeID, $0) })
    }

    func localRiskCounts(since: Date, to: Date? = nil, filter: TrafficFilter = .none,
                         visibleOnly: Bool = true) throws -> RiskAssessmentCounts {
        guard !visibleOnly || LocalRiskSettings.isActive else { return .init() }
        var clause = "e.ts >= ?"
        var values: [SQLValue] = [.double(since.timeIntervalSince1970)]
        if let to { clause += " AND e.ts <= ?"; values.append(.double(to.timeIntervalSince1970)) }
        if let app = filter.bundleID, !app.isEmpty {
            clause += filter.includeAttributedChildren
                ? " AND (e.bundle_id = ? OR e.agent = ?)" : " AND e.bundle_id = ?"
            values.append(.text(app))
            if filter.includeAttributedChildren { values.append(.text(app)) }
        }
        if let parent = filter.agentParent, !parent.isEmpty {
            clause += " AND e.agent = ?"
            values.append(.text(parent))
        }
        if let mcp = filter.mcpServer, !mcp.isEmpty {
            clause += " AND e.mcp_server = ?"
            values.append(.text(mcp))
        }
        if let host = filter.domain, !host.isEmpty {
            clause += " AND e.host = ?"
            values.append(.text(host))
        } else if filter.remoteIP != nil {
            // Inspected exchanges retain hostnames, not destination addresses. An IP-only traffic scope has no
            // corresponding request rows and must not silently widen the Potential harm card.
            clause += " AND 0"
        }
        if let suffix = filter.domainSuffix, !suffix.isEmpty {
            clause += " AND (e.host = ? OR e.host LIKE ?)"
            values += [.text(suffix), .text("%." + suffix)]
        }
        if !filter.focus.isEmpty {
            var focusParts: [String] = []
            if !filter.focus.bundleIDs.isEmpty {
                let marks = Array(repeating: "?", count: filter.focus.bundleIDs.count).joined(separator: ",")
                let matchesParent = filter.includeAttributedChildren || filter.agentParent != nil || filter.mcpServer != nil
                focusParts.append(matchesParent
                    ? "(e.bundle_id IN (\(marks)) OR e.agent IN (\(marks)))"
                    : "e.bundle_id IN (\(marks))")
                values += filter.focus.bundleIDs.map { .text($0) }
                if matchesParent { values += filter.focus.bundleIDs.map { .text($0) } }
            }
            for host in filter.focus.hosts where !AgentPolicy.isIPAddress(host) {
                focusParts.append("(e.host = ? OR e.host LIKE ?)")
                values += [.text(host), .text("%." + host)]
            }
            clause += focusParts.isEmpty ? " AND 0" : " AND (" + focusParts.joined(separator: " OR ") + ")"
        }
        return try conn.query("""
            SELECT
                SUM(CASE WHEN r.state = 'scored' AND r.severity = 'medium' THEN 1 ELSE 0 END),
                SUM(CASE WHEN r.state = 'scored' AND r.severity = 'high' THEN 1 ELSE 0 END),
                SUM(CASE WHEN r.state != 'scored' THEN 1 ELSE 0 END)
            FROM local_risk_assessments r JOIN http_exchanges e ON e.id = r.exchange_id WHERE \(clause)
            """, values) { row in
                RiskAssessmentCounts(medium: Int(row.int(0)), high: Int(row.int(1)), unassessed: Int(row.int(2)))
            }.first ?? .init()
    }

    func claimNextLocalRiskAssessment() throws -> RiskAssessment? {
        var claimed: RiskAssessment?
        try conn.transaction {
            guard let id = try conn.query("""
                SELECT exchange_id FROM local_risk_assessments
                WHERE state IN ('pending', 'deferred') ORDER BY created_at ASC LIMIT 1
                """, map: { $0.int(0) }).first else { return }
            try conn.run("UPDATE local_risk_assessments SET state = 'processing' WHERE exchange_id = ? AND state IN ('pending', 'deferred')", [.int(id)])
            guard conn.changes == 1 else { return }
            claimed = try conn.query("""
                SELECT exchange_id, analyzer_version, state, severity, confidence, summary, evidence, model_evidence_ids, candidate, created_at, scored_at
                FROM local_risk_assessments WHERE exchange_id = ?
                """, [.int(id)]) { row in decodeLocalRiskAssessment(row) }.first
        }
        return claimed
    }

    func recoverLocalRiskClaims() throws {
        try conn.run("UPDATE local_risk_assessments SET state = 'deferred' WHERE state = 'processing'")
    }

    func deferLocalRiskAssessment(exchangeID: Int64) throws {
        try conn.run("UPDATE local_risk_assessments SET state = 'deferred' WHERE exchange_id = ? AND state = 'processing'", [.int(exchangeID)])
    }

    func completeLocalRiskAssessment(exchangeID: Int64, result: LocalRiskProviderResult) throws {
        switch result {
        case .scored(let verdict):
            guard let severity = RiskSeverity(rawValue: verdict.severity), (0...1).contains(verdict.confidence),
                  verdict.summary.count <= 500, verdict.evidenceIDs.count <= 8 else {
                try markLocalRiskState(exchangeID: exchangeID, state: .failed, summary: L("The local model returned an invalid analysis."))
                return
            }
            let candidate = try localRiskCandidate(exchangeID: exchangeID)
            let available = Set(candidate.evidence.map(\.id))
            guard Set(verdict.evidenceIDs).isSubset(of: available) else {
                try markLocalRiskState(exchangeID: exchangeID, state: .failed, summary: L("The local model cited evidence that was not supplied."))
                return
            }
            try conn.run("""
                UPDATE local_risk_assessments SET state = ?, severity = ?, confidence = ?, summary = ?, model_evidence_ids = ?, scored_at = ?
                WHERE exchange_id = ?
                """, [.text(RiskAssessmentState.scored.rawValue), .text(severity.rawValue), .double(verdict.confidence),
                      .text(verdict.summary), .text(String(decoding: try JSONEncoder().encode(verdict.evidenceIDs), as: UTF8.self)),
                      .double(Date().timeIntervalSince1970), .int(exchangeID)])
        case .unavailable(let reason):
            try markLocalRiskState(exchangeID: exchangeID, state: .unavailable, summary: reason)
        case .deferred(let reason):
            try markLocalRiskState(exchangeID: exchangeID, state: .deferred, summary: reason)
        case .failed(let reason):
            try markLocalRiskState(exchangeID: exchangeID, state: .failed, summary: reason)
        }
    }

    private func markLocalRiskState(exchangeID: Int64, state: RiskAssessmentState, summary: String) throws {
        try conn.run("UPDATE local_risk_assessments SET state = ?, summary = ?, scored_at = ? WHERE exchange_id = ?",
                     [.text(state.rawValue), .text(String(summary.prefix(500))), .double(Date().timeIntervalSince1970), .int(exchangeID)])
    }

    private func localRiskCandidate(exchangeID: Int64) throws -> RiskCandidate {
        guard let text = try conn.query("SELECT candidate FROM local_risk_assessments WHERE exchange_id = ?", [.int(exchangeID)], map: { $0.text(0) }).first,
              let candidate = try? JSONDecoder().decode(RiskCandidate.self, from: Data(text.utf8)) else {
            throw SQLiteError.step("Missing local risk candidate")
        }
        return candidate
    }

    private func decodeLocalRiskAssessment(_ row: SQLRow) -> RiskAssessment {
        let decoder = JSONDecoder()
        let evidence = (try? decoder.decode([RiskEvidence].self, from: Data(row.text(6).utf8))) ?? []
        let IDs = (try? decoder.decode([String].self, from: Data(row.text(7).utf8))) ?? []
        let fallback = RiskCandidate(exchangeID: row.int(0), analyzerVersion: Int(row.int(1)), method: "", destinationClass: "", pathCategory: "",
                                     contentTypeCategory: "", requestBytes: 0, responseBytes: 0, requestTruncated: false, responseTruncated: false,
                                     appKind: "", hasAgent: false, hasMCP: false, toolNames: [], safeHeaderNames: [], evidence: evidence)
        let candidate = (try? decoder.decode(RiskCandidate.self, from: Data(row.text(8).utf8))) ?? fallback
        return RiskAssessment(exchangeID: row.int(0), analyzerVersion: Int(row.int(1)),
                              state: RiskAssessmentState(rawValue: row.text(2)) ?? .failed,
                              severity: RiskSeverity(rawValue: row.text(3)), confidence: row.isNull(4) ? nil : row.double(4),
                              summary: row.text(5).nilIfEmpty, evidence: evidence, modelEvidenceIDs: IDs,
                              createdAt: Date(timeIntervalSince1970: row.double(9)),
                              scoredAt: row.isNull(10) ? nil : Date(timeIntervalSince1970: row.double(10)), candidate: candidate)
    }

    func enqueueRecentLocalRiskCandidates(limit: Int) throws {
        let rows = try exchanges(since: Date().addingTimeInterval(-24 * 3600), limit: limit)
        for exchange in rows where exchange.id != nil {
            if let candidate = LocalRiskTriage.candidate(for: exchange) { try enqueueLocalRiskCandidate(candidate) }
        }
    }

    func clearLocalRiskAssessments() throws {
        try conn.run("DELETE FROM local_risk_assessments")
    }

    /// Exchanges newest first, without bodies (they're loaded one at a time with `exchangeBodies`).
    /// `search` also looks inside the bodies, so a keyword only present in a request or response still finds it.
    /// - Parameter app: a bundle id to scope to. Separate from `search` on purpose: "show me this app's traffic"
    ///   is a different question from "find this text", and answering the first with the second matches any
    ///   response body that merely mentions the app's name — which is how asking for Claude Code's traffic
    ///   returned every GitHub page whose HTML says "Claude Code".
    func exchanges(since: Date, search: String = "", limit: Int = 500, focus: FocusScope = .none,
                   app: String? = nil, host: String? = nil, hostIncludesSubdomains: Bool = true,
                   includeAttributedChildren: Bool = false, agentParent: String? = nil,
                   mcpServer: String? = nil) throws -> [HTTPExchange] {
        let like = "%\(search)%"
        var scopeClause = ""
        var scopeValues: [SQLValue] = []
        if let app, !app.isEmpty {
            scopeClause += includeAttributedChildren ? " AND (bundle_id = ? OR agent = ?)" : " AND bundle_id = ?"
            scopeValues.append(.text(app))
            if includeAttributedChildren { scopeValues.append(.text(app)) }
        }
        if let agentParent, !agentParent.isEmpty {
            scopeClause += " AND agent = ?"
            scopeValues.append(.text(agentParent))
        }
        if let mcpServer, !mcpServer.isEmpty {
            scopeClause += " AND mcp_server = ?"
            scopeValues.append(.text(mcpServer))
        }
        if let host, !host.isEmpty {
            scopeClause += hostIncludesSubdomains ? " AND (host = ? OR host LIKE ?)" : " AND host = ?"
            scopeValues.append(.text(host))
            if hostIncludesSubdomains { scopeValues.append(.text("%." + host)) }
        }
        // An exchange records the host it went to but not the address behind it, so an IP target can't match here.
        var focusClause = ""
        var focusValues: [SQLValue] = []
        if !focus.isEmpty {
            var parts: [String] = []
            if !focus.bundleIDs.isEmpty {
                let marks = Array(repeating: "?", count: focus.bundleIDs.count).joined(separator: ",")
                let matchesParent = includeAttributedChildren || agentParent != nil || mcpServer != nil
                parts.append(matchesParent
                    ? "(bundle_id IN (\(marks)) OR agent IN (\(marks)))"
                    : "bundle_id IN (\(marks))")
                focusValues += focus.bundleIDs.map { .text($0) }
                if matchesParent { focusValues += focus.bundleIDs.map { .text($0) } }
            }
            for host in focus.hosts where !AgentPolicy.isIPAddress(host) {
                parts.append("(host = ? OR host LIKE ?)")
                focusValues.append(.text(host))
                focusValues.append(.text("%." + host))
            }
            focusClause = parts.isEmpty ? " AND 0" : " AND (" + parts.joined(separator: " OR ") + ")"
        }
        return try conn.query("""
            SELECT id, ts, duration, scheme, host, port, method, path, status, req_headers, req_size, req_truncated, resp_headers,
                   resp_size, resp_truncated, content_type, pid, bundle_id, app_name, agent, agent_name, mcp_server, tool_calls, note,
                   tool_results, mcp, llm, mock_rule, guardrail, response_transform
            FROM http_exchanges WHERE ts >= ? AND (? = '' OR host LIKE ? OR path LIKE ? OR app_name LIKE ? OR agent_name LIKE ? OR tool_calls LIKE ?
                                                   OR mcp LIKE ? OR CAST(req_body AS TEXT) LIKE ? OR CAST(resp_body AS TEXT) LIKE ?)\(focusClause)\(scopeClause)
            ORDER BY ts DESC LIMIT ?
            """, [.double(since.timeIntervalSince1970), .text(search), .text(like), .text(like), .text(like), .text(like), .text(like), .text(like),
                  .text(like), .text(like)]
                  + focusValues + scopeValues + [.int(Int64(limit))]) { row in
            let decoder = JSONDecoder()
            func headers(_ i: Int32) -> [HTTPHeader] { (try? decoder.decode([HTTPHeader].self, from: Data(row.text(i).utf8))) ?? [] }
            let tools = row.text(22), results = row.text(24), mcp = row.text(25), llm = row.text(26)
            return HTTPExchange(
                id: row.int(0), started: Date(timeIntervalSince1970: row.double(1)), duration: row.double(2), scheme: row.text(3),
                host: row.text(4), port: Int(row.int(5)), method: row.text(6), path: row.text(7),
                status: row.isNull(8) ? nil : Int(row.int(8)), requestHeaders: headers(9), requestBody: Data(), requestSize: Int(row.int(10)),
                requestTruncated: row.int(11) != 0, responseHeaders: headers(12), responseBody: Data(), responseSize: Int(row.int(13)),
                responseTruncated: row.int(14) != 0, contentType: row.text(15), pid: Int32(row.int(16)), bundleID: row.text(17),
                appName: row.text(18), agent: row.text(19).nilIfEmpty, agentName: row.text(20).nilIfEmpty, mcpServer: row.text(21).nilIfEmpty,
                toolCalls: tools.isEmpty ? [] : ((try? decoder.decode([ToolCall].self, from: Data(tools.utf8))) ?? []),
                toolResults: results.isEmpty ? [] : ((try? decoder.decode([ToolResult].self, from: Data(results.utf8))) ?? []),
                mcp: mcp.isEmpty ? [] : ((try? decoder.decode([MCPActivity].self, from: Data(mcp.utf8))) ?? []),
                llm: llm.isEmpty ? nil : try? decoder.decode(LLMFacts.self, from: Data(llm.utf8)),
                note: row.text(23).nilIfEmpty, mockRule: row.text(27).nilIfEmpty, guardrail: row.text(28).nilIfEmpty,
                responseTransform: row.text(29).nilIfEmpty)
        }
    }

    func exchangeBodies(id: Int64) throws -> (request: Data, response: Data)? {
        try conn.query("SELECT req_body, resp_body FROM http_exchanges WHERE id = ?", [.int(id)]) { ($0.blob(0), $0.blob(1)) }.first
    }

    func pruneExchanges(olderThan cutoff: Date) throws {
        try conn.transaction {
            try conn.run("DELETE FROM local_risk_assessments WHERE exchange_id IN (SELECT id FROM http_exchanges WHERE ts < ?)",
                         [.double(cutoff.timeIntervalSince1970)])
            try conn.run("DELETE FROM plugin_findings WHERE exchange_id IN (SELECT id FROM http_exchanges WHERE ts < ?)",
                         [.double(cutoff.timeIntervalSince1970)])
            try conn.run("DELETE FROM http_exchanges WHERE ts < ?", [.double(cutoff.timeIntervalSince1970)])
        }
    }

    func deleteAllExchanges() throws {
        try conn.transaction {
            try conn.run("DELETE FROM local_risk_assessments")
            try conn.run("DELETE FROM plugin_findings")
            try conn.run("DELETE FROM http_exchanges")
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
    func addAlert(kind: String, bundleID: String, appName: String, detail: String, severity: Int, at date: Date = Date(),
                  allowPattern: String = "") throws -> AlertRecord {
        let ts = Int64(date.timeIntervalSince1970)
        try conn.run("INSERT INTO alerts (ts, kind, bundle_id, app_name, detail, severity, allow_pattern) VALUES (?,?,?,?,?,?,?)",
                     [.int(ts), .text(kind), .text(bundleID), .text(appName), .text(detail), .int(Int64(severity)),
                      .text(allowPattern)])
        let id = try conn.query("SELECT last_insert_rowid()") { $0.int(0) }.first ?? 0
        return AlertRecord(id: id, timestamp: date, kind: kind, bundleID: bundleID, appName: appName, detail: detail,
                           severity: severity, acknowledged: false, allowPattern: allowPattern)
    }

    /// Alerts newest first. An alert names the app that raised it and nothing about where it went, so Focus can
    /// only narrow these by app: focusing purely on destinations leaves the list alone rather than emptying it.
    func alerts(limit: Int = 500, focus: FocusScope = .none) throws -> [AlertRecord] {
        var clause = ""
        var values: [SQLValue] = []
        if !focus.bundleIDs.isEmpty {
            clause = " WHERE bundle_id IN (\(Array(repeating: "?", count: focus.bundleIDs.count).joined(separator: ",")))"
            values = focus.bundleIDs.map { .text($0) }
        }
        return try conn.query("""
            SELECT id, ts, kind, bundle_id, app_name, detail, severity, acknowledged, allow_pattern FROM alerts\(clause) \
            ORDER BY ts DESC, id DESC LIMIT ?
            """, values + [.int(Int64(limit))]) { r in
            AlertRecord(id: r.int(0), timestamp: Date(timeIntervalSince1970: TimeInterval(r.int(1))), kind: r.text(2),
                        bundleID: r.text(3), appName: r.text(4), detail: r.text(5), severity: Int(r.int(6)),
                        acknowledged: r.int(7) != 0, allowPattern: r.text(8))
        }
    }

    /// Narrowed by Focus the same way `alerts` is, so the sidebar badge matches the list it opens.
    func unacknowledgedAlertCount(focus: FocusScope = .none) throws -> Int {
        var clause = ""
        var values: [SQLValue] = []
        if !focus.bundleIDs.isEmpty {
            clause = " AND bundle_id IN (\(Array(repeating: "?", count: focus.bundleIDs.count).joined(separator: ",")))"
            values = focus.bundleIDs.map { .text($0) }
        }
        return Int(try conn.query("SELECT COUNT(*) FROM alerts WHERE acknowledged = 0\(clause)", values) { $0.int(0) }.first ?? 0)
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
            for t in Self.tables + ["rollup_state", "seen_destinations", "seen_ports", "apps", "baselines", "alerts", "http_exchanges", "local_risk_assessments", "plugin_findings", "device_events", "rule_events", "rule_pack_event_rollups"] {
                try conn.run("DELETE FROM \(t)")
            }
            // Keep event batch IDs so an acknowledgment lost before "Delete everything" cannot resurrect activity.
            try conn.run("UPDATE rule_pack_event_watermarks SET dropped_hits = 0, dropped_keys = 0")
        }
    }

    // MARK: Serialized access helpers

    func sync<T>(_ body: (TrafficDatabase) throws -> T) rethrows -> T { try queue.sync { try body(self) } }

    func async(_ body: @escaping (TrafficDatabase) throws -> Void) {
        queue.async {
            do { try body(self) } catch { appLog.error("db error: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Serialized work whose success or failure controls a caller decision. Unlike `async`, this never turns a
    /// persistence failure into a log-only event, and callers must not invoke `sync` from inside its body.
    func asyncResult<T: Sendable>(_ body: @escaping @Sendable (TrafficDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body(self) }) }
        }
    }
}
