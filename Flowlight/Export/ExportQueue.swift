import Foundation

/// One send's worth of records.
struct ExportBatch: Sendable, Equatable {
    var rollups: [ExportRollup] = []
    var alerts: [ExportAlert] = []

    var count: Int { rollups.count + alerts.count }
    var isEmpty: Bool { rollups.isEmpty && alerts.isEmpty }
}

/// What is waiting to be sent, with a hard ceiling on it.
///
/// A collector that can't be reached is the normal case, not the exception: a laptop leaves the office network
/// every day, and a collector gets restarted. So the queue is bounded by record count — past the limit the oldest
/// records are dropped and counted, and the count is shown in Settings rather than hidden. Buffering without a
/// limit would turn a monitoring feature into exactly the kind of quietly growing process this app exists to
/// point at, and wedging the app to preserve a minute of byte counts would be a worse trade still.
///
/// Plain functions over plain data, like `AgentPolicy.matches` and `BlockRules.verdict`, so the whole of the
/// batching, dropping and giving-up behaviour is covered without a network.
struct ExportQueue: Sendable {
    /// Total records held, including the one batch in flight.
    var limit = 10_000
    /// Most records in one request.
    var batchSize = 500
    /// How many times one batch is tried before it is given up on.
    var maxAttempts = 5

    private(set) var rollups: [ExportRollup] = []
    private(set) var alerts: [ExportAlert] = []
    /// The batch handed out by `next()` and not yet acknowledged. It is retried as-is rather than mixed back
    /// into the queue, so a failing batch can't be re-split every round and the attempt count keeps its meaning.
    private(set) var inFlight: ExportBatch?
    private(set) var attempt = 0
    /// Records thrown away, either because the queue was full or because a batch ran out of attempts. Surfaced
    /// in Settings: an export that silently lost records would be worse than one that plainly didn't run.
    private(set) var dropped = 0

    var count: Int { rollups.count + alerts.count + (inFlight?.count ?? 0) }

    mutating func add(rollups newRollups: [ExportRollup] = [], alerts newAlerts: [ExportAlert] = []) {
        rollups += newRollups
        alerts += newAlerts
        trim()
    }

    /// Drops oldest-first once the queue is over its limit, rollups before alerts: an alert is a one-off somebody
    /// wants to see, a rollup is one window out of many and the next one carries the same shape of information.
    private mutating func trim() {
        var over = count - limit
        guard over > 0 else { return }
        let fromRollups = min(over, rollups.count)
        rollups.removeFirst(fromRollups)
        dropped += fromRollups
        over -= fromRollups
        guard over > 0 else { return }
        let fromAlerts = min(over, alerts.count)
        alerts.removeFirst(fromAlerts)
        dropped += fromAlerts
    }

    /// The next batch to send: whatever is still in flight, or a fresh slice off the front.
    mutating func next() -> ExportBatch? {
        if let inFlight { return inFlight }
        var batch = ExportBatch()
        // Alerts first. They are the small, urgent half, and a backlog of rollups shouldn't delay the one record
        // somebody set this up to receive.
        let takeAlerts = min(batchSize, alerts.count)
        let takeRollups = min(batchSize - takeAlerts, rollups.count)
        guard takeAlerts + takeRollups > 0 else { return nil }
        batch.alerts = Array(alerts.prefix(takeAlerts))
        batch.rollups = Array(rollups.prefix(takeRollups))
        alerts.removeFirst(takeAlerts)
        rollups.removeFirst(takeRollups)
        inFlight = batch
        attempt = 0
        return batch
    }

    mutating func succeeded() {
        inFlight = nil
        attempt = 0
    }

    /// Records a failure. `remainder` is what still has to go: one OTLP batch becomes two requests, and metrics
    /// can land while logs don't, so only the part that failed is retried. Returns false when the batch has run
    /// out of attempts and been dropped.
    @discardableResult
    mutating func failed(retaining remainder: ExportBatch) -> Bool {
        attempt += 1
        guard attempt < maxAttempts, !remainder.isEmpty else {
            dropped += remainder.count
            inFlight = nil
            attempt = 0
            return false
        }
        inFlight = remainder
        return true
    }

    /// How long to wait before trying again: exponential and capped, with no jitter.
    ///
    /// No jitter because there is exactly one Flowlight talking to one collector that the user runs — there is no
    /// herd to spread out — and a delay that can be predicted is one that can be explained in a status line and
    /// checked in a test.
    func retryDelay(base: TimeInterval = 5, cap: TimeInterval = 300) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(cap, base * pow(2, Double(attempt - 1)))
    }
}
