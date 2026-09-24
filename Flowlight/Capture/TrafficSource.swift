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
}

extension TrafficSource {
    func setEnforcement(_ policies: [AgentPolicy]) {}
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case networkExtension, nettop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .networkExtension: return "Network Extension (content filter)"
        case .nettop: return "nettop sampler (no extension required)"
        }
    }
}
