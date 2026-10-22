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
    private var pendingHitResets: Set<UUID> = []
    private var pendingRuleInvalidations: Set<UUID> = []
    /// The first whole-list generation that describes each rule's current definition. Delayed decisions from an
    /// older definition are ignored, while an unrelated rule edit does not erase a valid spend.
    private var ruleInvalidatedAt: [UUID: UInt64] = [:]
    private var publicationGeneration: UInt64 = 0
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
        pendingRuleInvalidations.insert(rule.id)
        db?.async { try $0.saveRule(rule) }
        publish()
    }

    func delete(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        pendingRuleInvalidations.insert(rule.id)
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
        pendingHitResets.insert(found.id)
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
        var accepted: [RuleEvent] = []
        for event in incoming {
            if let eventSession = event.ruleSession,
               let eventGeneration = event.ruleGeneration,
               !acceptsDecision(
                   ruleID: event.ruleID,
                   session: eventSession,
                   generation: eventGeneration
               ) {
                continue
            }
            accepted.append(event)
            guard let index = rules.firstIndex(where: { $0.id == event.ruleID }) else { continue }
            rules[index].hits = rules[index].maxHits > 0
                ? min(rules[index].maxHits, rules[index].hits + 1)
                : rules[index].hits + 1
            rules[index].lastHit = Date(timeIntervalSince1970: TimeInterval(event.at))
            let rule = rules[index]
            db?.async { try $0.saveRule(rule) }
        }
        guard !accepted.isEmpty else { return }
        db?.async { [weak self] db in
            try db.recordRuleEvents(accepted)
            let events = (try? db.ruleEvents(limit: 300)) ?? []
            Task { @MainActor in
                self?.events = events
                self?.version += 1
            }
        }
        publish(advancingGeneration: false)
    }

    /// Clears the published feed after its durable rows were deleted by the caller.
    func clearPublishedEventsAfterDurableDeletion() {
        events = []
        version += 1
    }

    /// Persists an accepted bounded proxy claim and its visible explanation before the proxy acts on the decision.
    /// The extension already spent the claim; a failed write therefore fails this connection open and leaves the local
    /// mirror spent so neither side can quietly reuse it during this process.
    func recordBoundedClaim(
        _ claim: RuleClaim,
        event: RuleEvent,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard event.ruleID == claim.ruleID,
              event.ruleSession == claim.session,
              event.ruleGeneration == claim.generation,
              acceptsDecision(ruleID: claim.ruleID, session: claim.session, generation: claim.generation),
              let index = rules.firstIndex(where: { $0.id == claim.ruleID }),
              rules[index].maxHits > 0 else {
            completion(false)
            return
        }
        rules[index].hits = min(rules[index].maxHits, rules[index].hits + 1)
        rules[index].lastHit = Date(timeIntervalSince1970: TimeInterval(event.at))
        let rule = rules[index]
        live.markBoundedRuleClaimed(claim, at: rules[index].lastHit ?? Date())
        publish(advancingGeneration: false)
        guard let db else {
            completion(false)
            return
        }
        db.queue.async { [weak self, weak db] in
            guard let db else {
                completion(false)
                return
            }
            do {
                try db.recordBoundedRuleDecision(rule: rule, event: event)
                let events = (try? db.ruleEvents(limit: 300)) ?? []
                completion(true)
                Task { @MainActor in
                    self?.events = events
                    self?.version += 1
                }
            } catch {
                completion(false)
            }
        }
    }

    /// Conservatively retires a bounded claim whose XPC reply was lost. The extension may already have accepted it;
    /// saving the spent count before authorization completes prevents reconnect or relaunch from reusing it.
    func retireBoundedClaim(
        _ claim: RuleClaim,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard acceptsDecision(
                  ruleID: claim.ruleID,
                  session: claim.session,
                  generation: claim.generation
              ),
              let index = rules.firstIndex(where: { $0.id == claim.ruleID }),
              rules[index].maxHits > 0 else {
            completion(false)
            return
        }
        rules[index].hits = max(rules[index].hits, rules[index].maxHits)
        rules[index].lastHit = Date()
        let rule = rules[index]
        live.markBoundedRuleSpent(claim)
        publish(advancingGeneration: false)
        guard let db else {
            completion(false)
            return
        }
        db.queue.async { [weak db] in
            guard let db else {
                completion(false)
                return
            }
            do {
                try db.saveRule(rule)
                completion(true)
            } catch {
                completion(false)
            }
        }
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

    private func acceptsDecision(
        ruleID: UUID,
        session: String,
        generation: UInt64
    ) -> Bool {
        session == Self.session &&
            generation <= publicationGeneration &&
            generation >= (ruleInvalidatedAt[ruleID] ?? 0)
    }

    private func publish(advancingGeneration: Bool = true) {
        version += 1
        if advancingGeneration {
            publicationGeneration &+= 1
            for ruleID in pendingRuleInvalidations {
                ruleInvalidatedAt[ruleID] = publicationGeneration
            }
        }
        live.replace(
            rules,
            pausedUntil: pausedUntil,
            generation: publicationGeneration,
            resetHitCounts: pendingHitResets,
            ruleInvalidatedAt: ruleInvalidatedAt
        )
        onChange(ruleSet)
        pendingHitResets.removeAll()
        pendingRuleInvalidations.removeAll()
    }

    var ruleSet: RuleSet {
        RuleSet(rules: rules.filter { $0.enabled && $0.isComplete && $0.engine == .flow },
                generation: publicationGeneration, pausedUntil: pausedUntil, session: Self.session,
                resetHitCounts: pendingHitResets, ruleInvalidatedAt: ruleInvalidatedAt)
    }

    /// The rules the inspection proxy carries out: the ones that name a path or a method, which no filter can see.
    var requestRules: [Rule] { live.requestRules() }
}

/// The rule list as anything off the main actor sees it. Held behind a lock rather than an actor because the
/// proxy asks while it is framing a request, and a request that has to wait for an actor hop is a request that
/// arrives late.
struct LiveFlowRuleDecision: Sendable {
    var paused: Bool
    var decision: RuleDecision
    var externalClaim: RuleClaim?
}

final class LiveRuleClaimAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private weak var source: ExtensionTrafficSource?

    func replace(_ source: ExtensionTrafficSource?) {
        lock.lock(); defer { lock.unlock() }
        self.source = source
    }

    func claim(_ claim: RuleClaim, completion: @escaping @Sendable (Bool?) -> Void) {
        lock.lock()
        let source = source
        lock.unlock()
        source?.claimRule(claim, completion: completion) ?? completion(nil)
    }
}

final class LiveRules: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [Rule] = []
    private var pausedUntil: Date?
    private var generation: UInt64 = 0
    private var ruleInvalidatedAt: [UUID: UInt64] = [:]
    private var usesExternalClaimAuthority = false

    /// Atomically hands finite-rule counting to the extension and returns the exact whole-list publication it should
    /// install. Any local claim completed before this lock is reflected in the transferred hit count; every decision
    /// after it carries a generation-bound external claim instead of spending independently.
    func beginExternalClaimAuthority(with set: RuleSet) -> RuleSet {
        lock.lock(); defer { lock.unlock() }
        usesExternalClaimAuthority = true
        var synchronized = set
        synchronized.rules = set.rules.map { published in
            guard let runtime = rules.first(where: { $0.id == published.id }),
                  runtime.hits > published.hits else { return published }
            var merged = published
            merged.hits = runtime.hits
            merged.lastHit = runtime.lastHit
            return merged
        }
        return synchronized
    }

    func replace(
        _ rules: [Rule],
        pausedUntil: Date?,
        generation: UInt64 = 0,
        resetHitCounts: Set<UUID> = [],
        ruleInvalidatedAt: [UUID: UInt64] = [:]
    ) {
        lock.lock(); defer { lock.unlock() }
        self.rules = rules.map { published in
            guard !resetHitCounts.contains(published.id),
                  let runtime = self.rules.first(where: { $0.id == published.id }),
                  runtime.hits > published.hits else {
                return published
            }
            var merged = published
            merged.hits = runtime.hits
            merged.lastHit = runtime.lastHit
            return merged
        }
        self.pausedUntil = pausedUntil
        self.generation = generation
        self.ruleInvalidatedAt.merge(ruleInvalidatedAt, uniquingKeysWith: max)
        for ruleID in resetHitCounts {
            self.ruleInvalidatedAt[ruleID] = generation
        }
    }

    /// The flow-level answer for an already named proxied connection. Pause and rules are read under one lock so a
    /// connection cannot combine the pause from one publication with the rule list from another. Bounded rules can
    /// be previewed without spending them while the extension atomically claims the decision for both data paths.
    func flowDecision(
        _ facts: FlowFacts,
        now: Date = Date()
    ) -> LiveFlowRuleDecision {
        lock.lock(); defer { lock.unlock() }
        let consumeBounded = !usesExternalClaimAuthority
        let paused = pausedUntil.map { now < $0 } ?? false
        let decision = RuleBook.decide(facts, rules: rules, now: now, session: RuleStore.session,
                                       pausedUntil: pausedUntil)
        if let rule = decision.rule,
           (rule.maxHits == 0 || consumeBounded),
           let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index].hits += 1
            rules[index].lastHit = now
        }
        return LiveFlowRuleDecision(
            paused: paused,
            decision: decision,
            externalClaim: decision.rule.flatMap { rule in
                rule.maxHits > 0 && !consumeBounded
                    ? RuleClaim(ruleID: rule.id, session: RuleStore.session, generation: generation)
                    : nil
            }
        )
    }

    private func acceptsDecision(_ claim: RuleClaim) -> Bool {
        claim.session == RuleStore.session &&
            claim.generation <= generation &&
            claim.generation >= (ruleInvalidatedAt[claim.ruleID] ?? 0)
    }

    func markBoundedRuleClaimed(_ claim: RuleClaim, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard acceptsDecision(claim),
              let index = rules.firstIndex(where: { $0.id == claim.ruleID }),
              rules[index].maxHits > 0 else { return }
        rules[index].hits = min(rules[index].maxHits, rules[index].hits + 1)
        rules[index].lastHit = now
    }

    func markBoundedRuleSpent(_ claim: RuleClaim) {
        lock.lock(); defer { lock.unlock() }
        guard acceptsDecision(claim),
              let index = rules.firstIndex(where: { $0.id == claim.ruleID }),
              rules[index].maxHits > 0 else { return }
        rules[index].hits = max(rules[index].hits, rules[index].maxHits)
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
