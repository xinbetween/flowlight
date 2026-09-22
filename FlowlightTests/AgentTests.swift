import XCTest
@testable import Flowlight

final class AgentTests: XCTestCase {
    final class FakeActivity: ActivitySnapshotting, @unchecked Sendable {
        var idle: TimeInterval = 0
        func idleDuration(bundleID: String) -> TimeInterval? { nil }
        func systemIdleSeconds() -> TimeInterval { idle }
    }

    private func key(_ app: String, name: String? = nil, domain: String, ip: String = "93.184.216.34", port: UInt16 = 443,
                     proto: String = "https") -> FlowKey {
        FlowKey(pid: 1, bundleID: app, appName: name ?? app, appPath: "", remoteIP: ip, domain: domain, port: port,
                transport: .tcp, appProtocol: proto)
    }

    private func makeEngine(_ activity: FakeActivity = FakeActivity()) throws -> (AnomalyEngine, TrafficDatabase, () -> [AlertRecord]) {
        let db = try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID()).sqlite"))
        let engine = AnomalyEngine(db: db, activity: activity)
        var fired: [AlertRecord] = []
        engine.onAlert = { fired += $0 }
        engine.settings = { AnomalySettings() }
        return (engine, db, { fired })
    }

    func testCatalogRecognizesAgentsAndProviders() {
        XCTAssertEqual(AgentCatalog.knownAgent(bundleID: "claude", appName: "claude")?.name, "Claude Code")
        XCTAssertEqual(AgentCatalog.knownAgent(bundleID: "com.openai.chat", appName: "ChatGPT")?.vendor, "OpenAI")
        XCTAssertNil(AgentCatalog.knownAgent(bundleID: "com.apple.Safari", appName: "Safari"))
        XCTAssertEqual(AgentCatalog.provider(domain: "api.anthropic.com"), "Anthropic")
        XCTAssertEqual(AgentCatalog.provider(domain: "bedrock-runtime.us-east-1.amazonaws.com"), "AWS Bedrock")
        XCTAssertEqual(AgentCatalog.provider(domain: "my-res.openai.azure.com"), "Azure OpenAI")
        XCTAssertNil(AgentCatalog.provider(domain: "notopenai.com"), "suffix match respects label boundaries")
        XCTAssertEqual(AgentCatalog.provider(domain: "", owner: "Anthropic, PBC"), "Anthropic")
        XCTAssertNil(AgentCatalog.provider(domain: "", owner: "Cloudflare, Inc."))
    }

    func testModelFindsKnownAndDiscoveredAgentsButNotBrowsers() {
        func row(_ app: String, _ domain: String, _ ip: String, out: Int64, proto: String = "https", port: String = "443") -> BreakdownRow {
            BreakdownRow(bundleID: app, appName: app, appPath: "", domain: domain, remoteIP: ip, ports: port, protocols: proto,
                         counters: FlowCounters(bytesIn: 10, bytesOut: out, flows: 1))
        }
        let rows = [row("claude", "api.anthropic.com", "160.79.104.10", out: 5_000),
                    row("claude", "smtp.mailgun.org", "34.1.1.1", out: 2_000_000, proto: "smtp-submission", port: "587"),
                    row("python3", "api.openai.com", "104.18.1.1", out: 800),
                    row("python3", "", "45.9.9.9", out: 300, proto: "tcp", port: "4444"),
                    row("com.google.Chrome", "chatgpt.com", "104.18.2.2", out: 900),
                    row("com.apple.Music", "apple.com", "17.1.1.1", out: 50)]
        let agents = AgentsModel.build(rows: rows, alerts: [])
        XCTAssertEqual(Set(agents.map(\.bundleID)), ["claude", "python3"], "browsers and non-AI apps are not agents")
        let claude = agents.first { $0.bundleID == "claude" }!
        XCTAssertTrue(claude.isKnown)
        XCTAssertEqual(claude.name, "Claude Code")
        XCTAssertEqual(claude.ai.bytesOut, 5_000)
        XCTAssertEqual(claude.egress.bytesOut, 2_000_000)
        XCTAssertEqual(claude.sensitiveProtocols, ["smtp-submission"])
        let python = agents.first { $0.bundleID == "python3" }!
        XCTAssertFalse(python.isKnown, "discovered through its LLM API calls")
        XCTAssertEqual(python.providers.first?.name, "OpenAI")
        XCTAssertTrue(python.otherDestinations.contains { $0.isUnnamed })
        XCTAssertGreaterThan(claude.riskScore, python.riskScore)
        XCTAssertTrue(IPOwnerLookup.isLocalNetwork("192.168.1.1"))
        XCTAssertTrue(IPOwnerLookup.isLocalNetwork("fe80::1"))
        XCTAssertFalse(IPOwnerLookup.isLocalNetwork("203.0.113.9"), "reserved ranges still count as leaving the Mac")
    }

    func testSensitiveChannelAndUnnamedHostAlerts() throws {
        let (engine, _, fired) = try makeEngine()
        try engine.observe([TrafficBatch(timestamp: 1000, records: [
            TrafficRecord(key: key("claude", domain: "api.anthropic.com"), counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1)),
            TrafficRecord(key: key("claude", domain: "smtp.mailgun.org", port: 587, proto: "smtp-submission"),
                          counters: FlowCounters(bytesIn: 10, bytesOut: 50_000, flows: 1)),
            TrafficRecord(key: key("claude", domain: "", ip: "45.9.9.9", port: 4444, proto: "tcp"),
                          counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 1)),
        ])])
        let kinds = fired().map(\.kind)
        XCTAssertTrue(kinds.contains(AnomalyEngine.Kind.agentSensitiveChannel.rawValue))
        XCTAssertTrue(kinds.contains(AnomalyEngine.Kind.agentUnnamedHost.rawValue))
        let smtp = fired().first { $0.kind == AnomalyEngine.Kind.agentSensitiveChannel.rawValue }!
        XCTAssertEqual(smtp.severity, 3, "email from an agent is critical")
        XCTAssertTrue(smtp.detail.contains("smtp.mailgun.org"))
        // Repeats are rate-limited.
        let before = fired().count
        try engine.observe([TrafficBatch(timestamp: 1001, records: [
            TrafficRecord(key: key("claude", domain: "smtp.mailgun.org", port: 587, proto: "smtp-submission"),
                          counters: FlowCounters(bytesIn: 1, bytesOut: 1, flows: 0)),
        ])])
        XCTAssertEqual(fired().count, before)
    }

    /// The September 2026 ZCode incident: an AI coding app packaged whole workspaces (86% .git history) and
    /// uploaded ~313 MB snapshots to Alibaba Cloud storage in the background.
    func testZCodeStyleWorkspaceUploadIsFlagged() throws {
        XCTAssertEqual(AgentCatalog.knownAgent(bundleID: "ai.z.zcode", appName: "ZCode")?.vendor, "Zhipu AI")
        XCTAssertEqual(AgentCatalog.provider(domain: "open.bigmodel.cn"), "Zhipu AI")
        XCTAssertEqual(AgentCatalog.provider(domain: "api.z.ai"), "Zhipu AI")
        XCTAssertEqual(AgentCatalog.provider(domain: "dashscope.aliyuncs.com"), "Alibaba Qwen")
        XCTAssertNil(AgentCatalog.provider(domain: "zcode-snapshots.oss-cn-beijing.aliyuncs.com"), "cloud storage is not an AI API")

        let (engine, _, fired) = try makeEngine()
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970)
        try engine.observe([TrafficBatch(timestamp: ts, records: [
            TrafficRecord(key: key("ai.z.zcode", name: "ZCode", domain: "open.bigmodel.cn"),
                          counters: FlowCounters(bytesIn: 40_000, bytesOut: 20_000, flows: 1)),
            TrafficRecord(key: key("ai.z.zcode", name: "ZCode", domain: "zcode-snapshots.oss-cn-beijing.aliyuncs.com"),
                          counters: FlowCounters(bytesIn: 2_000, bytesOut: 313_000_000, flows: 1)),
        ])])
        try engine.evaluateAgents(now: now)
        let exfil = fired().first { $0.kind == AnomalyEngine.Kind.agentExfiltration.rawValue }
        XCTAssertNotNil(exfil, "a 313 MB upload to non-AI storage raises a critical alert")
        XCTAssertEqual(exfil?.severity, 3)
        XCTAssertTrue(exfil?.detail.contains("oss-cn-beijing.aliyuncs.com") == true)

        // Also caught with no hostname at all (packet capture off): egress is counted by destination, not name.
        let (bare, _, bareFired) = try makeEngine()
        try bare.observe([TrafficBatch(timestamp: ts, records: [
            TrafficRecord(key: key("ai.z.zcode", name: "ZCode", domain: "", ip: "47.95.1.10"),
                          counters: FlowCounters(bytesIn: 0, bytesOut: 313_000_000, flows: 1)),
        ])])
        try bare.evaluateAgents(now: now)
        XCTAssertTrue(bareFired().contains { $0.kind == AnomalyEngine.Kind.agentExfiltration.rawValue })
    }

    func testDiscoveryExfiltrationAndWhileAway() throws {
        let activity = FakeActivity()
        let (engine, _, fired) = try makeEngine(activity)
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970)
        // An unknown script becomes an agent once it calls an LLM API…
        try engine.observe([TrafficBatch(timestamp: ts, records: [
            TrafficRecord(key: key("node", domain: "api.openai.com"), counters: FlowCounters(bytesIn: 5, bytesOut: 5, flows: 1)),
        ])])
        XCTAssertEqual(engine.agentName(bundleID: "node", appName: "node"), "node")
        XCTAssertNil(engine.agentName(bundleID: "com.google.Chrome", appName: "Chrome"))
        // …then uploads 150 MB to storage while the user is away.
        activity.idle = 30 * 60
        try engine.observe([TrafficBatch(timestamp: ts, records: [
            TrafficRecord(key: key("node", domain: "bucket.s3.amazonaws.com"), counters: FlowCounters(bytesIn: 0, bytesOut: 150_000_000, flows: 1)),
        ])])
        try engine.evaluateAgents(now: now)
        let kinds = Set(fired().map(\.kind))
        XCTAssertTrue(kinds.contains(AnomalyEngine.Kind.agentExfiltration.rawValue))
        XCTAssertTrue(kinds.contains(AnomalyEngine.Kind.agentWhileAway.rawValue))
        let exfil = fired().first { $0.kind == AnomalyEngine.Kind.agentExfiltration.rawValue }!
        XCTAssertTrue(exfil.detail.contains("bucket.s3.amazonaws.com"))
        XCTAssertFalse(exfil.detail.contains("api.openai.com"), "AI provider traffic is not egress")
    }
}
