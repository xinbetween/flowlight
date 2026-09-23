import AppKit
import Foundation

/// Fallback capture that needs no entitlements: runs `/usr/bin/nettop -L 1` once per second.
///
/// A single long-running `nettop -L 0` would be simpler, but nettop busy-loops (~150% CPU) when
/// its stdout is a pipe. A one-shot sample takes ~0.3 s of mostly waiting, so polling stays cheap.
final class NettopTrafficSource: TrafficSource, @unchecked Sendable {
    let displayName = "nettop sampler"
    private let parser = NettopParser()
    private let processes = ProcessLookup()
    private let queue = DispatchQueue(label: "flowlight.nettop", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var consecutiveFailures = 0
    private var stalls = 0
    private let watchdog = DispatchQueue(label: "flowlight.nettop.watchdog", qos: .utility)
    /// A sample normally takes ~0.3 s. nettop occasionally spins forever inside NetworkStatistics (100%+ CPU, never
    /// exits); without a limit that one hung process would stop sampling for good.
    var sampleTimeout: TimeInterval = 5
    /// Overridable for tests.
    var executable = "/usr/bin/perl"
    /// nettop is run under perl's alarm so the kernel kills it even if Flowlight itself is killed mid-sample: a hung
    /// nettop reparented to launchd was seen spinning at 150% CPU for hours.
    var arguments = ["-e", "alarm \(Int(NettopTrafficSource.sampleLimit)); exec @ARGV", "--",
                     "/usr/bin/nettop", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
    static let sampleLimit: TimeInterval = 8

    func start(sink: @escaping ([TrafficBatch]) -> Void, status: @escaping (String) -> Void) {
        Self.killStrayNettops()
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
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        // Terminate a hung sample, then force it; reading below returns once the process is gone.
        let pid = process.processIdentifier
        let stall = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        watchdog.asyncAfter(deadline: .now() + sampleTimeout, execute: stall)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stall.cancel()
        if process.terminationReason == .uncaughtSignal {
            stalls += 1
            fail("nettop stopped responding and was restarted (\(stalls)×). Sampling continues.", status: status)
            return
        }
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
        // An empty batch still tells the app the sampler is alive; a quiet second isn't a stalled one.
        sink(batch.records.isEmpty ? [] : [batch])
    }

    /// Kills nettop processes left behind by an earlier Flowlight that was force-quit mid-sample. Only processes
    /// whose arguments match the ones this sampler uses are touched.
    static func killStrayNettops() {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        listing.standardOutput = pipe
        listing.standardError = FileHandle.nullDevice
        guard (try? listing.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        let me = getpid()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  line.contains("/usr/bin/nettop"), line.contains("bytes_in"),
                  parent != me, pid != me else { continue }
            // Only strays: a sample of ours always has Flowlight as its parent.
            if parent == 1 { kill(pid, SIGKILL) }
        }
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
