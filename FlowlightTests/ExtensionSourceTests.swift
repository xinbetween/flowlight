import XCTest
@testable import Flowlight

final class ExtensionSourceTests: XCTestCase {
    /// The extension only sends when there is traffic, so a quiet second has to register as "still alive"
    /// somewhere. ingest() reads an empty delivery that way; dropping it turned the status orange on an idle Mac.
    func testEmptyDeliveryReachesTheSink() {
        let source = ExtensionTrafficSource()
        let delivered = expectation(description: "empty batch delivered")
        var batches: [[TrafficBatch]] = []
        let lock = NSLock()
        source.start(sink: { received in
            lock.lock(); batches.append(received); lock.unlock()
            delivered.fulfill()
        }, status: { _ in })
        source.deliver(payload: TrafficCoding.encode([])) { }
        wait(for: [delivered], timeout: 2)
        source.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(batches.count, 1)
        XCTAssertTrue(batches[0].isEmpty, "an empty delivery is the heartbeat, not something to discard")
    }

    func testBatchesWithTrafficStillArrive() {
        let source = ExtensionTrafficSource()
        let delivered = expectation(description: "batch delivered")
        var count = 0
        let lock = NSLock()
        source.start(sink: { received in
            lock.lock(); count += received.count; lock.unlock()
            delivered.fulfill()
        }, status: { _ in })
        let key = FlowKey(pid: 1, bundleID: "com.a", appName: "A", appPath: "", remoteIP: "1.2.3.4", domain: "a.com",
                          port: 443, transport: .tcp, appProtocol: "https")
        let batch = TrafficBatch(timestamp: 100, records: [TrafficRecord(key: key, counters: FlowCounters(bytesIn: 1, bytesOut: 2, flows: 1))])
        source.deliver(payload: TrafficCoding.encode([batch])) { }
        wait(for: [delivered], timeout: 2)
        source.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(count, 1)
    }
}
