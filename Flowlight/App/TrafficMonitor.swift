import AppKit
import Combine
import Foundation

struct LiveTalker: Identifiable, Equatable {
    var bundleID: String
    var name: String
    var path: String
    var rateIn: Double
    var rateOut: Double
    var sessionIn: Int64
    var sessionOut: Int64
    var topDestination: String
    var id: String { bundleID }
}

/// Everything the one-second timer publishes to the Live screen. Replacing one snapshot gives SwiftUI one coherent
/// update; publishing the chart, table, rates, and source state separately can reload NSTableView while its delegate
/// is still reconciling the previous publication.
struct LiveSnapshot: Equatable {
    var talkers: [LiveTalker] = []
    var series: [SeriesPoint] = []
    var currentIn: Double = 0
    var currentOut: Double = 0
    var sessionIn: Int64 = 0
    var sessionOut: Int64 = 0
    var isReceiving = false
}

struct CaptureEnforcementAvailability {
    static func canBlock(mode: CaptureMode, extensionFellBack: Bool, isEntitled: Bool,
                         hasCaptureWarning: Bool, hasUpdateIncident: Bool, isDemo: Bool) -> Bool {
        mode == .networkExtension && !extensionFellBack && isEntitled
            && !hasCaptureWarning && !hasUpdateIncident && !isDemo
    }
}

/// Isolates the one-second live feed from the slower application state. Views that show rates or the live chart
/// observe this object directly; publishing a new sample must not invalidate every screen that uses TrafficMonitor.
/// Thread-safe enforcing allowlists for the inspection proxy. The extension remains authoritative for direct traffic;
/// this mirror closes the two exempt relay legs without asking a main-actor model on the proxy data path.
final class LiveAgentPolicies: @unchecked Sendable {
    private let lock = NSLock()
    private var policies: [AgentPolicy] = []

    func replace(_ values: [AgentPolicy]) {
        lock.lock()
        policies = values.filter { $0.enabled && $0.enforce }
        lock.unlock()
    }

    func resolve(identities: [String]) -> AgentPolicy? {
        lock.lock(); defer { lock.unlock() }
        return AgentPolicy.resolve(policies, identities: identities.filter { !$0.isEmpty })
    }
}

@MainActor
final class TrafficLiveState: ObservableObject {
    @Published private(set) var snapshot = LiveSnapshot()

    var talkers: [LiveTalker] { snapshot.talkers }
    var series: [SeriesPoint] { snapshot.series }
    var currentIn: Double { snapshot.currentIn }
    var currentOut: Double { snapshot.currentOut }
    var sessionIn: Int64 { snapshot.sessionIn }
    var sessionOut: Int64 { snapshot.sessionOut }
    var isReceiving: Bool { snapshot.isReceiving }

    func publish(_ next: LiveSnapshot) {
        if next != snapshot { snapshot = next }
    }
}

/// Owns the capture source, database, anomaly engine and live state.
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var status = L("Starting…")
    @Published private(set) var mode: CaptureMode
    let liveState = TrafficLiveState()
    var talkers: [LiveTalker] { liveState.talkers }
    var liveSeries: [SeriesPoint] { liveState.series }
    var currentIn: Double { liveState.currentIn }
    var currentOut: Double { liveState.currentOut }
    var sessionIn: Int64 { liveState.sessionIn }
    var sessionOut: Int64 { liveState.sessionOut }
    var isReceiving: Bool { liveState.isReceiving }
    private var sessionInTotal: Int64 = 0
    private var sessionOutTotal: Int64 = 0
    /// Sidebar badge count. The compatibility name is retained, but this is explicitly the number in `new` state.
    @Published private(set) var unacknowledgedAlerts = 0
    @Published private(set) var captureState: PacketSniffer.State = .stopped
    @Published private(set) var hostnamesLearned = 0
    /// Share of traffic in the last hour with a hostname / with at least a network owner, plus whether the window has evidence.
    @Published private(set) var coverage: (named: Double, owned: Double, hasTraffic: Bool) = (0, 0, false)
    let sniffer = PacketSniffer()
    /// First-launch offer to enable packet capture.
    @Published var showCaptureOnboarding = false
    private static let onboardingKey = "onboarding.captureOffered"
    private var lastDataAt: Date?
    @Published private(set) var dataVersion = 0 // bumps after each rollup so reports can refresh
    /// Set when the chosen capture source cannot work on this Mac, with an explanation. Nil when it's fine.
    @Published private(set) var captureWarning: String?
    /// Set once the extension source has exhausted its recovery ladder and the sampler has taken over. The chosen
    /// source is still the extension — this is not a preference being rewritten behind someone's back — so it
    /// lasts until they press Refresh, switch source, or relaunch.
    @Published private(set) var extensionFellBack = false
    /// One source of truth for both the persistent incident and its one-shot foreground presentation.
    @Published private var extensionUpdateState = ExtensionUpdateIncidentState()
    var extensionUpdateIncident: ExtensionUpdateIncident? { extensionUpdateState.active }
    var extensionUpdatePresentation: ExtensionUpdateIncident? { extensionUpdateState.presentation }
    @Published private(set) var extensionReinstallState: ExtensionReinstallState = .idle
    /// Focus mode's scope, mirrored here so the live pipeline can apply it. Set by `applyFocus`.
    private(set) var focus: FocusScope = .none
    @Published var lastError: String?

    let db: TrafficDatabase
    /// Opt-in HTTPS inspection (off by default).
    let inspection = InspectionController()
    /// Opt-in export to a collector the user chooses (off by default, and there is no default endpoint).
    let exporter = ExportController()
    /// Everything Flowlight has been told to block or allow, and what those rules have done.
    let rules = RuleStore()
    /// Official managed destination lists, kept separate from human-authored rules and disabled by default.
    let rulePacks: RulePackStore
    /// The exact extension-committed generation, readable from the inspection proxy's queue.
    private let liveRulePacks = LiveRulePacks()
    /// Enforcing allowlists mirrored for proxied traffic, whose two extension-visible relay legs are exempt.
    private let liveAgentPolicies = LiveAgentPolicies()
    /// The active extension is the one atomic authority for bounded rules across direct and proxied flows.
    private let liveRuleClaims = LiveRuleClaimAuthority()
    /// App-local pack refusals use their own ordered, retryable delivery session.
    private var proxyRulePackEvents: RulePackEventDelivery!
    /// Signed official catalog bootstrap, cache re-verification, and bounded refresh state.
    private(set) var rulePackCatalog: RulePackCatalogUpdater!
    /// Which tools each agent may use, which is a different question from which hosts it may reach.
    let guardrails = GuardrailStore()
    /// Advisory inspection plugins: official built-ins first, installed third-party packs later.
    let plugins = PluginStore()
    /// Local non-secret provider metadata shared by Settings, live plugin execution, and backfill.
    let providerProfiles = ProviderProfileStore()
    /// Channels that aren't the network: Bluetooth, USB. Both off until switched on.
    let devices = DeviceStore()
    /// Questions in plain language, answered from the recorded history.
    let ask = AskController()
    /// Bumps when inspection records new exchanges, so the Inspect view can refresh.
    @Published private(set) var inspectionVersion = 0
    /// Bumps after a derived assessment changes, keeping the request list and Reports independent from capture reloads.
    @Published private(set) var localRiskVersion = 0
    /// Read-only connection for UI queries.
    private let readDB: TrafficDatabase
    private lazy var localRisk = LocalRiskCoordinator(db: db, provider: OnDeviceRiskProvider()) { [weak self] in
        Task { @MainActor in self?.localRiskVersion += 1 }
    }
    let activity = ActivityMonitor()
    private let engine: AnomalyEngine
    private let trafficSourceFactory: (() -> TrafficSource)?
    private let policyLoader: @Sendable (TrafficDatabase) throws -> [String: AgentPolicy]
    private let catalogTransportInjected: Bool
    private var source: TrafficSource?
    private var timers: [Timer] = []

    private var windows = WindowVisibility()

    /// Whether anything on screen needs the live chart series and the per-app list. With nothing visible the menu
    /// bar only needs the current rates, so neither is built at all. The launch-only screenshot fixture forces the
    /// complete snapshot because headless capture can see an offscreen window that AppKit correctly calls occluded.
    var uiVisible: Bool {
        Self.needsLiveUI(
            windowVisible: windows.isVisible,
            demoEnabled: DemoData.isEnabled,
            forceRender: UserDefaults.standard.bool(forKey: "FLRenderLive")
        )
    }

    static func needsLiveUI(windowVisible: Bool, demoEnabled: Bool, forceRender: Bool) -> Bool {
        windowVisible || (demoEnabled && forceRender)
    }

    func windowVisibility(_ window: AnyObject, isVisible: Bool) {
        guard windows.update(window, isVisible: isVisible) == .becameHidden else { return }
        // Nothing can see them, and they are rebuilt on the next tick once something can.
        var next = liveState.snapshot
        next.series = []
        next.talkers = []
        liveState.publish(next)
    }

    private let liveWindow = 120
    private let rateWindow = 5
    private var perSecond: [Int64: [String: (name: String, path: String, counters: FlowCounters, topDest: String, topBytes: Int64)]] = [:]
    private var sessionPerApp: [String: FlowCounters] = [:]

    init(databaseURL: URL? = nil,
         catalogTransport: HTTPDataTransport? = nil,
         trafficSourceFactory: (() -> TrafficSource)? = nil,
         policyLoader: @escaping @Sendable (TrafficDatabase) throws -> [String: AgentPolicy] = { try $0.loadPolicies() }) {
        AnomalySettings.registerDefaults()
        LocalRiskSettings.registerDefaults()
        InspectionBudget.registerDefaults()
        DemoData.prepareUITestDefaults()
        #if APP_STORE
        mode = .networkExtension
        #else
        mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: AnomalySettings.Keys.captureMode) ?? "") ?? .nettop
        #endif
        self.trafficSourceFactory = trafficSourceFactory
        self.policyLoader = policyLoader
        catalogTransportInjected = catalogTransport != nil
        rulePacks = RulePackStore(currentAppVersion: ExtensionManager.appVersion)
        do {
            if let databaseURL {
                db = try TrafficDatabase(url: databaseURL)
            } else if DemoData.isEnabled {
                DemoData.resetDatabase()
                db = try TrafficDatabase(url: DemoData.databaseURL)
            } else {
                db = try TrafficDatabase()
            }
        } catch {
            // Fall back to a throwaway database so the UI still works; surface the error.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-\(UUID().uuidString).sqlite")
            db = try! TrafficDatabase(url: tmp)
            lastError = L("Could not open database: %@", "\(error)")
        }
        // Unlike the bulk demo history, this opt-in UI fixture has to exist before catalog bootstrap and the pack
        // store load race each other. The database is disposable and was reset just above.
        if DemoData.isEnabled && DemoData.showsPackReview {
            do { try DemoData.seedPackReview(db) }
            catch { lastError = L("Could not prepare managed-pack review demo: %@", error.localizedDescription) }
        }
        if DemoData.isUITesting {
            try? DemoData.seedUITestPolicies(db)
        }
        readDB = (try? TrafficDatabase(url: db.url, readOnly: true)) ?? db
        engine = AnomalyEngine(db: db, activity: activity)
        providerProfiles.installRuntimeSink { [weak db] profiles in
            db?.async { $0.replaceProviderProfiles(profiles) }
        }
        proxyRulePackEvents = RulePackEventDelivery { [weak rulePacks] batch, claim, completion in
            Task { @MainActor in
                rulePacks?.record(
                    batch,
                    claim: claim,
                    acknowledgeDuringClear: false,
                    completion: completion
                ) ?? completion(false)
            }
        }
        rulePackCatalog = RulePackCatalogUpdater(
            db: db,
            store: rulePacks,
            currentAppVersion: ExtensionManager.appVersion,
            bundledCatalog: {
                guard let url = Bundle.main.url(forResource: "official", withExtension: "json") else {
                    throw RulePackCatalogPersistenceError.invalidReceipt
                }
                return try Data(contentsOf: url)
            },
            transport: catalogTransport
        )
        IPOwnerLookup.shared.onResolved = { [db] ip, owner in
            db.async { try $0.saveOwner(ip: ip, owner) }
        }
        sniffer.onStateChange = { [weak self] state in
            Task { @MainActor in self?.captureState = state }
        }
        engine.onAlert = { [weak self] alerts in
            Notifier.post(alerts)
            Task { @MainActor in
                self?.exporter.record(alerts)
                self?.refreshAlertCount()
            }
        }
    }

    private var started = false
    private var rulePackCatalogReady = false
    private var inspectionRulesReady = false
    private var inspectionPoliciesReady = false
    private var inspectionGuardrailsReady = false
    private var inspectionRulePacksReady = false
    private var inspectionAttached = false

    private func attachInspectionWhenPolicyStateIsReady() {
        let ready = inspectionRulesReady && inspectionPoliciesReady
            && inspectionGuardrailsReady && inspectionRulePacksReady
        inspection.setPolicyStateReady(ready)
        guard ready, !inspectionAttached else { return }
        inspectionAttached = true
        inspection.attach(db: db)
    }

    func start() {
        guard !started else { return }
        started = true
        if DemoData.forcesExtensionUpdateWarning {
            mode = .networkExtension
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.publishExtensionUpdateIncident(.init(
                    kind: .identityMismatch,
                    actual: "0.18.0/84",
                    expected: ExtensionManager.expectedExtensionVersion
                ))
            }
        }
        // A signed build may have an older extension process still enforcing its disconnect grace or holding a
        // buffered finite-rule decision. Reserve the extension as the only counter from process startup, even when
        // this run begins in sampler mode; unavailable claims fail open rather than reusing a bounded allowance.
        if ExtensionManager.isEntitled {
            _ = rules.live.beginExternalClaimAuthority(with: rules.ruleSet)
        }
        if DemoData.isEnabled {
            IPOwnerLookup.shared.isEnabled = { false }
            IPOwnerLookup.shared.preload(DemoData.owners())
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)
            db.async { [weak self] db in
                try DemoData.seed(db)
                Task { @MainActor in self?.dataVersion += 1; self?.refreshAlertCount() }
            }
        }
        activity.start()
        inspection.onRecorded = { [weak self] in self?.inspectionVersion += 1 }
        inspection.onLocalRiskCandidate = { [weak self] in
            guard let self else { return }
            Task { await self.localRisk.wake() }
        }
        Task { await localRisk.recover() }
        rules.onChange = { [weak self] set in
            guard let self else { return }
            if self.source is ExtensionTrafficSource {
                self.source?.setRules(self.rules.live.beginExternalClaimAuthority(with: set))
            } else {
                self.source?.setRules(set)
            }
        }
        rules.attach(db: db) { [weak self] in
            self?.inspectionRulesReady = true
            self?.attachInspectionWhenPolicyStateIsReady()
        }
        rulePacks.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.liveRulePacks.replace(snapshot: nil)
            self.inspectionRulePacksReady = snapshot == nil
            self.attachInspectionWhenPolicyStateIsReady()
            if self.source is ExtensionTrafficSource { self.rulePacks.markApplying() }
            else { self.rulePacks.updateStatus(self.rulePacks.hasEnabledPacks ? .watchingOnly : .off) }
            self.source?.setRulePacks(snapshot)
        }
        // The proxy reads one lock-backed publication for rules and one for the extension-committed pack generation.
        inspection.requestRules = { [live = rules.live] in live.requestRules() }
        inspection.requestRuleGeneration = { [live = rules.live] in live.currentGeneration }
        inspection.flowRuleDecision = { [live = rules.live] facts in
            live.flowDecision(facts)
        }
        inspection.previewFlowRuleDecision = { [live = rules.live] facts in
            live.previewFlowDecision(facts)
        }
        inspection.claimFlowRule = { [liveRuleClaims] claim, completion in
            liveRuleClaims.claim(claim, completion: completion)
        }
        inspection.flowRuleClaimed = { [weak rules] claim, event, completion in
            Task { @MainActor in
                rules?.recordBoundedClaim(claim, event: event, completion: completion) ?? completion(false)
            }
        }
        inspection.flowRuleSpent = { [weak rules] claim, completion in
            Task { @MainActor in
                rules?.retireBoundedClaim(claim, completion: completion) ?? completion(false)
            }
        }
        #if APP_STORE
        inspection.trustedProxyOwner = { [weak self] clientAddress, clientPort, proxyPort, completion in
            Task { @MainActor in
                guard let source = self?.source as? ExtensionTrafficSource else {
                    completion(nil)
                    return
                }
                source.resolveInspectionProxyClient(
                    clientAddress: clientAddress,
                    clientPort: clientPort,
                    proxyPort: proxyPort,
                    completion: completion
                )
            }
        }
        inspection.publishProxyPort = { [weak self] port in
            Task { @MainActor in
                (self?.source as? ExtensionTrafficSource)?.setInspectionProxyPort(port)
            }
        }
        #endif
        inspection.rulePackMatch = { [liveRulePacks] host, bundleID in
            liveRulePacks.match(host: host, bundleID: bundleID)
        }
        inspection.onRulePackRefusal = { [weak proxyRulePackEvents] event, completion in
            proxyRulePackEvents?.enqueue(event, completion: completion) ?? completion(false)
        }
        inspection.agentPolicy = { [liveAgentPolicies] owner in
            liveAgentPolicies.resolve(identities: [
                owner.agent ?? "", owner.bundleID, owner.agentName ?? "", owner.appName,
            ])
        }
        inspection.onAllowlistRefusal = { [weak self] event, completion in
            self?.recordBlocked([event], reply: completion) ?? completion(false)
        }
        inspection.onRuleRefusal = { [weak self] event, completion in
            Task { @MainActor in
                self?.rules.record([event], completion: completion) ?? completion(false)
            }
        }
        // Starting the proxy before these persisted publications are loaded creates a real bypass window. Attach and
        // apply inspection only after ordinary rules and enforcing AgentPolicy state are both available to its queue.
        pushEnforcement { [weak self] loaded in
            self?.inspectionPoliciesReady = loaded
            self?.attachInspectionWhenPolicyStateIsReady()
        }
        guardrails.attach(db: db) { [weak self] in
            self?.inspectionGuardrailsReady = true
            self?.attachInspectionWhenPolicyStateIsReady()
        }
        plugins.attach(db: db)
        devices.attach(db: db)
        ask.attach(db: readDB)
        ask.environment = { [weak self] in self?.askEnvironment() ?? .empty }
        inspection.guardrails = { [live = guardrails.live] in live.all() }
        inspection.onGuardrailHit = { [weak self] event in
            Task { @MainActor in self?.guardrails.record([event]) }
        }
        // Export reads ordinary traffic from the same minute rollups as Reports, but lineage metadata crosses an
        // external trust boundary and therefore comes from the provenance-aware projection.
        exporter.start(rollups: { [weak self] from, to in
            guard let self else { return [] }
            return try await self.read { try $0.exportRows(.minute, from: from, to: to) }
                .map { ExportRollup($0, from: from, to: to) }
        }, recentAlerts: { [weak self] limit in
            guard let self else { return [] }
            return try await self.read { try $0.alerts(limit: limit) }.map(ExportAlert.init)
        })
        Notifier.configure()
        // Either kind of notification needs permission: anomaly alerts, or "a new version is available".
        let defaults = UserDefaults.standard
        #if APP_STORE
        let wantsNotifications = defaults.bool(forKey: AnomalySettings.Keys.notifications)
        #else
        let wantsNotifications = defaults.bool(forKey: AnomalySettings.Keys.notifications)
            || defaults.bool(forKey: UpdateChecker.Keys.automatic)
        #endif
        if wantsNotifications { Notifier.requestAuthorization() }
        // Establish the signed catalog before loading saved consent and exceptions. Starting capture waits for both,
        // so a corrupt higher cache can never briefly enforce bundled content, and enabled packs never omit exceptions.
        Task { [weak self] in
            guard let self else { return }
            await self.rulePackCatalog.bootstrap()
            self.rulePacks.attach(db: self.db) { [weak self] in
                guard let self else { return }
                self.rulePackCatalogReady = true
                self.inspectionRulePacksReady = !self.rulePacks.hasEnabledPacks
                self.attachInspectionWhenPolicyStateIsReady()
                self.startSource()
                let mayUseNetwork = self.catalogTransportInjected
                    || !DemoData.isEnabled && !FlowlightApp.runningTests
                self.rulePackCatalog.startScheduling(networkingEnabled: mayUseNetwork)
            }
        }
        db.async { [engine] db in
            IPOwnerLookup.shared.preload(try db.loadOwners())
            for ip in try db.unownedIPs(since: Date().addingTimeInterval(-86400)) { IPOwnerLookup.shared.owner(for: ip) }
            let agents = try db.appDestinations(since: Date().addingTimeInterval(-7 * 86400))
                .filter { AgentCatalog.provider(domain: $0.domain, owner: $0.owner) != nil && !AgentCatalog.isBrowser($0.bundleID) }
                .map(\.bundleID)
            engine.seedDiscoveredAgents(Set(agents))
        }
        #if !APP_STORE
        updatePacketCapture()
        // Not yet: the first thing someone sees should be their own traffic, not a request for a password.
        // Hostnames are a refinement, and the offer explains itself better once there are rows on screen to
        // refine. See `offerCaptureSetupIfNeeded`.
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.onboardingDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerCaptureSetupIfNeeded() }
        })
        #endif
        refreshAlertCount()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickLive() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if !APP_STORE
                self.sniffer.refreshInterface()
                if self.captureState == .noPermission { self.updatePacketCapture() }
                #endif
            }
        })
        runMaintenance()
    }

    /// Drops the capture source and starts it again. The extension source recovers a lost connection by itself
    /// and says so as it goes; this is for when someone has just fixed something and doesn't want to wait for it,
    /// and for starting over after it has given up and handed capture to the sampler.
    func reconnectSource() {
        // Someone asking for this has usually just fixed something, so the extension gets a clean run at it
        // again even if it had given up earlier in this session.
        extensionRetry?.cancel()
        extensionRetryAttempt = 0
        extensionFellBack = false
        status = L("Reconnecting…")
        startSource()
    }

    /// How long to wait before trying the extension again after falling back to the sampler.
    ///
    /// An app update is the common case: macOS keeps running the extension it activated, so for a minute or two
    /// after an upgrade the installed filter is the previous build and the app cannot reach it. Capture is
    /// already safe — the sampler took over — so the only thing missing was going back, and until now that took
    /// a button press. The gaps grow because a Mac where the filter can never run (another content filter owns
    /// the slot) should settle into checking every few minutes rather than redialling forever.
    private static let extensionRetryDelays: [TimeInterval] = [20, 60, 180, 600]
    private var extensionRetryAttempt = 0
    private var extensionRetry: Task<Void, Never>?

    private func scheduleExtensionRetry() {
        extensionRetry?.cancel()
        let delay = Self.extensionRetryDelays[min(extensionRetryAttempt, Self.extensionRetryDelays.count - 1)]
        extensionRetryAttempt += 1
        extensionRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.mode == .networkExtension, self.extensionFellBack else { return }
                self.extensionFellBack = false
                self.status = L("Trying the filter extension again…")
                self.startSource()
            }
        }
    }

    func setMode(_ newMode: CaptureMode) {
        #if APP_STORE
        guard newMode == .networkExtension else { return }
        #endif
        guard newMode != mode else { return }
        mode = newMode
        extensionRetry?.cancel()
        extensionRetryAttempt = 0
        extensionFellBack = false
        if newMode != .networkExtension { clearExtensionUpdateIncident() }
        UserDefaults.standard.set(newMode.rawValue, forKey: AnomalySettings.Keys.captureMode)
        startSource()
    }

    /// Whether the current capture source can actually refuse a connection. Only the Network Extension sits in the
    /// data path: the nettop sampler reads counters after the traffic has already left, and demo mode invents it.
    /// A fallback counts as not being on the extension, or the Rules screen would promise enforcement that the
    /// sampler running in its place cannot carry out.
    var canBlock: Bool {
        CaptureEnforcementAvailability.canBlock(
            mode: mode,
            extensionFellBack: extensionFellBack,
            isEntitled: ExtensionManager.isEntitled,
            hasCaptureWarning: captureWarning != nil,
            hasUpdateIncident: extensionUpdateIncident != nil,
            isDemo: DemoData.isEnabled
        )
    }

    /// Passive hostname capture is only needed for the nettop source; the extension sees payloads itself.
    func updatePacketCapture() {
        #if APP_STORE
        sniffer.stop()
        captureState = .stopped
        return
        #else
        let onSampler = mode == .nettop || extensionFellBack
        let wanted = !DemoData.isEnabled && onSampler && UserDefaults.standard.bool(forKey: AnomalySettings.Keys.packetCapture)
        if wanted {
            if case .running = captureState { return }
            sniffer.start()
        } else {
            sniffer.stop()
        }
        captureState = sniffer.state
        #endif
    }

    /// How long the first run is left alone before hostname setup is offered.
    static let onboardingDelay: TimeInterval = 45

    private func offerCaptureSetupIfNeeded() {
        let defaults = UserDefaults.standard
        // `-FLForceCaptureOnboarding YES` shows the offer regardless (for testing the flow).
        if defaults.bool(forKey: "FLForceCaptureOnboarding") { showCaptureOnboarding = true; return }
        guard !defaults.bool(forKey: Self.onboardingKey), mode == .nettop,
              defaults.bool(forKey: AnomalySettings.Keys.packetCapture),
              captureState == .noPermission, !CaptureAccess.isInstalled else { return }
        // Only while someone is actually looking. Asking for an administrator password over whatever they are
        // doing, at a window they may not even have open, is how a monitor gets quit instead of set up — and the
        // offer keeps: it is made again next launch until taken or dismissed.
        guard uiVisible else { return }
        showCaptureOnboarding = true
    }

    /// Once seen, the offer is not repeated (closing the window counts as "Not Now").
    func markCaptureOnboardingShown() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    func dismissCaptureOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        showCaptureOnboarding = false
    }

    /// Runs the admin-approved setup (or removal) and restarts capture. Returns a message for the UI.
    func performCaptureSetup(_ action: CaptureAccess.Action) -> String? {
        switch CaptureAccess.run(action) {
        case .success:
            sniffer.stop()
            updatePacketCapture()
            if action == .uninstall { return L("Packet capture access was removed.") }
            if captureState == .noPermission { return L("Access granted. Log out and back in to finish.") }
            return L("Packet capture is enabled.")
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private func startSource() {
        guard rulePackCatalogReady else { return }
        liveRulePacks.replace(snapshot: nil)
        if rulePacks.hasEnabledPacks {
            inspectionRulePacksReady = false
            attachInspectionWhenPolicyStateIsReady()
        }
        source?.stop()
        #if APP_STORE
        inspection.setAttributionReady(false)
        #endif
        let newSource: TrafficSource
        // A build without the entitlement can never reach the extension; capture with the sampler rather than
        // sitting there recording nothing.
        let canUseExtension = ExtensionManager.isEntitled
        var fallbackNote: String?
        if let trafficSourceFactory {
            newSource = trafficSourceFactory()
        } else if DemoData.isEnabled {
            newSource = DemoTrafficSource()
        } else if mode == .networkExtension, canUseExtension, !extensionFellBack {
            newSource = ExtensionTrafficSource()
        } else {
            #if APP_STORE
            fallbackNote = L("Couldn't reach the filter extension. Enable it under Content filter, then press Refresh.")
            newSource = UnavailableTrafficSource(message: fallbackNote!)
            #else
            if mode == .networkExtension {
                fallbackNote = extensionFellBack
                    // Names the button that is on screen. It used to say "under Network Extension", which was
                    // where these controls lived until the filter got a section of its own.
                    ? L("Couldn't reach the filter extension — sampling with nettop instead. Press Try the Extension Again under Content filter.")
                    : L("This build isn't signed for the Network Extension — sampling with nettop instead.")
            }
            newSource = NettopTrafficSource()
            #endif
        }
        // Same idea as FLForceCaptureOnboarding: a way to see this state on a Mac where the filter works.
        if extensionUpdateIncident == nil {
            captureWarning = UserDefaults.standard.bool(forKey: "FLForceFilterWarning")
                ? L("macOS hasn't started Flowlight's filter. It runs one content filter at a time, and another one — a VPN or a security agent such as Palo Alto Networks GlobalProtect or CrowdStrike Falcon — already has that slot. The extension can't capture anything on this Mac until that changes.")
                : nil
        }
        if let extensionSource = newSource as? ExtensionTrafficSource {
            #if APP_STORE
            extensionSource.onAttributionReadinessChanged = { [weak self, weak extensionSource] ready in
                Task { @MainActor in
                    guard let self, let extensionSource, self.source === extensionSource else { return }
                    self.inspection.setAttributionReady(ready)
                }
            }
            #endif
            extensionSource.onFilterAvailabilityChanged = { [weak self, weak extensionSource] running, message in
                Task { @MainActor in
                    guard let self, let extensionSource, self.source === extensionSource,
                          !UserDefaults.standard.bool(forKey: "FLForceFilterWarning") else { return }
                    self.captureWarning = running ? nil : message
                    if running { self.extensionRecovered() }
                }
            }
            extensionSource.onIdentityMismatch = { [weak self, weak extensionSource] mismatch in
                Task { @MainActor in
                    guard let self, let extensionSource, self.source === extensionSource else { return }
                    self.extensionIdentityMismatch(mismatch)
                }
            }
            extensionSource.onBlocked = { [weak self] events, reply in
                guard let self else { reply(false); return }
                self.recordBlocked(events, reply: reply)
            }
            extensionSource.onRuleDecisions = { [weak self] events, reply in
                guard let self else { reply(false); return }
                Task { @MainActor in self.rules.record(events, completion: reply) }
            }
            extensionSource.onRulePackEvents = { [weak self] batch, completion in
                self?.recordRulePackEvents(batch, completion: completion) ?? completion(false)
            }
            extensionSource.onRulePackStatus = { [weak self, weak extensionSource] result in
                Task { @MainActor in
                    guard let self, let extensionSource, self.source === extensionSource else { return }
                    self.updateRulePackStatus(result)
                }
            }
            #if !APP_STORE
            extensionSource.onVersionProbeRequested = { [weak self] in
                Task { @MainActor in self?.repairExtensionVersion() }
            }
            #endif
            extensionSource.onGaveUp = { [weak self] message in
                Task { @MainActor in
                    #if APP_STORE
                    self?.filterBecameUnavailable(message)
                    #else
                    self?.fallBackToSampler()
                    #endif
                }
            }
        }
        source = newSource
        let extensionSource = newSource as? ExtensionTrafficSource
        #if APP_STORE
        extensionSource?.setInspectionProxyPort(inspection.port)
        #endif
        liveRuleClaims.replace(extensionSource)
        let sourceRuleSet: RuleSet
        if extensionSource != nil {
            sourceRuleSet = rules.live.beginExternalClaimAuthority(with: rules.ruleSet)
        } else {
            // External finite-rule ownership is session-sticky. The extension deliberately enforces for a short
            // disconnect grace and may still hold an undelivered spend; resuming a local counter would permit reuse.
            sourceRuleSet = rules.ruleSet
        }
        status = fallbackNote ?? L("Starting %@…", newSource.displayName)
        if started { updatePacketCapture() }
        newSource.start(sink: { [weak self] batches in
            self?.ingest(batches)
        }, status: { [weak self] message in
            Task { @MainActor in self?.status = fallbackNote ?? message }
        })
        pushEnforcement()
        newSource.setRules(sourceRuleSet)
        newSource.setRulePacks(rulePacks.snapshot)
        if rulePacks.hasEnabledPacks, !(newSource is ExtensionTrafficSource) {
            inspectionRulePacksReady = false
            attachInspectionWhenPolicyStateIsReady()
            inspection.lastError = L("HTTPS inspection is waiting for the filter to commit the enabled managed policies.")
            rulePacks.updateStatus(.watchingOnly)
        }
    }

    private func updateRulePackStatus(_ result: RulePackApplyResult) {
        switch result.status {
        case .accepted:
            liveRulePacks.replace(snapshot: nil)
            inspectionRulePacksReady = false
            attachInspectionWhenPolicyStateIsReady()
            rulePacks.updateStatus(.applying)
        case .committed:
            let desired = rulePacks.snapshot
            liveRulePacks.commit(snapshot: desired, activeDigest: result.activeDigest)
            if desired?.digest == result.activeDigest {
                inspectionRulePacksReady = true
                attachInspectionWhenPolicyStateIsReady()
                rulePacks.updateStatus(.enforcing)
            } else {
                inspectionRulePacksReady = false
                attachInspectionWhenPolicyStateIsReady()
                let message = "The filter acknowledged a different rule pack snapshot."
                inspection.lastError = L("The filter acknowledged a different rule pack snapshot.")
                rulePacks.updateStatus(.failed(message))
            }
        case .cleared:
            liveRulePacks.replace(snapshot: nil)
            inspectionRulePacksReady = true
            attachInspectionWhenPolicyStateIsReady()
            rulePacks.updateStatus(.off)
        case .incompatible:
            liveRulePacks.replace(snapshot: nil)
            inspectionRulePacksReady = false
            attachInspectionWhenPolicyStateIsReady()
            inspection.lastError = result.detail
            rulePacks.updateStatus(.incompatible(result.detail))
        case .invalid, .stale:
            liveRulePacks.replace(snapshot: nil)
            inspectionRulePacksReady = false
            attachInspectionWhenPolicyStateIsReady()
            inspection.lastError = result.detail
            rulePacks.updateStatus(.failed(result.detail))
        }
    }

    private func extensionIdentityMismatch(_ mismatch: ExtensionIdentityMismatch) {
        guard mode == .networkExtension else { return }
        let message = L("The app updated to filter %@, but macOS is still running %@. Reinstall the filter or restart your Mac to finish the update.",
                        mismatch.expected, mismatch.actual)
        captureWarning = message
        status = message
        publishExtensionUpdateIncident(.init(kind: .identityMismatch,
                                             actual: mismatch.actual,
                                             expected: mismatch.expected))
    }

    private func publishExtensionUpdateIncident(_ incident: ExtensionUpdateIncident) {
        guard mode == .networkExtension else { return }
        if extensionUpdateIncident?.id != incident.id { extensionReinstallState = .idle }
        extensionUpdateState.publish(incident)
    }

    private func extensionRecovered() {
        clearExtensionUpdateIncident()
    }

    /// Clears the persistent diagnosis without forgetting that its dialog was already presented this session. This is
    /// used both for proven healthy recovery and when the person explicitly leaves Network Extension mode.
    private func clearExtensionUpdateIncident() {
        guard extensionUpdateState.active != nil || extensionUpdateState.presentation != nil else { return }
        extensionUpdateState.recovered()
        extensionReinstallState = .idle
    }

    func consumeExtensionUpdatePresentation() {
        extensionUpdateState.consumePresentation()
    }

    func reinstallExtension(using manager: ExtensionManager) {
        guard extensionUpdateIncident != nil, !extensionReinstallState.isInProgress else { return }
        extensionReinstallState = .reinstalling
        status = L("Reinstalling the filter, then reconnecting…")
        manager.reinstall(approvalRequired: { [weak self] in
            guard let self else { return }
            self.extensionReinstallState = .awaitingApproval
            self.status = L("Approve the filter update in System Settings, then return to Flowlight.")
        }) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .started:
                    self.extensionReinstallState = .started
                    (self.source as? ExtensionTrafficSource)?.versionRepairStarted()
                    // Developer recovery may already be sampling after the mismatch; Store recovery may be on its
                    // unavailable source. Both products need a fresh exact registration immediately.
                    self.reconnectSource()
                case .rebootRequired:
                    self.extensionReinstallState = .rebootRequired
                    self.status = L("Restart your Mac to finish replacing the filter.")
                case .failed(let message):
                    self.extensionReinstallState = .failed(message)
                    self.status = L("Could not reinstall the filter: %@", message)
                    self.captureWarning = self.status
                }
            }
        }
    }

    nonisolated private func recordRulePackEvents(
        _ batch: RulePackEventBatch,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.rulePacks.record(batch) { [weak self] committed in
                completion(committed)
                guard committed else { return }
                Task { @MainActor [weak self] in self?.dataVersion += 1 }
            }
        }
    }

    #if !APP_STORE
    /// The extension source has been refused often enough that plain redialling isn't the answer. Ask macOS which
    /// build of the extension it is running: if it isn't this app's, re-activating replaces it, and that is the
    /// one fault behind "the filter is enabled but the app can't reach it" that the app can repair by itself.
    ///
    /// Asked for once per source, by the ladder in `ExtensionRecovery`, because it can end in a System Settings
    /// prompt. A matching version costs nothing and changes nothing.
    /// Routes startup and retry-ladder version checks through one decision point. A held-copy scan alone does not
    /// interrupt someone whose exact extension is registering and filtering; the modal needs both authoritative
    /// update evidence and an observed outage.
    func extensionVersionCheckCompleted(_ check: ExtensionManager.VersionCheck, outageProven: Bool = false) {
        if check.needsRestart {
            guard outageProven, mode == .networkExtension else { return }
            status = L("Version %@ of the filter is installed, but macOS is still holding the previous version. Reinstall the filter or restart your Mac to finish the update.",
                       check.expectedVersion)
            publishExtensionUpdateIncident(.init(kind: .heldCopies, actual: nil,
                                                 expected: check.expectedVersion))
            fallBackToSampler()
            return
        }
        guard check.repairing else { return }
        extensionVersionRepairing(check)
    }

    /// macOS found the installed extension is a different version from this app — which is what an upgrade
    /// always leaves behind for a moment. Replacing it takes longer than the redial ladder's patience, so the
    /// ladder is reset and the status says what is happening rather than reporting silence.
    func extensionVersionRepairing(_ check: ExtensionManager.VersionCheck) {
        status = L("The installed filter extension is %@ and this app is %@ — macOS is replacing it. Capture resumes once it has.",
                   check.installedDescription, check.expectedVersion)
        if let extensionSource = source as? ExtensionTrafficSource {
            extensionSource.versionRepairStarted()
            // Replacing a system extension is macOS's business and takes as long as it takes. Sampling in the
            // meantime is the difference between a minute of history and a minute of nothing; the scheduled outer
            // retry brings the extension back once the replacement lands. Duplicate coalesced answers stay idempotent.
            fallBackToSampler()
        }
    }

    private func repairExtensionVersion() {
        guard let manager = ExtensionManager.current else { return }
        manager.matchExtensionToApp { [weak self] check in
            Task { @MainActor in
                guard let self else { return }
                self.extensionVersionCheckCompleted(check, outageProven: true)
            }
        }
    }
    #endif

    #if APP_STORE
    /// The Store product has no privileged sampler fallback. Leave enforcement visibly unavailable and let Refresh
    /// create a new bounded reconnect ladder after the person enables the content filter in System Settings.
    private func filterBecameUnavailable(_ message: String) {
        guard mode == .networkExtension else { return }
        extensionFellBack = true
        let note = L("%@ — enable Flowlight under Content filter, then press Refresh.", message)
        source?.stop()
        let unavailable = UnavailableTrafficSource(message: note)
        source = unavailable
        liveRuleClaims.replace(nil)
        liveRulePacks.replace(snapshot: nil)
        if rulePacks.hasEnabledPacks { rulePacks.updateStatus(.watchingOnly) }
        status = note
        unavailable.start(sink: { _ in }, status: { _ in })
    }
    #else
    /// The extension has stopped answering for good. Rather than leave someone with an orange dot and no data,
    /// capture with the sampler and say plainly that this is what happened — their chosen source is still the
    /// extension, and the status line says how to go back to it.
    private func fallBackToSampler() {
        guard mode == .networkExtension, !extensionFellBack else { return }
        extensionFellBack = true
        startSource()
        scheduleExtensionRetry()
    }
    #endif

    /// Hands the capture source the allowlists it should refuse connections against. Only the ones the user has
    /// switched to blocking travel: everything else stays a matter for alerts, and a source that can't block
    /// ignores them.
    private func pushEnforcement(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let db = db
        let loader = policyLoader
        let liveAgentPolicies = liveAgentPolicies
        Task { [weak self] in
            do {
                let enforcing = try await db.asyncResult { db in
                    Array(try loader(db).values.filter { $0.enabled && $0.enforce })
                }
                guard let self else { return }
                liveAgentPolicies.replace(enforcing)
                self.source?.setEnforcement(enforcing)
                completion(true)
            } catch {
                guard let self else { return }
                // Do not publish an empty list: that would turn a persistence failure into a policy bypass. Complete
                // the startup barrier as failed, keep inspection stopped, and make the reason visible instead.
                self.inspection.lastError = L("Could not open database: %@", error.localizedDescription)
                completion(false)
            }
        }
    }

    /// Connections the filter refused. Each one becomes an alert naming the agent, where it was headed and the
    /// fact that it didn't get there — a refusal nobody can see would be worse than not refusing at all.
    nonisolated func recordBlocked(_ events: [BlockEvent], reply: @escaping @Sendable (Bool) -> Void = { _ in }) {
        Task { [weak self] in
            guard let self else { reply(false); return }
            do {
                let alerts = try await db.asyncResult { database in
                    var alerts: [AlertRecord] = []
                    try database.withTransaction {
                        let acceptedEvents = try database.recordBlockEventsInTransaction(events)
                        for event in acceptedEvents {
                            let who = event.appName.isEmpty || event.appName == event.agentName
                                ? event.agentName : "\(event.agentName) › \(event.appName)"
                            let pattern = event.host.isEmpty ? event.ip : AnomalyEngine.registrableDomain(event.host)
                            let why = event.rule.isEmpty ? L("not on %@'s allowlist", event.agentName)
                                                         : L("the rule \"%@\"", event.rule)
                            alerts.append(try database.addAlert(
                                kind: AnomalyEngine.Kind.blockedConnection.rawValue,
                                bundleID: event.agentKey,
                                appName: event.agentName,
                                detail: L("Blocked %@ from connecting to %@:%lld — %@", who, event.destination,
                                          Int(event.port), why),
                                severity: 3,
                                at: Date(timeIntervalSince1970: TimeInterval(event.at)),
                                allowPattern: pattern
                            ))
                        }
                    }
                    return alerts
                }
                // The extension's health tracks durable reporting, not UI delivery. A busy main actor must not turn a
                // committed refusal into five seconds of apparent reporting failure and make enforcement fail open.
                reply(true)
                Notifier.post(alerts)
                await MainActor.run {
                    self.exporter.record(alerts)
                    self.refreshAlertCount()
                    self.dataVersion += 1
                }
            } catch {
                reply(false)
            }
        }
    }

    // MARK: Ingest (any thread)

    nonisolated func ingest(_ incoming: [TrafficBatch]) {
        // An empty delivery is the sampler's heartbeat: nothing moved this second, but capture is alive.
        guard !incoming.isEmpty else {
            Task { @MainActor in self.lastDataAt = Date() }
            return
        }
        // Tools and MCP servers an agent started are attributed to that agent (demo data carries its own).
        // Traffic through the HTTPS inspection proxy belongs to the app that sent it, not to Flowlight.
        let batches = DemoData.isEnabled ? incoming : AgentAttributor.shared.enrich(ProxyAttribution.shared.rewrite(incoming))
        // Anything without a hostname gets at least its network owner.
        for batch in batches {
            for record in batch.records where record.key.domain.isEmpty {
                IPOwnerLookup.shared.owner(for: record.key.remoteIP)
            }
        }
        db.async { [engine] db in
            try db.insert(batches)
            try engine.observe(batches)
        }
        Task { @MainActor in self.updateLive(with: batches) }
    }

    /// Focus changed: the live feed is a running total, so it restarts rather than mixing two scopes together.
    func applyFocus(_ scope: FocusScope) {
        guard scope != focus else { return }
        focus = scope
        perSecond.removeAll()
        sessionPerApp.removeAll()
        sessionInTotal = 0
        sessionOutTotal = 0
        var next = liveState.snapshot
        next.talkers = []
        next.series = []
        next.sessionIn = 0
        next.sessionOut = 0
        liveState.publish(next)
        refreshAlertCount()
    }

    private func updateLive(with batches: [TrafficBatch]) {
        lastDataAt = Date()
        // Anything older than the live window is history: it is already on its way to the database, and feeding
        // it through here only to have tickLive drop it again wastes the work.
        let oldest = Int64(Date().timeIntervalSince1970) - Int64(liveWindow)
        for batch in batches where batch.timestamp >= oldest {
            var bucket = perSecond[batch.timestamp] ?? [:]
            for r in batch.records {
                let k = r.key
                // Focus hides traffic from the live feed and the menu bar rates. It is never applied before the
                // database write above: history and the anomaly baselines always see everything.
                if !focus.isEmpty, !focus.matches(bundleID: k.bundleID, domain: k.domain, remoteIP: k.remoteIP) { continue }
                var entry = bucket[k.bundleID] ?? (k.appName, k.appPath, FlowCounters(), "", 0)
                entry.counters += r.counters
                // Prefer a real remote host over local unconnected sockets (e.g. mDNS).
                let dest = !k.domain.isEmpty ? k.domain : (IPOwnerLookup.shared.cached(k.remoteIP).map { "\($0.name) · \(k.remoteIP)" } ?? k.remoteIP)
                let isRemote = k.remoteIP != "(unconnected)"
                let weight = isRemote ? r.counters.total : 0
                if entry.topDest.isEmpty || weight > entry.topBytes {
                    entry.topBytes = weight
                    entry.topDest = dest
                }
                bucket[k.bundleID] = entry
                sessionPerApp[k.bundleID, default: FlowCounters()] += r.counters
                sessionInTotal += r.counters.bytesIn
                sessionOutTotal += r.counters.bytesOut
            }
            perSecond[batch.timestamp] = bucket
        }
    }

    private func tickLive() {
        let now = Int64(Date().timeIntervalSince1970)
        var next = liveState.snapshot
        next.sessionIn = sessionInTotal
        next.sessionOut = sessionOutTotal
        next.isReceiving = lastDataAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        // Without a window, only the last few seconds are needed for the menu bar rates.
        let keep = Int64(uiVisible ? liveWindow : rateWindow + 3)
        perSecond = perSecond.filter { $0.key > now - keep }

        if uiVisible {
            next.series = ((now - Int64(liveWindow))..<now).map { ts in
                let values = perSecond[ts]?.values.map(\.counters) ?? []
                return SeriesPoint(date: Date(timeIntervalSince1970: TimeInterval(ts)),
                                   bytesIn: values.reduce(0) { $0 + $1.bytesIn },
                                   bytesOut: values.reduce(0) { $0 + $1.bytesOut },
                                   flows: values.reduce(0) { $0 + $1.flows })
            }
        }

        // Rates over the most recent complete seconds (sources lag ~1–2 s).
        let window = ((now - Int64(rateWindow) - 1)..<(now - 1))
        var rates: [String: (name: String, path: String, counters: FlowCounters, topDest: String, topBytes: Int64)] = [:]
        for ts in window {
            for (bundle, entry) in perSecond[ts] ?? [:] {
                var agg = rates[bundle] ?? (entry.name, entry.path, FlowCounters(), entry.topDest, 0)
                agg.counters += entry.counters
                if entry.topBytes > agg.topBytes { agg.topBytes = entry.topBytes; agg.topDest = entry.topDest }
                rates[bundle] = agg
            }
        }
        let seconds = Double(rateWindow)
        guard uiVisible else {
            // Menu bar only: the totals, without building or publishing the per-app list.
            setRates(inRate: rates.values.reduce(0.0) { $0 + Double($1.counters.bytesIn) / seconds },
                     outRate: rates.values.reduce(0.0) { $0 + Double($1.counters.bytesOut) / seconds }, in: &next)
            publishLive(next)
            return
        }
        next.talkers = rates.map { bundle, v in
            LiveTalker(bundleID: bundle, name: v.name, path: v.path, rateIn: Double(v.counters.bytesIn) / seconds,
                       rateOut: Double(v.counters.bytesOut) / seconds, sessionIn: sessionPerApp[bundle]?.bytesIn ?? 0,
                       sessionOut: sessionPerApp[bundle]?.bytesOut ?? 0, topDestination: v.topDest)
        }
        .filter { $0.rateIn + $0.rateOut > 0 }
        .sorted { $0.rateIn + $0.rateOut > $1.rateIn + $1.rateOut }
        setRates(inRate: next.talkers.reduce(0) { $0 + $1.rateIn },
                 outRate: next.talkers.reduce(0) { $0 + $1.rateOut }, in: &next)
        publishLive(next)
    }

    /// Publishes rates only when they actually move, so an idle Mac doesn't redraw the menu bar every second.
    private func setRates(inRate: Double, outRate: Double, in snapshot: inout LiveSnapshot) {
        if abs(inRate - snapshot.currentIn) > max(64, snapshot.currentIn * 0.02) { snapshot.currentIn = inRate }
        if abs(outRate - snapshot.currentOut) > max(64, snapshot.currentOut * 0.02) { snapshot.currentOut = outRate }
    }

    private func publishLive(_ snapshot: LiveSnapshot) {
        liveState.publish(snapshot)
    }

    // MARK: Maintenance

    func runMaintenance() {
        let retentionHours = UserDefaults.standard.double(forKey: AnomalySettings.Keys.retentionHours)
        Task { await localRisk.recover() }
        db.async { [engine, weak self] db in
            var retention = TrafficDatabase.Retention()
            retention.seconds = max(1, retentionHours) * 3600
            let completed = try db.rollup(retention: retention)
            for hour in completed.completedHours { try engine.hourCompleted(hour) }
            for day in completed.completedDays { try engine.dayCompleted(day) }
            try engine.evaluateIdleTraffic()
            let eventCutoff = Date().addingTimeInterval(-max(1, retentionHours) * 3600)
            try db.pruneRuleEvents(before: eventCutoff)
            try db.pruneRulePackEvents(before: eventCutoff)
            let coverage = try db.coverage(since: Date().addingTimeInterval(-3600))
            Task { @MainActor in
                self?.coverage = coverage
                self?.hostnamesLearned = DNSCache.shared.learnedCount
                self?.dataVersion += 1
            }
        }
    }

    func refreshAlertCount() {
        let scope = focus
        db.async { [weak self] db in
            let count = try db.newAlertCount(focus: scope)
            Task { @MainActor in self?.unacknowledgedAlerts = count }
        }
    }

    func setLocalRiskEnabled(_ enabled: Bool) {
        guard LocalRiskSettings.canAnalyze || !enabled else { return }
        UserDefaults.standard.set(enabled, forKey: LocalRiskSettings.Keys.enabled)
        localRiskVersion += 1
        Task { [localRisk] in
            if enabled && LocalRiskSettings.canAnalyze { await localRisk.recover() }
            else { await localRisk.stop() }
        }
    }

    func analyzeRecentInspectedRequests() {
        Task { await localRisk.backfillRecent() }
    }

    func clearPluginFindings() {
        plugins.clearFindings()
    }

    func clearLocalRiskAnalyses() {
        Task { [weak self, db] in
            db.async { db in
                try db.clearLocalRiskAssessments()
                Task { @MainActor in self?.localRiskVersion += 1 }
            }
            await self?.localRisk.stop()
        }
    }

    func clearAllData() {
        rulePacks.beginActivityClear()
        devices.beginHistoryClear()
        proxyRulePackEvents.invalidate { [weak self, db] in
            Task { @MainActor [weak self, db] in
                guard let self else { return }
                do {
                    try await db.asyncResult { try $0.clearAll() }
                    self.sessionPerApp.removeAll()
                    self.perSecond.removeAll()
                    self.sessionInTotal = 0
                    self.sessionOutTotal = 0
                    var next = self.liveState.snapshot
                    next.talkers = []
                    next.series = []
                    next.currentIn = 0
                    next.currentOut = 0
                    next.sessionIn = 0
                    next.sessionOut = 0
                    self.liveState.publish(next)
                    self.rulePacks.finishActivityClear(succeeded: true)
                    self.rules.clearPublishedEventsAfterDurableDeletion()
                    self.devices.finishHistoryClear(succeeded: true)
                    self.dataVersion += 1
                    self.refreshAlertCount()
                } catch {
                    self.rulePacks.finishActivityClear(succeeded: false)
                    self.devices.finishHistoryClear(succeeded: false)
                    self.lastError = L("Couldn't delete the captured data: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Runs a read query off the main thread on the read-only connection.
    func read<T: Sendable>(_ body: @escaping @Sendable (TrafficDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            readDB.queue.async { [readDB] in
                continuation.resume(with: Result { try body(readDB) })
            }
        }
    }

    /// How Flowlight is set up, for the Ask panel to answer questions about the app rather than about traffic.
    ///
    /// Read on the main actor and handed to the query that needs it, so nothing reaches across threads for it.
    /// Settings only: no keys, no export headers, no endpoint. Those live in the Keychain and have no business
    /// travelling to a model to answer "is export on?".
    private var askCaptureSource: String {
        #if APP_STORE
        return extensionFellBack ? "Network Extension unavailable" : "Network Extension"
        #else
        return mode == .networkExtension && !extensionFellBack ? "Network Extension" : "nettop sampler"
        #endif
    }

    func askEnvironment() -> AskEnvironment {
        AskEnvironment(
            appVersion: ExtensionManager.appVersion,
            captureSource: DemoData.isEnabled ? "demo data" : askCaptureSource,
            captureStatus: status,
            receiving: isReceiving,
            extensionState: ExtensionManager.current?.state.label ?? "unknown",
            fellBackToSampler: {
                #if APP_STORE
                false
                #else
                extensionFellBack
                #endif
            }(),
            canBlock: canBlock,
            inspecting: inspection.enabled && inspection.running,
            inspectionScope: inspection.scope.title,
            exportEnabled: exporter.configuration.isReady,
            exportConfigured: exporter.configuration.endpointURL != nil,
            focus: focus.isEmpty ? "" : "\(focus.bundleIDs.count) apps, \(focus.hosts.count) destinations",
            backgroundOnly: UserDefaults.standard.bool(forKey: AnomalySettings.Keys.backgroundOnly),
            watchingBluetooth: devices.watchingBluetooth,
            watchingUSB: devices.watchingUSB,
            watchingCamera: devices.watchingCamera,
            rules: rules.rules.map { rule in
                "\(rule.title) — \(rule.enabled ? "on" : "off"), \(rule.schedule.describe(session: RuleStore.session)), fired \(rule.hits)×"
            },
            guardrails: guardrails.guardrails.map { "\($0.title) — \($0.enabled ? "on" : "off"), \($0.hits)×" },
            agentAllowlists: engine.policies.values.filter(\.enabled).count,
            askProvider: ask.provider.title,
            askSendsOffDevice: ask.sendsOffDevice)
    }

    /// Saves an agent's allowlist and applies it to new traffic right away — to the alerts, and to what the filter
    /// refuses.
    func savePolicy(_ policy: AgentPolicy) {
        db.async { [engine, weak self] db in
            try db.savePolicy(policy)
            try engine.reloadPolicies()
            Task { @MainActor in
                self?.dataVersion += 1
                self?.pushEnforcement()
            }
        }
    }

    /// "Allow from now on", from the alert about a connection that was refused.
    func allowFromNowOn(pattern: String, agentID: String) {
        db.async { [engine, weak self] db in
            let loaded = try db.loadPolicies()
            var policy = AgentPolicy.resolve(loaded.values, identities: [agentID]) ?? AgentPolicy(agentID: agentID)
            guard !policy.patterns.contains(pattern) else { return }
            policy.patterns.append(pattern)
            try db.savePolicy(policy)
            try engine.reloadPolicies()
            Task { @MainActor in
                self?.dataVersion += 1
                self?.pushEnforcement()
            }
        }
    }

    @discardableResult
    func acknowledgeAlerts(ids: [Int64]?, focus: FocusScope = .none) async -> Bool {
        await updateAlertTriage { database in
            try database.acknowledgeAlerts(ids: ids, focus: focus)
        }
    }

    @discardableResult
    func setAlertTriageState(_ state: AlertTriageState, ids: [Int64]) async -> Bool {
        await updateAlertTriage { database in
            try database.setAlertTriageState(state, ids: ids)
        }
    }

    @discardableResult
    func setAlertDisposition(_ disposition: AlertDisposition, ids: [Int64]) async -> Bool {
        await updateAlertTriage { database in
            try database.setAlertDisposition(disposition, ids: ids)
        }
    }

    @discardableResult
    func setAlertNote(_ note: String, id: Int64) async -> Bool {
        await updateAlertTriage { database in
            try database.setAlertNote(note, id: id)
        }
    }

    private func updateAlertTriage(
        _ mutation: @escaping @Sendable (TrafficDatabase) throws -> Void
    ) async -> Bool {
        do {
            try await db.asyncResult(mutation)
            alertTriageDidChange()
            return true
        } catch {
            lastError = L("Couldn't update alerts: %@", error.localizedDescription)
            return false
        }
    }

    private func alertTriageDidChange() {
        refreshAlertCount()
        dataVersion += 1
    }
}
