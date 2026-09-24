import Foundation

/// Exported by the system extension on its Mach service.
@objc protocol FlowlightProviderXPC {
    /// Called by the host app after connecting; the extension starts pushing batches.
    func register(withReply reply: @escaping (Bool, String) -> Void)

    /// Whether macOS has actually started this filter — that is, whether `startFilter` ran and its settings
    /// applied. Connecting to the extension only proves the process is alive: macOS runs one content filter at a
    /// time, and when another product holds that slot ours is launched and then never asked to filter anything.
    func filterState(withReply reply: @escaping (Bool, String) -> Void)

    /// Replaces the allowlists the filter enforces. `payload` is `BlockCoding.encode([AgentPolicy])`, holding only
    /// the policies the user has switched to blocking; an empty list turns enforcement off entirely. The app sends
    /// this on every connection and on every change, so the extension never has to read the database itself.
    func setEnforcement(payload: Data, withReply reply: @escaping (Int) -> Void)

    /// Replaces the rule list the filter carries out. `payload` is `BlockCoding.encode(RuleSet)`; an empty payload
    /// means no rules at all. Like `setEnforcement` this is sent whole on every connection and every change, and
    /// like it the extension keeps none of it across a launch: a rule nobody is left to record is not enforced.
    func setRules(payload: Data, withReply reply: @escaping (Int) -> Void)
}

/// Exported by the host app on the same connection.
@objc protocol FlowlightAppXPC {
    /// `payload` is `TrafficCoding.encode([TrafficBatch])`. The app calls `reply` once the batches
    /// are accepted; the extension keeps them queued until then.
    func deliver(payload: Data, reply: @escaping () -> Void)

    /// Connections the filter refused. `payload` is `BlockCoding.encode([BlockEvent])`. These come up on their own
    /// call rather than riding with the traffic batches: they are rare, and they must not wait behind a backlog.
    func blocked(payload: Data, reply: @escaping () -> Void)

    /// Connections a rule decided, refusals and relaxations alike. `payload` is `BlockCoding.encode([RuleEvent])`.
    /// Both halves come back: a refusal has to be visible, and so does an exception that let something through,
    /// because "why is this getting through?" is the question a rule list exists to answer.
    func ruleDecisions(payload: Data, reply: @escaping () -> Void)
}
