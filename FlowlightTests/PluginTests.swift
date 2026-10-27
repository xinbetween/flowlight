import CryptoKit
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
        XCTAssertNil(decodedBare.signature)
        XCTAssertEqual(decodedBare.packageVersion, 1)

        let wrapped = try JSONEncoder().encode(PluginPackage(manifest: decodedBare.manifest))
        let decodedWrapped = try JSONDecoder().decode(PluginPackage.self, from: wrapped)
        XCTAssertEqual(decodedWrapped.manifest.id, "thirdparty.test")
    }

    func testUnsignedPackageReviewNormalizesOfficialClaimToThirdParty() throws {
        var manifest = PluginManifest(id: "thirdparty.unsigned", name: "Unsigned", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .official, guardrailProvider: .custom,
                                      description: "Unsigned plugin.", privacySummary: "Uses metadata only.")
        manifest.script = "function evaluate(context) { return []; }"
        let data = try JSONEncoder().encode(PluginPackage(manifest: manifest))
        let review = try PluginPackageVerifier.review(data: data)
        XCTAssertEqual(review.signatureStatus, .unsigned)
        XCTAssertEqual(review.manifest.publisher, .thirdParty)
        XCTAssertEqual(review.manifest.provenance.reviewStatus, .unsigned)
        XCTAssertFalse(review.packageDigest.isEmpty)
        XCTAssertFalse(review.scriptDigest.isEmpty)
        XCTAssertFalse(review.approvalFingerprint.isEmpty)
        XCTAssertTrue(review.warnings.joined(separator: "\n").contains("cannot claim official"))
    }

    func testSignedCommunityPackageReviewBindsDigestAndApproval() throws {
        var manifest = PluginManifest(id: "thirdparty.signed", name: "Signed", version: "0.1.0", kind: .llmMCP,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Signed plugin.", privacySummary: "Uses metadata only.",
                                      capabilities: [.annotate, .suggestGuardrail],
                                      permissions: [.trafficMetadata, .llmMetadata, .suggestGuardrail],
                                      privacy: PluginPrivacyDisclosure(categories: [.metadataOnly, .toolNames, .guardrailSuggestions], summary: "Metadata only."))
        manifest.script = "function evaluate(context) { return []; }"
        let privateKey = P256.Signing.PrivateKey()
        let signer = PluginTrustedSigner(keyID: "test-community-v1", publisher: .thirdParty, publisherName: "Test Community",
                                         channel: .community, publicKeyPEM: privateKey.publicKey.pemRepresentation)
        let package = try PluginPackageVerifier.signedPackage(manifest: manifest, keyID: signer.keyID, privateKey: privateKey)
        let review = try PluginPackageVerifier.review(data: JSONEncoder().encode(package), trustedSigners: [signer])
        XCTAssertEqual(review.signatureStatus, .verifiedCommunity)
        XCTAssertEqual(review.manifest.publisher, .thirdParty)
        XCTAssertEqual(review.manifest.provenance.signingKeyID, "test-community-v1")
        XCTAssertTrue(review.manifest.permissions.contains(.suggestGuardrail))
        XCTAssertEqual(review.manifest.provenance.packageDigest, review.packageDigest)
        XCTAssertEqual(review.manifest.provenance.approvalFingerprint, review.approvalFingerprint)
    }

    func testSignedCommunityPackageAcceptsBase64DERPublicKey() throws {
        var manifest = PluginManifest(id: "thirdparty.der-key", name: "DER key", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Signed plugin.", privacySummary: "Uses metadata only.",
                                      privacy: PluginPrivacyDisclosure(categories: [.metadataOnly], summary: "Metadata only."))
        manifest.script = "function evaluate(context) { return []; }"
        let privateKey = P256.Signing.PrivateKey()
        let signer = PluginTrustedSigner(
            keyID: "test-der-v1", publisher: .thirdParty, publisherName: "Test DER",
            channel: .community, publicKeyPEM: privateKey.publicKey.derRepresentation.base64EncodedString()
        )
        let package = try PluginPackageVerifier.signedPackage(
            manifest: manifest, keyID: signer.keyID, privateKey: privateKey
        )
        let review = try PluginPackageVerifier.review(data: JSONEncoder().encode(package), trustedSigners: [signer])
        XCTAssertEqual(review.signatureStatus, .verifiedCommunity)
    }

    func testSignedPackageRejectsMalformedTrustedKey() throws {
        var manifest = PluginManifest(id: "thirdparty.bad-key", name: "Bad key", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Signed plugin.", privacySummary: "Uses metadata only.",
                                      privacy: PluginPrivacyDisclosure(categories: [.metadataOnly], summary: "Metadata only."))
        manifest.script = "function evaluate(context) { return []; }"
        let privateKey = P256.Signing.PrivateKey()
        let signer = PluginTrustedSigner(keyID: "test-bad-v1", publisher: .thirdParty, publisherName: "Bad Key",
                                         channel: .community, publicKeyPEM: "not a key")
        let package = try PluginPackageVerifier.signedPackage(
            manifest: manifest, keyID: signer.keyID, privateKey: privateKey
        )
        XCTAssertThrowsError(
            try PluginPackageVerifier.review(data: JSONEncoder().encode(package), trustedSigners: [signer])
        ) { error in
            XCTAssertEqual(error as? PluginPackageError, .invalidSignature)
        }
    }

    func testSignedPackageRejectsTamperedManifest() throws {
        var manifest = PluginManifest(id: "thirdparty.tamper", name: "Tamper", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "Signed plugin.", privacySummary: "Uses metadata only.")
        manifest.script = "function evaluate(context) { return []; }"
        let privateKey = P256.Signing.PrivateKey()
        let signer = PluginTrustedSigner(keyID: "test-community-v1", publisher: .thirdParty, publisherName: "Test Community",
                                         channel: .community, publicKeyPEM: privateKey.publicKey.pemRepresentation)
        var package = try PluginPackageVerifier.signedPackage(manifest: manifest, keyID: signer.keyID, privateKey: privateKey)
        package.manifest.script = "function evaluate(context) { return [{ severity: 'high', title: 'Changed', summary: 'Changed', evidence: [] }]; }"
        XCTAssertThrowsError(try PluginPackageVerifier.review(data: JSONEncoder().encode(package), trustedSigners: [signer])) { error in
            XCTAssertEqual(error as? PluginPackageError, .invalidSignature)
        }
    }

    func testPermissionFilteringRemovesHeaderNamesFromJavaScriptContext() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.permissions", name: "Permissions", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses traffic metadata only.",
                                      permissions: [.trafficMetadata], privacy: PluginPrivacyDisclosure(categories: [.metadataOnly], summary: "Metadata only."))
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'low',
            title: 'Permission check',
            summary: context.exchange.requestHeaderNames === undefined ? 'headers hidden' : 'headers visible',
            evidence: [{ label: 'Headers', value: String(context.exchange.requestHeaderNames) }]
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange())
        let finding = try XCTUnwrap(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "thirdparty.permissions" })
        XCTAssertEqual(finding.summary, "headers hidden")
        XCTAssertFalse(finding.evidence.map(\.value).joined().contains("Authorization"))
    }

    func testJavaScriptEnforcementSuggestionsRequireDeclaredCapability() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.no-suggest", name: "No Suggest", version: "0.1.0", kind: .llmMCP,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses metadata only.",
                                      capabilities: [.annotate], permissions: [.trafficMetadata, .llmMetadata])
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'medium',
            title: 'Suggestion without capability',
            summary: 'This should stay advisory only.',
            evidence: [{ label: 'Host', value: context.exchange.host }],
            suggestedGuardrail: { agent: 'agent', tool: 'Bash' },
            suggestedRule: { action: 'block', app: 'agent', destination: 'api.example.test' }
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange(requestSize: 10, headers: []))
        let finding = try XCTUnwrap(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "thirdparty.no-suggest" })
        XCTAssertNil(finding.suggestedGuardrail)
        XCTAssertNil(finding.suggestedRule)
    }

    func testJavaScriptPluginCanSuggestNormalRuleWhenDeclared() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.rule-suggest", name: "Rule Suggest", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses metadata only.",
                                      capabilities: [.annotate, .suggestGuardrail], permissions: [.trafficMetadata, .appIdentity, .suggestGuardrail])
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'medium',
            title: 'Suggest rule',
            summary: 'Suggest a normal Flowlight rule for the inspected endpoint.',
            evidence: [{ label: 'Host', value: context.exchange.host }],
            suggestedRule: {
              action: 'block',
              app: context.exchange.agent || context.exchange.bundleID,
              destination: context.exchange.host,
              path: context.exchange.path,
              method: context.exchange.method,
              status: 451,
              name: 'Review inspected endpoint'
            }
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange(method: "POST", path: "/v1/messages?token=secret", requestSize: 10, headers: []))
        let finding = try XCTUnwrap(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "thirdparty.rule-suggest" })
        let rule = try XCTUnwrap(finding.suggestedRule)
        XCTAssertEqual(rule.action, .block)
        XCTAssertEqual(rule.app, "agent")
        XCTAssertEqual(rule.destination, "api.example.test")
        XCTAssertEqual(rule.path, "/v1/messages")
        XCTAssertEqual(rule.method, "POST")
        XCTAssertEqual(rule.status, 451)
        XCTAssertEqual(rule.origin, .alert)
        XCTAssertTrue(rule.isComplete)
        XCTAssertEqual(finding.suggestedActions.first?.kind, .networkRule)
    }

    func testJavaScriptPluginCanSuggestReviewedActionsWhenDeclared() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.actions", name: "Actions", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses metadata only.",
                                      capabilities: [.annotate, .suggestAction], permissions: [.trafficMetadata, .appIdentity, .suggestAction])
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'medium',
            title: 'Suggest reviewed actions',
            summary: 'Suggest reviewed editor handoffs.',
            evidence: [{ label: 'Host', value: context.exchange.host }],
            suggestedActions: [
              {
                kind: 'mockResponse',
                title: 'Review mock outage',
                reason: 'Exercise retry handling.',
                mock: { host: context.exchange.host, path: context.exchange.path, method: context.exchange.method, status: 503, delay: 2, body: '{"error":"try later"}' }
              },
              {
                kind: 'requestRewrite',
                title: 'Review rewrite',
                reason: 'Pin a safe option.',
                rewrite: { host: context.exchange.host, path: context.exchange.path, method: context.exchange.method, body: [{ op: 'set', path: 'metadata.safe', value: 'true' }] }
              },
              {
                kind: 'responseTransform',
                title: 'Review transform',
                reason: 'Remove a noisy response field.',
                responseTransform: { host: context.exchange.host, path: context.exchange.path, method: context.exchange.method, script: 'function modifyResponse(args) { return args.responseJSON; }' }
              }
            ]
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange(method: "POST", path: "/v1/messages?token=secret", requestSize: 10, headers: []))
        let finding = try XCTUnwrap(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "thirdparty.actions" })
        XCTAssertEqual(finding.suggestedActions.map(\.kind), [.mockResponse, .requestRewrite, .responseTransform])
        XCTAssertEqual(finding.suggestedActions[0].mock?.path, "/v1/messages")
        XCTAssertEqual(finding.suggestedActions[0].mock?.status, 503)
        XCTAssertEqual(finding.suggestedActions[1].rewrite?.body.first?.path, "metadata.safe")
        XCTAssertEqual(finding.suggestedActions[2].responseTransform?.script, "function modifyResponse(args) { return args.responseJSON; }")
    }

    func testMalformedReviewedActionIsDroppedButFindingPersists() throws {
        let db = try database()
        var manifest = PluginManifest(id: "thirdparty.bad-action", name: "Bad Action", version: "0.1.0", kind: .traffic,
                                      source: .installed, publisher: .thirdParty, guardrailProvider: .custom,
                                      description: "JS plugin.", privacySummary: "Uses metadata only.",
                                      capabilities: [.annotate, .suggestAction], permissions: [.trafficMetadata, .suggestAction])
        manifest.script = """
        function evaluate(context) {
          return [{
            severity: 'low',
            title: 'Malformed action',
            summary: 'The finding should survive.',
            evidence: [{ label: 'Host', value: context.exchange.host }],
            suggestedActions: [{ kind: 'requestRewrite', title: 'Bad rewrite', rewrite: { headers: [], body: [] } }]
          }];
        }
        """
        try db.savePluginManifest(manifest)
        let id = try db.insertExchange(exchange(requestSize: 10, headers: []))
        let finding = try XCTUnwrap(try db.pluginFindings(exchangeIDs: [id])[id]?.first { $0.pluginID == "thirdparty.bad-action" })
        XCTAssertEqual(finding.title, "Malformed action")
        XCTAssertTrue(finding.suggestedActions.isEmpty)
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
