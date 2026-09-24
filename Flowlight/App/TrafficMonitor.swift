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

/// Owns the capture source, database, anomaly engine and live state.
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var status = "Starting…"
    @Published private(set) var mode: CaptureMode
    @Published private(set) var talkers: [LiveTalker] = []
    @Published private(set) var liveSeries: [SeriesPoint] = []
    @Published private(set) var currentIn: Double = 0
    @Published private(set) var currentOut: Double = 0
    @Published private(set) var sessionIn: Int64 = 0
    @Published private(set) var sessionOut: Int64 = 0
    @Published private(set) var unacknowledgedAlerts = 0
    @Published private(set) var isReceiving = false
    @Published private(set) var captureState: PacketSniffer.State = .stopped
    @Published private(set) var hostnamesLearned = 0
    /// Share of traffic in the last hour with a hostname / with at least a network owner.
    @Published private(set) var coverage: (named: Double, owned: Double) = (0, 0)
    let sniffer = PacketSniffer()
    /// First-launch offer to enable packet capture.
    @Published var showCaptureOnboarding = false
    private static let onboardingKey = "onboarding.captureOffered"
    private var lastDataAt: Date?
    @Published private(set) var dataVersion = 0 // bumps after each rollup so reports can refresh
    /// Set when the chosen capture source cannot work on this Mac, with an explanation. Nil when it's fine.
    @Published private(set) var captureWarning: String?
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
    /// Bumps when inspection records new exchanges, so the Inspect view can refresh.
    @Published private(set) var inspectionVersion = 0
    /// Read-only connection for UI queries.
    private let readDB: TrafficDatabase
    let activity = ActivityMonitor()
    private let engine: AnomalyEngine
    private var source: TrafficSource?
    private var timers: [Timer] = []

    /// How many Flowlight windows are on screen. With none, the menu bar only needs the current rates, so the live
    /// chart series and the per-app list aren't built at all.
    private var visibleWindows = 0
    var uiVisible: Bool { visibleWindows > 0 }

    func windowAppeared() { visibleWindows += 1 }

    func windowDisappeared() {
        visibleWindows = max(0, visibleWindows - 1)
        if !uiVisible {
            liveSeries = []
            talkers = []
        }
    }

    private let liveWindow = 120
    private let rateWindow = 5
    private var perSecond: [Int64: [String: (name: String, path: String, counters: FlowCounters, topDest: String, topBytes: Int64)]] = [:]
    private var sessionPerApp: [String: FlowCounters] = [:]

    init() {
        AnomalySettings.registerDefaults()
        mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: AnomalySettings.Keys.captureMode) ?? "") ?? .nettop
        do {
            if DemoData.isEnabled {
                DemoData.resetDatabase()
                db = try TrafficDatabase(url: DemoData.databaseURL)
            } else {
                db = try TrafficDatabase()
            }
        } catch {
            // Fall back to a throwaway database so the UI still works; surface the error.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-\(UUID().uuidString).sqlite")
            db = try! TrafficDatabase(url: tmp)
            lastError = "Could not open database: \(error)"
        }
        readDB = (try? TrafficDatabase(url: db.url, readOnly: true)) ?? db
        engine = AnomalyEngine(db: db, activity: activity)
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

    func start() {
        guard !started else { return }
        started = true
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
        inspection.attach(db: db)
        rules.onChange = { [weak self] set in self?.source?.setRules(set) }
        rules.attach(db: db)
        // A rule that names a path is carried out by the proxy, which reads its list fresh on every connection.
        inspection.requestRules = { [live = rules.live] in live.requestRules() }
        inspection.onRuleRefusal = { [weak self] event in
            Task { @MainActor in self?.rules.record([event]) }
        }
        // Export reads what Reports reads — the same minute rollups, through the same read-only connection — so
        // there is nothing it can send that isn't already on a screen the user can look at.
        exporter.start(rollups: { [weak self] from, to in
            guard let self else { return [] }
            return try await self.read { try $0.breakdown(.minute, from: from, to: to) }
                .map { ExportRollup($0, from: from, to: to) }
        }, recentAlerts: { [weak self] limit in
            guard let self else { return [] }
            return try await self.read { try $0.alerts(limit: limit) }.map(ExportAlert.init)
        })
        Notifier.configure()
        // Either kind of notification needs permission: anomaly alerts, or "a new version is available".
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: AnomalySettings.Keys.notifications) || defaults.bool(forKey: UpdateChecker.Keys.automatic) {
            Notifier.requestAuthorization()
        }
        startSource()
        db.async { [engine] db in
            IPOwnerLookup.shared.preload(try db.loadOwners())
            for ip in try db.unownedIPs(since: Date().addingTimeInterval(-86400)) { IPOwnerLookup.shared.owner(for: ip) }
            let agents = try db.appDestinations(since: Date().addingTimeInterval(-7 * 86400))
                .filter { AgentCatalog.provider(domain: $0.domain, owner: $0.owner) != nil && !AgentCatalog.isBrowser($0.bundleID) }
                .map(\.bundleID)
            engine.seedDiscoveredAgents(Set(agents))
        }
        updatePacketCapture()
        // Not yet: the first thing someone sees should be their own traffic, not a request for a password.
        // Hostnames are a refinement, and the offer explains itself better once there are rows on screen to
        // refine. See `offerCaptureSetupIfNeeded`.
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.onboardingDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerCaptureSetupIfNeeded() }
        })
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
                self.sniffer.refreshInterface()
                if self.captureState == .noPermission { self.updatePacketCapture() }
            }
        })
        runMaintenance()
    }

    /// Drops the capture source and starts it again. The extension source retries a lost connection every five
    /// seconds by itself; this is for when someone has just fixed something and doesn't want to wait or relaunch.
    func reconnectSource() {
        status = "Reconnecting…"
        startSource()
    }

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: AnomalySettings.Keys.captureMode)
        startSource()
    }

    /// Whether the current capture source can actually refuse a connection. Only the Network Extension sits in the
    /// data path: the nettop sampler reads counters after the traffic has already left, and demo mode invents it.
    var canBlock: Bool {
        mode == .networkExtension && ExtensionManager.isEntitled && captureWarning == nil && !DemoData.isEnabled
    }

    /// Passive hostname capture is only needed for the nettop source; the extension sees payloads itself.
    func updatePacketCapture() {
        let wanted = !DemoData.isEnabled && mode == .nettop && UserDefaults.standard.bool(forKey: AnomalySettings.Keys.packetCapture)
        if wanted {
            if case .running = captureState { return }
            sniffer.start()
        } else {
            sniffer.stop()
        }
        captureState = sniffer.state
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
            if action == .uninstall { return "Packet capture access was removed." }
            if captureState == .noPermission { return "Access granted. Log out and back in to finish." }
            return "Packet capture is enabled."
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private func startSource() {
        source?.stop()
        let newSource: TrafficSource
        // A build without the entitlement can never reach the extension; capture with the sampler rather than
        // sitting there recording nothing.
        let canUseExtension = ExtensionManager.isEntitled
        var fallbackNote: String?
        if DemoData.isEnabled {
            newSource = DemoTrafficSource()
        } else if mode == .networkExtension, canUseExtension {
            newSource = ExtensionTrafficSource()
        } else {
            if mode == .networkExtension {
                fallbackNote = "This build isn't signed for the Network Extension — sampling with nettop instead."
            }
            newSource = NettopTrafficSource()
        }
        // Same idea as FLForceCaptureOnboarding: a way to see this state on a Mac where the filter works.
        captureWarning = UserDefaults.standard.bool(forKey: "FLForceFilterWarning")
            ? "macOS hasn't started Flowlight's filter. It runs one content filter at a time, and another one — a VPN "
              + "or a security agent such as Palo Alto Networks GlobalProtect or CrowdStrike Falcon — already has that slot. The "
              + "extension can't capture anything on this Mac until that changes."
            : nil
        if let extensionSource = newSource as? ExtensionTrafficSource {
            extensionSource.onFilterUnavailable = { [weak self] message in
                Task { @MainActor in self?.captureWarning = message }
            }
            extensionSource.onBlocked = { [weak self] events in self?.recordBlocked(events) }
            extensionSource.onRuleDecisions = { [weak self] events in
                Task { @MainActor in self?.rules.record(events) }
            }
        }
        source = newSource
        status = fallbackNote ?? "Starting \(newSource.displayName)…"
        if started { updatePacketCapture() }
        newSource.start(sink: { [weak self] batches in
            self?.ingest(batches)
        }, status: { [weak self] message in
            Task { @MainActor in self?.status = fallbackNote ?? message }
        })
        pushEnforcement()
        newSource.setRules(rules.ruleSet)
    }

    /// Hands the capture source the allowlists it should refuse connections against. Only the ones the user has
    /// switched to blocking travel: everything else stays a matter for alerts, and a source that can't block
    /// ignores them.
    private func pushEnforcement() {
        db.async { [weak self] db in
            let enforcing = try db.loadPolicies().values.filter { $0.enabled && $0.enforce }
            Task { @MainActor in self?.source?.setEnforcement(Array(enforcing)) }
        }
    }

    /// Connections the filter refused. Each one becomes an alert naming the agent, where it was headed and the
    /// fact that it didn't get there — a refusal nobody can see would be worse than not refusing at all.
    nonisolated func recordBlocked(_ events: [BlockEvent]) {
        db.async { [weak self] db in
            var alerts: [AlertRecord] = []
            for event in events {
                let who = event.appName.isEmpty || event.appName == event.agentName
                    ? event.agentName : "\(event.agentName) › \(event.appName)"
                let pattern = event.host.isEmpty ? event.ip : AnomalyEngine.registrableDomain(event.host)
                let why = event.rule.isEmpty ? "not on \(event.agentName)'s allowlist" : "the rule \"\(event.rule)\""
                alerts.append(try db.addAlert(kind: AnomalyEngine.Kind.blockedConnection.rawValue, bundleID: event.agentKey,
                                              appName: event.agentName,
                                              detail: "Blocked \(who) from connecting to \(event.destination):\(event.port) — \(why)",
                                              severity: 3, at: Date(timeIntervalSince1970: TimeInterval(event.at)),
                                              allowPattern: pattern))
            }
            Notifier.post(alerts)
            Task { @MainActor in
                self?.exporter.record(alerts)
                self?.refreshAlertCount()
                self?.dataVersion += 1
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
        sessionIn = 0
        sessionOut = 0
        talkers = []
        liveSeries = []
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
                sessionIn += r.counters.bytesIn
                sessionOut += r.counters.bytesOut
            }
            perSecond[batch.timestamp] = bucket
        }
    }

    private func tickLive() {
        let now = Int64(Date().timeIntervalSince1970)
        let receiving = lastDataAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if receiving != isReceiving { isReceiving = receiving }
        // Without a window, only the last few seconds are needed for the menu bar rates.
        let keep = Int64(uiVisible ? liveWindow : rateWindow + 3)
        perSecond = perSecond.filter { $0.key > now - keep }

        if uiVisible {
            liveSeries = ((now - Int64(liveWindow))..<now).map { ts in
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
                     outRate: rates.values.reduce(0.0) { $0 + Double($1.counters.bytesOut) / seconds })
            return
        }
        talkers = rates.map { bundle, v in
            LiveTalker(bundleID: bundle, name: v.name, path: v.path, rateIn: Double(v.counters.bytesIn) / seconds,
                       rateOut: Double(v.counters.bytesOut) / seconds, sessionIn: sessionPerApp[bundle]?.bytesIn ?? 0,
                       sessionOut: sessionPerApp[bundle]?.bytesOut ?? 0, topDestination: v.topDest)
        }
        .filter { $0.rateIn + $0.rateOut > 0 }
        .sorted { $0.rateIn + $0.rateOut > $1.rateIn + $1.rateOut }
        setRates(inRate: talkers.reduce(0) { $0 + $1.rateIn }, outRate: talkers.reduce(0) { $0 + $1.rateOut })
    }

    /// Publishes rates only when they actually move, so an idle Mac doesn't redraw the menu bar every second.
    private func setRates(inRate: Double, outRate: Double) {
        if abs(inRate - currentIn) > max(64, currentIn * 0.02) { currentIn = inRate }
        if abs(outRate - currentOut) > max(64, currentOut * 0.02) { currentOut = outRate }
    }

    // MARK: Maintenance

    func runMaintenance() {
        let retentionHours = UserDefaults.standard.double(forKey: AnomalySettings.Keys.retentionHours)
        db.async { [engine, weak self] db in
            var retention = TrafficDatabase.Retention()
            retention.seconds = max(1, retentionHours) * 3600
            let completed = try db.rollup(retention: retention)
            for hour in completed.completedHours { try engine.hourCompleted(hour) }
            for day in completed.completedDays { try engine.dayCompleted(day) }
            try engine.evaluateIdleTraffic()
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
            let count = try db.unacknowledgedAlertCount(focus: scope)
            Task { @MainActor in self?.unacknowledgedAlerts = count }
        }
    }

    func clearAllData() {
        db.async { [weak self] db in
            try db.clearAll()
            Task { @MainActor in
                self?.sessionPerApp.removeAll()
                self?.perSecond.removeAll()
                self?.sessionIn = 0
                self?.sessionOut = 0
                self?.dataVersion += 1
                self?.refreshAlertCount()
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
            var policy = try db.loadPolicies()[agentID] ?? AgentPolicy(agentID: agentID)
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

    func acknowledgeAlerts(ids: [Int64]?) {
        db.async { [weak self] db in
            try db.acknowledgeAlerts(ids: ids)
            Task { @MainActor in
                self?.refreshAlertCount()
                self?.dataVersion += 1
            }
        }
    }
}
