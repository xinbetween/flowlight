import AppKit
import Foundation

/// HTTPS inspection: an opt-in mode, off by default, that decrypts the traffic of apps routed through Flowlight's
/// local proxy using a certificate authority created on this Mac. Everything it records stays in the local database.
@MainActor
final class InspectionController: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case agents, all
        var id: String { rawValue }
        var title: String { self == .agents ? L("AI agents and their tools") : L("Every app that uses the proxy") }
    }

    enum Keys {
        static let enabled = "inspection.enabled"
        static let port = "inspection.port"
        static let scope = "inspection.scope"
        static let neverInspect = "inspection.neverInspect"
        static let systemProxy = "inspection.systemProxy"
        static let mockRules = "inspection.mockRules"
        /// Rules that rewrite an outgoing request's headers or JSON body before it is forwarded (see `RewriteRule`).
        static let rewriteRules = "inspection.rewriteRules"
        /// When the running session was switched on, so its end survives a relaunch.
        static let sessionStarted = "inspection.sessionStarted"
        /// Names of the agents the user asked Flowlight to keep routed through the proxy by editing their own
        /// settings files (see `SettingsEnforcer`), so it applies again on every launch without being asked.
        static let monitoredAgents = "inspection.monitoredAgents"
    }

    /// Hosts that are never decrypted, even when routed through the proxy: Apple services (many pin certificates and
    /// carry account data) and password managers.
    nonisolated static let defaultNeverInspect = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "mzstatic.com", "cdn-apple.com",
        "1password.com", "1password.ca", "1password.eu", "bitwarden.com", "lastpass.com", "dashlane.com", "keepersecurity.com",
    ]

    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var trusted = false
    @Published private(set) var caExists = false
    @Published var lastError: String?
    @Published private(set) var recordedCount = 0
    @Published private(set) var systemProxyOn = false
    /// True while the one-click setup is waiting on the administrator prompt.
    @Published private(set) var working = false
    /// What a setup check found, or nil if it hasn't been run since inspection was turned on.
    @Published private(set) var diagnosis: String?
    /// Whether that sentence is the good news. Kept beside it rather than read back out of it: the sentence is
    /// translated, so matching its wording would only work in English.
    @Published private(set) var diagnosisIsGood = false

    private let proxy = InspectionProxy()
    private let recorder = InspectionRecorder()
    private let ca = CertificateAuthority.shared
    private weak var db: TrafficDatabase?
    private var pruneTimer: Timer?
    private var sessionTimer: Timer?
    var onRecorded: () -> Void = {}
    /// The rules that refuse a request rather than a whole connection — the ones that name a path or a method,
    /// which only the proxy can see. Read fresh on every connection, so a rule written now applies to the next
    /// request rather than the next launch.
    nonisolated(unsafe) var requestRules: @Sendable () -> [Rule] = { [] }
    /// Called with every request a rule refused, ready to be recorded in the violations feed.
    nonisolated(unsafe) var onRuleRefusal: @Sendable (RuleEvent) -> Void = { _ in }
    /// The guardrails in force, read fresh per connection like the rules.
    nonisolated(unsafe) var guardrails: @Sendable () -> [Guardrail] = { [] }
    /// Called with every tool a guardrail took away, and every call it refused.
    nonisolated(unsafe) var onGuardrail: @Sendable (RuleEvent) -> Void = { _ in }

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.enabled: false, Keys.port: 8877, Keys.scope: Scope.all.rawValue,
            Keys.neverInspect: Self.defaultNeverInspect, Keys.systemProxy: false,
        ])
        proxy.observer = recorder
        recorder.proxyPort = { [proxy] in proxy.port }
        recorder.budget = { InspectionBudget.load() }
        proxy.onStateChange = { [weak self, proxy] message in
            Task { @MainActor in
                self?.running = proxy.port != nil
                self?.port = proxy.port
                ProxyAttribution.shared.proxyPort = proxy.port
                if let message { self?.lastError = message }
                // The proxy going up or down decides whether it is safe for a settings file to point at it, so the
                // persisted routing is reconciled to that here rather than only when the switch is flipped.
                self?.reconcileEnforcement()
            }
        }
        proxy.pacScript = { [proxy] in
            Self.pacScript(port: proxy.port ?? 8877,
                           never: UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect)
        }
        let scopeAndList = { () -> (Scope, [String]) in
            (Scope(rawValue: UserDefaults.standard.string(forKey: Keys.scope) ?? "") ?? .agents,
             UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect)
        }
        let mockRules = { Self.decodeMockRules(UserDefaults.standard.data(forKey: Keys.mockRules)) }
        let rewriteRules = { Self.decodeRewriteRules(UserDefaults.standard.data(forKey: Keys.rewriteRules)) }
        // A rule refusing a request is answered by the same machinery that gives a mock its canned response, and
        // it goes first: a block someone wrote has to outrank a mock they left switched on.
        let answersFor = { [weak self, recorder, proxy] (host: String, clientPort: UInt16) -> [MockRule] in
            var refusals = (self?.requestRules() ?? []).filter {
                $0.action == .block && ($0.destination.isEmpty || AgentPolicy.matches($0.destination, host: host, ip: ""))
            }
            if refusals.contains(where: { !$0.app.isEmpty }) {
                // Only then is it worth asking who opened this connection: naming an app is the uncommon case,
                // and the answer costs a lookup on the proxy's own queue.
                let owner = recorder.owner(clientPort: clientPort, proxyPort: proxy.port)
                refusals = refusals.filter {
                    Rule.appMatches($0.app, bundleID: owner.bundleID, agentKey: owner.agent ?? owner.bundleID)
                        || Rule.appMatches($0.app, bundleID: owner.appName, agentKey: owner.agentName ?? "")
                }
            }
            return refusals.map { $0.asRefusal(host: host) } + MockRules.mocks(mockRules(), host: host)
        }
        proxy.mockRules = { host, clientPort in answersFor(host, clientPort) }
        // Guardrails read and change whole requests, which is a different job from matching a URL, so they get
        // their own hook rather than being squeezed into the answer machinery.
        proxy.interventions = { [weak self, recorder, proxy] host, clientPort in
            guard let self else { return nil }
            let guardrails = self.guardrails()
            let rewrites = RewriteRules.matching(rewriteRules(), host: host)
            let owner = recorder.owner(clientPort: clientPort, proxyPort: proxy.port)
            let agent = owner.agent ?? owner.bundleID
            let guardsApply = !guardrails.isEmpty && GuardrailBook.any(guardrails, agent: agent)
            // Hold the request only when something would act on it: a guardrail for this agent, or a rewrite rule
            // for this host. Everything else streams untouched.
            guard guardsApply || !rewrites.isEmpty else { return nil }
            return { [weak self] head, bytes in
                guard let self else { return nil }
                let server = owner.mcpServer
                // A guardrail that answers an MCP call locally short-circuits — nothing goes upstream to rewrite.
                if guardsApply, let body = Self.body(of: bytes),
                   let refusal = GuardrailEngine.refuse(jsonrpc: body, guardrails: guardrails, agent: agent, server: server) {
                    self.report(refusal.guardrail, subject: refusal.subject, owner: owner, host: host,
                                port: UInt16(clamping: 443), method: head.method, engine: .request)
                    return .answer(MockRule(id: refusal.guardrail.id, name: refusal.guardrail.title, host: host,
                                            path: "*", status: 200, body: refusal.body, blocked: true))
                }
                var current = bytes
                var notes: [String] = []
                // Guardrails first — strip refused tools from the declaration — so a rewrite acts on the filtered body.
                if guardsApply, let body = Self.body(of: current),
                   let filtered = GuardrailEngine.filter(request: body, guardrails: guardrails, agent: agent) {
                    current = Self.reframe(current, body: filtered.body)
                    self.report(guardrails.first { g in filtered.removed.contains { g.refuses(agent: agent, server: server, tool: $0) } },
                                subject: filtered.removed.joined(separator: ", "), owner: owner, host: host,
                                port: UInt16(clamping: 443), method: head.method, engine: .request)
                    notes.append(L("Removed %@", filtered.removed.joined(separator: ", ")))
                }
                // Then the user's rewrite rules — header and JSON-body edits.
                let path = head.target.split(separator: "?").first.map(String.init) ?? "/"
                if !rewrites.isEmpty,
                   let edited = RewriteRules.apply(rewrites, to: current, host: host, method: head.method, path: path) {
                    current = edited.data
                    notes.append(edited.note)
                }
                guard !notes.isEmpty else { return nil }
                return .replace(current, note: notes.joined(separator: " · "))
            }
        }
        proxy.onAnswered = { [weak self, recorder, proxy] rule, flow, head in
            guard rule.blocked, let refused = (self?.requestRules() ?? []).first(where: { $0.id == rule.id }) else { return }
            let owner = recorder.owner(clientPort: flow.clientPort, proxyPort: proxy.port)
            let path = head?.target.split(separator: "?").first.map(String.init) ?? refused.path
            self?.onRuleRefusal(RuleEvent(at: Int64(Date().timeIntervalSince1970), ruleID: refused.id, action: .block,
                                          engine: .request, agentKey: owner.agent ?? owner.bundleID,
                                          agentName: owner.agentName ?? owner.appName, appName: owner.appName,
                                          bundleID: owner.bundleID, host: flow.host, ip: "",
                                          port: UInt16(clamping: flow.port), path: path,
                                          method: head?.method ?? refused.method))
        }
        let decide = DispatchQueue(label: "flowlight.inspect.decide", qos: .userInitiated, attributes: .concurrent)
        proxy.shouldInspect = { [recorder, proxy] host, clientPort, answer in
            let (scope, never) = scopeAndList()
            guard !Self.matches(host: host, patterns: never) else { answer(false); return }
            // A host someone wrote a mock rule for is decrypted whatever the scope says: a rule can only answer a
            // request Flowlight can read, and "my mock didn't fire" is a bad afternoon.
            guard answersFor(host, clientPort).isEmpty else { answer(true); return }
            // Same for a host with a rewrite rule: it can only edit a request Flowlight can read.
            guard RewriteRules.matching(rewriteRules(), host: host).isEmpty else { answer(true); return }
            guard scope == .agents else { answer(true); return }
            decide.async {
                answer(recorder.owner(clientPort: clientPort, proxyPort: proxy.port).agent != nil)
            }
        }
        recorder.onExchange = { [weak self] exchange in
            // Plain-HTTP requests reach the recorder regardless of scope; keep only what the scope allows.
            let (scope, _) = scopeAndList()
            // A mocked exchange is always kept: an answer Flowlight invented has to be visible wherever it lands.
            guard scope == .all || exchange.agent != nil || exchange.note != nil || exchange.mockRule != nil else { return }
            guard let self else { return }
            Task { @MainActor in
                self.db?.async { try $0.insertExchange(exchange) }
                self.recordedCount += 1
                self.onRecorded()
            }
        }
        refreshStatus()
    }

    /// One decision a guardrail made, on its way to the same feed the network rules use — it is the same
    /// question, asked about a tool instead of a destination.
    nonisolated private func report(_ guardrail: Guardrail?, subject: String, owner: InspectionRecorder.Owner,
                                    host: String, port: UInt16, method: String, engine: Rule.Engine) {
        guard let guardrail else { return }
        onGuardrail(RuleEvent(at: Int64(Date().timeIntervalSince1970), ruleID: guardrail.id, action: .block,
                              engine: engine, agentKey: owner.agent ?? owner.bundleID,
                              agentName: owner.agentName ?? owner.appName, appName: owner.appName,
                              bundleID: owner.bundleID, host: host, ip: "", port: port, path: subject, method: method))
    }

    /// The body of a framed request, or nil when there isn't one to read.
    nonisolated static func body(of request: Data) -> Data? {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = request[end.upperBound...]
        return body.isEmpty ? nil : Data(body)
    }

    /// The same request with a new body, and a `Content-Length` that agrees with it. A length that disagreed
    /// would hang the connection rather than change the request.
    nonisolated static func reframe(_ request: Data, body: Data) -> Data {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return request }
        let head = String(decoding: request[request.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n").filter {
            !$0.lowercased().hasPrefix("content-length:")
        }
        lines.append("Content-Length: \(body.count)")
        var out = Data(lines.joined(separator: "\r\n").utf8)
        out.append(Data("\r\n\r\n".utf8))
        out.append(body)
        return out
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled); objectWillChange.send(); apply() }
    }

    var scope: Scope {
        get { Scope(rawValue: UserDefaults.standard.string(forKey: Keys.scope) ?? "") ?? .agents }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.scope); objectWillChange.send() }
    }

    var neverInspect: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect }
        set { UserDefaults.standard.set(newValue, forKey: Keys.neverInspect); objectWillChange.send() }
    }

    /// What inspection is allowed to keep. Tightening it applies to the next request; it cannot reach back into
    /// what is already recorded, which is why `retentionDays` and Remove Recorded Data exist as well.
    var budget: InspectionBudget {
        get { InspectionBudget.load() }
        set {
            newValue.save()
            objectWillChange.send()
            // A shorter retention has to take effect now rather than at the next hourly sweep, or the setting
            // reads as a promise the app has not kept yet.
            prune()
            scheduleSessionExpiry()
        }
    }

    /// When the current session turns itself off, or nil if it runs until switched off by hand.
    @Published private(set) var sessionEndsAt: Date?
    /// Said once, after the session ended on its own. Not `lastError`: nothing went wrong.
    @Published var sessionNote: String?

    /// Canned answers for chosen endpoints, in the order they're tried. Kept in UserDefaults as JSON like
    /// `neverInspect`: they're settings rather than history, the proxy reads them before the database is open, and
    /// "remove everything Flowlight recorded" mustn't quietly throw away a rule someone wrote.
    var mockRules: [MockRule] {
        get { Self.decodeMockRules(UserDefaults.standard.data(forKey: Keys.mockRules)) }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Keys.mockRules)
            objectWillChange.send()
        }
    }

    /// How many rules would answer something right now. Shown wherever inspection is, because a mock left on is
    /// otherwise indistinguishable from an agent behaving strangely.
    var activeMockRules: Int { mockRules.filter(\.enabled).count }

    nonisolated static func decodeMockRules(_ data: Data?) -> [MockRule] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([MockRule].self, from: data)) ?? []
    }

    /// Rules that rewrite outgoing requests. Stored like mocks: settings, not history, so "remove everything
    /// Flowlight recorded" leaves them alone.
    var rewriteRules: [RewriteRule] {
        get { Self.decodeRewriteRules(UserDefaults.standard.data(forKey: Keys.rewriteRules)) }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Keys.rewriteRules)
            objectWillChange.send()
        }
    }

    /// How many rewrite rules are live, so a request quietly being changed isn't mistaken for the server's own reply.
    var activeRewriteRules: Int { rewriteRules.filter(\.enabled).count }

    nonisolated static func decodeRewriteRules(_ data: Data?) -> [RewriteRule] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([RewriteRule].self, from: data)) ?? []
    }

    var configuredPort: UInt16 { UInt16(clamping: max(1024, UserDefaults.standard.integer(forKey: Keys.port))) }

    func attach(db: TrafficDatabase) {
        self.db = db
        guard !DemoData.isEnabled else { return }
        reconcileEnforcementAtLaunch()
        apply()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        prune()
        scheduleSessionExpiry()
    }

    // MARK: The session ends by itself

    /// Inspection used to run until somebody remembered to turn it off, which meant the most sensitive mode in the
    /// app was the one most likely to be left on after the reason for it had passed. It now has an end, and the
    /// end is visible on screen rather than implied — a countdown you can see is a countdown you can extend on
    /// purpose, where a silent one would just look like inspection breaking.
    private func scheduleSessionExpiry() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        let minutes = budget.sessionMinutes
        guard enabled, running, minutes > 0 else {
            sessionEndsAt = nil
            UserDefaults.standard.removeObject(forKey: Keys.sessionStarted)
            return
        }
        // The clock runs from when inspection was switched on, not from now, so changing an unrelated setting
        // cannot quietly buy another eight hours.
        let started = (UserDefaults.standard.object(forKey: Keys.sessionStarted) as? Date) ?? Date()
        UserDefaults.standard.set(started, forKey: Keys.sessionStarted)
        let ends = started.addingTimeInterval(Double(minutes) * 60)
        sessionEndsAt = ends
        guard ends > Date() else { return expireSession() }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: ends.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.expireSession() }
        }
    }

    private func expireSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionEndsAt = nil
        UserDefaults.standard.removeObject(forKey: Keys.sessionStarted)
        guard enabled else { return }
        enabled = false
        // Four whole sentences rather than one with the period handed in. This is the last string that composed
        // a duration it could not see, and the worst one to leave: it is what someone reads immediately after
        // inspection stopped without being asked, so it is the moment a half-translated sentence does most harm.
        let total = budget.sessionMinutes, hours = total / 60, minutes = total % 60
        if hours == 0 {
            sessionNote = L("Inspection turned itself off after %lld minutes, as set in Advanced. Recorded requests are kept.", minutes)
        } else if minutes == 0 {
            sessionNote = hours == 1
                ? L("Inspection turned itself off after 1 hour, as set in Advanced. Recorded requests are kept.")
                : L("Inspection turned itself off after %lld hours, as set in Advanced. Recorded requests are kept.", hours)
        } else {
            sessionNote = L("Inspection turned itself off after %lld hours %lld minutes, as set in Advanced. Recorded requests are kept.", hours, minutes)
        }
    }

    /// Start the session again from now, for another full period.
    func extendSession() {
        UserDefaults.standard.set(Date(), forKey: Keys.sessionStarted)
        scheduleSessionExpiry()
    }

    /// Everything the simple switch does: create the certificate, trust it, start the proxy and route apps through it.
    /// Trusting and changing the proxy both need an administrator, so they go in one prompt rather than two.
    func setEnabled(_ on: Bool) {
        lastError = nil
        if on {
            do { try ca.ensure() } catch { lastError = error.localizedDescription; return }
            caExists = true
            proxy.start(port: configuredPort)
        }
        working = true
        let pac = "http://127.0.0.1:\(port ?? configuredPort)/proxy.pac"
        let services = SystemProxy.services()
        var commands: [String] = []
        for service in services {
            let quoted = InspectionShell.quote(service)
            commands += on
                ? ["/usr/sbin/networksetup -setautoproxyurl \(quoted) \(pac)",
                   "/usr/sbin/networksetup -setautoproxystate \(quoted) on"]
                : ["/usr/sbin/networksetup -setautoproxystate \(quoted) off"]
        }
        let script = "do shell script " + InspectionShell.appleScriptQuote(commands.joined(separator: " && "))
            + " with administrator privileges"
        let certificate = ca
        // Skip a prompt that would change nothing: re-enabling with the certificate already trusted asks only for
        // the proxy, and turning off an untrusted certificate asks only to undo the proxy.
        let needsTrustChange = certificate.isTrustedAnywhere != on
        let needsProxyChange = !services.isEmpty
        if on, services.isEmpty {
            working = false
            lastError = L("No network services to send through the proxy, so nothing would be inspected. Check System Settings › Network.")
            proxy.stop()
            return
        }
        Task.detached(priority: .userInitiated) {
            var failure: String?
            var trustChanged = false
            // Trust first: it has its own dialog, and there's no point changing the proxy if it's refused.
            if needsTrustChange {
                do { try certificate.setTrusted(on); trustChanged = true } catch { failure = error.localizedDescription }
            }
            if failure == nil, needsProxyChange {
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                failure = error.flatMap { e -> String? in
                    (e[NSAppleScript.errorNumber] as? Int) == -128 ? "cancelled"
                        : (e[NSAppleScript.errorMessage] as? String ?? L("authorization failed"))
                }
                // Don't leave the certificate trusted for a proxy that was never set up.
                if failure != nil, trustChanged { try? certificate.setTrusted(!on) }
            }
            await MainActor.run { self.finishSetup(on: on, failure: failure) }
        }
    }

    private func finishSetup(on: Bool, failure: String?) {
        working = false
        if let failure {
            if !failure.lowercased().contains("cancel") { lastError = L("Couldn't set Flowlight up: %@", failure) }
            if on { proxy.stop() }   // leave nothing half-configured
            UserDefaults.standard.set(false, forKey: Keys.enabled)
            UserDefaults.standard.set(false, forKey: Keys.systemProxy)
        } else {
            UserDefaults.standard.set(on, forKey: Keys.enabled)
            UserDefaults.standard.set(on, forKey: Keys.systemProxy)
            if !on { proxy.stop() }
            diagnosis = nil
            diagnosisIsGood = false
            // Confirm it actually works rather than assuming the commands took effect.
            if on { Task { await checkSetup() } }
        }
        objectWillChange.send()
        refreshStatus()
    }

    /// Starts or stops the proxy to match the setting.
    func apply() {
        refreshStatus()
        if enabled && !DemoData.isEnabled {
            do { try ca.ensure() } catch { lastError = error.localizedDescription; return }
            caExists = true
            proxy.start(port: configuredPort)
        } else {
            if systemProxyOn { setSystemProxy(false) }
            proxy.stop()
        }
    }

    func refreshStatus() {
        caExists = ca.exists
        trusted = caExists && ca.isTrustedAnywhere
        systemProxyOn = UserDefaults.standard.bool(forKey: Keys.systemProxy)
    }

    // MARK: Always monitor — persisting routing into agents' own settings

    private var janitorInstalled = false

    /// The known agents Flowlight can keep routed by editing their own settings file (those with a `configRecipe`),
    /// so a tip has one list to offer and the UI one place to ask.
    nonisolated static var monitorableAgents: [KnownAgent] { AgentCatalog.agents.filter { $0.configRecipe != nil } }

    /// The agents the user asked Flowlight to always monitor. Setting it reconciles the on-disk enforcement now.
    var monitoredAgents: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.monitoredAgents) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Keys.monitoredAgents)
            objectWillChange.send()
            reconcileEnforcement()
        }
    }

    /// Turn "always monitor" on or off for one agent Flowlight knows how to route this way.
    func setAlwaysMonitor(_ on: Bool, agent name: String) {
        var set = monitoredAgents
        if on { set.insert(name) } else { set.remove(name) }
        monitoredAgents = set
    }

    /// Bring the settings files in line with the current state. While the proxy is up and inspection is on, every
    /// monitored agent's file is pointed at it; otherwise none is, because a file pointing at a proxy that isn't
    /// listening would stop the agent reaching its API. Idempotent, so it is safe to call on every state change.
    func reconcileEnforcement() {
        guard !DemoData.isEnabled else { return }
        let enforcer = SettingsEnforcer.shared
        let monitored = monitoredAgents
        let recipes: [(String, ConfigRecipe)] = AgentCatalog.agents
            .filter { monitored.contains($0.name) }
            .compactMap { agent in agent.configRecipe.map { (agent.name, $0) } }

        if enabled, running, let port, !recipes.isEmpty {
            let env = proxyEnvironment
            let url = proxyURL
            for (name, recipe) in recipes {
                do { try enforcer.enforce(agent: name, recipe: recipe, proxyURL: url, env: env, proxyPort: port) }
                catch { lastError = error.localizedDescription }
            }
            if !janitorInstalled { ProxyJanitor.install(manifestPath: enforcer.manifestURL.path); janitorInstalled = true }
        } else {
            enforcer.relaxAll()
            if janitorInstalled { ProxyJanitor.uninstall(); janitorInstalled = false }
        }
    }

    /// On launch, clear anything a previous run left enforced before the proxy is running again: a crash skips the
    /// normal strip, so the file could still point at last run's dead proxy. Normal routing re-applies once the
    /// proxy is up, through `reconcileEnforcement`.
    func reconcileEnforcementAtLaunch() {
        guard !DemoData.isEnabled else { return }
        SettingsEnforcer.shared.relaxAll()
        ProxyJanitor.uninstall()
        janitorInstalled = false
    }

    private func prune() {
        let days = budget.retentionDays
        db?.async { try $0.pruneExchanges(olderThan: Date().addingTimeInterval(-Double(days) * 86400)) }
    }

    // MARK: Certificate

    func trustCertificate() {
        lastError = nil
        Task.detached { [ca] in
            do { try ca.trust() } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run { self.refreshStatus() }
        }
    }

    /// Turns inspection off, removes the system proxy, deletes the CA, its trust setting and every recorded exchange.
    func removeEverything() {
        enabled = false
        let db = db
        Task.detached { [ca] in
            ca.remove()
            db?.async { try $0.deleteAllExchanges() }
            await MainActor.run { self.recordedCount = 0; self.refreshStatus(); self.onRecorded() }
        }
    }

    func revealCertificate() {
        NSWorkspace.shared.activateFileViewerSelecting([ca.caCertificateURL])
    }

    // MARK: Routing

    /// Environment variables that route command-line agents (Claude Code, Codex, Gemini CLI, Aider…) and their tools
    /// through the proxy and make them trust the Flowlight CA. Nothing else on the Mac is affected.
    /// The proxy address as a program would be told it.
    var proxyURL: String { "http://127.0.0.1:\(port ?? configuredPort)" }

    /// Everything a process needs to send its HTTPS through Flowlight and still trust what comes back, as
    /// variables rather than as a shell snippet.
    ///
    /// One source of truth, because there are now two ways to apply it: pasting it into a shell, and launching
    /// a program with it. The two disagreeing would mean a terminal that is inspected and an app that silently
    /// isn't, which is the failure this whole feature exists to remove.
    var proxyEnvironment: [String: String] {
        let bundle = ca.bundleURL.path, caPath = ca.caCertificateURL.path
        return [
            "HTTPS_PROXY": proxyURL, "HTTP_PROXY": proxyURL, "https_proxy": proxyURL, "http_proxy": proxyURL,
            "NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1",
            // Node reads the proxy variables only when told to, and trusts its own CA list unless given another.
            "NODE_USE_ENV_PROXY": "1", "NODE_EXTRA_CA_CERTS": caPath,
            // curl, Python, Git and anything else that takes a bundle from the environment.
            "SSL_CERT_FILE": bundle, "REQUESTS_CA_BUNDLE": bundle,
            "CURL_CA_BUNDLE": bundle, "GIT_SSL_CAINFO": bundle,
        ]
    }

    var shellSetup: String {
        // Grouped the way they were written out by hand before, so the snippet someone pastes still reads as
        // four lines about four things rather than a dozen unordered exports.
        let env = proxyEnvironment
        func line(_ keys: [String], quoted: Bool = false) -> String {
            "export " + keys.map { quoted ? "\($0)=\"\(env[$0] ?? "")\"" : "\($0)=\(env[$0] ?? "")" }.joined(separator: " ")
        }
        return """
        # Flowlight HTTPS inspection: route this shell's tools through Flowlight
        \(line(["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]))
        \(line(["NO_PROXY", "no_proxy"]))
        \(line(["NODE_USE_ENV_PROXY"])) \(line(["NODE_EXTRA_CA_CERTS"], quoted: true).dropFirst(7))
        \(line(["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"], quoted: true))
        """
    }

    func copyShellSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellSetup, forType: .string)
    }

    /// Opens a Terminal window with the setup applied; agents started there are inspected.
    func openInspectedTerminal() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Flowlight Inspected Shell.command")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // The greeting is translated, so it is escaped before it goes into the script: a quote or a $ in a
        // translation would otherwise be read by the shell rather than printed.
        let greeting = L("Flowlight is inspecting HTTPS from this window. Agents you start here show up in Flowlight › Inspect.")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        let body = """
        #!/bin/sh
        \(shellSetup)
        clear
        echo "\(greeting)"
        exec \(shell) -l
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            lastError = L("Couldn't open a Terminal window: %@", error.localizedDescription)
        }
    }

    /// The proxy auto-config served to apps that follow system proxy settings. It falls back to a direct connection
    /// when Flowlight isn't running, so quitting Flowlight never cuts the Mac off.
    /// Checks the three things that have to be true for an app's traffic to reach the proxy, and says which
    /// one isn't. Turning inspection on reports success as soon as the commands run, but a listener that never
    /// came up or a proxy setting that didn't take leaves the app quietly inspecting nothing.
    func checkSetup() async {
        diagnosisIsGood = false
        guard UserDefaults.standard.bool(forKey: Keys.enabled) else { diagnosis = nil; return }
        guard let listening = port else {
            diagnosis = L("The proxy isn't listening. Another program may be using port %lld — change it under Advanced.",
                          Int(configuredPort))
            return
        }
        let services = SystemProxy.services()
        let expected = "http://127.0.0.1:\(listening)/proxy.pac"
        let unset: [String] = await Task.detached(priority: .userInitiated) {
            services.filter { service in
                let result = CertificateAuthority.run("/usr/sbin/networksetup", ["-getautoproxyurl", service])
                return !(result.output.contains(expected) && result.output.contains("Enabled: Yes"))
            }
        }.value
        if !unset.isEmpty {
            diagnosis = L("%@ isn't set to use Flowlight's proxy. Turn inspection off and on again.",
                          unset.joined(separator: ", "))
            return
        }
        // The PAC file has to be served, or macOS quietly falls back to connecting directly.
        var request = URLRequest(url: URL(string: expected)!)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                diagnosis = L("Flowlight isn't serving its proxy settings file, so macOS is connecting directly.")
                return
            }
        } catch {
            diagnosis = L("Couldn't reach Flowlight's proxy settings file: %@", error.localizedDescription)
            return
        }
        let covered = scope == .agents ? L("AI agents and their tools") : L("every app that uses the proxy")
        diagnosis = L("Ready: %@ routed through 127.0.0.1:%lld, inspecting %@.",
                      services.joined(separator: ", "), Int(listening), covered)
        diagnosisIsGood = true
    }

    nonisolated static func pacScript(port: UInt16, never patterns: [String]) -> String {
        let proxy = "PROXY 127.0.0.1:\(port); DIRECT"
        let never = patterns.map { "\"\(Self.jsString($0))\"" }.joined(separator: ", ")
        return """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (isPlainHostName(host) || host == "localhost" || shExpMatch(host, "127.*") || shExpMatch(host, "10.*") ||
              shExpMatch(host, "192.168.*") || shExpMatch(host, "*.local")) return "DIRECT";
          var never = [\(never)];
          for (var i = 0; i < never.length; i++) {
            if (host == never[i] || dnsDomainIs(host, "." + never[i])) return "DIRECT";
          }
          return "\(proxy)";
        }
        """
    }

    /// Points every enabled network service's automatic proxy configuration at Flowlight's PAC file, or restores it.
    /// macOS asks for an administrator password.
    func setSystemProxy(_ on: Bool) {
        let services = SystemProxy.services()
        guard !services.isEmpty else { lastError = L("No network services found."); return }
        let pac = "http://127.0.0.1:\(port ?? configuredPort)/proxy.pac"
        let commands = services.flatMap { service -> [String] in
            let quoted = InspectionShell.quote(service)
            return on
                ? ["/usr/sbin/networksetup -setautoproxyurl \(quoted) \(pac)", "/usr/sbin/networksetup -setautoproxystate \(quoted) on"]
                : ["/usr/sbin/networksetup -setautoproxystate \(quoted) off"]
        }
        let source = "do shell script \(InspectionShell.appleScriptQuote(commands.joined(separator: " && "))) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                lastError = L("Couldn't change the proxy settings: %@",
                              error[NSAppleScript.errorMessage] as? String ?? L("unknown error"))
            }
            return
        }
        UserDefaults.standard.set(on, forKey: Keys.systemProxy)
        refreshStatus()
    }

    // MARK: Matching

    nonisolated static func matches(host: String, patterns: [String]) -> Bool {
        let host = host.lowercased()
        return patterns.contains { raw in
            let p = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " *."))
            return !p.isEmpty && (host == p || host.hasSuffix("." + p))
        }
    }

    nonisolated private static func jsString(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || "-._".contains($0) }
    }
}

enum SystemProxy {
    /// Enabled network service names ("Wi-Fi", "Ethernet"). Disabled services are listed with a leading asterisk.
    static func services() -> [String] {
        let result = CertificateAuthority.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }
}

enum InspectionShell {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
