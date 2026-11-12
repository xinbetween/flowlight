import XCTest
@testable import Flowlight

final class AgentInventoryTests: XCTestCase {
    private let healthyInspection = AgentInspectionDiagnostics(
        available: true, enabled: true, running: true, certificateTrusted: true, setupFailed: false
    )

    private func summary(
        id: String,
        name: String,
        known: Bool = true,
        path: String = "",
        provider: String = "Anthropic",
        otherHost: String? = nil
    ) -> AgentSummary {
        let ai = FlowCounters(bytesIn: 400, bytesOut: 100, flows: 1)
        var destinations = [
            AgentDestination(
                label: "api.provider.test", ip: "203.0.113.10", provider: provider,
                protocols: ["https"], ports: "443", counters: ai
            ),
        ]
        var egress = FlowCounters()
        if let otherHost {
            egress = FlowCounters(bytesIn: 20, bytesOut: 10, flows: 1)
            destinations.append(AgentDestination(
                label: otherHost, ip: "203.0.113.11", provider: nil,
                protocols: ["https"], ports: "443", counters: egress
            ))
        }
        return AgentSummary(
            bundleID: id,
            name: name,
            vendor: known ? "Vendor" : nil,
            isKnown: known,
            appPath: path,
            ai: ai,
            egress: egress,
            providers: [(provider, ai)],
            destinations: destinations,
            alerts: 0
        )
    }

    private func alert(
        bundleID: String,
        appName: String,
        state: AlertTriageState = .new,
        detail: String = "Review this activity"
    ) -> AlertRecord {
        AlertRecord(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1_000),
            kind: "agent-test",
            bundleID: bundleID,
            appName: appName,
            detail: detail,
            severity: 2,
            state: state
        )
    }

    func testInstalledRecognizedGUIAgentIsInactiveWithoutTraffic() {
        let cursor = InstalledApps.App(
            name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", path: "/Applications/Cursor.app"
        )

        let item = AgentInventoryBuilder.build(AgentInventoryInput(installedApps: [cursor])).first

        XCTAssertEqual(item?.name, "Cursor")
        XCTAssertEqual(item?.health, .inactive)
        XCTAssertEqual(item?.reasons, ["Installed on this Mac, with no traffic in the selected window."])
    }

    func testUppercaseStableIdentifierStillResolvesKnownAgent() throws {
        let cursor = InstalledApps.App(
            name: "Cursor", bundleID: "COM.TODESKTOP.230313MZL4W4U92", path: "/Applications/Cursor.app"
        )
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(installedApps: [cursor])).first)
        XCTAssertEqual(item.name, "Cursor")
        XCTAssertEqual(item.health, .inactive)
    }

    func testActiveInstalledAgentMergesWithTrafficAndCanBeHealthy() throws {
        let cursor = InstalledApps.App(
            name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", path: "/Applications/Cursor.app"
        )
        let traffic = summary(id: cursor.bundleID, name: "Cursor", path: cursor.path, provider: "Cursor")

        let items = AgentInventoryBuilder.build(AgentInventoryInput(
            installedApps: [cursor],
            traffic: [traffic],
            routes: [cursor.bundleID: .observed],
            inspection: healthyInspection
        ))

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(item.installed)
        XCTAssertTrue(item.observed)
        XCTAssertEqual(item.health, .healthy)
    }

    func testObservedKnownCLIAgentAppearsWithoutApplicationBundle() throws {
        let claude = summary(id: "claude", name: "Claude Code")

        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [claude],
            routes: ["claude": .observed],
            inspection: healthyInspection
        )).first)

        XCTAssertEqual(item.id, "claude")
        XCTAssertEqual(item.name, "Claude Code")
        XCTAssertFalse(item.installed)
        XCTAssertTrue(item.observed)
        XCTAssertEqual(item.health, .healthy)
    }

    func testKnownAliasesMergeAllTrafficEvidence() throws {
        let primary = summary(id: "claude", name: "Claude Code", provider: "Anthropic")
        let alias = summary(id: "claude-code", name: "Claude Code", provider: "OpenAI",
                            otherHost: "uploads.example")

        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [alias, primary],
            routes: ["claude-code": .observed],
            inspection: healthyInspection
        )).first)

        XCTAssertEqual(item.id, "claude")
        XCTAssertEqual(item.identities.first, "claude")
        XCTAssertTrue(item.identities.contains("claude-code"))
        XCTAssertTrue(item.identities.contains("Claude Code"))
        XCTAssertEqual(Set(item.trafficIdentities), ["claude", "claude-code"])
        XCTAssertFalse(item.trafficIdentities.contains("Claude Code"),
                       "display labels must not become exact traffic filters")
        XCTAssertEqual(item.summary?.total.total, primary.total.total + alias.total.total)
        XCTAssertEqual(Set(item.summary?.providers.map(\.name) ?? []), ["Anthropic", "OpenAI"])
        XCTAssertEqual(Set(item.summary?.destinations.map(\.label) ?? []),
                       ["api.provider.test", "uploads.example"])
        XCTAssertEqual(item.route, .observed)
    }

    func testPolicySelectionUsesStableIdentityPriority() throws {
        let primary = summary(id: "claude", name: "Claude Code", provider: "Anthropic")
        let alias = summary(id: "claude-code", name: "Claude Code", provider: "OpenAI",
                            otherHost: "uploads.example")
        let canonical = AgentPolicy(agentID: "claude", enabled: true,
                                    patterns: ["uploads.example"], enforce: true)
        let secondary = AgentPolicy(agentID: "claude-code", enabled: true, patterns: [], enforce: false)
        var forward: [String: AgentPolicy] = [:]
        forward[canonical.agentID] = canonical
        forward[secondary.agentID] = secondary
        var reverse: [String: AgentPolicy] = [:]
        reverse[secondary.agentID] = secondary
        reverse[canonical.agentID] = canonical

        let first = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [primary, alias], policies: forward
        )).first)
        let second = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [alias, primary], policies: reverse
        )).first)

        XCTAssertEqual(first.id, "claude")
        XCTAssertEqual(first.policy, second.policy)
        XCTAssertTrue(first.policy.enabled)
        XCTAssertTrue(first.policy.enforcing)
        XCTAssertEqual(first.policy.uncoveredDestinations, 0)
    }

    func testConfiguredKnownCLIAgentIsNotObserved() throws {
        let workspace = AgentWorkspace(agent: "codex", root: "~/.codex", isProject: false)

        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            workspaces: [workspace],
            inspection: healthyInspection
        )).first)

        XCTAssertEqual(item.name, "Codex")
        XCTAssertTrue(item.configured)
        XCTAssertEqual(item.health, .notObserved)
        XCTAssertEqual(item.reasons.first,
                       "Configuration was found, but no traffic was observed in the selected window.")
    }

    func testAutoDiscoversNonBrowserProviderClient() throws {
        let script = summary(id: "python3", name: "Research worker", known: false, provider: "OpenAI")

        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [script], inspection: .unavailable
        )).first)

        XCTAssertEqual(item.id, "python3")
        XCTAssertTrue(item.autoDiscovered)
        XCTAssertEqual(item.health, .limitedVisibility)
    }

    func testSavedPolicyKeepsQuietAgentVisibleWithStableCatalogID() throws {
        let policy = AgentPolicy(agentID: "claude-code", patterns: ["github.com"])
        let quiet = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            policies: [policy.agentID: policy]
        )).first)
        XCTAssertEqual(quiet.id, "claude")
        XCTAssertEqual(quiet.name, "Claude Code")
        XCTAssertTrue(quiet.policy.enabled)

        let observed = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [summary(id: "claude-code", name: "Claude Code")],
            policies: [policy.agentID: policy]
        )).first)
        XCTAssertEqual(observed.id, quiet.id, "catalog row identity must not change with the observed alias")
    }

    func testAgentScopedGuardrailKeepsQuietAgentVisibleForDeepLinks() throws {
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            guardrailAgentIDs: ["quiet-worker"]
        )).first)

        XCTAssertEqual(item.id, "quiet-worker")
        XCTAssertTrue(item.identities.contains("quiet-worker"))
        XCTAssertEqual(item.trafficIdentities, ["quiet-worker"])
        XCTAssertFalse(item.observed)
    }

    func testUnknownObservedAgentAndSavedPolicyMergeIntoOneRow() throws {
        let policy = AgentPolicy(agentID: "custom-worker", enabled: true, patterns: ["api.example"])
        let items = AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [summary(id: "custom-worker", name: "Custom worker", known: false)],
            policies: [policy.agentID: policy]
        ))

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "custom-worker")
        XCTAssertTrue(item.policy.enabled)
    }

    func testBrowserProviderTrafficIsExcluded() {
        let browser = summary(
            id: "com.google.Chrome", name: "Chrome", known: false, provider: "OpenAI"
        )
        let installed = InstalledApps.App(
            name: "Safari", bundleID: "com.apple.Safari", path: "/System/Applications/Safari.app"
        )

        XCTAssertTrue(AgentInventoryBuilder.build(AgentInventoryInput(
            installedApps: [installed], traffic: [browser]
        )).isEmpty)
    }

    func testStaleAndFailedRoutesNeedAttention() throws {
        let claude = summary(id: "claude", name: "Claude Code")
        let stale = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [claude], routes: ["claude": .stale], inspection: healthyInspection
        )).first)
        let failed = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [claude], routes: ["Claude Code": .failed], inspection: healthyInspection
        )).first)

        XCTAssertEqual(stale.health, .attention)
        XCTAssertTrue(stale.reasons.contains("The saved Flowlight route was not observed in this window."))
        XCTAssertEqual(failed.health, .attention)
        XCTAssertTrue(failed.reasons.contains("Flowlight could not establish the requested route."))
    }

    func testMissingCertificateTrustNeedsSetup() throws {
        let inspection = AgentInspectionDiagnostics(
            available: true, enabled: true, running: true, certificateTrusted: false, setupFailed: false
        )
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [summary(id: "claude", name: "Claude Code")],
            routes: ["claude": .observed],
            inspection: inspection
        )).first)

        XCTAssertEqual(item.health, .needsSetup)
        XCTAssertTrue(item.reasons.contains("The HTTPS inspection certificate is not trusted."))
    }

    func testPolicyCoverageAndUnresolvedAlertsNeedAttention() throws {
        let traffic = summary(id: "claude", name: "Claude Code", otherHost: "uploads.example")
        let policy = AgentPolicy(agentID: "claude", enabled: true, patterns: ["github.com"], enforce: true)
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [traffic],
            routes: ["claude": .observed],
            inspection: healthyInspection,
            policies: ["claude": policy],
            alerts: [
                alert(bundleID: "claude", appName: "Claude Code"),
                alert(bundleID: "claude", appName: "Claude Code", state: .investigating),
                alert(bundleID: "claude", appName: "Claude Code", state: .resolved),
            ]
        )).first)

        XCTAssertEqual(item.policy.uncoveredDestinations, 1)
        XCTAssertEqual(item.unresolvedAlerts, 2, "new and investigating alerts remain open; resolved alerts do not")
        XCTAssertEqual(item.health, .attention)
        XCTAssertTrue(item.reasons.contains("One observed destination is outside its policy."))
        XCTAssertTrue(item.reasons.contains("2 unresolved alerts need review."))
    }

    func testGroupedAlertCountsMatchAliasesWithoutDoubleCounting() throws {
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [summary(id: "claude", name: "Claude Code")],
            routes: ["claude": .observed],
            inspection: healthyInspection,
            openAlertCounts: [
                AgentOpenAlertCount(bundleID: "claude", appName: "Claude Code", count: 3),
            ]
        )).first)

        XCTAssertEqual(item.unresolvedAlerts, 3,
                       "one grouped row matching both process and display aliases must only be counted once")
    }

    func testClaudeDesktopAndCodeKeepDistinctInventoryEvidence() throws {
        let items = AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [
                summary(id: "com.anthropic.claudefordesktop", name: "Claude"),
                summary(id: "claude", name: "Claude Code"),
            ],
            routes: ["Claude": .stale, "claude": .observed],
            openAlertCounts: [
                AgentOpenAlertCount(bundleID: "com.anthropic.claudefordesktop", appName: "Claude", count: 2),
            ]
        ))

        let desktop = try XCTUnwrap(items.first { $0.name == "Claude" })
        let code = try XCTUnwrap(items.first { $0.name == "Claude Code" })
        XCTAssertEqual(desktop.unresolvedAlerts, 2)
        XCTAssertEqual(desktop.route, .stale)
        XCTAssertEqual(code.unresolvedAlerts, 0)
        XCTAssertEqual(code.route, .observed)
        XCTAssertNotEqual(AgentCatalog.identityComparisonKey("Claude"),
                          AgentCatalog.identityComparisonKey("claude"))
    }

    func testDisabledProviderExemptionCountsProviderOutsidePolicy() throws {
        let traffic = summary(id: "claude", name: "Claude Code")
        let policy = AgentPolicy(agentID: "claude", enabled: true, allowAIProviders: false,
                                 patterns: [], enforce: true)
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [traffic], routes: ["claude": .observed], inspection: healthyInspection,
            policies: ["claude": policy]
        )).first)

        XCTAssertEqual(item.policy.uncoveredDestinations, 1)
        XCTAssertEqual(item.health, .attention)
    }

    func testReasonsHaveStableEvidenceRouteInspectionPolicyAlertOrder() throws {
        let traffic = summary(id: "claude", name: "Claude Code", otherHost: "uploads.example")
        let policy = AgentPolicy(agentID: "claude", enabled: true, patterns: [], enforce: false)
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [traffic],
            routes: ["claude": .stale],
            inspection: healthyInspection,
            policies: ["claude": policy],
            alerts: [alert(bundleID: "claude", appName: "Claude Code")]
        )).first)

        XCTAssertEqual(item.reasons, [
            "Traffic was observed in the selected window.",
            "The saved Flowlight route was not observed in this window.",
            "No inspected requests were observed in this window.",
            "One observed destination is outside its policy.",
            "One unresolved alert needs review.",
        ])
    }

    func testDisplayTextRedactsPathsEndpointsSecretsAndAlertDetails() throws {
        let secretPath = "/Users/alice/private/token-123/.claude"
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: AgentGatewayConfig.Endpoint(scheme: "https", host: "secret.internal", port: 9443),
            source: secretPath + "/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let workspace = AgentWorkspace(
            agent: "claude", root: secretPath, isProject: false, gateways: [gateway]
        )
        let item = try XCTUnwrap(AgentInventoryBuilder.build(AgentInventoryInput(
            traffic: [summary(id: "claude", name: "Claude Code", path: secretPath + "/claude")],
            workspaces: [workspace],
            routes: ["claude": .failed],
            inspection: healthyInspection,
            alerts: [alert(
                bundleID: "claude", appName: "Claude Code",
                detail: "Bearer sk-secret-value at \(secretPath) via https://secret.internal:9443"
            )]
        )).first)

        for secret in [secretPath, "token-123", "secret.internal", "9443", "sk-secret-value", "Bearer"] {
            XCTAssertFalse(item.displayText.contains(secret), "display text leaked \(secret)")
        }
        XCTAssertTrue(item.displayText.contains("Attention"))
        XCTAssertEqual(item.appPath, secretPath + "/claude", "the path remains available only for icon loading")
    }
}
