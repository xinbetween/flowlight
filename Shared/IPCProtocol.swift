import Foundation

/// Exported by the system extension on its Mach service.
@objc protocol FlowlightProviderXPC {
    /// Called by the host app after connecting; the extension starts pushing batches.
    func register(withReply reply: @escaping (Bool, String) -> Void)

    /// Whether macOS has actually started this filter — that is, whether `startFilter` ran and its settings
    /// applied. Connecting to the extension only proves the process is alive: macOS runs one content filter at a
    /// time, and when another product holds that slot ours is launched and then never asked to filter anything.
    func filterState(withReply reply: @escaping (Bool, String) -> Void)
}

/// Exported by the host app on the same connection.
@objc protocol FlowlightAppXPC {
    /// `payload` is `TrafficCoding.encode([TrafficBatch])`. The app calls `reply` once the batches
    /// are accepted; the extension keeps them queued until then.
    func deliver(payload: Data, reply: @escaping () -> Void)
}
