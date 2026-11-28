import Foundation

/// An opt-in synthetic workload for the AI Agents page. No endpoint in this fixture is contacted.
enum DemoAgentsStress {
    static let quietAgent = "com.example.flowlight.quiet"
    static let quietAgentName = "Quiet Demo Agent"
    static let quietCounters = FlowCounters(bytesIn: 73, bytesOut: 19, flows: 1)
    static let historicalDuration: Int64 = 6 * 3_600
    static let historicalRows = 120_000
    static let liveRowsPerSecond = 5

    static func seed(_ db: TrafficDatabase, now: Date = Date()) throws {
        let end = Int64(now.timeIntervalSince1970) / 60 * 60
        let start = end - historicalDuration
        var batches: [TrafficBatch] = []
        batches.reserveCapacity(600)
        for second in start..<end {
            batches.append(batch(at: second, extra: second - start < Int64(historicalRows) - historicalDuration * 5))
            if batches.count == 600 {
                try db.insert(batches)
                batches.removeAll(keepingCapacity: true)
            }
        }
        if !batches.isEmpty { try db.insert(batches) }
        // Fold the seed once through the same minute, hour, and day path used during the soak. The live feed
        // writes seconds only, so maintenance can advance every tier without adding the seed twice.
        var retention = TrafficDatabase.Retention()
        retention.seconds = 10 * 3_600
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(end + 5)), retention: retention)
        try db.savePolicy(AgentPolicy(agentID: "claude", enabled: true, allowAIProviders: true,
                                      patterns: ["github.com"]))
        try DemoData.seedInspection(db, now: now)
    }

    static func batch(at second: Int64, extra: Bool = false) -> TrafficBatch {
        let proxyID = "com.example.flowlight.demo-proxy"
        let proxyName = "Demo TUN Proxy"
        func record(slot: Int) -> TrafficRecord {
            let index = (Int(second % 8_192) * 2 + slot) % 8_192
            let busyAgent = slot == 0 || slot == 1
            let quiet = slot == 4 && second % 60 == 53
            let app = quiet ? (quietAgent, quietAgentName)
                : busyAgent ? ("claude", "Claude Code")
                : ("com.example.flowlight.proxy-client.\(slot)", "Demo Proxy Client \(slot)")
            let host: String
            let ip: String
            if quiet {
                host = "api.openai.com"
                ip = "203.0.113.253"
            } else if busyAgent {
                host = "agent-\(index).example"
                ip = "198.18.\(index / 256).\(index % 256)"
            } else {
                host = slot == 3 ? "" : "site-\(index).example"
                ip = "198.19.\(index / 256).\(index % 256)"
            }
            let key = FlowKey(pid: Int32(4_100 + slot), bundleID: app.0, appName: app.1, appPath: "",
                              remoteIP: ip, domain: host, port: 443, transport: .tcp, appProtocol: "HTTPS",
                              routeProxyBundleID: proxyID, routeProxyName: proxyName)
            let counters = quiet ? quietCounters
                : FlowCounters(bytesIn: Int64(1_000 + index), bytesOut: Int64(100 + slot), flows: 1)
            return TrafficRecord(key: key, counters: counters)
        }
        let count = liveRowsPerSecond + (extra ? 1 : 0)
        return TrafficBatch(timestamp: second, records: (0..<count).map(record))
    }
}

/// Samples wall-clock scheduling delay on the app's main queue during the disposable demo only.
@MainActor
final class DemoAgentsMainQueueProbe {
    private var timer: DispatchSourceTimer?
    private var previous = DispatchTime.now().uptimeNanoseconds
    private var peakLag: UInt64 = 0
    private var ticks = 0

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    private func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = now - previous
        previous = now
        let lag = gap > 250_000_000 ? (gap - 250_000_000) / 1_000_000 : 0
        peakLag = max(peakLag, lag)
        ticks += 1
        if lag >= 500 { NSLog("AGENTS_STRESS_MAIN_STALL lag_ms=%llu", lag) }
        if ticks == 240 {
            NSLog("AGENTS_STRESS_MAIN_PEAK lag_ms=%llu", peakLag)
            ticks = 0
            peakLag = 0
        }
    }

    deinit { timer?.cancel() }
}
