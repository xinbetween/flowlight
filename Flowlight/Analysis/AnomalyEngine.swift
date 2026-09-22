import Foundation

/// Explainable anomaly detection: EWMA baselines with z-score alerts plus simple rules.
/// All methods run on the database queue.
final class AnomalyEngine: @unchecked Sendable {
    enum Kind: String {
        case volumeSpike = "Traffic spike"
        case destinationSpike = "Unusual number of destinations"
        case firstContact = "First contact with domain"
        case newApp = "New app on the network"
        case nonStandardPort = "Non-standard port"
        case uploadPercentile = "Upload above 99th percentile"
        case idleTraffic = "Traffic without UI activity"
        case agentSensitiveChannel = "Agent used a sensitive channel"
        case agentExfiltration = "Possible data exfiltration by agent"
        case agentUnnamedHost = "Agent contacted an unnamed host"
        case agentWhileAway = "Agent active while you were away"

        static let agentKinds: Set<String> = [Kind.agentSensitiveChannel, .agentExfiltration, .agentUnnamedHost, .agentWhileAway]
            .reduce(into: Set<String>()) { $0.insert($1.rawValue) }
    }

    static let standardPorts: Set<UInt16> = [
        20, 21, 22, 25, 53, 67, 68, 80, 110, 123, 137, 138, 143, 443, 465, 587, 853, 990, 993, 995,
        1900, 3478, 3479, 3480, 3481, 5223, 5228, 5353, 8080, 8443,
    ]

    private let db: TrafficDatabase
    private let activity: ActivitySnapshotting
    var settings: () -> AnomalySettings = { .current }
    var onAlert: ([AlertRecord]) -> Void = { _ in }

    private var seenDestinations: Set<String> = []
    private var seenPorts: Set<String> = []
    private var appsFirstSeen: [String: Int64] = [:]
    private var loaded = false

    private var minuteUploads: [String: (name: String, bytes: Int64)] = [:]
    private var lastIdleAlert: [String: Date] = [:]

    // AI agent state
    /// Apps seen talking to an LLM API (auto-discovered agents), beyond the known catalog.
    private(set) var discoveredAgents: Set<String> = []
    private struct AgentMinute { var minute: Int64; var egressOut: Int64; var total: Int64; var destinations: [String: Int64] }
    private var agentMinutes: [String: [AgentMinute]] = [:]
    private var agentNames: [String: String] = [:]
    private var agentAlertedAt: [String: Date] = [:]

    /// Display name if the app is an AI agent (known, or discovered by its LLM API traffic).
    func agentName(bundleID: String, appName: String) -> String? {
        if let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: appName) { return known.name }
        return discoveredAgents.contains(bundleID) ? appName : nil
    }

    func seedDiscoveredAgents(_ bundleIDs: Set<String>) { discoveredAgents.formUnion(bundleIDs) }

    /// Rate limit: true (and records it) when `token` hasn't alerted within `interval`.
    private func shouldAlert(_ token: String, every interval: TimeInterval, now: Date = Date()) -> Bool {
        if let last = agentAlertedAt[token], now.timeIntervalSince(last) < interval { return false }
        agentAlertedAt[token] = now
        return true
    }

    init(db: TrafficDatabase, activity: ActivitySnapshotting) {
        self.db = db
        self.activity = activity
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        let seen = try db.loadSeen()
        seenDestinations = seen.destinations
        seenPorts = seen.ports
        appsFirstSeen = seen.apps
        loaded = true
    }

    /// Collapses a hostname to an approximate registrable domain so CDN hostnames do not churn.
    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let secondLevel = labels[labels.count - 2]
        let keep = secondLevel.count <= 3 && labels.last!.count == 2 ? 3 : 2 // e.g. co.uk, com.au
        return labels.suffix(keep).joined(separator: ".")
    }

    static func isLocal(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("fe80") || ip.hasPrefix("169.254.") ||
            ip.hasPrefix("224.") || ip.hasPrefix("239.") || ip.hasPrefix("ff") || ip == "(unconnected)" || ip == "*"
    }

    // MARK: Per-batch rules

    func observe(_ batches: [TrafficBatch]) throws {
        try loadIfNeeded()
        let s = settings()
        var alerts: [AlertRecord] = []
        var newDestinations: [(String, String)] = []
        var newPorts: [(String, UInt16)] = []
        var newApps: [String] = []

        for batch in batches {
            for record in batch.records {
                let k = record.key
                let now = batch.timestamp
                minuteUploads[k.bundleID, default: (k.appName, 0)].bytes += record.counters.bytesOut

                let owner = k.domain.isEmpty ? (IPOwnerLookup.shared.cached(k.remoteIP)?.name ?? "") : ""
                let provider = AgentCatalog.provider(domain: k.domain, owner: owner)
                if provider != nil, !AgentCatalog.isBrowser(k.bundleID), record.counters.total > 0 {
                    discoveredAgents.insert(k.bundleID)
                }
                let agent = agentName(bundleID: k.bundleID, appName: k.appName)
                if let agent {
                    alerts += try observeAgent(k, record.counters, agent: agent, provider: provider, owner: owner, at: now, settings: s)
                }

                if appsFirstSeen[k.bundleID] == nil {
                    appsFirstSeen[k.bundleID] = now
                    newApps.append(k.bundleID)
                    // Only interesting once Flowlight itself has finished learning.
                    if let oldest = appsFirstSeen.values.min(), now - oldest > Int64(s.learningPeriod) {
                        alerts.append(try db.addAlert(kind: Kind.newApp.rawValue, bundleID: k.bundleID, appName: k.appName,
                                                      detail: "\(k.appName) made its first observed connection (\(k.domain.isEmpty ? k.remoteIP : k.domain))",
                                                      severity: 1))
                    }
                }
                // Agents learn faster: new destinations from an autonomous tool matter sooner.
                let learning = agent != nil ? min(s.learningPeriod, s.agentLearningPeriod) : s.learningPeriod
                let appLearned = now - (appsFirstSeen[k.bundleID] ?? now) > Int64(learning)

                if !k.domain.isEmpty {
                    let dest = Self.registrableDomain(k.domain)
                    let token = k.bundleID + "|" + dest
                    if seenDestinations.insert(token).inserted {
                        newDestinations.append((k.bundleID, dest))
                        if appLearned && s.alertFirstContact {
                            alerts.append(try db.addAlert(kind: Kind.firstContact.rawValue, bundleID: k.bundleID, appName: k.appName,
                                                          detail: "\(k.appName) contacted \(k.domain) (\(k.remoteIP):\(k.port)) for the first time",
                                                          severity: 1))
                        }
                    }
                }

                if !Self.standardPorts.contains(k.port), !Self.isLocal(k.remoteIP) {
                    let token = k.bundleID + "|" + String(k.port)
                    if seenPorts.insert(token).inserted {
                        newPorts.append((k.bundleID, k.port))
                        if appLearned && s.alertNonStandardPorts {
                            alerts.append(try db.addAlert(kind: Kind.nonStandardPort.rawValue, bundleID: k.bundleID, appName: k.appName,
                                                          detail: "\(k.appName) → \(k.domain.isEmpty ? k.remoteIP : k.domain) on \(k.transport.rawValue.uppercased()) port \(k.port) (\(k.appProtocol))",
                                                          severity: 2))
                        }
                    }
                }
            }
        }
        if !newDestinations.isEmpty || !newPorts.isEmpty || !newApps.isEmpty {
            try db.markSeen(destinations: newDestinations, ports: newPorts, apps: newApps, at: Int64(Date().timeIntervalSince1970))
        }
        if !alerts.isEmpty { onAlert(alerts) }
    }

    /// Per-record agent rules: sensitive channels and unnamed hosts; also feeds the per-minute
    /// egress and while-away accounting evaluated in `evaluateIdleTraffic`.
    private func observeAgent(_ k: FlowKey, _ c: FlowCounters, agent: String, provider: String?, owner: String,
                              at ts: Int64, settings s: AnomalySettings) throws -> [AlertRecord] {
        var alerts: [AlertRecord] = []
        agentNames[k.bundleID] = agent
        let local = IPOwnerLookup.isLocalNetwork(k.remoteIP)
        let destination = !k.domain.isEmpty ? k.domain : (!owner.isEmpty ? "\(owner) · \(k.remoteIP)" : k.remoteIP)

        // Minute accounting (non-AI uploads count as egress).
        let minute = ts / 60
        var history = agentMinutes[k.bundleID] ?? []
        if history.last?.minute != minute { history.append(AgentMinute(minute: minute, egressOut: 0, total: 0, destinations: [:])) }
        history[history.count - 1].total += c.total
        if provider == nil && !local {
            history[history.count - 1].egressOut += c.bytesOut
            history[history.count - 1].destinations[destination, default: 0] += c.bytesOut
        }
        agentMinutes[k.bundleID] = Array(history.suffix(60))

        let category = ProtocolCatalog.category(of: k.appProtocol)
        if s.agentSensitiveChannels, category.isSensitiveEgress, !local, c.total > 0,
           shouldAlert("channel|\(k.bundleID)|\(k.appProtocol)|\(destination)", every: 6 * 3600) {
            let severe: Set<ProtocolCategory> = [.mail, .fileTransfer, .tunnel, .peerToPeer]
            alerts.append(try db.addAlert(kind: Kind.agentSensitiveChannel.rawValue, bundleID: k.bundleID, appName: agent,
                                          detail: "\(agent) used \(k.appProtocol.uppercased()) (\(category.title.lowercased())) to \(destination):\(k.port) — \(ByteFormat.string(c.bytesOut)) sent",
                                          severity: severe.contains(category) ? 3 : 2))
        }
        if s.agentUnnamedHosts, k.domain.isEmpty, owner.isEmpty || provider == nil, !local,
           !Self.standardPorts.contains(k.port), c.total > 0,
           shouldAlert("unnamed|\(k.bundleID)|\(k.remoteIP):\(k.port)", every: 24 * 3600) {
            alerts.append(try db.addAlert(kind: Kind.agentUnnamedHost.rawValue, bundleID: k.bundleID, appName: agent,
                                          detail: "\(agent) connected to \(owner.isEmpty ? "" : owner + " ")\(k.remoteIP):\(k.port) (\(k.appProtocol)) with no hostname",
                                          severity: 2))
        }
        return alerts
    }

    /// Minute rules for agents: sustained uploads to non-AI hosts, and activity while the user is away.
    func evaluateAgents(now: Date = Date()) throws {
        let s = settings()
        let currentMinute = Int64(now.timeIntervalSince1970) / 60
        var alerts: [AlertRecord] = []
        let idle = activity.systemIdleSeconds()
        for (bundleID, history) in agentMinutes {
            let name = agentNames[bundleID] ?? bundleID
            let lastHour = history.filter { $0.minute > currentMinute - 60 }
            let egress = lastHour.reduce(Int64(0)) { $0 + $1.egressOut }
            if s.agentEgressBytesPerHour > 0, egress >= s.agentEgressBytesPerHour,
               shouldAlert("egress|\(bundleID)", every: 3600, now: now) {
                var totals: [String: Int64] = [:]
                lastHour.forEach { $0.destinations.forEach { totals[$0.key, default: 0] += $0.value } }
                let top = totals.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) (\(ByteFormat.string($0.value)))" }
                alerts.append(try db.addAlert(kind: Kind.agentExfiltration.rawValue, bundleID: bundleID, appName: name,
                                              detail: "\(name) uploaded \(ByteFormat.string(egress)) to non-AI hosts in the last hour: \(top.joined(separator: ", "))",
                                              severity: 3, at: now))
            }
            let recent = history.filter { $0.minute >= currentMinute - 1 }.reduce(Int64(0)) { $0 + $1.total }
            if s.agentWhileAway, idle >= s.agentAwayMinutes * 60, recent >= s.agentAwayBytes,
               shouldAlert("away|\(bundleID)", every: 3600, now: now) {
                alerts.append(try db.addAlert(kind: Kind.agentWhileAway.rawValue, bundleID: bundleID, appName: name,
                                              detail: "\(name) moved \(ByteFormat.string(recent)) in the last minute while you were away (no input for \(Int(idle / 60)) min)",
                                              severity: 2, at: now))
            }
        }
        if !alerts.isEmpty { onAlert(alerts) }
    }

    /// Called about once a minute: uploads by GUI apps the user has not touched recently.
    func evaluateIdleTraffic(now: Date = Date()) throws {
        try evaluateAgents(now: now)
        let s = settings()
        let uploads = minuteUploads
        minuteUploads.removeAll()
        var alerts: [AlertRecord] = []
        for (bundleID, entry) in uploads where entry.bytes >= s.idleUploadBytesPerMinute {
            guard let idle = activity.idleDuration(bundleID: bundleID), idle >= s.idleMinutes * 60 else { continue }
            if let last = lastIdleAlert[bundleID], now.timeIntervalSince(last) < 3600 { continue }
            lastIdleAlert[bundleID] = now
            alerts.append(try db.addAlert(kind: Kind.idleTraffic.rawValue, bundleID: bundleID, appName: entry.name,
                                          detail: "\(entry.name) uploaded \(ByteFormat.string(entry.bytes)) in the last minute while idle for \(Int(idle / 60)) min",
                                          severity: 2))
        }
        if !alerts.isEmpty { onAlert(alerts) }
    }

    // MARK: Baselines

    static func update(_ b: TrafficDatabase.Baseline?, with x: Double) -> TrafficDatabase.Baseline {
        guard var b, b.samples > 0 else { return .init(mean: x, variance: 0, samples: 1) }
        // Cumulative average while young, then an EWMA with ~1 week memory for hourly data.
        let alpha = max(1.0 / Double(b.samples + 1), 0.02)
        let diff = x - b.mean
        let increment = alpha * diff
        b.mean += increment
        b.variance = (1 - alpha) * (b.variance + diff * increment)
        b.samples += 1
        return b
    }

    static func zScore(_ x: Double, _ b: TrafficDatabase.Baseline, floor: Double) -> Double {
        let sd = max(b.variance.squareRoot(), floor)
        return (x - b.mean) / sd
    }

    func hourCompleted(_ hour: Int64) throws {
        let s = settings()
        let totals = try db.appTotals(table: "agg_1h", at: hour)
        var baselines = try db.baselines(metric: "bytes_hour")
        var alerts: [AlertRecord] = []

        for bundleID in Set(baselines.keys).union(totals.keys) {
            let entry = totals[bundleID]
            let x = Double(entry?.counters.total ?? 0)
            let name = entry?.name ?? bundleID
            if let b = baselines[bundleID], b.samples >= s.minHourlySamples, x >= Double(s.minAlertBytes) {
                let z = Self.zScore(x, b, floor: max(b.mean * 0.1, 64_000))
                if z >= s.sigma {
                    alerts.append(try db.addAlert(kind: Kind.volumeSpike.rawValue, bundleID: bundleID, appName: name,
                                                  detail: "\(name) moved \(ByteFormat.string(Int64(x))) in the hour starting \(Self.timeString(hour)) — \(String(format: "%.1f", z))σ above its baseline of \(ByteFormat.string(Int64(b.mean)))/h",
                                                  severity: z >= s.sigma * 2 ? 3 : 2))
                }
            }
            let updated = Self.update(baselines[bundleID], with: x)
            baselines[bundleID] = updated
            try db.saveBaseline(bundleID: bundleID, metric: "bytes_hour", updated)

            // Upload percentile rule.
            if let out = entry?.counters.bytesOut, out >= s.minAlertBytes {
                let history = try db.hourlyUploads(bundleID: bundleID, since: hour - 30 * 86400, before: hour).sorted()
                if history.count >= 48 {
                    let p99 = history[Int(Double(history.count - 1) * 0.99)]
                    if out > p99 {
                        alerts.append(try db.addAlert(kind: Kind.uploadPercentile.rawValue, bundleID: bundleID, appName: name,
                                                      detail: "\(name) uploaded \(ByteFormat.string(out)) in the hour starting \(Self.timeString(hour)); its 30-day p99 is \(ByteFormat.string(p99))",
                                                      severity: 2))
                    }
                }
            }
        }
        if !alerts.isEmpty { onAlert(alerts) }
    }

    func dayCompleted(_ day: Int64) throws {
        let s = settings()
        let totals = try db.appTotals(table: "agg_1d", at: day)
        var baselines = try db.baselines(metric: "destinations_day")
        var alerts: [AlertRecord] = []
        for bundleID in Set(baselines.keys).union(totals.keys) {
            let x = Double(totals[bundleID]?.destinations ?? 0)
            let name = totals[bundleID]?.name ?? bundleID
            if let b = baselines[bundleID], b.samples >= s.minDailySamples {
                let z = Self.zScore(x, b, floor: max(3, b.mean * 0.2))
                if z >= s.sigma {
                    alerts.append(try db.addAlert(kind: Kind.destinationSpike.rawValue, bundleID: bundleID, appName: name,
                                                  detail: "\(name) contacted \(Int(x)) distinct destinations on \(Self.dayString(day)) (baseline \(Int(b.mean.rounded())), \(String(format: "%.1f", z))σ)",
                                                  severity: 2))
                }
            }
            let updated = Self.update(baselines[bundleID], with: x)
            baselines[bundleID] = updated
            try db.saveBaseline(bundleID: bundleID, metric: "destinations_day", updated)
        }
        if !alerts.isEmpty { onAlert(alerts) }
    }

    private static func timeString(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private static func dayString(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
}
