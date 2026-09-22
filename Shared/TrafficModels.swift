import Foundation

enum TransportProtocol: String, Codable, Sendable {
    case tcp, udp
}

/// Aggregation key emitted by capture sources: `(pid, bundle id, remote ip, domain, port, protocol)`.
/// `appName` / `appPath` ride along as attributes; they are fixed for a given pid.
struct FlowKey: Hashable, Codable, Sendable {
    var pid: Int32
    var bundleID: String
    var appName: String
    var appPath: String
    var remoteIP: String
    var domain: String
    var port: UInt16
    var transport: TransportProtocol
    var appProtocol: String
    /// The AI agent this process works for (it's a descendant of the agent's process), e.g. `curl` run by Claude Code.
    /// Optional so older batches still decode. Filled in by the app, not by capture sources.
    var parentAgent: String? = nil
    var parentAgentName: String? = nil
    /// The MCP server this process is, when it matches an agent's MCP configuration.
    var mcpServer: String? = nil
}

struct FlowCounters: Codable, Sendable, Equatable {
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var flows: Int64 = 0

    static func += (lhs: inout FlowCounters, rhs: FlowCounters) {
        lhs.bytesIn += rhs.bytesIn
        lhs.bytesOut += rhs.bytesOut
        lhs.flows += rhs.flows
    }

    var total: Int64 { bytesIn + bytesOut }
    var isEmpty: Bool { bytesIn == 0 && bytesOut == 0 && flows == 0 }
}

struct TrafficRecord: Codable, Sendable {
    var key: FlowKey
    var counters: FlowCounters
}

/// One per-second summary. Capture sources never emit per-packet events.
struct TrafficBatch: Codable, Sendable {
    var timestamp: Int64          // unix seconds, start of the bucket
    var records: [TrafficRecord]
}

enum TrafficCoding {
    static func encode(_ batches: [TrafficBatch]) -> Data {
        (try? PropertyListEncoder.binary.encode(batches)) ?? Data()
    }

    static func decode(_ data: Data) -> [TrafficBatch] {
        (try? PropertyListDecoder().decode([TrafficBatch].self, from: data)) ?? []
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

/// Thread-safe per-second accumulator used by both the extension and the fallback sampler.
final class SecondAggregator: @unchecked Sendable {
    private var buckets: [Int64: [FlowKey: FlowCounters]] = [:]
    private let lock = NSLock()

    func add(_ key: FlowKey, _ counters: FlowCounters, at timestamp: Int64 = Int64(Date().timeIntervalSince1970)) {
        guard !counters.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        buckets[timestamp, default: [:]][key, default: FlowCounters()] += counters
    }

    /// Returns all buckets strictly older than `before`.
    func drain(before: Int64) -> [TrafficBatch] {
        lock.lock(); defer { lock.unlock() }
        let ready = buckets.keys.filter { $0 < before }.sorted()
        return ready.map { ts in
            let records = buckets.removeValue(forKey: ts)!.map { TrafficRecord(key: $0.key, counters: $0.value) }
            return TrafficBatch(timestamp: ts, records: records)
        }
    }
}
