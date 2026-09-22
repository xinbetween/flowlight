import Foundation

/// A producer of per-second `TrafficBatch`es.
protocol TrafficSource: AnyObject {
    var displayName: String { get }
    /// `sink` may be called on any queue.
    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void)
    func stop()
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
