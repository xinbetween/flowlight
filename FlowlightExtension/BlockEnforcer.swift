import Darwin
import Foundation

/// Holds the allowlists the app asked the filter to enforce, judges flows against them, and hands every refusal
/// back so it can be recorded where someone will see it.
///
/// **Where the agent identity comes from.** In the app, `AgentAttributor` decides which agent a flow belongs to by
/// walking up the process tree: `curl` or an MCP server started by Claude Code is Claude Code's traffic. The
/// extension has to reach the same answer without any of that machinery. The flow's own process comes from
/// `ProcessResolver` (audit token → bundle id, name, pid); its ancestors come from the kernel process table, which
/// the extension can read for any process because it runs as root. A policy is keyed by whatever bundle id the app
/// recorded for the agent — which for a command-line agent such as `claude` is its process name — so both are
/// matched. A miss means the flow is allowed and merely alerted on, which is the direction this errs in.
final class BlockEnforcer: @unchecked Sendable {
    static let shared = BlockEnforcer()

    private let lock = NSLock()
    /// Serializes the revision read/flow claim with publication mutation and reevaluation scanning. The lock is
    /// released before the expensive process/rule/pack decision work runs.
    private let revisionLock = NSLock()
    private var policies: [String: AgentPolicy] = [:]
    private var connectionState = EnforcementConnectionState()
    private var cache: [Int32: (agent: Agent?, at: Date)] = [:]
    /// The rule list, which is asked before any allowlist: a rule is something someone wrote down about this
    /// exact connection, and it should not be second-guessed by a policy written about a whole agent.
    private var ruleSet = RuleSet()
    /// One immutable, fully validated managed-pack generation. It is built away from the flow callback and swapped
    /// under the same short lock as rules; a transfer in progress never appears here.
    private var packMatcher: RulePackMatcher?
    private var packGeneration: UUID?
    private var packDigest = ""
    /// Every complete enforcement publication advances this value. The provider is notified after the mutation is
    /// unlocked so it can put terminally allowed sockets back into data filtering for one bounded callback.
    private var enforcementRevision: UInt64 = 1
    private var reevaluateExistingFlows: ((UInt64) -> Void)?
    /// How many decisions each rule has made this run, for the rules that stop after a set number ("allow once").
    /// The app is the one that persists them; this is only what is needed to stop applying a spent rule.
    private var ruleHits: [UUID: Int] = [:]

    private struct Agent { var key: String; var name: String }

    /// Called with every refusal. `IPCServer` sets this; without it nothing would be recorded and nothing would
    /// be blocked either, because enforcement needs the app connected.
    var report: (BlockEvent) -> Void = { _ in }

    /// Called with every connection a rule decided, refusal and relaxation alike.
    var reportDecision: (RuleEvent) -> Void = { _ in }
    /// Pack hits are aggregated by `IPCServer`; this callback is intentionally not the ordinary block-alert path.
    var reportPack: (RulePackEvent) -> Void = { _ in }

    /// Asked before anything else on the data path: with no enforcing policy the filter does no extra work at all.
    var isEnforcing: Bool {
        lock.lock(); defer { lock.unlock() }
        return !policies.isEmpty || !ruleSet.rules.isEmpty || packMatcher != nil
    }

    func setFlowReevaluationHandler(_ handler: ((UInt64) -> Void)?) {
        lock.lock()
        reevaluateExistingFlows = handler
        lock.unlock()
    }

    /// Called while the lock is held. The returned callback must run only after unlocking because it enters the
    /// provider and tracker, which are independently synchronized.
    private func advanceRevisionLocked() -> (revision: UInt64, callback: ((UInt64) -> Void)?) {
        enforcementRevision &+= 1
        return (enforcementRevision, reevaluateExistingFlows)
    }

    private func announce(_ publication: (revision: UInt64, callback: ((UInt64) -> Void)?)) {
        // The provider schedules the actual Network Extension updates off the IPC/data queue. Keeping this call
        // outside the state lock also preserves the short publication critical section.
        publication.callback?(publication.revision)
    }

    /// Replaces the enforcing set. The app sends this on connect and on every change, so it is always the whole
    /// list rather than a delta.
    func apply(_ list: [AgentPolicy]) -> Int {
        revisionLock.lock()
        lock.lock()
        policies = Dictionary(list.filter { $0.enabled && $0.enforce }.map { ($0.agentID, $0) }, uniquingKeysWith: { a, _ in a })
        cache.removeAll()   // a policy change can change which process counts as an agent
        let count = policies.count
        let publication = advanceRevisionLocked()
        lock.unlock()
        announce(publication)
        revisionLock.unlock()
        return count
    }

    /// Replaces the rule list. Like `apply(_:)` above this is always the whole list, and the hit counts the app
    /// sends with it replace what this run has counted — the app is where they survive a restart.
    func apply(_ set: RuleSet) -> Int {
        revisionLock.lock()
        lock.lock()
        ruleSet = set
        ruleHits = Dictionary(set.rules.map { rule in
            let published = rule.hits
            let runtime = ruleHits[rule.id] ?? published
            return (rule.id, set.resetHitCounts.contains(rule.id) ? published : max(published, runtime))
        }, uniquingKeysWith: { a, _ in a })
        let count = set.rules.filter(\.enabled).count
        let publication = advanceRevisionLocked()
        lock.unlock()
        announce(publication)
        revisionLock.unlock()
        return count
    }

    /// Atomically spends one bounded rule for a connection the local proxy is about to decide. Unbounded rules need
    /// no claim. Nil means the app and extension no longer share this rule generation and the proxy must fail open.
    func claimRule(_ claim: RuleClaim) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard ruleSet.accepts(claim),
              let rule = ruleSet.rules.first(where: { $0.id == claim.ruleID }),
              rule.maxHits > 0 else {
            return nil
        }
        let hits = ruleHits[claim.ruleID] ?? rule.hits
        guard hits < rule.maxHits else { return false }
        ruleHits[claim.ruleID] = hits + 1
        return true
    }

    func apply(_ snapshot: RulePackSnapshot) throws -> RulePackApplyResult {
        let matcher = try RulePackMatcher(snapshot: snapshot)
        revisionLock.lock()
        lock.lock()
        packMatcher = matcher
        packGeneration = snapshot.generation
        packDigest = snapshot.digest
        let publication = advanceRevisionLocked()
        lock.unlock()
        announce(publication)
        revisionLock.unlock()
        return RulePackApplyResult(status: .committed, generation: snapshot.generation,
                                   activeDigest: snapshot.digest, activePacks: snapshot.configurations.filter(\.enabled).count)
    }

    func clearPacks() -> RulePackApplyResult {
        revisionLock.lock()
        lock.lock()
        packMatcher = nil
        packGeneration = nil
        packDigest = ""
        let publication = advanceRevisionLocked()
        lock.unlock()
        announce(publication)
        revisionLock.unlock()
        return RulePackApplyResult(status: .cleared)
    }

    func packHandshake() -> RulePackHandshake {
        lock.lock(); defer { lock.unlock() }
        return RulePackHandshake(protocolVersion: RulePackSnapshot.protocolVersion,
                                 activeGeneration: packGeneration, activeDigest: packDigest)
    }

    func appConnectionChanged(connected: Bool, now: Date = Date()) {
        revisionLock.lock()
        lock.lock()
        guard EnforcementRevisionGate.shouldAdvanceConnection(
            from: connectionState.connected,
            to: connected
        ) else {
            lock.unlock()
            revisionLock.unlock()
            return
        }
        connectionState.update(connected: connected, now: now)
        let publication = advanceRevisionLocked()
        lock.unlock()
        announce(publication)
        revisionLock.unlock()
    }

    private func inForce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connectionState.isInForce()
    }

    private func beginDecision(for state: FlowState) -> UInt64? {
        revisionLock.lock()
        lock.lock()
        let enforcing = !policies.isEmpty || !ruleSet.rules.isEmpty || packMatcher != nil
        let revision = enforcementRevision
        let claimed = enforcing && state.beginEvaluation(for: revision)
        lock.unlock()
        revisionLock.unlock()
        return claimed ? revision : nil
    }

    /// The filter's one question. True means refuse this flow — by then the refusal has already been reported.
    /// Each flow is judged at most once per enforcement publication. A terminal allow can be re-armed for one real
    /// callback after publication, while ordinary packet callbacks avoid re-walking the kernel process table.
    func refuses(_ state: FlowState) -> Bool {
        guard let revision = beginDecision(for: state) else { return false }
        var terminalDecision: FlowTerminalDecision?
        defer { state.finishEvaluation(for: revision, decision: terminalDecision) }
        let agent = agent(for: state.process)
        let facts = FlowFacts(agentKey: agent?.key ?? state.process.bundleID, bundleID: state.process.bundleID,
                              host: state.domain, ip: state.remoteIP, port: state.remotePort,
                              hostSettled: state.inspectionDone)

        // The rules first. They name this connection rather than a whole agent, and an exception written here is
        // the only way out of an allowlist, so it has to be able to win.
        let ruled = ruleDecision(facts, process: state.process, agent: agent)
        switch ruled.verdict {
        case .undecided:
            return false
        case .block:
            terminalDecision = .blocked
            return true
        case .allow where ruled.rule != nil:
            // An exception someone wrote, which is the only thing that outranks an allowlist. An allow with no
            // rule behind it is merely the absence of one, and says nothing about the policy below.
            terminalDecision = .allowed
            return false
        case .allow:
            break
        }

        // A managed pack can only decide from a hostname. The first flow callback often arrives before TLS SNI or
        // HTTP Host, so keep the flow unjudged until inspection either names it or reaches its bounded end. Without
        // this, a flow with no matching AgentPolicy would be permanently waved through on its first callback.
        if packNeedsHostname(facts) { return false }

        if let match = packDecision(facts, process: state.process, agent: agent) {
            terminalDecision = .blocked
            let now = Int64(Date().timeIntervalSince1970)
            reportPack(.refusal(match: match, at: now, bundleID: facts.bundleID,
                                appName: state.process.name, agentKey: facts.agentKey,
                                agentName: agent?.name ?? state.process.name, port: facts.port))
            extensionLog.info("Pack \(match.packID, privacy: .public) refused \(match.entry.host, privacy: .public)")
            return true
        }

        guard let agent, let policy = policy(for: agent.key) else {
            terminalDecision = .allowed
            return false
        }
        switch BlockRules.verdict(for: facts, policy: policy, inForce: inForce()) {
        case .undecided:
            return false
        case .allow:
            terminalDecision = .allowed
            return false
        case .block:
            terminalDecision = .blocked
            let event = BlockEvent(at: Int64(Date().timeIntervalSince1970), agentKey: agent.key, agentName: agent.name,
                                   appName: state.process.name, bundleID: facts.bundleID,
                                   host: facts.host, ip: facts.ip, port: facts.port)
            extensionLog.info("Refused a connection for \(agent.key, privacy: .public)")
            report(event)
            return true
        }
    }

    /// What the rules say, with the refusal or the relaxation already reported. Nothing is refused while the app
    /// is away, for the same reason an allowlist isn't: a refusal nobody can see, and nobody can undo, is worse
    /// than the connection it stopped.
    private func ruleDecision(_ facts: FlowFacts, process: ProcessInfoRecord, agent: Agent?) -> RuleDecision {
        // The pause stands everything down, allowlists included: it is the one global escape hatch, and an escape
        // hatch that only half works is worse than none. `.undecided` rather than `.allow`, so the flow is judged
        // again when the pause ends rather than being waved through for its whole life.
        guard inForce() else { return RuleDecision(verdict: .allow, rule: nil) }
        if BlockRules.isExempt(facts) { return RuleDecision(verdict: .allow, rule: nil) }
        lock.lock()
        let set = ruleSet
        if let until = set.pausedUntil, Date() < until {
            lock.unlock()
            return RuleDecision(verdict: .undecided, rule: nil)
        }
        guard !set.rules.isEmpty else {
            lock.unlock()
            return RuleDecision(verdict: .allow, rule: nil)
        }
        let rules = set.rules.map { rule -> Rule in
            var copy = rule
            copy.hits = ruleHits[rule.id] ?? rule.hits
            return copy
        }
        let decision = RuleBook.decide(facts, rules: rules, session: set.session, pausedUntil: set.pausedUntil)
        guard let rule = decision.rule else {
            lock.unlock()
            return decision
        }
        ruleHits[rule.id] = (ruleHits[rule.id] ?? 0) + 1
        lock.unlock()
        let event = RuleEvent(at: Int64(Date().timeIntervalSince1970), ruleID: rule.id,
                              ruleSession: set.session, ruleGeneration: set.generation, action: rule.action,
                              engine: .flow, agentKey: facts.agentKey, agentName: agent?.name ?? process.name,
                              appName: process.name, bundleID: process.bundleID, host: facts.host, ip: facts.ip,
                              port: facts.port)
        extensionLog.info("Rule \(rule.action.rawValue, privacy: .public) for \(process.name, privacy: .public)")
        reportDecision(event)
        if rule.action == .block {
            report(BlockEvent(at: event.at, agentKey: facts.agentKey, agentName: agent?.name ?? process.name,
                              appName: process.name, bundleID: facts.bundleID,
                              host: facts.host, ip: facts.ip, port: facts.port,
                              rule: rule.title))
        }
        return decision
    }

    private func packNeedsHostname(_ facts: FlowFacts) -> Bool {
        guard !facts.hostSettled, facts.host.isEmpty, inForce(), !BlockRules.isExempt(facts) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard ruleSet.pausedUntil.map({ Date() >= $0 }) ?? true else { return false }
        return packMatcher != nil
    }

    private func packDecision(_ facts: FlowFacts, process: ProcessInfoRecord, agent: Agent?) -> RulePackMatch? {
        guard inForce(), !facts.host.isEmpty, !BlockRules.isExempt(facts) else { return nil }
        lock.lock()
        let matcher = packMatcher
        let pausedUntil = ruleSet.pausedUntil
        lock.unlock()
        guard pausedUntil.map({ Date() >= $0 }) ?? true else { return nil }
        return matcher?.matches(host: facts.host, bundleID: process.bundleID).first
    }

    private func policy(for key: String) -> AgentPolicy? {
        lock.lock(); defer { lock.unlock() }
        return AgentPolicy.resolve(policies.values, identities: [key])
    }

    // MARK: Agent identity

    /// The agent a process works for: itself, or the nearest ancestor an enforcing policy names.
    private func agent(for process: ProcessInfoRecord, maxDepth: Int = 16) -> Agent? {
        // Cached per pid, and briefly: pids are reused, and an agent's children are short-lived by nature.
        lock.lock()
        if let hit = cache[process.pid], Date().timeIntervalSince(hit.at) < 30 { lock.unlock(); return hit.agent }
        lock.unlock()

        var identity = (bundleID: process.bundleID, name: process.name)
        var pid = process.pid
        var found: Agent?
        for _ in 0..<maxDepth {
            if let policy = match(identity) {
                found = Agent(key: policy.agentID, name: identity.name)
                break
            }
            guard pid > 1, let parent = Self.parent(of: pid), parent > 1, parent != pid,
                  let next = Self.identity(of: parent) else { break }
            pid = parent
            identity = next
        }
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        cache[process.pid] = (found, Date())
        lock.unlock()
        return found
    }

    private func match(_ identity: (bundleID: String, name: String)) -> AgentPolicy? {
        lock.lock(); defer { lock.unlock() }
        return AgentPolicy.resolve(policies.values, identities: [identity.bundleID, identity.name])
    }

    #if APP_STORE
    /// Agent lineage exported for one exact Store proxy leg. Enforcing custom/discovered policies are authoritative;
    /// the built-in catalog remains the fallback when no policy names the process or one of its ancestors.
    func inspectionAgentContext(
        for process: ProcessInfoRecord,
        maxDepth: Int = 16
    ) -> (bundleID: String, name: String)? {
        guard maxDepth > 0 else { return nil }
        var lineage = [InspectionAgentLineageIdentity(
            bundleID: process.bundleID,
            name: process.name
        )]
        var pid = process.pid
        for _ in 1..<maxDepth {
            guard pid > 1, let parent = Self.parent(of: pid), parent > 1, parent != pid,
                  let next = Self.identity(of: parent) else { break }
            pid = parent
            lineage.append(InspectionAgentLineageIdentity(
                bundleID: next.bundleID,
                name: next.name
            ))
        }
        lock.lock()
        let appliedPolicies = Array(policies.values)
        lock.unlock()
        guard let context = InspectionAgentContextResolver.resolve(
            lineage: lineage,
            policies: appliedPolicies
        ) else { return nil }
        return (context.bundleID, context.name)
    }
    #endif

    /// Parent pid from the kernel process table.
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// An ancestor has no audit token to go on, so its identity comes from its executable path — the same fallback
    /// `ProcessResolver` uses when code signing can't name a process.
    static func identity(of pid: Int32) -> (bundleID: String, name: String)? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return ProcessResolver.bundleInfo(path: path, fallbackIdentifier: nil, pid: pid)
    }
}
