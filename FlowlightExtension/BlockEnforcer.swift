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
    private var policies: [String: AgentPolicy] = [:]
    private var appConnected = false
    private var disconnectedAt: Date?
    private var cache: [Int32: (agent: Agent?, at: Date)] = [:]
    /// The rule list, which is asked before any allowlist: a rule is something someone wrote down about this
    /// exact connection, and it should not be second-guessed by a policy written about a whole agent.
    private var ruleSet = RuleSet()
    /// How many decisions each rule has made this run, for the rules that stop after a set number ("allow once").
    /// The app is the one that persists them; this is only what is needed to stop applying a spent rule.
    private var ruleHits: [UUID: Int] = [:]

    private struct Agent { var key: String; var name: String }

    /// Called with every refusal. `IPCServer` sets this; without it nothing would be recorded and nothing would
    /// be blocked either, because enforcement needs the app connected.
    var report: (BlockEvent) -> Void = { _ in }

    /// Called with every connection a rule decided, refusal and relaxation alike.
    var reportDecision: (RuleEvent) -> Void = { _ in }

    /// Asked before anything else on the data path: with no enforcing policy the filter does no extra work at all.
    var isEnforcing: Bool {
        lock.lock(); defer { lock.unlock() }
        return !policies.isEmpty || !ruleSet.rules.isEmpty
    }

    /// Replaces the enforcing set. The app sends this on connect and on every change, so it is always the whole
    /// list rather than a delta.
    func apply(_ list: [AgentPolicy]) -> Int {
        lock.lock(); defer { lock.unlock() }
        policies = Dictionary(list.filter { $0.enabled && $0.enforce }.map { ($0.agentID, $0) }, uniquingKeysWith: { a, _ in a })
        cache.removeAll()   // a policy change can change which process counts as an agent
        return policies.count
    }

    /// Replaces the rule list. Like `apply(_:)` above this is always the whole list, and the hit counts the app
    /// sends with it replace what this run has counted — the app is where they survive a restart.
    func apply(_ set: RuleSet) -> Int {
        lock.lock(); defer { lock.unlock() }
        ruleSet = set
        ruleHits = Dictionary(set.rules.map { ($0.id, $0.hits) }, uniquingKeysWith: { a, _ in a })
        return set.rules.filter(\.enabled).count
    }

    func appConnectionChanged(connected: Bool) {
        lock.lock(); defer { lock.unlock() }
        appConnected = connected
        if !connected { disconnectedAt = Date() }
    }

    private func inForce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return BlockRules.inForce(appConnected: appConnected,
                                  sinceDisconnect: disconnectedAt.map { Date().timeIntervalSince($0) })
    }

    /// The filter's one question. True means refuse this flow — by then the refusal has already been reported.
    /// Each flow is judged once: the answer can't change while it is open, and re-walking the process tree for
    /// every packet would put the kernel process table on the data path.
    func refuses(_ state: FlowState) -> Bool {
        guard isEnforcing, !state.judged else { return false }
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
            state.judged = true
            return true
        case .allow where ruled.rule != nil:
            // An exception someone wrote, which is the only thing that outranks an allowlist. An allow with no
            // rule behind it is merely the absence of one, and says nothing about the policy below.
            state.judged = true
            return false
        case .allow:
            break
        }

        guard let agent, let policy = policy(for: agent.key) else {
            state.judged = true
            return false
        }
        switch BlockRules.verdict(for: facts, policy: policy, inForce: inForce()) {
        case .undecided:
            return false
        case .allow:
            state.judged = true
            return false
        case .block:
            state.judged = true
            let event = BlockEvent(at: Int64(Date().timeIntervalSince1970), agentKey: agent.key, agentName: agent.name,
                                   appName: state.process.name, host: facts.host, ip: facts.ip, port: facts.port)
            extensionLog.info("Refused a connection for \(agent.key, privacy: .public)")
            report(event)
            return true
        }
    }

    /// What the rules say, with the refusal or the relaxation already reported. Nothing is refused while the app
    /// is away, for the same reason an allowlist isn't: a refusal nobody can see, and nobody can undo, is worse
    /// than the connection it stopped.
    private func ruleDecision(_ facts: FlowFacts, process: ProcessInfoRecord, agent: Agent?) -> RuleDecision {
        lock.lock()
        let set = ruleSet
        let hits = ruleHits
        lock.unlock()
        // The pause stands everything down, allowlists included: it is the one global escape hatch, and an escape
        // hatch that only half works is worse than none. `.undecided` rather than `.allow`, so the flow is judged
        // again when the pause ends rather than being waved through for its whole life.
        if let until = set.pausedUntil, Date() < until { return RuleDecision(verdict: .undecided, rule: nil) }
        guard !set.rules.isEmpty, inForce() else { return RuleDecision(verdict: .allow, rule: nil) }
        if BlockRules.isExempt(facts) { return RuleDecision(verdict: .allow, rule: nil) }
        let rules = set.rules.map { rule -> Rule in
            var copy = rule
            copy.hits = hits[rule.id] ?? rule.hits
            return copy
        }
        let decision = RuleBook.decide(facts, rules: rules, session: set.session, pausedUntil: set.pausedUntil)
        guard let rule = decision.rule else { return decision }
        lock.lock(); ruleHits[rule.id] = (ruleHits[rule.id] ?? 0) + 1; lock.unlock()
        let event = RuleEvent(at: Int64(Date().timeIntervalSince1970), ruleID: rule.id, action: rule.action,
                              engine: .flow, agentKey: facts.agentKey, agentName: agent?.name ?? process.name,
                              appName: process.name, bundleID: process.bundleID, host: facts.host, ip: facts.ip,
                              port: facts.port)
        extensionLog.info("Rule \(rule.action.rawValue, privacy: .public) for \(process.name, privacy: .public)")
        reportDecision(event)
        if rule.action == .block {
            report(BlockEvent(at: event.at, agentKey: facts.agentKey, agentName: agent?.name ?? process.name,
                              appName: process.name, host: facts.host, ip: facts.ip, port: facts.port,
                              rule: rule.title))
        }
        return decision
    }

    private func policy(for key: String) -> AgentPolicy? {
        lock.lock(); defer { lock.unlock() }
        return policies[key]
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
        if let hit = policies[identity.bundleID] { return hit }
        if let hit = policies[identity.name] { return hit }
        let name = identity.name.lowercased()
        return policies.values.first { $0.agentID.lowercased() == name }
    }

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
