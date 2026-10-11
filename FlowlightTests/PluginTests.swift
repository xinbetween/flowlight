import XCTest
@testable import Flowlight

final class PluginTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID()).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func database() throws -> TrafficDatabase { try TrafficDatabase(url: url) }

    private func exchange(method: String = "DELETE", path: String = "/admin/delete?token=secret", requestSize: Int = 700_000,
                          headers: [HTTPHeader] = [HTTPHeader(name: "Authorization", value: "Bearer secret-token"),
                                                   HTTPHeader(name: "X-API-Key", value: "secret-key")],
                          toolCalls: [ToolCall] = [], llm: LLMFacts? = nil, mcp: [MCPActivity] = []) -> HTTPExchange {
        HTTPExchange(id: nil, started: Date(), duration: 0.2, scheme: "https", host: "api.example.test", port: 443,
                     method: method, path: path, status: 200, requestHeaders: headers,
                     requestBody: Data("{\"secret\":\"do-not-leak\"}".utf8), requestSize: requestSize, requestTruncated: false,
                     responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false, contentType: "application/json",
                     pid: 1, bundleID: "agent", appName: "Agent", agent: "agent", agentName: "Agent", mcpServer: nil,
                     toolCalls: toolCalls, toolResults: [], mcp: mcp, llm: llm, note: nil, mockRule: nil, guardrail: nil)
    }

    func testBuiltInTrafficPluginsProduceBoundedAdvisoryFindings() {
        let findings = PluginEngine.evaluate(exchange(), manifests: PluginEngine.builtInManifests)
        XCTAssertTrue(findings.contains { $0.pluginID == "traffic.large-upload" })
        XCTAssertTrue(findings.contains { $0.pluginID == "traffic.risky-method" })
        XCTAssertTrue(findings.contains { $0.pluginID == "traffic.sensitive-headers" })
        let allText = findings.flatMap { [$0.title, $0.summary] + $0.evidence.map(\.value) }.joined(separator: "\n")
        XCTAssertFalse(allText.contains("secret-token"))
        XCTAssertFalse(allText.contains("secret-key"))
        XCTAssertFalse(allText.contains("do-not-leak"))
    }

    func testHighRiskToolPluginSuggestsARealGuardrail() throws {
        let llm = LLMFacts(provider: .anthropic, model: "claude-test", declaredTools: [DeclaredTool(name: "Bash", kind: .function)],
                           connectors: [], usage: nil, stopReason: nil, errorType: nil)
        let findings = PluginEngine.evaluate(exchange(requestSize: 10, headers: [], llm: llm), manifests: PluginEngine.builtInManifests)
        let finding = try XCTUnwrap(findings.first { $0.pluginID == "llm-mcp.high-risk-tools" })
        XCTAssertEqual(finding.kind, .llmMCP)
        let guardrail = try XCTUnwrap(finding.suggestedGuardrail)
        XCTAssertEqual(guardrail.origin, .observed)
        XCTAssertEqual(guardrail.tool, "Bash")
        XCTAssertTrue(guardrail.isComplete)
    }

    func testDisabledPluginProducesNoNewFinding() throws {
        let manifests = PluginEngine.builtInManifests.map { manifest -> PluginManifest in
            var copy = manifest
            if copy.id == "traffic.large-upload" { copy.enabled = false }
            return copy
        }
        let findings = PluginEngine.evaluate(exchange(), manifests: manifests)
        XCTAssertFalse(findings.contains { $0.pluginID == "traffic.large-upload" })
        XCTAssertTrue(findings.contains { $0.pluginID == "traffic.risky-method" })
    }

    func testFindingsPersistHideWhenDisabledAndPruneWithExchange() throws {
        let db = try database()
        let id = try db.insertExchange(exchange())
        let visible = try db.pluginFindings(exchangeIDs: [id])
        XCTAssertNotNil(visible[id]?.first { $0.pluginID == "traffic.large-upload" })

        try db.setPluginEnabled(id: "traffic.large-upload", enabled: false)
        XCTAssertNil(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "traffic.large-upload" })
        XCTAssertNotNil(try db.pluginFindings(exchangeIDs: [id], visibleOnly: false)[id]?.first { $0.pluginID == "traffic.large-upload" })

        try db.pruneExchanges(olderThan: Date().addingTimeInterval(60))
        XCTAssertTrue(try db.pluginFindings(exchangeIDs: [id], visibleOnly: false).isEmpty)
    }

    func testManifestTracksOfficialCommonGuardrailProviders() throws {
        var manifest = PluginManifest(id: "official.presidio-pii", name: "Presidio PII", version: "1.0.0", kind: .llmMCP,
                                      guardrailProvider: .presidio,
                                      description: "Detects and masks PII.", privacySummary: "Uses redacted inspection metadata.")
        manifest.source = .installed
        manifest.publisher = .official
        manifest.configuration = ["policy": "default"]
        manifest.script = "function evaluate(context) { return []; }"
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: data)
        XCTAssertEqual(decoded.publisher, .official)
        XCTAssertEqual(decoded.guardrailProvider, .presidio)
        XCTAssertEqual(decoded.configuration["policy"], "default")
        XCTAssertEqual(decoded.script, "function evaluate(context) { return []; }")
        XCTAssertEqual(PluginManifest.GuardrailProvider.prismaAIRS.title, "PANW Prisma AIRS")

        let legacy = Data(#"{"id":"legacy.plugin","name":"Legacy","version":"0.1.0","kind":"traffic","description":"Legacy plugin.","privacySummary":"Metadata only."}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PluginManifest.self, from: legacy).script, "")
    }

    func testPluginPackageAcceptsBareManifestAndWrappedPackage() throws {
        let bare = Data(#"{"id":"thirdparty.test","name":"Test","version":"0.1.0","kind":"traffic","source":"installed","publisher":"thirdParty","guardrailProvider":"custom","description":"Test plugin.","privacySummary":"Uses metadata only.","capabilities":["annotate"]}"#.utf8)
        let decodedBare = try JSONDecoder().decode(PluginPackage.self, from: bare)
        XCTAssertEqual(decodedBare.manifest.id, "thirdparty.test")

        let wrapped = try JSONEncoder().encode(PluginPackage(manifest: decodedBare.manifest))
        let decodedWrapped = try JSONDecoder().decode(PluginPackage.self, from: wrapped)
        XCTAssertEqual(decodedWrapped.manifest.id, "thirdparty.test")
    }

    @MainActor
    func testPluginStoreRejectsReservedBuiltInPackageID() {
        let store = PluginStore()
        let data = Data(#"{"id":"traffic.large-upload","name":"Pretend","version":"0.1.0","kind":"traffic","source":"installed","publisher":"thirdParty","guardrailProvider":"custom","description":"Pretend plugin.","privacySummary":"Uses metadata only.","capabilities":["annotate"]}"#.utf8)
        let exp = expectation(description: "import completes")
        store.attach(db: try! database())
        store.importPackage(data: data) { result in
            if case .failure(let error as PluginPackageError) = result {
                XCTAssertEqual(error, .reservedBuiltInID)
            } else {
                XCTFail("expected reserved built-in ID rejection")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testInstalledPluginConfigurationAndRemovalPersist() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.example", name: "Example", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Example plugin.", privacySummary: "Uses metadata only.")
        try db.savePluginManifest(manifest)
        try db.updatePluginConfiguration(id: manifest.id, configuration: ["mode": "audit"])
        manifest = try XCTUnwrap(db.loadPluginManifests().first { $0.id == "thirdparty.example" })
        XCTAssertEqual(manifest.configuration["mode"], "audit")

        try db.deleteInstalledPlugin(id: manifest.id)
        XCTAssertNil(try db.loadPluginManifests().first { $0.id == "thirdparty.example" })
    }

    func testBackfillRecreatesBuiltInFindingsForRetainedExchanges() throws {
        let db = try database()
        let id = try db.insertExchange(exchange())
        XCTAssertFalse(try db.pluginFindings(exchangeIDs: [id]).isEmpty)
        try db.clearPluginFindings()
        XCTAssertTrue(try db.pluginFindings(exchangeIDs: [id], visibleOnly: false).isEmpty)
        let count = try db.backfillPluginFindings(pluginID: "traffic.large-upload")
        XCTAssertEqual(count, 1)
        let findings = try db.pluginFindings(exchangeIDs: [id], visibleOnly: false)
        XCTAssertEqual(findings[id]?.map(\.pluginID), ["traffic.large-upload"])
    }

    func testInstalledJavaScriptPluginProducesBoundedFinding() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.js", name: "JS", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses metadata only.")
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'low',
            title: 'JS saw host',
            summary: context.exchange.appName + ' contacted ' + context.exchange.host,
            evidence: [
              { label: 'Host', value: context.exchange.host },
              { label: 'Headers', value: context.exchange.requestHeaderNames.join(', ') }
            ]
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange())
        let findings = try db.pluginFindings(exchangeIDs: [id])
        let finding = try XCTUnwrap(findings[id]?.first { $0.pluginID == "thirdparty.js" })
        XCTAssertEqual(finding.title, "JS saw host")
        let text = ([finding.title, finding.summary] + finding.evidence.map(\.value)).joined(separator: "\n")
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertFalse(text.contains("secret-key"))
        XCTAssertFalse(text.contains("do-not-leak"))
    }

    func testBrokenJavaScriptPluginFailsOpenAfterExchangeInsertion() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.broken", name: "Broken", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Broken plugin.", privacySummary: "Uses metadata only.")
        manifest.script = "function evaluate(context) { while (true) {} }"
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange())
        let findings = try db.pluginFindings(exchangeIDs: [id])
        XCTAssertNotNil(findings[id]?.first { $0.pluginID == "traffic.large-upload" })
        XCTAssertNil(findings[id]?.first { $0.pluginID == "thirdparty.broken" })
    }
}
