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

    func testRulePublicationRequiresTheExactExtensionBuildIdentity() {
        XCTAssertTrue(ExtensionTrafficSource.acceptsRegisteredVersion("0.15.4/27", expected: "0.15.4/27"))
        XCTAssertFalse(ExtensionTrafficSource.acceptsRegisteredVersion("0.15.4", expected: "0.15.4/27"))
        XCTAssertFalse(ExtensionTrafficSource.acceptsRegisteredVersion("0.15.4/26", expected: "0.15.4/27"))
        XCTAssertFalse(ExtensionTrafficSource.acceptsRegisteredVersion("", expected: "0.15.4/27"))
        XCTAssertFalse(ExtensionTrafficSource.acceptsRegisteredVersion("0.15.4/27", expected: ""))
    }

    func testRulePackPushGateAbsorbsDuplicateStartupPush() {
        var gate = RulePackPushGate()

        XCTAssertTrue(gate.begin(epoch: 2))
        XCTAssertFalse(gate.begin(epoch: 2))
        XCTAssertEqual(gate.finish(epoch: 2), false)
        XCTAssertTrue(gate.begin(epoch: 2))
    }

    func testRulePackPushGateCoalescesANewerSnapshot() {
        var gate = RulePackPushGate()

        XCTAssertTrue(gate.begin(epoch: 2))
        XCTAssertFalse(gate.begin(epoch: 3))
        XCTAssertFalse(gate.begin(epoch: 4))
        XCTAssertEqual(gate.finish(epoch: 2), true)
        XCTAssertTrue(gate.begin(epoch: 4))
        XCTAssertNil(gate.finish(epoch: 3))
        XCTAssertEqual(gate.finish(epoch: 4), false)
    }

    func testEveryPackMutationRequiresTheRegisteredXPCClient() throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "IPCServer", withExtension: "txt"))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("func claimRule(payload: Data"), "the bundled fixture must be the live IPC source")
        let methods = ["claimRule", "rulePackHello", "beginRulePack", "appendRulePack", "commitRulePack", "clearRulePacks"]
        for method in methods {
            let start = try XCTUnwrap(source.range(of: "func \(method)("))
            let remaining = source[start.lowerBound...]
            let next = remaining.dropFirst().range(of: "\n    func ")?.lowerBound ?? remaining.endIndex
            let body = remaining[..<next]
            XCTAssertTrue(body.contains("NSXPCConnection.current()"), method)
            XCTAssertTrue(body.contains("self.client === connection"), method)
        }
        let registerStart = try XCTUnwrap(source.range(of: "func register("))
        let registerRemaining = source[registerStart.lowerBound...]
        let registerEnd = registerRemaining.dropFirst().range(of: "\n    func ")?.lowerBound ?? registerRemaining.endIndex
        XCTAssertTrue(registerRemaining[..<registerEnd].contains("self.packTransfer.reset()"))
    }
}
