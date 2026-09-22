import Foundation

/// Exported by the system extension on its Mach service.
@objc protocol FlowlightProviderXPC {
    /// Called by the host app after connecting; the extension starts pushing batches.
    func register(withReply reply: @escaping (Bool, String) -> Void)
}

/// Exported by the host app on the same connection.
@objc protocol FlowlightAppXPC {
    /// `payload` is `TrafficCoding.encode([TrafficBatch])`. The app calls `reply` once the batches
    /// are accepted; the extension keeps them queued until then.
    func deliver(payload: Data, reply: @escaping () -> Void)
}
