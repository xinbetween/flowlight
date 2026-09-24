import Foundation

/// Every rule Flowlight has been given, what they have done, and the one switch that stands them all down.
///
/// The rules themselves live in `Shared/Rule.swift` as plain data, because the extension carries them out and has
/// to understand them too. This is the app's half: where they are kept, who is told when they change, and what
/// happened each time one of them decided something.
@MainActor
final class RuleStore: ObservableObject {
    /// This run of Flowlight. A rule that lasts "until I quit" is measured against it, so nothing has to be swept
    /// at quit — which a crash or a forced restart would skip anyway.
    static let session = UUID().uuidString

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var events: [RuleEventRecord] = []
    /// Nothing is refused before this moment. The escape hatch that makes strict rules liveable.
    @Published private(set) var pausedUntil: Date?
    /// Bumps whenever the list or the feed changes, for views that only need to know that something did.
    @Published private(set) var version = 0

    /// Hands the current rules to whatever can carry them out. Set by `TrafficMonitor`.
    var onChange: (RuleSet) -> Void = { _ in }

    private weak var db: TrafficDatabase?
    private var pauseTimer: Timer?
    /// The same rules, readable from the proxy's queue. The store itself is main-actor — it is a published model —
    /// but the proxy asks which rules apply while framing a request, so it needs an answer without a hop.
    let live = LiveRules()

    var enabledRules: [Rule] { rules.filter(\.enabled) }
    /// Rules that would decide something right now — enabled, finished, and inside their hours.
    var liveRules: [Rule] {
        let now = Date()
        return rules.filter { $0.enabled && $0.isComplete && $0.isUsable && $0.schedule.isActive(at: now, session: Self.session) }
    }

    var isPaused: Bool { pausedUntil.map { Date() < $0 } ?? false }

    func attach(db: TrafficDatabase) {
        self.db = db
        reload()
    }

    func reload() {
        guard let db else { return }
        db.async { [weak self] db in
            let rules = (try? db.loadRules()) ?? []
            let events = (try? db.ruleEvents(limit: 300)) ?? []
            Task { @MainActor in
                guard let self else { return }
                // A rule tied to an earlier run of Flowlight is over. Dropping it here rather than at quit means a
                // crash can't leave a relaxation in force forever.
                let expired = rules.filter { $0.schedule.kind == .session && $0.schedule.session != Self.session }
                self.rules = rules.filter { !expired.contains($0) }
                self.events = events
                for rule in expired { db.async { try $0.deleteRule(rule.id) } }
                self.publish()
            }
        }
    }

    // MARK: Changing the list

    func save(_ rule: Rule) {
        var rule = rule
        rule.destination = Self.cleaned(rule.destination)
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        db?.async { try $0.saveRule(rule) }
        publish()
    }

    func delete(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        db?.async { try $0.deleteRule(rule.id) }
        publish()
    }

    func setEnabled(_ rule: Rule, _ on: Bool) {
        guard var found = rules.first(where: { $0.id == rule.id }) else { return }
        found.enabled = on
        save(found)
    }

    /// Clears everything a rule has done, so "is this doing anything?" can be asked again from now.
    func resetHits(_ rule: Rule) {
        guard var found = rules.first(where: { $0.id == rule.id }) else { return }
        found.hits = 0
        found.lastHit = nil
        save(found)
    }

    // MARK: The escape hatch

    /// Stands every rule down for a while. Ten minutes by default: long enough to get something done, short
    /// enough that forgetting to switch it back on isn't a quiet hole in the afternoon.
    func pause(for seconds: TimeInterval = 600) {
        pausedUntil = Date().addingTimeInterval(seconds)
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: seconds + 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        publish()
    }

    func resume() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        publish()
    }

    // MARK: What the rules did

    /// Decisions from the filter: recorded, counted, and shown. Both refusals and relaxations arrive here.
    func record(_ incoming: [RuleEvent]) {
        guard !incoming.isEmpty else { return }
        for event in incoming {
            guard let index = rules.firstIndex(where: { $0.id == event.ruleID }) else { continue }
            rules[index].hits += 1
            rules[index].lastHit = Date(timeIntervalSince1970: TimeInterval(event.at))
            let rule = rules[index]
            db?.async { try $0.saveRule(rule) }
        }
        db?.async { [weak self] db in
            try db.recordRuleEvents(incoming)
            let events = (try? db.ruleEvents(limit: 300)) ?? []
            Task { @MainActor in
                self?.events = events
                self?.version += 1
            }
        }
        publish()
    }

    /// The feed for one rule, for its own page.
    func events(for rule: Rule) -> [RuleEventRecord] { events.filter { $0.ruleID == rule.id } }

    // MARK: Writing a rule from somewhere else

    /// "Block this", from a table row. The subject is whatever the row knew.
    static func block(app: String = "", destination: String = "", name: String = "",
                      schedule: Rule.Schedule = Rule.Schedule(), origin: Rule.Origin = .typed) -> Rule {
        Rule(enabled: true, action: .block, app: app, destination: cleaned(destination), schedule: schedule,
             origin: origin, name: name)
    }

    /// The way out of a refusal, which is the half that makes refusing usable at all. An exception is itself a
    /// rule with an expiry, so the list can always answer "why is this getting through?".
    static func allow(app: String = "", destination: String = "", forSeconds: TimeInterval? = nil,
                      once: Bool = false, origin: Rule.Origin = .alert) -> Rule {
        var rule = Rule(enabled: true, action: .allow, app: app, destination: cleaned(destination), origin: origin)
        if once { rule.maxHits = 1 }
        if let forSeconds { rule.schedule = .expiring(in: forSeconds) }
        return rule
    }

    static func cleaned(_ destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return AgentPolicy.normalize(trimmed) ?? trimmed.lowercased()
    }

    // MARK: Telling everyone else

    private func publish() {
        version += 1
        live.replace(rules, pausedUntil: pausedUntil)
        onChange(ruleSet)
    }

    var ruleSet: RuleSet {
        RuleSet(rules: rules.filter { $0.enabled && $0.isComplete && $0.engine == .flow },
                pausedUntil: pausedUntil, session: Self.session)
    }

    /// The rules the inspection proxy carries out: the ones that name a path or a method, which no filter can see.
    var requestRules: [Rule] { live.requestRules() }
}

/// The rule list as anything off the main actor sees it. Held behind a lock rather than an actor because the
/// proxy asks while it is framing a request, and a request that has to wait for an actor hop is a request that
/// arrives late.
final class LiveRules: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [Rule] = []
    private var pausedUntil: Date?

    func replace(_ rules: [Rule], pausedUntil: Date?) {
        lock.lock(); defer { lock.unlock() }
        self.rules = rules
        self.pausedUntil = pausedUntil
    }

    /// The rules that would answer a request right now. Timing is judged here, at the moment the request arrives,
    /// rather than when the list was last published — a window that closed a minute ago has closed.
    func requestRules(now: Date = Date()) -> [Rule] {
        lock.lock(); defer { lock.unlock() }
        if let pausedUntil, now < pausedUntil { return [] }
        return rules.filter {
            $0.enabled && $0.isComplete && $0.engine == .request && $0.isUsable
                && $0.schedule.isActive(at: now, session: RuleStore.session)
        }
    }
}
