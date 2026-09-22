import AppKit
import Foundation

/// Fallback capture that needs no entitlements: runs `/usr/bin/nettop -L 1` once per second.
///
/// A single long-running `nettop -L 0` would be simpler, but nettop busy-loops (~150% CPU) when
/// its stdout is a pipe. A one-shot sample costs ~10 ms, so polling keeps the sampler around 1% CPU.
final class NettopTrafficSource: TrafficSource, @unchecked Sendable {
    let displayName = "nettop sampler"
    private let parser = NettopParser()
    private let processes = ProcessLookup()
    private let queue = DispatchQueue(label: "flowlight.nettop", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var consecutiveFailures = 0

    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sampleOnce(sink: sink, status: status) }
        timer.resume()
        self.timer = timer
        status("Sampling with nettop every second")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sampleOnce(sink: ([TrafficBatch]) -> Void, status: (String) -> Void) {
        let sampledAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fail("Failed to launch nettop: \(error.localizedDescription)", status: status)
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            fail("nettop exited with status \(process.terminationStatus)", status: status)
            return
        }
        if consecutiveFailures > 0 {
            consecutiveFailures = 0
            status("Sampling with nettop every second")
        }
        let deltas = parser.feedSample(String(decoding: data, as: UTF8.self))
        // The delta covers the second that just ended.
        let batch = makeBatch(deltas, timestamp: Int64(sampledAt.timeIntervalSince1970) - 1)
        if !batch.records.isEmpty { sink([batch]) }
    }

    private func fail(_ message: String, status: (String) -> Void) {
        consecutiveFailures += 1
        if consecutiveFailures == 1 || consecutiveFailures % 30 == 0 { status(message) }
    }

    private func makeBatch(_ deltas: [NettopParser.Delta], timestamp: Int64) -> TrafficBatch {
        var merged: [FlowKey: FlowCounters] = [:]
        for delta in deltas {
            let info = processes.info(pid: delta.pid)
            let c = delta.connection
            let unconnected = c.remoteIP == "*"
            // Hostname priority: TLS SNI / DNS answers seen on the wire, then reverse DNS as a last resort.
            let domain = unconnected ? "" : (DNSCache.shared.name(for: c.remoteIP) ?? ReverseDNS.shared.name(for: c.remoteIP) ?? "")
            let proto = ProtocolClassifier.default.classify(ClassificationInput(
                remotePort: c.remotePort, transport: c.transport, firstOutbound: nil, firstInbound: nil))
            let key = FlowKey(pid: delta.pid, bundleID: info.bundleID, appName: info.name, appPath: info.path,
                              remoteIP: unconnected ? "(unconnected)" : c.remoteIP, domain: domain,
                              port: c.remotePort, transport: c.transport, appProtocol: ProtocolCatalog.refine(proto, domain: domain))
            merged[key, default: FlowCounters()] += delta.counters
        }
        return TrafficBatch(timestamp: timestamp, records: merged.map { TrafficRecord(key: $0.key, counters: $0.value) })
    }
}
