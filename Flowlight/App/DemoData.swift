import Foundation

/// Synthetic but realistic traffic for trying Flowlight and for screenshots (`-FLDemo YES`).
/// Suspicious destinations use reserved documentation addresses (203.0.113.0/24, *.example) so no
/// real service is depicted as malicious.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "FLDemo") }

    static var databaseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flowlight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("demo.sqlite")
    }

    static func resetDatabase() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    struct Flow {
        var host: String
        var ip: String
        var port: UInt16
        var proto: String
        var transport: TransportProtocol = .tcp
        var inRate: Double      // bytes per active minute
        var outRate: Double
    }

    struct App {
        var bundleID: String
        var name: String
        var path: String
        var weight: Double      // how busy during work hours
        var flows: [Flow]
        /// Set for tools and MCP servers an agent started: (agent bundle ID, agent name, MCP server).
        var parent: (id: String, name: String, mcp: String?)? = nil

        func key(_ flow: Flow) -> FlowKey {
            FlowKey(pid: Int32(abs(bundleID.hashValue % 30_000) + 200), bundleID: bundleID, appName: name, appPath: path,
                    remoteIP: flow.ip, domain: flow.host, port: flow.port, transport: flow.transport, appProtocol: flow.proto,
                    parentAgent: parent?.id, parentAgentName: parent?.name, mcpServer: parent?.mcp)
        }
    }

    static let apps: [App] = [
        App(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app", weight: 1.0, flows: [
            Flow(host: "www.youtube.com", ip: "198.51.100.10", port: 443, proto: "quic", transport: .udp, inRate: 9_000_000, outRate: 200_000),
            Flow(host: "github.com", ip: "198.51.100.11", port: 443, proto: "https", inRate: 700_000, outRate: 60_000),
            Flow(host: "docs.google.com", ip: "198.51.100.12", port: 443, proto: "https", inRate: 500_000, outRate: 90_000),
            Flow(host: "news.ycombinator.com", ip: "198.51.100.13", port: 443, proto: "https", inRate: 90_000, outRate: 8_000),
            Flow(host: "chatgpt.com", ip: "198.51.100.14", port: 443, proto: "https", inRate: 300_000, outRate: 40_000),
        ]),
        App(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app", weight: 0.4, flows: [
            Flow(host: "www.apple.com", ip: "198.51.100.20", port: 443, proto: "https", inRate: 600_000, outRate: 20_000),
            Flow(host: "en.wikipedia.org", ip: "198.51.100.21", port: 443, proto: "https", inRate: 250_000, outRate: 9_000),
        ]),
        App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app", weight: 0.8, flows: [
            Flow(host: "wss-primary.slack.com", ip: "198.51.100.30", port: 443, proto: "websocket", inRate: 120_000, outRate: 30_000),
            Flow(host: "files.slack.com", ip: "198.51.100.31", port: 443, proto: "https", inRate: 400_000, outRate: 90_000),
        ]),
        App(bundleID: "com.apple.Music", name: "Music", path: "/System/Applications/Music.app", weight: 0.6, flows: [
            Flow(host: "aod.itunes.apple.com", ip: "198.51.100.40", port: 443, proto: "https", inRate: 1_600_000, outRate: 10_000),
        ]),
        App(bundleID: "com.apple.mail", name: "Mail", path: "/System/Applications/Mail.app", weight: 0.3, flows: [
            Flow(host: "imap.mail.me.com", ip: "198.51.100.50", port: 993, proto: "imaps", inRate: 200_000, outRate: 15_000),
            Flow(host: "smtp.mail.me.com", ip: "198.51.100.51", port: 587, proto: "smtp-submission", inRate: 4_000, outRate: 60_000),
        ]),
        App(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app", weight: 0.5, flows: [
            Flow(host: "marketplace.visualstudio.com", ip: "198.51.100.60", port: 443, proto: "https", inRate: 150_000, outRate: 10_000),
            Flow(host: "api.githubcopilot.com", ip: "198.51.100.61", port: 443, proto: "https", inRate: 90_000, outRate: 70_000),
        ]),
        App(bundleID: "us.zoom.xos", name: "zoom.us", path: "/Applications/zoom.us.app", weight: 0.25, flows: [
            Flow(host: "zoom.us", ip: "198.51.100.70", port: 8801, proto: "zoom-media", transport: .udp, inRate: 6_000_000, outRate: 4_500_000),
        ]),
        App(bundleID: "claude", name: "claude", path: "/opt/homebrew/bin/claude", weight: 0.9, flows: [
            Flow(host: "api.anthropic.com", ip: "198.51.100.80", port: 443, proto: "https", inRate: 700_000, outRate: 1_400_000),
            Flow(host: "registry.npmjs.org", ip: "198.51.100.81", port: 443, proto: "https", inRate: 300_000, outRate: 10_000),
            Flow(host: "github.com", ip: "198.51.100.11", port: 22, proto: "ssh", inRate: 50_000, outRate: 30_000),
        ]),
        App(bundleID: "git", name: "git", path: "/usr/bin/git", weight: 0.5, flows: [
            Flow(host: "github.com", ip: "198.51.100.11", port: 443, proto: "https", inRate: 400_000, outRate: 60_000),
        ], parent: ("claude", "Claude Code", nil)),
        App(bundleID: "node", name: "node", path: "/opt/homebrew/bin/node", weight: 0.5, flows: [
            Flow(host: "api.github.com", ip: "198.51.100.12", port: 443, proto: "https", inRate: 120_000, outRate: 20_000),
        ], parent: ("claude", "Claude Code", "github")),
        App(bundleID: "uv", name: "uv", path: "/opt/homebrew/bin/uv", weight: 0.3, flows: [
            Flow(host: "docs.python.org", ip: "198.51.100.13", port: 443, proto: "https", inRate: 200_000, outRate: 8_000),
        ], parent: ("com.todesktop.230313mzl4w4u92", "Cursor", "fetch")),
        App(bundleID: "curl", name: "curl", path: "/usr/bin/curl", weight: 0.05, flows: [
            Flow(host: "registry.npmjs.org", ip: "198.51.100.81", port: 443, proto: "https", inRate: 30_000, outRate: 2_000),
        ], parent: ("claude", "Claude Code", nil)),
        App(bundleID: "codex", name: "codex", path: "/opt/homebrew/bin/codex", weight: 0.6, flows: [
            Flow(host: "api.openai.com", ip: "198.51.100.90", port: 443, proto: "https", inRate: 500_000, outRate: 900_000),
            Flow(host: "pypi.org", ip: "198.51.100.91", port: 443, proto: "https", inRate: 200_000, outRate: 6_000),
        ]),
        App(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", path: "/Applications/Cursor.app", weight: 0.7, flows: [
            Flow(host: "api2.cursor.sh", ip: "198.51.100.100", port: 443, proto: "https", inRate: 600_000, outRate: 800_000),
            Flow(host: "repo42.cursor.sh", ip: "198.51.100.101", port: 443, proto: "https", inRate: 80_000, outRate: 200_000),
        ]),
        App(bundleID: "com.electron.ollama", name: "Ollama", path: "/Applications/Ollama.app", weight: 0.1, flows: [
            Flow(host: "registry.ollama.ai", ip: "198.51.100.110", port: 443, proto: "https", inRate: 20_000_000, outRate: 20_000),
        ]),
        App(bundleID: "python3", name: "python3", path: "/opt/homebrew/bin/python3", weight: 0.3, flows: [
            Flow(host: "api.mistral.ai", ip: "198.51.100.120", port: 443, proto: "https", inRate: 90_000, outRate: 150_000),
            Flow(host: "", ip: "203.0.113.45", port: 4444, proto: "tcp", inRate: 3_000, outRate: 40_000),
        ]),
        App(bundleID: "com.apple.CloudDocs.MobileDocumentsFileProvider", name: "iCloud Drive", path: "/System/Library/CoreServices/Finder.app", weight: 0.3, flows: [
            Flow(host: "p45-content.icloud.com", ip: "198.51.100.130", port: 443, proto: "https", inRate: 400_000, outRate: 700_000),
        ]),
        App(bundleID: "mDNSResponder", name: "mDNSResponder", path: "/usr/sbin/mDNSResponder", weight: 1.0, flows: [
            Flow(host: "", ip: "192.168.1.1", port: 53, proto: "dns", transport: .udp, inRate: 20_000, outRate: 8_000),
            Flow(host: "dns.google", ip: "198.51.100.140", port: 443, proto: "dns-over-https", inRate: 6_000, outRate: 3_000),
        ]),
        App(bundleID: "apsd", name: "apsd", path: "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd", weight: 1.0, flows: [
            Flow(host: "", ip: "198.51.100.150", port: 5223, proto: "apns", inRate: 3_000, outRate: 1_500),
        ]),
        App(bundleID: "timed", name: "timed", path: "/usr/libexec/timed", weight: 1.0, flows: [
            Flow(host: "time.apple.com", ip: "198.51.100.160", port: 123, proto: "ntp", transport: .udp, inRate: 200, outRate: 200),
        ]),
    ]

    /// Anomalies placed in the recent past: (minutes ago, app, flow, bytes out).
    static let incidents: [(minutesAgo: Int, app: String, flow: Flow, bytesOut: Int64)] = [
        (95, "codex", Flow(host: "uploads.paste.example", ip: "203.0.113.20", port: 443, proto: "https", inRate: 0, outRate: 0), 180_000_000),
        (40, "claude", Flow(host: "smtp.relay.example", ip: "203.0.113.25", port: 587, proto: "smtp-submission", inRate: 0, outRate: 0), 2_400_000),
        (22, "python3", Flow(host: "", ip: "203.0.113.45", port: 4444, proto: "tcp", inRate: 0, outRate: 0), 9_000_000),
        (12, "curl", Flow(host: "paste.example", ip: "203.0.113.60", port: 443, proto: "https", inRate: 0, outRate: 0), 1_200_000),
        (300, "Cursor", Flow(host: "files.share.example", ip: "203.0.113.30", port: 21, proto: "ftp", inRate: 0, outRate: 0), 35_000_000),
    ]

    static func owners() -> [String: IPOwner] {
        ["198.51.100.150": IPOwner(asn: 714, name: "Apple Inc."), "203.0.113.45": IPOwner(asn: 64_512, name: "Example Hosting")]
    }

    private static func key(_ app: App, _ flow: Flow) -> FlowKey { app.key(flow) }

    /// Activity level by local hour: busy 9–19, quiet overnight, lighter on weekends.
    static func activity(at date: Date, calendar: Calendar = .current) -> Double {
        let hour = calendar.component(.hour, from: date)
        let weekend = calendar.isDateInWeekend(date)
        let base: Double = (9...18).contains(hour) ? 1.0 : (7...22).contains(hour) ? 0.45 : 0.06
        return base * (weekend ? 0.45 : 1)
    }

    /// Fills the tiers with history ending now and marks them rolled up.
    static func seed(_ db: TrafficDatabase, now: Date = Date()) throws {
        var rng = SeededGenerator(seed: 42)
        let nowTs = Int64(now.timeIntervalSince1970)
        let minuteNow = (nowTs / 60) * 60
        var minutes: [(Int64, FlowKey, FlowCounters)] = []
        var hours: [Int64: [FlowKey: FlowCounters]] = [:]
        var days: [Int64: [FlowKey: FlowCounters]] = [:]
        let offset = Int64(TimeZone.current.secondsFromGMT(for: now))

        func add(ts: Int64, key: FlowKey, counters: FlowCounters, minuteDetail: Bool) {
            if minuteDetail { minutes.append((ts, key, counters)) }
            hours[(ts / 3600) * 3600, default: [:]][key, default: FlowCounters()] += counters
            days[((ts + offset) / 86400) * 86400 - offset, default: [:]][key, default: FlowCounters()] += counters
        }

        // 26 hours at minute resolution, 90 days at 15-minute steps (aggregated to hours/days only).
        let detailedFrom = minuteNow - 26 * 3600
        var ts = minuteNow - 90 * 86400
        while ts < minuteNow {
            let detailed = ts >= detailedFrom
            let step: Int64 = detailed ? 60 : 900
            let level = activity(at: Date(timeIntervalSince1970: TimeInterval(ts)))
            for app in apps {
                let busy = app.weight * level
                guard Double.random(in: 0...1, using: &rng) < min(0.95, busy + 0.03) else { continue }
                for flow in app.flows where Double.random(in: 0...1, using: &rng) < 0.7 {
                    let jitter = Double.random(in: 0.2...1.8, using: &rng) * Double(step) / 60 * (0.4 + busy)
                    let c = FlowCounters(bytesIn: Int64(flow.inRate * jitter), bytesOut: Int64(flow.outRate * jitter),
                                         flows: Int64.random(in: 0...2, using: &rng))
                    add(ts: ts, key: key(app, flow), counters: c, minuteDetail: detailed)
                }
            }
            ts += step
        }
        // A weekly backup spike (Sunday 2 am) so long views have something to show.
        for weeksAgo in 1...12 {
            let t = minuteNow - Int64(weeksAgo) * 7 * 86400
            let app = apps.first { $0.bundleID.hasPrefix("com.apple.CloudDocs") }!
            add(ts: t, key: key(app, app.flows[0]), counters: FlowCounters(bytesIn: 10_000_000, bytesOut: 2_500_000_000, flows: 4),
                minuteDetail: false)
        }
        for incident in incidents {
            let app = apps.first { $0.name == incident.app || $0.bundleID == incident.app }!
            let t = minuteNow - Int64(incident.minutesAgo) * 60
            add(ts: t, key: key(app, incident.flow), counters: FlowCounters(bytesIn: incident.bytesOut / 200, bytesOut: incident.bytesOut, flows: 3),
                minuteDetail: true)
        }

        try db.insertAggregates("agg_1m", minutes.map { ($0.0, $0.1, $0.2) })
        try db.insertAggregates("agg_1h", hours.flatMap { ts, keys in keys.map { (ts, $0.key, $0.value) } })
        try db.insertAggregates("agg_1d", days.flatMap { ts, keys in keys.map { (ts, $0.key, $0.value) } })
        try db.setRollupWatermarks(minuteNow)
        for (ip, owner) in owners() { try db.saveOwner(ip: ip, owner) }
        try db.savePolicy(AgentPolicy(agentID: "claude", enabled: true, allowAIProviders: true,
                                      patterns: ["github.com", "npmjs.org", "githubusercontent.com"]))
        try seedAlerts(db, now: now)
    }

    private static func seedAlerts(_ db: TrafficDatabase, now: Date) throws {
        typealias K = AnomalyEngine.Kind
        let items: [(Int, K, String, String, String, Int)] = [
            (12, .allowlistViolation, "claude", "Claude Code › curl", "Claude Code › curl contacted paste.example:443 (https), which isn't on Claude Code's allowlist — 1.2 MB sent", 3),
            (95, .agentExfiltration, "codex", "Codex", "Codex uploaded 180 MB to non-AI hosts in the last hour: uploads.paste.example (180 MB)", 3),
            (40, .agentSensitiveChannel, "claude", "Claude Code", "Claude Code used SMTP-SUBMISSION (email) to smtp.relay.example:587 — 2.4 MB sent", 3),
            (22, .agentUnnamedHost, "python3", "python3", "python3 connected to Example Hosting 203.0.113.45:4444 (tcp) with no hostname", 2),
            (300, .agentSensitiveChannel, "com.todesktop.230313mzl4w4u92", "Cursor", "Cursor used FTP (file transfer) to files.share.example:21 — 35 MB sent", 3),
            (410, .agentWhileAway, "codex", "Codex", "Codex moved 48 MB in the last minute while you were away (no input for 37 min)", 2),
            (620, .volumeSpike, "com.apple.CloudDocs.MobileDocumentsFileProvider", "iCloud Drive", "iCloud Drive moved 2.5 GB in the hour starting 2:00 AM — 9.4σ above its baseline of 38 MB/h", 3),
            (840, .firstContact, "com.todesktop.230313mzl4w4u92", "Cursor", "Cursor contacted repo42.cursor.sh (198.51.100.101:443) for the first time", 1),
            (1300, .nonStandardPort, "python3", "python3", "python3 → 203.0.113.45 on TCP port 4444 (tcp)", 2),
        ]
        for (minutesAgo, kind, bundle, name, detail, severity) in items {
            try db.addAlert(kind: kind.rawValue, bundleID: bundle, appName: name, detail: detail, severity: severity,
                            at: now.addingTimeInterval(-Double(minutesAgo) * 60))
        }
    }
}

/// Live feed for demo mode: plausible per-second batches following the same app mix.
final class DemoTrafficSource: TrafficSource, @unchecked Sendable {
    let displayName = "Demo data"
    private var timer: DispatchSourceTimer?
    private var rng = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970))

    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            sink([self.batch(at: Int64(Date().timeIntervalSince1970) - 1)])
        }
        timer.resume()
        self.timer = timer
        status("Demo mode · synthetic traffic")
    }

    func stop() { timer?.cancel(); timer = nil }

    private func batch(at ts: Int64) -> TrafficBatch {
        var records: [TrafficRecord] = []
        let level = max(0.35, DemoData.activity(at: Date()))
        for app in DemoData.apps where Double.random(in: 0...1, using: &rng) < min(0.9, app.weight * level + 0.05) {
            for flow in app.flows where Double.random(in: 0...1, using: &rng) < 0.5 {
                let scale = Double.random(in: 0.1...1.6, using: &rng) / 60
                let burst = Double.random(in: 0...1, using: &rng) < 0.03 ? 12.0 : 1.0
                let key = app.key(flow)
                records.append(TrafficRecord(key: key, counters: FlowCounters(bytesIn: Int64(flow.inRate * scale * burst),
                                                                             bytesOut: Int64(flow.outRate * scale * burst),
                                                                             flows: Double.random(in: 0...1, using: &rng) < 0.05 ? 1 : 0)))
            }
        }
        return TrafficBatch(timestamp: ts, records: records)
    }
}

/// Deterministic RNG so demo history looks the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
