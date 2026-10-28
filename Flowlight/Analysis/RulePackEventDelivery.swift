import Foundation

/// Receives app-originated managed-pack events with the same durable watermark contract as extension events.
/// Every refusal has its own deadline: a stalled write cannot make unrelated connections wait behind it. A retry
/// reuses its session and sequence so an uncertain acknowledgement cannot count a refusal twice.
final class RulePackEventDelivery: @unchecked Sendable {
    typealias Claim = @Sendable () -> Bool
    typealias Sink = @Sendable (
        RulePackEventBatch,
        @escaping Claim,
        @escaping @Sendable (Bool) -> Void
    ) -> Void

    private final class AttemptLease: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var claimed = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard active else { return false }
            claimed = true
            return true
        }

        /// A claimed attempt has begun its serialized durable write and must be allowed to finish. An unclaimed one
        /// can be cancelled without any later activity appearing for a connection that was allowed on timeout.
        func cancelIfUnclaimed() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard active, !claimed else { return false }
            active = false
            return true
        }

        func invalidate() {
            lock.lock(); defer { lock.unlock() }
            active = false
        }
    }

    private struct Pending: Sendable {
        var batch: RulePackEventBatch
        var attempts = 0
        var generation: UInt64
        var attemptID: UInt64 = 0
        var lease: AttemptLease?
        var completion: @Sendable (Bool) -> Void
    }

    private let queue = DispatchQueue(label: "flowlight.rule-pack.proxy-events")
    private let retryDelay: TimeInterval
    private let attemptTimeout: TimeInterval
    private var generation: UInt64 = 0
    private var nextDeliveryID: Int64 = 0
    private var pending: [Int64: Pending] = [:]
    private var attemptID: UInt64 = 0
    private let sink: Sink

    init(retryDelay: TimeInterval = 0.1,
         attemptTimeout: TimeInterval = 5,
         sink: @escaping Sink) {
        self.retryDelay = retryDelay
        self.attemptTimeout = attemptTimeout
        self.sink = sink
    }

    func enqueue(_ event: RulePackEvent, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            nextDeliveryID += 1
            let deliveryID = nextDeliveryID
            // App-local retries complete against the same serialized database callback and need no permanent
            // watermark row. The immutable batch ID still makes every retry of this refusal identical.
            let batch = RulePackEventBatch(
                deliverySession: UUID(),
                sequence: 1,
                requiresDurableWatermark: false,
                events: [event]
            )
            pending[deliveryID] = Pending(batch: batch, generation: generation, completion: completion)
            deliver(deliveryID: deliveryID)
        }
    }

    /// Fails pre-clear authorizations open and prevents every unclaimed database block from beginning. A write that
    /// already claimed its place on the serial database queue finishes before the clear scheduled by the completion.
    func invalidate(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            generation &+= 1
            let abandoned = Array(pending.values)
            pending.removeAll()
            abandoned.forEach {
                $0.lease?.invalidate()
                $0.completion(false)
            }
            completion()
        }
    }

    private func deliver(deliveryID: Int64) {
        guard var item = pending[deliveryID], item.generation == generation else { return }
        attemptID &+= 1
        let thisAttempt = attemptID
        let lease = AttemptLease()
        item.attemptID = thisAttempt
        item.lease = lease
        pending[deliveryID] = item
        let claim: Claim = { lease.claim() }
        sink(item.batch, claim) { [weak self] committed in
            self?.queue.async {
                self?.finished(committed: committed, deliveryID: deliveryID, attemptID: thisAttempt)
            }
        }
        queue.asyncAfter(deadline: .now() + attemptTimeout) { [weak self] in
            guard lease.cancelIfUnclaimed() else { return }
            self?.finished(committed: false, deliveryID: deliveryID, attemptID: thisAttempt)
        }
    }

    private func finished(committed: Bool, deliveryID: Int64, attemptID finishedAttempt: UInt64) {
        guard var item = pending[deliveryID], item.attemptID == finishedAttempt,
              item.generation == generation else { return }
        item.lease?.invalidate()
        if committed {
            pending.removeValue(forKey: deliveryID)?.completion(true)
            return
        }
        if item.attempts == 0 {
            item.attempts = 1
            item.lease = nil
            pending[deliveryID] = item
            queue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in self?.deliver(deliveryID: deliveryID) }
        } else {
            pending.removeValue(forKey: deliveryID)?.completion(false)
        }
    }
}
