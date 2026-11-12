import Foundation

#if APP_STORE
/// A source identity observed by the content filter for one client connection to the local inspection proxy.
///
/// The Store app cannot scan other processes from its sandbox. The filter can identify the client from the
/// `NEFilterSocketFlow` audit token, then return only the identity bound to the exact loopback source/destination
/// port pair. An empty reply means "unknown" and must fail open for app-scoped enforcement.
struct ProxyClientIdentity: Codable, Equatable, Sendable {
    var pid: Int32
    var bundleID: String
    var name: String
    var path: String
    /// Parent-agent lineage is resolved in the content filter, where process ancestry is available. The sandboxed
    /// Store host treats these as trusted audit-token context instead of trying (and failing) to rediscover it.
    var agentBundleID: String? = nil
    var agentName: String? = nil
    var mcpServer: String? = nil
}

/// Identity replies carry the filter generation that authorized them. The host compares this with its latest
/// authoritative filter state before applying any app-scoped policy, so a restart cannot make a late reply trusted.
struct ProxyClientIdentityReply: Codable, Equatable, Sendable {
    var identity: ProxyClientIdentity
    var filterGeneration: UInt64
}

/// One content-filter observation considered for explicit-proxy attribution.
///
/// The resolver is shared with the Store host tests so exact-port, loopback, identity, and ambiguity behavior can
/// be proven without constructing private `NEFilterSocketFlow` instances. The extension remains the only producer.
struct ProxyClientFlowCandidate: Equatable, Sendable {
    var localIP: String
    var localPort: UInt16
    var remoteIP: String
    var remotePort: UInt16
    var isTCP: Bool
    var identity: ProxyClientIdentity
    var filterGeneration: UInt64 = 0
}

struct InspectionAgentLineageIdentity: Equatable, Sendable {
    var bundleID: String
    var name: String
}

struct InspectionAgentContext: Equatable, Sendable {
    var bundleID: String
    var name: String
}

/// Resolves the nearest enforcing custom/discovered policy before falling back to the built-in catalog. Keeping the
/// decision pure lets the Store host prove extension ancestry behavior without constructing private socket-flow objects.
enum InspectionAgentContextResolver {
    static func resolve(
        lineage: [InspectionAgentLineageIdentity],
        policies: [AgentPolicy]
    ) -> InspectionAgentContext? {
        let enforcing = policies.filter { $0.enabled && $0.enforce }
        for identity in lineage {
            if let policy = AgentPolicy.resolve(
                enforcing,
                identities: [identity.bundleID, identity.name]
            ) {
                return InspectionAgentContext(bundleID: policy.agentID, name: identity.name)
            }
        }
        for identity in lineage {
            if let known = AgentCatalog.knownAgent(bundleID: identity.bundleID, appName: identity.name) {
                return InspectionAgentContext(bundleID: identity.bundleID, name: known.name)
            }
        }
        return nil
    }
}

enum ProxyClientIdentityResolver {
    static func resolve(
        candidates: [ProxyClientFlowCandidate],
        clientIP: String,
        clientPort: UInt16,
        proxyPort: UInt16,
        filterGeneration: UInt64? = 0
    ) -> ProxyClientIdentity? {
        guard let filterGeneration,
              let clientIP = HostCanonicalizer.address(clientIP) else { return nil }
        let matches = candidates.filter {
            $0.filterGeneration == filterGeneration
                && $0.isTCP
                && HostCanonicalizer.address($0.localIP) == clientIP
                && $0.localPort == clientPort
                && $0.remotePort == proxyPort
                && ($0.remoteIP == "127.0.0.1" || $0.remoteIP == "::1")
        }
        // An old flow can await close accounting after the same app reconnects. Identical audit-token identities are
        // still unambiguous; differing identities for one full tuple must fail open rather than choosing one.
        guard let identity = matches.first?.identity,
              matches.allSatisfy({ $0.identity == identity }),
              identity.pid > 0, !identity.bundleID.isEmpty, identity.bundleID != "unknown" else {
            return nil
        }
        return identity
    }
}
#endif

/// Exported by the system extension on its Mach service.
@objc protocol FlowlightProviderXPC {
    /// Called by the host app after connecting; the extension starts pushing batches.
    func register(withReply reply: @escaping (Bool, String) -> Void)

    /// Whether macOS has actually started this filter — that is, whether `startFilter` ran and its settings
    /// applied. Connecting to the extension only proves the process is alive: macOS runs one content filter at a
    /// time, and when another product holds that slot ours is launched and then never asked to filter anything.
    /// `generation` changes at every filter start/stop boundary so the app can reject a delayed stale reply.
    func filterState(withReply reply: @escaping (Bool, String, UInt64) -> Void)

    /// Enables the stable-ID refusal delivery selectors after the app has verified the extension's exact build.
    /// Registration itself deliberately does not send this backlog: an older app exports only the legacy selectors.
    func enableDurableEvents(appProtocol: Int, withReply reply: @escaping (Bool) -> Void)

    /// Replaces the allowlists the filter enforces. `payload` is `BlockCoding.encode([AgentPolicy])`, holding only
    /// the policies the user has switched to blocking; an empty list turns enforcement off entirely. The app sends
    /// this on every connection and on every change, so the extension never has to read the database itself.
    func setEnforcement(payload: Data, withReply reply: @escaping (Int) -> Void)

    /// Replaces the rule list the filter carries out. `payload` is `BlockCoding.encode(RuleSet)`; an empty payload
    /// means no rules at all. Like `setEnforcement` this is sent whole on every connection and every change, and
    /// like it the extension keeps none of it across a launch: a rule nobody is left to record is not enforced.
    func setRules(payload: Data, withReply reply: @escaping (Int) -> Void)

    /// Atomically spends one bounded flow rule on behalf of the inspection proxy. The extension is the single claim
    /// authority while it is active, so a direct flow and a proxied flow cannot both consume "allow once". `payload`
    /// is `BlockCoding.encode(RuleClaim)` and binds the claim to the exact app session and whole-list generation the
    /// proxy previewed. The reply is 1 when claimed, 0 when already spent, and -1 when that publication no longer matches.
    func claimRule(payload: Data, withReply reply: @escaping (Int) -> Void)

    /// Negotiates the independently-versioned pack protocol before any bytes move.
    func rulePackHello(appProtocol: Int, withReply reply: @escaping (Data) -> Void)
    /// Starts one generation. Chunks are accepted only for this header and never affect the active matcher yet.
    func beginRulePack(payload: Data, withReply reply: @escaping (Data) -> Void)
    func appendRulePack(generation: String, index: Int, payload: Data, withReply reply: @escaping (Bool) -> Void)
    /// Validates, compiles, then atomically swaps one complete generation. A failure leaves the previous one active.
    func commitRulePack(generation: String, withReply reply: @escaping (Data) -> Void)
    func clearRulePacks(payload: Data, withReply reply: @escaping (Data) -> Void)

    #if APP_STORE
    /// Publishes the app's current loopback proxy port. Zero clears it. The filter uses the value only to retain
    /// trusted client identities for explicit proxy connections; it does not redirect or modify any flow.
    func setInspectionProxyPort(_ port: Int, withReply reply: @escaping (Bool) -> Void)

    /// Returns `BlockCoding.encode(ProxyClientIdentity)` only when the content filter observed the exact TCP flow
    /// from `clientAddress:clientPort` to the currently published `proxyPort`. Unknown and stale tuples return empty data.
    func inspectionProxyClient(
        clientAddress: String,
        clientPort: Int,
        proxyPort: Int,
        withReply reply: @escaping (Data) -> Void
    )
    #endif
}

/// Exported by the host app on the same connection.
@objc protocol FlowlightAppXPC {
    /// `payload` is `TrafficCoding.encode([TrafficBatch])`. The app calls `reply` once the batches
    /// are accepted; the extension keeps them queued until then.
    func deliver(payload: Data, reply: @escaping () -> Void)

    /// Legacy delivery selectors retained unchanged for mixed-version upgrades. Current extensions wait for
    /// `enableDurableEvents` and then use the durable selectors below.
    func blocked(payload: Data, reply: @escaping () -> Void)
    func ruleDecisions(payload: Data, reply: @escaping () -> Void)

    /// Stable-ID refusal delivery. True is returned only after the rows commit durably; retries reuse the same event
    /// IDs. New selectors avoid changing an existing Objective-C reply-block ABI in place.
    func blockedDurably(payload: Data, reply: @escaping @Sendable (Bool) -> Void)
    /// Rule decisions additionally return true when every rejected row is generation-stale and therefore terminally
    /// obsolete. Retrying such a row cannot make it current; current rows are acknowledged only after durable commit.
    func ruleDecisionsDurably(payload: Data, reply: @escaping @Sendable (Bool) -> Void)

    /// Bounded minute rollups from managed packs. True is returned only after the batch is durably committed.
    func rulePackEvents(payload: Data, reply: @escaping @Sendable (Bool) -> Void)
}
