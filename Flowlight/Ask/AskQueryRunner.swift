import Foundation

/// Runs the queries in `AskQuery` against the local history and turns the results into the compact JSON a model
/// is given back.
///
/// Two rules shape everything here. **Aggregates, not rows**: nothing returns a flow, a timestamp to the second or
/// a packet — only counts, totals and names, which is what answering a question needs. And **bounded**: every
/// result has a row limit and every window has an end, so a model cannot ask for the database one page at a time.
enum AskQueryRunner {
    static let maximumRows = 50

    struct Result: Equatable, Sendable {
        /// What the model is handed.
        var json: String
        /// A sentence for the transcript, so someone reading it doesn't have to parse JSON to see what came back.
        var summary: String
        /// What clicking this result should show in Reports, when it maps to something Flowlight can display.
        var filter: TrafficFilter?
        var from: Date?
        var to: Date?
        /// Drawn under the answer when the shape of the result says more than its numbers.
        var chart: AskChart?
        /// Where the answer points for a question about the app rather than about traffic.
        var screen: SidebarItem?
    }

    enum Failure: Error, CustomStringConvertible {
        case badWindow(String)
        case badArgument(String)

        var description: String {
            switch self {
            case .badWindow(let text): return "I couldn't read the time window: \(text). Use something like '24h', '7d', 'yesterday', or an ISO-8601 timestamp."
            case .badArgument(let text): return "That argument didn't work: \(text)."
            }
        }
    }

    /// Runs one call. Throwing is how a bad argument gets back to the model — as a sentence it can correct, not as
    /// a silent empty result that it will read as "nothing happened".
    static func run(_ call: AskCall, db: TrafficDatabase, now: Date = Date(),
                    environment: AskEnvironment = .empty) throws -> Result {
        // The questions about Flowlight itself need no window: they are about how it is set up, not about when.
        switch call.query {
        case .settings: return settings(environment)
        case .howTo: return howTo(call.arguments["topic"] ?? "")
        case .rules: return list(environment.rules, what: "rule", screen: .rules)
        case .guardrails: return list(environment.guardrails, what: "guardrail", screen: .agents)
        default: break
        }
        guard let from = call.arguments["from"], let window = AskWindow.resolve(from: from, to: call.arguments["to"], now: now)
        else { throw Failure.badWindow(call.arguments["from"] ?? "(missing)") }
        let limit = try rowLimit(call.arguments["limit"])
        let app = call.arguments["app"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let grain = granularity(for: window, requested: call.arguments["granularity"])

        switch call.query {
        case .trafficTotals:
            return try totals(db: db, window: window, app: app, grain: grain, chart: call.arguments["chart"])
        case .topApps:
            return try topApps(db: db, window: window, limit: limit, grain: grain, chart: call.arguments["chart"])
        case .topDestinations:
            return try topDestinations(db: db, window: window, app: app, limit: limit, grain: grain, chart: call.arguments["chart"])
        case .newDestinations:
            return try newDestinations(db: db, window: window, app: app, limit: limit, grain: grain)
        case .alerts:
            return try alerts(db: db, window: window, limit: limit)
        case .agents:
            return try agents(db: db, window: window, grain: grain)
        case .overTime:
            return try overTime(db: db, window: window, app: app, grain: grain, chart: call.arguments["chart"])
        case .settings, .howTo, .rules, .guardrails:
            // Handled above, before a window was required.
            throw Failure.badArgument("that query takes no time window")
        }
    }

    // MARK: About Flowlight rather than about traffic

    private static func settings(_ environment: AskEnvironment) -> Result {
        var fields: [String: String] = [
            "version": environment.appVersion,
            "captureSource": environment.captureSource,
            "captureStatus": environment.captureStatus,
            "receivingTraffic": environment.receiving ? "yes" : "no",
            "networkExtension": environment.extensionState,
            "canRefuseConnections": environment.canBlock ? "yes" : "no",
            "httpsInspection": environment.inspecting ? "on (\(environment.inspectionScope))" : "off",
            "export": environment.exportEnabled ? "on" : (environment.exportConfigured ? "configured but off" : "not set up"),
            "focus": environment.focus.isEmpty ? "off" : environment.focus,
            "runsInBackground": environment.backgroundOnly ? "yes" : "no",
            "watchingBluetooth": environment.watchingBluetooth ? "yes" : "no",
            "watchingUSB": environment.watchingUSB ? "yes" : "no",
            "rules": "\(environment.rules.count)",
            "guardrails": "\(environment.guardrails.count)",
            "agentAllowlists": "\(environment.agentAllowlists)",
            "answeringQuestions": environment.askProvider,
        ]
        if environment.fellBackToSampler {
            fields["note"] = "The filter extension stopped answering, so the nettop sampler is standing in. Blocking is off while it does."
        }
        return Result(json: encode(fields),
                      summary: "\(environment.captureSource), inspection \(environment.inspecting ? "on" : "off"), \(environment.rules.count) rules",
                      screen: .capture)
    }

    private static func howTo(_ topic: String) -> Result {
        let matches = FeatureGuide.search(topic)
        guard !matches.isEmpty else {
            return Result(json: encode(["features": FeatureGuide.all.map(\.title).joined(separator: ", ")]),
                          summary: "nothing matched '\(topic)'")
        }
        return Result(json: encode(matches.map(\.asDictionary)),
                      summary: matches.map(\.title).joined(separator: ", "),
                      screen: matches.first?.screen)
    }

    private static func list(_ items: [String], what: String, screen: SidebarItem) -> Result {
        Result(json: encode(items.map { [what: $0] }),
               summary: items.isEmpty ? "no \(what)s" : "\(items.count) \(what)\(items.count == 1 ? "" : "s")",
               screen: screen)
    }

    // MARK: The queries

    private static func totals(db: TrafficDatabase, window: (from: Date, to: Date), app: String?,
                               grain: Granularity, chart: String?) throws -> Result {
        let rows = try Self.rows(db: db, window: window, grain: grain)
        let matching = rows.filter { matches(app, row: $0) }
        let counters = matching.reduce(into: FlowCounters()) { $0 += $1.counters }
        let who = app.map { " for \(name(of: $0, in: rows))" } ?? ""
        let kind = AskChart.kind(requested: chart, natural: counters.total > 0 ? .pie : .none)
        return Result(json: encode(["received": counters.bytesIn, "sent": counters.bytesOut,
                                    "connections": counters.flows,
                                    "apps": Int64(Set(matching.map(\.bundleID)).count)]),
                      summary: "\(ByteFormat.string(counters.bytesIn)) in, \(ByteFormat.string(counters.bytesOut)) out\(who)",
                      filter: app.map { TrafficFilter(bundleID: bundleID(of: $0, in: rows)) } ?? .none,
                      from: window.from, to: window.to,
                      chart: AskChart(kind: kind, title: "Received and sent\(who)", unit: .bytes,
                                      points: [AskChart.Point(label: "Received", value: Double(counters.bytesIn)),
                                               AskChart.Point(label: "Sent", value: Double(counters.bytesOut))]))
    }

    private static func topApps(db: TrafficDatabase, window: (from: Date, to: Date), limit: Int,
                                grain: Granularity, chart: String?) throws -> Result {
        let rows = try Self.rows(db: db, window: window, grain: grain)
        var byApp: [String: (name: String, counters: FlowCounters)] = [:]
        for row in rows {
            var entry = byApp[row.bundleID] ?? (row.appName, FlowCounters())
            entry.counters += row.counters
            byApp[row.bundleID] = entry
        }
        let top = byApp.sorted { $0.value.counters.total > $1.value.counters.total }.prefix(limit)
        let payload = top.map { ["app": $0.value.name, "bundleID": $0.key,
                                 "received": "\($0.value.counters.bytesIn)", "sent": "\($0.value.counters.bytesOut)"] }
        let points = top.map { AskChart.Point(label: $0.value.name, value: Double($0.value.counters.bytesOut),
                                              secondary: Double($0.value.counters.bytesIn)) }
        return Result(json: encode(payload),
                      summary: top.isEmpty ? "nothing moved" : top.map { "\($0.value.name) \(ByteFormat.string($0.value.counters.total))" }.joined(separator: ", "),
                      filter: .none, from: window.from, to: window.to,
                      chart: AskChart(kind: AskChart.kind(requested: chart, natural: points.isEmpty ? .none : .bar),
                                      title: "Busiest apps", unit: .bytes,
                                      points: AskChart.trimmed(points, kind: .bar)))
    }

    private static func topDestinations(db: TrafficDatabase, window: (from: Date, to: Date), app: String?,
                                        limit: Int, grain: Granularity, chart: String?) throws -> Result {
        let rows = try Self.rows(db: db, window: window, grain: grain).filter { matches(app, row: $0) }
        var byDestination: [String: (owner: String, counters: FlowCounters)] = [:]
        for row in rows {
            let key = row.domain.isEmpty ? row.remoteIP : row.domain
            guard !key.isEmpty else { continue }
            var entry = byDestination[key] ?? (row.owner, FlowCounters())
            entry.counters += row.counters
            if entry.owner.isEmpty { entry.owner = row.owner }
            byDestination[key] = entry
        }
        let top = byDestination.sorted { $0.value.counters.total > $1.value.counters.total }.prefix(limit)
        let payload = top.map { entry in
            ["destination": entry.key, "network": entry.value.owner,
             "received": "\(entry.value.counters.bytesIn)", "sent": "\(entry.value.counters.bytesOut)"]
        }
        let kind = AskChart.kind(requested: chart, natural: top.isEmpty ? .none : .bar)
        let points = top.map { AskChart.Point(label: $0.key, value: Double($0.value.counters.total)) }
        return Result(json: encode(payload),
                      summary: top.isEmpty ? "no destinations" : top.prefix(3).map(\.key).joined(separator: ", "),
                      filter: app.map { TrafficFilter(bundleID: bundleID(of: $0, in: rows)) } ?? .none,
                      from: window.from, to: window.to,
                      chart: AskChart(kind: kind, title: "Busiest destinations", unit: .bytes,
                                      points: AskChart.trimmed(points, kind: kind), primaryName: "Total"))
    }

    /// Destinations reached in this window that had never been reached before it — the question that actually
    /// matters when something has started behaving differently.
    private static func newDestinations(db: TrafficDatabase, window: (from: Date, to: Date), app: String?,
                                        limit: Int, grain: Granularity) throws -> Result {
        let inWindow = try Self.rows(db: db, window: window, grain: grain).filter { matches(app, row: $0) }
        // "Before" is the same length of time again, ending where the window starts. A fixed comparison period
        // beats "all of history", which on a fresh install would call everything new.
        let before = window.from.addingTimeInterval(-window.to.timeIntervalSince(window.from))
        let earlier = try db.breakdown(grain, from: before, to: window.from, limit: TrafficDatabase.breakdownLimit)
            .filter { matches(app, row: $0) }
        let seen = Set(earlier.map { "\($0.bundleID)|\($0.domain.isEmpty ? $0.remoteIP : $0.domain)" })
        var fresh: [(app: String, destination: String, counters: FlowCounters)] = []
        for row in inWindow {
            let destination = row.domain.isEmpty ? row.remoteIP : row.domain
            guard !destination.isEmpty, !seen.contains("\(row.bundleID)|\(destination)") else { continue }
            fresh.append((row.appName, destination, row.counters))
        }
        let top = fresh.sorted { $0.counters.total > $1.counters.total }.prefix(limit)
        let payload = top.map { ["app": $0.app, "destination": $0.destination, "sent": "\($0.counters.bytesOut)"] }
        return Result(json: encode(payload),
                      summary: top.isEmpty ? "nothing new" : top.prefix(3).map { "\($0.app) → \($0.destination)" }.joined(separator: ", "),
                      filter: app.map { TrafficFilter(bundleID: bundleID(of: $0, in: inWindow)) } ?? .none,
                      from: window.from, to: window.to)
    }

    private static func alerts(db: TrafficDatabase, window: (from: Date, to: Date), limit: Int) throws -> Result {
        let all = try db.alerts(limit: 2000)
        let inWindow = all.filter { $0.timestamp >= window.from && $0.timestamp < window.to }.prefix(limit)
        let payload = inWindow.map { alert in
            ["rule": alert.kind, "app": alert.appName, "detail": alert.detail,
             "severity": alert.severity >= 3 ? "critical" : alert.severity == 2 ? "warning" : "info",
             "at": ISO8601DateFormatter().string(from: alert.timestamp)]
        }
        return Result(json: encode(payload),
                      summary: inWindow.isEmpty ? "no alerts" : "\(inWindow.count) alerts, newest \(inWindow.first?.kind ?? "")",
                      filter: .none, from: window.from, to: window.to)
    }

    private static func agents(db: TrafficDatabase, window: (from: Date, to: Date), grain: Granularity) throws -> Result {
        let rows = try Self.rows(db: db, window: window, grain: grain)
        var byAgent: [String: (name: String, providers: Set<String>, other: Set<String>, counters: FlowCounters)] = [:]
        for row in rows {
            let key = row.parentAgent.isEmpty ? row.bundleID : row.parentAgent
            let name = row.parentAgentName.isEmpty ? row.appName : row.parentAgentName
            let isAgent = !row.parentAgent.isEmpty || AgentCatalog.knownAgent(bundleID: row.bundleID, appName: row.appName) != nil
                || AgentCatalog.provider(domain: row.domain) != nil
            guard isAgent else { continue }
            var entry = byAgent[key] ?? (name, [], [], FlowCounters())
            entry.counters += row.counters
            if let provider = AgentCatalog.provider(domain: row.domain) {
                entry.providers.insert(provider)
            } else if !row.domain.isEmpty {
                entry.other.insert(AnomalyEngine.registrableDomain(row.domain))
            }
            byAgent[key] = entry
        }
        let payload = byAgent.sorted { $0.value.counters.total > $1.value.counters.total }.prefix(maximumRows).map { entry in
            ["agent": entry.value.name,
             "providers": entry.value.providers.sorted().joined(separator: ", "),
             "otherDestinations": entry.value.other.sorted().prefix(10).joined(separator: ", "),
             "sent": "\(entry.value.counters.bytesOut)"]
        }
        return Result(json: encode(payload),
                      summary: payload.isEmpty ? "no agents" : payload.compactMap { $0["agent"] }.joined(separator: ", "),
                      filter: .none, from: window.from, to: window.to)
    }

    private static func overTime(db: TrafficDatabase, window: (from: Date, to: Date), app: String?,
                                 grain: Granularity, chart: String?) throws -> Result {
        var filter = TrafficFilter.none
        if let app {
            filter.bundleID = bundleID(of: app, in: try Self.rows(db: db, window: window, grain: grain))
        }
        var series = try db.series(grain, from: window.from, to: window.to, filter: filter)
        // Same fallback as the tables: a series that is all zeroes because the rollup hasn't run yet is not an
        // answer, it is a rollup schedule showing through.
        if series.allSatisfy({ $0.total == 0 }), let finer = Self.finer(than: grain) {
            series = try db.series(finer, from: window.from, to: window.to, filter: filter)
        }
        let iso = ISO8601DateFormatter()
        let payload = series.suffix(200).map { point in
            ["at": iso.string(from: point.date), "received": "\(point.bytesIn)", "sent": "\(point.bytesOut)"]
        }
        let peak = series.max { $0.total < $1.total }
        let points = series.map { AskChart.Point(label: "", date: $0.date, value: Double($0.bytesOut),
                                                 secondary: Double($0.bytesIn)) }
        return Result(json: encode(payload),
                      summary: peak.map { "busiest \(grain.rawValue) \($0.date.formatted(date: .abbreviated, time: .shortened)) at \(ByteFormat.string($0.total))" }
                        ?? "nothing in this window",
                      filter: filter, from: window.from, to: window.to,
                      chart: AskChart(kind: AskChart.kind(requested: chart, natural: points.isEmpty ? .none : .line),
                                      title: "Over time, by \(grain.rawValue)", unit: .bytes, points: points))
    }

    /// The breakdown for a window, falling back to a finer tier when the coarse one has nothing.
    ///
    /// History is folded upwards on a timer, so the most recent minutes live in the per-second table and haven't
    /// reached the hourly one yet. Without this, "what happened in the last hour" could answer "nothing" purely
    /// because a rollup hadn't run — an answer that is wrong in the worst way, because it sounds definite.
    static func rows(db: TrafficDatabase, window: (from: Date, to: Date), grain: Granularity) throws -> [BreakdownRow] {
        var tiers = [grain]
        if let finer = finer(than: grain) { tiers.append(finer) }
        if let finest = tiers.last.flatMap(finer(than:)) { tiers.append(finest) }
        for tier in tiers {
            let rows = try db.breakdown(tier, from: window.from, to: window.to, limit: TrafficDatabase.breakdownLimit)
            if !rows.isEmpty { return rows }
        }
        return []
    }

    static func finer(than grain: Granularity) -> Granularity? {
        switch grain {
        case .year, .month, .week, .day: return .hour
        case .hour: return .minute
        case .minute: return .second
        case .second: return nil
        }
    }

    // MARK: Odds and ends

    /// An app named however the person said it: a bundle identifier, or the name Flowlight shows.
    static func matches(_ app: String?, row: BreakdownRow) -> Bool {
        guard let app, !app.isEmpty else { return true }
        return row.bundleID.caseInsensitiveCompare(app) == .orderedSame
            || row.appName.caseInsensitiveCompare(app) == .orderedSame
            || row.appName.localizedCaseInsensitiveContains(app)
    }

    static func bundleID(of app: String, in rows: [BreakdownRow]) -> String {
        rows.first { matches(app, row: $0) }?.bundleID ?? app
    }

    static func name(of app: String, in rows: [BreakdownRow]) -> String {
        rows.first { matches(app, row: $0) }?.appName ?? app
    }

    static func rowLimit(_ raw: String?) throws -> Int {
        guard let raw, !raw.isEmpty else { return 10 }
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw Failure.badArgument("limit must be a whole number, not '\(raw)'")
        }
        return min(max(1, value), maximumRows)
    }

    /// The tier that can actually answer the question. A week of seconds would be millions of rows; an hour of
    /// days would be one. The model may ask, but the window decides when the ask is silly.
    static func granularity(for window: (from: Date, to: Date), requested: String?) -> Granularity {
        let span = window.to.timeIntervalSince(window.from)
        let natural: Granularity = span <= 900 ? .second : span <= 60 * 60 * 6 ? .minute : span <= 86_400 * 4 ? .hour : .day
        guard let requested, let asked = Granularity(rawValue: requested.trimmingCharacters(in: .whitespaces).lowercased())
        else { return natural }
        // Honour the ask unless it would mean reading a tier far too fine for the window.
        switch (asked, span) {
        case (.second, let s) where s > 3600: return .minute
        case (.minute, let s) where s > 86_400 * 2: return .hour
        default: return asked
        }
    }

    private static func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is [[String: String]] || value is [String: Int64],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
