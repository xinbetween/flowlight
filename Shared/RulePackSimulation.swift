import Foundation

/// Replays retained traffic through the full user-rule/managed-pack ordering before a pack is enabled or broadened.
/// Like `RuleSimulation`, it reports a delta: list membership alone is not a claim that traffic would change.
enum RulePackSimulation {
    static func run(candidate: RulePackConfiguration, definitions: [RulePackDefinition],
                    configurations: [RulePackConfiguration], overrides: [RulePackOverride],
                    rules: [Rule], policies: [String: AgentPolicy] = [:], paused: Bool = false,
                    flows: [RuleSimulation.Flow], session: String = "") -> RuleSimulation.Result {
        let before = matcher(definitions: definitions, configurations: configurations, overrides: overrides)
        var enabled = candidate
        enabled.enabled = true
        let afterConfigurations = configurations.filter { $0.packID != candidate.packID } + [enabled]
        let after = matcher(definitions: definitions, configurations: afterConfigurations, overrides: overrides)

        var result = RuleSimulation.Result()
        var merged: [String: RuleSimulation.Change] = [:]
        for flow in flows {
            result.flowsConsidered += 1
            result.connectionsConsidered += flow.connections
            result.earliest = min(result.earliest ?? flow.when, flow.when)
            let wasBlocked = blocked(flow, matcher: before, rules: rules, policies: policies,
                                     paused: paused, session: session)
            let willBlock = blocked(flow, matcher: after, rules: rules, policies: policies,
                                    paused: paused, session: session)
            guard wasBlocked != willBlock else { continue }

            let key = "\(flow.bundleID)|\(flow.host)|\(flow.ip)|\(flow.port)|\(willBlock)"
            if var seen = merged[key] {
                seen.bytes += flow.bytes
                seen.connections += flow.connections
                seen.lastSeen = max(seen.lastSeen, flow.when)
                merged[key] = seen
            } else {
                merged[key] = RuleSimulation.Change(appName: flow.appName, bundleID: flow.bundleID,
                                                    host: flow.host, ip: flow.ip, port: flow.port,
                                                    bytes: flow.bytes, connections: flow.connections,
                                                    lastSeen: flow.when, refused: willBlock)
            }
        }
        result.changes = merged.values.sorted {
            $0.connections == $1.connections ? $0.bytes > $1.bytes : $0.connections > $1.connections
        }
        return result
    }

    private static func blocked(_ flow: RuleSimulation.Flow, matcher: RulePackMatcher?, rules: [Rule],
                                policies: [String: AgentPolicy], paused: Bool, session: String) -> Bool {
        guard !paused, !BlockRules.isExempt(flow.facts) else { return false }
        let user = RuleBook.decide(flow.facts, rules: rules, now: flow.when, session: session)
        if user.rule != nil { return user.verdict == .block }
        if matcher?.matches(host: flow.host, bundleID: flow.bundleID).isEmpty == false { return true }
        guard let policy = policies[flow.agentKey] ?? policies[flow.bundleID] else { return false }
        return BlockRules.verdict(for: flow.facts, policy: policy) == .block
    }

    private static func matcher(definitions: [RulePackDefinition], configurations: [RulePackConfiguration],
                                overrides: [RulePackOverride]) -> RulePackMatcher? {
        let active = configurations.filter(\.enabled)
        guard !active.isEmpty else { return nil }
        let ids = Set(active.map(\.packID))
        let snapshot = RulePackSnapshot.make(definitions: definitions.filter { ids.contains($0.id) },
                                             configurations: active,
                                             overrides: overrides.filter { ids.contains($0.packID) })
        return try? RulePackMatcher(snapshot: snapshot)
    }
}
