import Foundation

/// A producer of per-second `TrafficBatch`es.
protocol TrafficSource: AnyObject {
    var displayName: String { get }
    /// `sink` may be called on any queue.
    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void)
    func stop()
    /// Allowlists this source should refuse connections against. Only the Network Extension sits in the data path,
    /// so every other source ignores them — which is why the UI says so rather than offering a dead switch.
    func setEnforcement(_ policies: [AgentPolicy])
    /// The rule list this source should carry out. Same story as `setEnforcement`: only the Network Extension is
    /// in the data path, and the Rules screen says so per rule rather than pretending.
    func setRules(_ rules: RuleSet)
    /// Atomically spends one bounded flow rule. Nil means this source cannot authoritatively claim it.
    func claimRule(_ claim: RuleClaim, completion: @escaping @Sendable (Bool?) -> Void)
    /// One complete managed-pack generation. Nil clears packs. Other capture sources ignore it and the UI reports
    /// watching-only instead of claiming that the setting is enforced.
    func setRulePacks(_ snapshot: RulePackSnapshot?)
}

extension TrafficSource {
    func setEnforcement(_ policies: [AgentPolicy]) {}
    func setRules(_ rules: RuleSet) {}
    func claimRule(_ claim: RuleClaim, completion: @escaping @Sendable (Bool?) -> Void) { completion(nil) }
    func setRulePacks(_ snapshot: RulePackSnapshot?) {}
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case networkExtension, nettop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .networkExtension: return L("Network Extension (content filter)")
        case .nettop: return L("nettop sampler (no extension required)")
        }
    }
}
