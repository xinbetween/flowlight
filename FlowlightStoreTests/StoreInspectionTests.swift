import Security
import SwiftUI
import XCTest
@testable import Flowlight

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}

@MainActor
final class StoreInspectionTests: XCTestCase {
    func testStoreCapabilityBoundarySupportsInspectionWithoutDeveloperAutomation() {
        let capabilities = ProductCapabilities.current
        XCTAssertTrue(capabilities.proxyInspection)
        XCTAssertTrue(capabilities.manualCertificateTrust)
        XCTAssertTrue(capabilities.trustedProxyAttribution)
        XCTAssertTrue(capabilities.guardrails)
        XCTAssertTrue(capabilities.mocks)
        XCTAssertTrue(capabilities.requestRewrites)
        XCTAssertFalse(capabilities.automaticSystemProxy)
        XCTAssertFalse(capabilities.automaticExternalAppConfiguration)
        XCTAssertFalse(capabilities.responseTransforms)
        XCTAssertFalse(capabilities.scriptPlugins)
        XCTAssertEqual(InspectionController.defaultScope, .agents)
    }

    func testStoreHostnameGuideUsesTheContentFilterInsteadOfDeveloperPacketSetup() throws {
        let guide = try XCTUnwrap(FeatureGuide.all.first { $0.id == "hostnames" })
        let guidance = guide.searchText

        XCTAssertTrue(guidance.contains("content filter"), guidance)
        for developerOnlyTerm in ["sampler", "packet-capture", "helper permission", "read hostnames from the network"] {
            XCTAssertFalse(guidance.contains(developerOnlyTerm), guidance)
        }
    }

    func testStoreDataGuideUsesSandboxedDeletionGuidance() throws {
        let guide = try XCTUnwrap(FeatureGuide.all.first { $0.id == "data" })
        let guidance = guide.searchText

        XCTAssertTrue(guidance.contains("sandboxed application support container"), guidance)
        XCTAssertTrue(guidance.contains("keeping policies and settings"), guidance)
        XCTAssertTrue(guidance.contains("remove certificate & recorded data"), guidance)
        XCTAssertTrue(guidance.contains("does not remove policies"), guidance)
        XCTAssertFalse(guidance.contains("delete everything flowlight stores"), guidance)
        XCTAssertFalse(guidance.contains("~/library/application support/flowlight"), guidance)
    }

    func testInspectionCannotEnableBeforePolicyStateIsReady() {
        let defaults = UserDefaults.standard
        let priorEnabled = defaults.object(forKey: InspectionController.Keys.enabled)
        let priorPort = defaults.object(forKey: InspectionController.Keys.port)
        let priorMigration = defaults.object(forKey: InspectionController.Keys.storeMigration)
        let priorSession = defaults.object(forKey: InspectionController.Keys.sessionStarted)
        func restore(_ value: Any?, key: String) {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: InspectionController.Keys.storeMigration)
        defaults.set(false, forKey: InspectionController.Keys.enabled)
        defaults.set(63_000, forKey: InspectionController.Keys.port)

        let controller = InspectionController()
        defer {
            controller.setEnabled(false)
            restore(priorEnabled, key: InspectionController.Keys.enabled)
            restore(priorPort, key: InspectionController.Keys.port)
            restore(priorMigration, key: InspectionController.Keys.storeMigration)
            restore(priorSession, key: InspectionController.Keys.sessionStarted)
        }

        XCTAssertFalse(controller.policyStateReady)
        defaults.set(true, forKey: InspectionController.Keys.enabled)
        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled, "turning inspection off must remain available while policy state loads")

        controller.setEnabled(true)
        XCTAssertFalse(controller.enabled, "turning inspection on must wait for the complete policy publication")
        XCTAssertFalse(controller.running)
    }

    func testStoreReadinessRequiresTheCompleteAttributionHandshake() {
        var gate = StoreAttributionGate()
        XCTAssertFalse(gate.isReady)

        gate.protocolAccepted = true
        XCTAssertFalse(gate.isReady)
        XCTAssertFalse(gate.captureHealthy)
        gate.updateFilterState(running: true, generation: 1)
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.captureHealthy)
        gate.publishedProxyPort = InspectionController.storeDefaultPort
        XCTAssertTrue(gate.isReady)

        gate.updateFilterState(running: false, generation: 2)
        XCTAssertFalse(gate.isReady)
        XCTAssertFalse(gate.captureHealthy, "a connected but stopped filter must not emit healthy capture heartbeats")
        gate.updateFilterState(running: true, generation: 3)
        XCTAssertTrue(gate.isReady)
        gate.reset()
        XCTAssertFalse(gate.isReady)
    }

    func testStoreReadinessRejectsAStaleStartReplyAfterStop() {
        var gate = StoreAttributionGate()
        gate.protocolAccepted = true
        gate.publishedProxyPort = InspectionController.storeDefaultPort
        gate.updateFilterState(running: true, generation: 4)
        XCTAssertTrue(gate.isReady)

        gate.updateFilterState(running: false, generation: 5)
        XCTAssertFalse(gate.isReady)
        gate.updateFilterState(running: true, generation: 4)
        XCTAssertFalse(gate.isReady, "a delayed pre-stop reply must not restore attribution readiness")

        gate.updateFilterState(running: true, generation: 6)
        XCTAssertTrue(gate.isReady)
    }

    func testStoreIdentityReplyMustMatchTheCurrentFilterGeneration() {
        let identity = ProxyClientIdentity(pid: 42, bundleID: "com.example.client", name: "Client", path: "/client")
        var gate = StoreAttributionGate()
        gate.protocolAccepted = true
        gate.publishedProxyPort = InspectionController.storeDefaultPort
        gate.updateFilterState(running: true, generation: 7)

        XCTAssertTrue(gate.acceptsIdentityReply(
            ProxyClientIdentityReply(identity: identity, filterGeneration: 7),
            proxyPort: InspectionController.storeDefaultPort
        ))
        XCTAssertFalse(gate.acceptsIdentityReply(
            ProxyClientIdentityReply(identity: identity, filterGeneration: 6),
            proxyPort: InspectionController.storeDefaultPort
        ), "a reply completed across a filter restart must fail open")

        gate.updateFilterState(running: false, generation: 8)
        XCTAssertFalse(gate.acceptsIdentityReply(
            ProxyClientIdentityReply(identity: identity, filterGeneration: 7),
            proxyPort: InspectionController.storeDefaultPort
        ))
    }

    func testFirstStoreLaunchNeutralizesOnlyStoreInspectionOnce() throws {
        let suite = "flowlight-store-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: InspectionController.Keys.enabled)
        defaults.set(Date(), forKey: InspectionController.Keys.sessionStarted)
        defaults.set(8_877, forKey: InspectionController.Keys.port)
        defaults.set(true, forKey: InspectionController.Keys.systemProxy)
        defaults.set(["Claude Code"], forKey: InspectionController.Keys.monitoredAgents)

        InspectionController.migrateStoreDefaults(defaults)

        XCTAssertFalse(defaults.bool(forKey: InspectionController.Keys.enabled))
        XCTAssertNil(defaults.object(forKey: InspectionController.Keys.sessionStarted))
        XCTAssertEqual(defaults.integer(forKey: InspectionController.Keys.port), 8_878)
        XCTAssertTrue(defaults.bool(forKey: InspectionController.Keys.systemProxy),
                      "Store launch must preserve the Developer product's ability to undo its macOS route")
        XCTAssertEqual(defaults.stringArray(forKey: InspectionController.Keys.monitoredAgents), ["Claude Code"],
                       "Store launch must not discard Developer-managed agent routing metadata")

        defaults.set(true, forKey: InspectionController.Keys.enabled)
        defaults.set(9_999, forKey: InspectionController.Keys.port)
        InspectionController.migrateStoreDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: InspectionController.Keys.enabled),
                      "the one-time migration must not disable a later Store opt-in")
        XCTAssertEqual(defaults.integer(forKey: InspectionController.Keys.port), 9_999)
    }

    func testStoreDetectsInheritedDeveloperProxyWithoutMutatingIt() {
        let inheritedPAC: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://127.0.0.1:8877/proxy.pac",
        ]
        XCTAssertEqual(
            StoreProxyConfiguration.inheritedRoute(in: inheritedPAC, storePort: 8_878),
            .flowlightPAC
        )

        let staleExplicit: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": 8_877,
        ]
        XCTAssertEqual(
            StoreProxyConfiguration.inheritedRoute(in: staleExplicit, storePort: 8_878),
            .staleExplicitProxy(port: 8_877)
        )

        let currentStoreRoute: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8_878,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 8_878,
        ]
        XCTAssertNil(StoreProxyConfiguration.inheritedRoute(in: currentStoreRoute, storePort: 8_878))

        let unrelatedLocalProxy: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "localhost", "HTTPPort": 8_888,
        ]
        XCTAssertNil(StoreProxyConfiguration.inheritedRoute(in: unrelatedLocalProxy, storePort: 8_878),
                     "Charles, mitmproxy, and other localhost proxies must not be presented as stale Flowlight routing")

        let unrelatedPAC: [String: Any] = [
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://127.0.0.1:9999/proxy.pac",
        ]
        XCTAssertNil(StoreProxyConfiguration.inheritedRoute(in: unrelatedPAC, storePort: 8_878))
    }

    func testStoreNavigationAndPoliciesExposeOnlySupportedInspectionFeatures() {
        XCTAssertTrue(SidebarItem.availableCases.contains(.inspect))
        XCTAssertEqual(SidebarItem.inspect.shortcut, KeyEquivalent("7"))
        XCTAssertEqual(SidebarItem.rules.shortcut, KeyEquivalent("8"))
        XCTAssertEqual(SidebarItem.sources.shortcut, KeyEquivalent("9"))

        let capabilities = PolicyInventoryCapabilities.current
        XCTAssertTrue(capabilities.inspectionPolicies)
        XCTAssertFalse(capabilities.responseTransforms)
        let visible = PolicyInventoryKind.allCases.filter { kind in
            PolicyInventoryItem(
                kind: kind,
                sourceID: kind.rawValue,
                title: kind.rawValue,
                detail: "",
                isEnabled: true,
                effect: .effective,
                reason: nil,
                destination: .managedPack(nil)
            ).isVisible(in: capabilities)
        }
        XCTAssertEqual(visible, [
            .networkRule, .agentAllowlist, .managedPack, .guardrail, .mock, .requestRewrite
        ])
    }

    func testCustomEnforcingPolicyAttributesTheNearestAncestor() {
        let child = InspectionAgentLineageIdentity(
            bundleID: "com.example.helper",
            name: "helper"
        )
        let customAncestor = InspectionAgentLineageIdentity(
            bundleID: "com.example.custom-agent",
            name: "Custom Agent"
        )
        let fartherBuiltInAncestor = InspectionAgentLineageIdentity(
            bundleID: "com.anthropic.claudefordesktop",
            name: "Claude"
        )
        let policy = AgentPolicy(
            agentID: "com.example.custom-agent",
            enabled: true,
            patterns: ["api.example"],
            enforce: true
        )

        XCTAssertEqual(
            InspectionAgentContextResolver.resolve(
                lineage: [child, customAncestor, fartherBuiltInAncestor],
                policies: [policy]
            ),
            InspectionAgentContext(bundleID: "com.example.custom-agent", name: "Custom Agent")
        )
    }

    func testNonEnforcingCustomPolicyCannotOverrideBuiltInLineage() {
        let known = InspectionAgentLineageIdentity(
            bundleID: "com.anthropic.claudefordesktop",
            name: "Claude"
        )
        let advisory = AgentPolicy(
            agentID: "com.anthropic.claudefordesktop",
            enabled: true,
            patterns: [],
            enforce: false
        )

        XCTAssertEqual(
            InspectionAgentContextResolver.resolve(lineage: [known], policies: [advisory]),
            InspectionAgentContext(bundleID: known.bundleID, name: "Claude")
        )
    }

    func testProxyIdentityRequiresTheExactLiveLoopbackPortPair() {
        let identity = ProxyClientIdentity(
            pid: 42,
            bundleID: "com.example.client",
            name: "Client",
            path: "/Applications/Client.app/Contents/MacOS/Client"
        )
        let candidate = ProxyClientFlowCandidate(
            localIP: "127.0.0.1",
            localPort: 50_001,
            remoteIP: "127.0.0.1",
            remotePort: 8_877,
            isTCP: true,
            identity: identity
        )

        XCTAssertEqual(
            ProxyClientIdentityResolver.resolve(
                candidates: [candidate],
                clientIP: "127.0.0.1",
                clientPort: 50_001,
                proxyPort: 8_877
            ),
            identity
        )
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [candidate], clientIP: "127.0.0.1", clientPort: 50_002, proxyPort: 8_877
        ))
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [candidate], clientIP: "127.0.0.1", clientPort: 50_001, proxyPort: 8_878
        ))
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [candidate], clientIP: "192.168.1.152", clientPort: 50_001, proxyPort: 8_877
        ), "the same source port on another local address is a different client tuple")
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [ProxyClientFlowCandidate(
                localIP: "127.0.0.1",
                localPort: 50_001,
                remoteIP: "192.0.2.10",
                remotePort: 8_877,
                isTCP: true,
                identity: identity
            )],
            clientIP: "127.0.0.1",
            clientPort: 50_001,
            proxyPort: 8_877
        ))
    }

    func testProxyIdentityFailsOpenForUnknownOrAmbiguousFlows() {
        let valid = ProxyClientIdentity(
            pid: 42,
            bundleID: "com.example.client",
            name: "Client",
            path: "/Applications/Client.app/Contents/MacOS/Client"
        )
        let exact = ProxyClientFlowCandidate(
            localIP: "::1",
            localPort: 50_001,
            remoteIP: "::1",
            remotePort: 8_877,
            isTCP: true,
            identity: valid
        )
        var unknown = exact
        unknown.identity = ProxyClientIdentity(pid: 0, bundleID: "unknown", name: "", path: "")
        var conflicting = exact
        conflicting.identity = ProxyClientIdentity(
            pid: 84,
            bundleID: "com.example.other",
            name: "Other",
            path: "/Applications/Other.app/Contents/MacOS/Other"
        )

        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [unknown], clientIP: "::1", clientPort: 50_001, proxyPort: 8_877
        ))
        XCTAssertEqual(ProxyClientIdentityResolver.resolve(
            candidates: [exact, exact], clientIP: "::1", clientPort: 50_001, proxyPort: 8_877
        ), valid, "a stale duplicate with the same audit identity remains unambiguous")
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [exact, conflicting], clientIP: "::1", clientPort: 50_001, proxyPort: 8_877
        ), "a reused full tuple must never choose between different app identities")
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [], clientIP: "::1", clientPort: 50_001, proxyPort: 8_877
        ))
    }

    func testProxyIdentityIsIsolatedAcrossFilterStopAndSourcePortReuse() {
        let first = ProxyClientIdentity(pid: 42, bundleID: "com.example.first", name: "First", path: "/first")
        let second = ProxyClientIdentity(pid: 84, bundleID: "com.example.second", name: "Second", path: "/second")
        let old = ProxyClientFlowCandidate(localIP: "127.0.0.1", localPort: 50_001,
                                           remoteIP: "127.0.0.1", remotePort: 8_878,
                                           isTCP: true, identity: first, filterGeneration: 7)
        let reused = ProxyClientFlowCandidate(localIP: "127.0.0.1", localPort: 50_001,
                                              remoteIP: "127.0.0.1", remotePort: 8_878,
                                              isTCP: true, identity: second, filterGeneration: 9)

        XCTAssertEqual(ProxyClientIdentityResolver.resolve(
            candidates: [old], clientIP: "127.0.0.1", clientPort: 50_001,
            proxyPort: 8_878, filterGeneration: 7
        ), first)
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [old], clientIP: "127.0.0.1", clientPort: 50_001,
            proxyPort: 8_878, filterGeneration: nil
        ), "a stopped filter has no authoritative identity generation")
        XCTAssertNil(ProxyClientIdentityResolver.resolve(
            candidates: [old], clientIP: "127.0.0.1", clientPort: 50_001,
            proxyPort: 8_878, filterGeneration: 9
        ), "a source port reused after restart must not inherit the prior generation")
        XCTAssertEqual(ProxyClientIdentityResolver.resolve(
            candidates: [old, reused], clientIP: "127.0.0.1", clientPort: 50_001,
            proxyPort: 8_878, filterGeneration: 9
        ), second)
    }

    func testProxyIdentityMissClearsAReusedSourcePortOwner() {
        let recorder = InspectionRecorder()
        let port: UInt16 = 50_001
        recorder.remember(
            owner: InspectionRecorder.Owner(
                pid: 42,
                bundleID: "com.example.first",
                appName: "First",
                appPath: "/Applications/First.app/Contents/MacOS/First"
            ),
            clientAddress: "127.0.0.1",
            clientPort: port
        )
        XCTAssertEqual(
            recorder.owner(clientAddress: "127.0.0.1", clientPort: port, proxyPort: nil).bundleID,
            "com.example.first"
        )
        XCTAssertTrue(
            recorder.owner(clientAddress: "192.168.1.152", clientPort: port, proxyPort: nil).bundleID.isEmpty
        )

        recorder.remember(owner: InspectionRecorder.Owner(), clientAddress: "127.0.0.1", clientPort: port)

        let missing = recorder.owner(clientAddress: "127.0.0.1", clientPort: port, proxyPort: nil)
        XCTAssertTrue(missing.bundleID.isEmpty)
        XCTAssertEqual(missing.pid, 0)
    }

    func testProxyFlowKeepsTheAuthorizedOwnerWhenEndpointCacheChanges() {
        let authorized = InspectionRecorder.Owner(
            pid: 42,
            bundleID: "com.example.authorized",
            appName: "Authorized"
        )
        let flow = ProxyFlow(
            host: "example.com",
            port: 443,
            clientAddress: "127.0.0.1",
            clientPort: 50_002,
            owner: authorized,
            inspected: true,
            scheme: "https"
        )
        let recorder = InspectionRecorder()
        recorder.remember(
            owner: InspectionRecorder.Owner(pid: 99, bundleID: "com.example.reused", appName: "Reused"),
            clientAddress: flow.clientAddress,
            clientPort: flow.clientPort
        )

        XCTAssertEqual(flow.owner.bundleID, "com.example.authorized")
        XCTAssertEqual(flow.owner.pid, 42)
    }

    func testProxyFlowEndClearsItsCachedOwner() {
        let recorder = InspectionRecorder()
        let flow = ProxyFlow(
            host: "example.com",
            port: 443,
            clientAddress: "127.0.0.1",
            clientPort: 50_002,
            inspected: true,
            scheme: "https"
        )
        recorder.remember(
            owner: InspectionRecorder.Owner(
                pid: 42,
                bundleID: "com.example.first",
                appName: "First",
                appPath: "/Applications/First.app/Contents/MacOS/First"
            ),
            clientAddress: flow.clientAddress,
            clientPort: flow.clientPort
        )
        recorder.flowStarted(flow)

        recorder.flowEnded(flow, note: nil)

        XCTAssertTrue(
            recorder.owner(
                clientAddress: flow.clientAddress,
                clientPort: flow.clientPort,
                proxyPort: nil
            ).bundleID.isEmpty
        )
    }

    func testMissingProxyIdentityStillAppliesIdentityIndependentPolicy() async {
        let controller = InspectionController()
        let owner = InspectionRecorder.Owner()
        let destinationBlock = Rule(action: .block, destination: "blocked.example")
        controller.onRuleRefusal = { _, completion in completion(true) }
        controller.flowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: [destinationBlock]),
                externalClaim: nil
            )
        }

        let destinationAllowed = await authorize(
            controller,
            host: "blocked.example",
            owner: owner
        )
        XCTAssertFalse(destinationAllowed, "global destination policy must not be bypassed by an attribution miss")

        let appBlock = Rule(
            action: .block,
            app: "com.example.client",
            destination: "blocked.example"
        )
        controller.flowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: [appBlock]),
                externalClaim: nil
            )
        }

        let appScopedAllowed = await authorize(
            controller,
            host: "blocked.example",
            owner: owner
        )
        XCTAssertTrue(appScopedAllowed, "app-scoped policy must fail open when trusted identity is unavailable")
    }

    func testCertificatePinningBypassIsScopedToTheRejectingApp() {
        let proxy = InspectionProxy()
        let rejecting = InspectionRecorder.Owner(bundleID: "com.example.rejecting", appName: "Rejecting")
        let other = InspectionRecorder.Owner(bundleID: "com.example.other", appName: "Other")

        proxy.markInspectionUnavailable(
            host: "API.Example.com",
            owner: rejecting,
            until: Date().addingTimeInterval(60)
        )

        XCTAssertFalse(proxy.isInspectionAvailable(host: "api.example.com", owner: rejecting))
        XCTAssertTrue(proxy.isInspectionAvailable(host: "api.example.com", owner: other),
                      "one app's certificate pinning must not disable inspection for another app")
    }

    func testUnknownOwnerCertificateFailureIsPinnedWithoutAffectingKnownApps() {
        let proxy = InspectionProxy()
        let unknown = InspectionRecorder.Owner()
        let known = InspectionRecorder.Owner(bundleID: "com.example.known", appName: "Known")

        proxy.markInspectionUnavailable(
            host: "api.example.com",
            owner: unknown,
            until: Date().addingTimeInterval(60)
        )

        XCTAssertFalse(proxy.isInspectionAvailable(host: "api.example.com", owner: unknown))
        XCTAssertTrue(proxy.isInspectionAvailable(host: "api.example.com", owner: known))
    }

    func testResolvedProxyAddressEnforcesCIDRBeforeForwardingBytes() async {
        let controller = InspectionController()
        let owner = InspectionRecorder.Owner(
            pid: 42,
            bundleID: "com.example.client",
            appName: "Client",
            appPath: "/Applications/Client.app/Contents/MacOS/Client"
        )
        let block = Rule(action: .block, destination: "203.0.113.0/24")
        let decide: @Sendable (FlowFacts) -> LiveFlowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: [block]),
                externalClaim: nil
            )
        }
        controller.flowRuleDecision = decide
        controller.previewFlowRuleDecision = decide
        controller.onRuleRefusal = { event, completion in
            XCTAssertEqual(event.host, "api.example.com")
            XCTAssertEqual(event.ip, "203.0.113.42")
            completion(true)
        }

        let initiallyAllowed = await authorize(controller, host: "api.example.com", owner: owner)
        XCTAssertTrue(initiallyAllowed, "a CIDR cannot be decided until the upstream address is known")

        let resolvedAllowed = await authorizeResolved(
            controller,
            host: "api.example.com",
            remoteIP: "203.0.113.42",
            owner: owner
        )
        XCTAssertFalse(resolvedAllowed, "the exact address must be authorized before any client bytes are forwarded")
    }

    func testHostnameAllowlistDenialWaitsForResolvedAddress() async {
        let controller = InspectionController()
        let owner = InspectionRecorder.Owner(
            pid: 42,
            bundleID: "com.example.tool",
            appName: "Tool",
            agent: "claude",
            agentName: "Claude"
        )
        controller.agentPolicy = { _ in
            AgentPolicy(agentID: "claude", enabled: true, allowAIProviders: false,
                        patterns: ["203.0.113.0/24"], enforce: true)
        }
        let refusals = LockedCounter()
        controller.onAllowlistRefusal = { _, completion in
            refusals.increment()
            completion(true)
        }

        let allowedBeforeFirstResolution = await authorize(controller, host: "api.example.com", owner: owner)
        let allowedCIDR = await authorizeResolved(controller, host: "api.example.com",
                                                  remoteIP: "203.0.113.42", owner: owner)
        XCTAssertTrue(allowedBeforeFirstResolution,
                      "a hostname cannot be refused before its exact address is known")
        XCTAssertTrue(allowedCIDR)
        XCTAssertEqual(refusals.value, 0)

        let allowedBeforeSecondResolution = await authorize(controller, host: "other.example.com", owner: owner)
        let deniedResolvedAddress = await authorizeResolved(controller, host: "other.example.com",
                                                            remoteIP: "198.51.100.10", owner: owner)
        XCTAssertTrue(allowedBeforeSecondResolution)
        XCTAssertFalse(deniedResolvedAddress)
        XCTAssertEqual(refusals.value, 1)
    }

    func testResolvedProxyAddressDoesNotCommitTheSameHostnameAllowanceTwice() async {
        let controller = InspectionController()
        let owner = InspectionRecorder.Owner(bundleID: "com.example.client", appName: "Client")
        let allow = Rule(action: .allow, destination: "api.example.com", destinationMatch: .exact)
        let cidrBlock = Rule(action: .block, destination: "203.0.113.0/24")
        let rules = [allow, cidrBlock]
        controller.flowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: rules),
                externalClaim: nil
            )
        }
        controller.previewFlowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: rules),
                externalClaim: nil
            )
        }
        let eventCount = LockedCounter()
        controller.onRuleRefusal = { _, completion in
            eventCount.increment()
            completion(true)
        }

        let initiallyAllowed = await authorize(controller, host: "api.example.com", owner: owner)
        let resolvedAllowed = await authorizeResolved(
            controller,
            host: "api.example.com",
            remoteIP: "203.0.113.42",
            owner: owner,
            authorizedRuleID: allow.id
        )
        XCTAssertTrue(initiallyAllowed)
        XCTAssertTrue(resolvedAllowed)
        XCTAssertEqual(eventCount.value, 1)
    }

    func testProxyEnforcesAgentAllowlistAfterRulesAndPacks() async {
        let controller = InspectionController()
        let owner = InspectionRecorder.Owner(
            pid: 42,
            bundleID: "com.example.tool",
            appName: "Tool",
            appPath: "/Applications/Tool.app/Contents/MacOS/Tool",
            agent: "claude",
            agentName: "Claude"
        )
        let policy = AgentPolicy(
            agentID: "claude",
            enabled: true,
            allowAIProviders: false,
            patterns: ["github.com"],
            enforce: true
        )
        controller.agentPolicy = { _ in policy }
        controller.flowRuleDecision = { _ in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleDecision(verdict: .allow, rule: nil),
                externalClaim: nil
            )
        }
        controller.onAllowlistRefusal = { event, completion in
            XCTAssertEqual(event.agentKey, "claude")
            XCTAssertEqual(event.bundleID, "com.example.tool")
            XCTAssertEqual(event.host, "evil.example")
            completion(true)
        }

        let provisional = await authorize(controller, host: "evil.example", owner: owner)
        XCTAssertTrue(provisional, "hostname allowlist denial waits for the selected upstream address")
        let blocked = await authorizeResolved(controller, host: "evil.example",
                                              remoteIP: "198.51.100.10", owner: owner)
        XCTAssertFalse(blocked)
        let allowlisted = await authorize(controller, host: "api.github.com", owner: owner)
        let resolvedAllowlisted = await authorizeResolved(controller, host: "api.github.com",
                                                          remoteIP: "198.51.100.11", owner: owner)
        XCTAssertTrue(allowlisted)
        XCTAssertTrue(resolvedAllowlisted)

        controller.onAllowlistRefusal = { _, completion in completion(false) }
        let unrecorded = await authorizeResolved(controller, host: "evil.example",
                                                 remoteIP: "198.51.100.10", owner: owner)
        XCTAssertTrue(unrecorded, "an allowlist refusal whose durable alert cannot commit must fail open")

        let explicitAllow = Rule(action: .allow, app: "claude", destination: "evil.example")
        let explicitDecision: @Sendable (FlowFacts) -> LiveFlowRuleDecision = { facts in
            LiveFlowRuleDecision(
                paused: false,
                decision: RuleBook.decide(facts, rules: [explicitAllow]),
                externalClaim: nil
            )
        }
        controller.flowRuleDecision = explicitDecision
        controller.previewFlowRuleDecision = explicitDecision
        let explicitlyAllowed = await authorizeResolved(controller, host: "evil.example",
                                                        remoteIP: "198.51.100.10", owner: owner,
                                                        authorizedRuleID: explicitAllow.id)
        XCTAssertTrue(explicitlyAllowed, "an explicit ordinary allow rule must retain precedence over the agent allowlist")
    }

    func testGuardrailRefusalUsesDurableAuthorizationInsteadOfOrdinaryRuleLookup() async {
        let controller = InspectionController()
        let guardrail = Guardrail(agent: "claude", tool: "bash")
        controller.guardrails = { [guardrail] }
        let persisted = LockedCounter()
        let hit = LockedCounter()
        controller.onRuleRefusal = { event, completion in
            XCTAssertEqual(event.ruleID, guardrail.id)
            XCTAssertEqual(event.engine, .guardrail)
            XCTAssertEqual(event.path, "bash")
            persisted.increment()
            completion(true)
        }
        controller.onGuardrailHit = { event in
            XCTAssertEqual(event.ruleID, guardrail.id)
            hit.increment()
        }
        let flow = ProxyFlow(host: "mcp.example.com", port: 443, clientAddress: "127.0.0.1",
                             clientPort: 50_000,
                             owner: .init(bundleID: "com.example.tool", appName: "Tool",
                                          agent: "claude", agentName: "Claude"),
                             inspected: true, scheme: "https")
        let refusal = MockRule(id: guardrail.id, name: guardrail.title, host: flow.host,
                               path: "bash", status: 200, body: "refused", blocked: true)
        let allowed = await withCheckedContinuation { continuation in
            controller.authorizeProxyAnswer(rule: refusal, flow: flow,
                                            head: ProxyRequestHead(method: "POST", target: "/mcp",
                                                                   version: "HTTP/1.1", headers: [])) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertTrue(allowed)
        XCTAssertEqual(persisted.value, 1)
        XCTAssertEqual(hit.value, 1)
    }

    func testStoreCertificateTrustRequiresEffectiveUnrestrictedSSLTrust() {
        let result = kSecTrustSettingsResult as String
        let policy = kSecTrustSettingsPolicy as String
        let policyString = kSecTrustSettingsPolicyString as String
        let trustRoot = NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue)
        let deny = NSNumber(value: SecTrustSettingsResult.deny.rawValue)
        let unspecified = NSNumber(value: SecTrustSettingsResult.unspecified.rawValue)

        XCTAssertEqual(CertificateAuthority.sslTrustDecision([]), .trusted)
        XCTAssertEqual(CertificateAuthority.sslTrustDecision([[result: trustRoot]]), .trusted)
        XCTAssertEqual(CertificateAuthority.sslTrustDecision([[result: deny]]), .denied)
        XCTAssertEqual(CertificateAuthority.sslTrustDecision([[result: unspecified]]), .noDecision)
        XCTAssertEqual(
            CertificateAuthority.sslTrustDecision([[result: trustRoot, policy: SecPolicyCreateBasicX509()]]),
            .noDecision,
            "trust for a non-SSL policy must not make HTTPS setup green"
        )
        XCTAssertEqual(
            CertificateAuthority.sslTrustDecision([
                [result: trustRoot, policy: SecPolicyCreateSSL(true, nil), policyString: "one.example"]
            ]),
            .noDecision,
            "host-restricted trust is not product-wide server trust"
        )
        XCTAssertFalse(CertificateAuthority.isTrustedForSSL(decisions: [.denied, .trusted]),
                       "a user denial must override administrator trust")
        XCTAssertTrue(CertificateAuthority.isTrustedForSSL(decisions: [.noDecision, .trusted]))
    }

    func testNativeCertificateAuthorityCreatesValidDNSAndIPIdentities() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-store-ca-\(UUID().uuidString)", isDirectory: true)
        let authority = CertificateAuthority(directory: directory)
        defer { authority.remove() }

        try authority.ensure()
        XCTAssertTrue(authority.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: authority.caCertificateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: authority.bundleURL.path))

        let root = try XCTUnwrap(authority.caCertificate())
        try await assertTrustedIdentity(authority.identity(for: "api.example.com"), host: "api.example.com", root: root)
        try await assertTrustedIdentity(authority.identity(for: "127.0.0.1"), host: "127.0.0.1", root: root)
        let first = try authority.identity(for: "api.example.com")
        let second = try authority.identity(for: "api.example.com")
        XCTAssertTrue(first === second, "a host identity should be reused for the app session")
    }

    func testStoreCertificateAuthorityUsesAProductSpecificDirectory() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let developerDirectory = applicationSupport.appendingPathComponent(
            "Flowlight/Inspection",
            isDirectory: true
        )

        XCTAssertEqual(
            CertificateAuthority.defaultDirectory.standardizedFileURL,
            applicationSupport.appendingPathComponent("Flowlight/StoreInspection", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertNotEqual(
            CertificateAuthority.defaultDirectory.standardizedFileURL,
            developerDirectory.standardizedFileURL
        )
    }

    func testNativeCertificateAuthorityRepairsMismatchedCertificateAndKeyState() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-store-ca-mismatch-\(UUID().uuidString)", isDirectory: true)
        let authority = CertificateAuthority(directory: container.appendingPathComponent("owned", isDirectory: true))
        let foreign = CertificateAuthority(directory: container.appendingPathComponent("foreign", isDirectory: true))
        defer {
            authority.remove()
            foreign.remove()
            try? FileManager.default.removeItem(at: container)
        }

        try authority.ensure()
        try foreign.ensure()
        let foreignPEM = try Data(contentsOf: foreign.caCertificateURL)
        try foreignPEM.write(to: authority.caCertificateURL, options: .atomic)

        XCTAssertFalse(
            authority.exists,
            "a certificate whose public key does not match the app-owned CA key must not be accepted"
        )

        try authority.ensure()
        XCTAssertTrue(authority.exists)
        let repairedRoot = try XCTUnwrap(authority.caCertificate())
        let foreignRoot = try XCTUnwrap(foreign.caCertificate())
        XCTAssertNotEqual(
            SecCertificateCopyData(repairedRoot) as Data,
            SecCertificateCopyData(foreignRoot) as Data
        )
        try await assertTrustedIdentity(
            authority.identity(for: "api.example.com"),
            host: "api.example.com",
            root: repairedRoot
        )
    }

    func testNativeCertificateAuthorityRemovalPreservesAnImportedRootCertificate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-store-ca-imported-\(UUID().uuidString)", isDirectory: true)
        let authority = CertificateAuthority(directory: directory)
        var importedRoot: SecCertificate?
        defer {
            if let importedRoot {
                SecItemDelete([
                    kSecClass as String: kSecClassCertificate,
                    kSecValueRef as String: importedRoot,
                ] as CFDictionary)
            }
            authority.remove()
        }

        try authority.ensure()
        let root = try XCTUnwrap(authority.caCertificate())
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: root,
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        importedRoot = root

        authority.remove()

        var retained: CFTypeRef?
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: root,
            kSecReturnRef as String: true,
        ]
        XCTAssertEqual(
            SecItemCopyMatching(lookup as CFDictionary, &retained),
            errSecSuccess,
            "removing app-owned CA state must leave a certificate the user imported into Keychain"
        )
        XCTAssertNotNil(retained)
    }

    func testNativeCertificateAuthorityRejectsUnsafeHostMaterial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-store-ca-invalid-\(UUID().uuidString)", isDirectory: true)
        let authority = CertificateAuthority(directory: directory)
        defer { authority.remove() }

        XCTAssertThrowsError(try authority.identity(for: "example.com\nsubjectAltName=DNS:attacker.example"))
    }

    private func authorize(
        _ controller: InspectionController,
        host: String,
        owner: InspectionRecorder.Owner
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            controller.authorizeProxyConnection(host: host, port: 443, owner: owner) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func authorizeResolved(
        _ controller: InspectionController,
        host: String,
        remoteIP: String,
        owner: InspectionRecorder.Owner,
        authorizedRuleID: UUID? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            controller.authorizeResolvedProxyConnection(
                host: host,
                remoteIP: remoteIP,
                port: 443,
                owner: owner,
                authorizedRuleID: authorizedRuleID
            ) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func assertTrustedIdentity(_ identity: SecIdentity, host: String, root: SecCertificate) async throws {
        var leaf: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &leaf), errSecSuccess)
        let certificate = try XCTUnwrap(leaf)
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([certificate, root] as CFArray, policy, &trust), errSecSuccess)
        let evaluated = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(evaluated, [root] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(evaluated, true), errSecSuccess)
        let result = await Task.detached(priority: .userInitiated) {
            var error: CFError?
            let trusted = SecTrustEvaluateWithError(evaluated, &error)
            return (trusted: trusted, error: error.map(String.init(describing:)))
        }.value
        XCTAssertTrue(result.trusted, result.error ?? "trust failed")
    }
}
