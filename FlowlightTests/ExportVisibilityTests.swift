import XCTest
@testable import Flowlight

/// Flowlight promises that what it sends to a collector is visible in its own screens. The proxy's rule for
/// discarding its internal loopback legs would otherwise swallow exactly that.
final class ExportVisibilityTests: XCTestCase {
    private func record(port: UInt16, pid: Int32) -> TrafficBatch {
        let key = FlowKey(pid: pid, bundleID: "com.flowlight.app", appName: "Flowlight", appPath: "",
                          remoteIP: "127.0.0.1", domain: "", port: port, transport: .tcp, appProtocol: "http")
        return TrafficBatch(timestamp: 100, records: [TrafficRecord(key: key, counters: FlowCounters(bytesIn: 1, bytesOut: 2, flows: 1))])
    }

    override func tearDown() {
        ProxyAttribution.shared.proxyPort = nil
        ProxyAttribution.shared.exportPort = nil
        super.tearDown()
    }

    func testTrafficToALocalCollectorSurvives() {
        ProxyAttribution.shared.proxyPort = 8877
        ProxyAttribution.shared.exportPort = 4318
        let kept = ProxyAttribution.shared.rewrite([record(port: 4318, pid: getpid())])
        XCTAssertEqual(kept.first?.records.count, 1, "an export to a local collector is real traffic worth showing")
    }

    func testTheProxysOwnLoopbackLegsAreStillDropped() {
        ProxyAttribution.shared.proxyPort = 8877
        ProxyAttribution.shared.exportPort = 4318
        let dropped = ProxyAttribution.shared.rewrite([record(port: 8877, pid: getpid())])
        XCTAssertEqual(dropped.first?.records.count, 0, "already counted on the upstream side")
    }

    func testWithNoCollectorConfiguredNothingChanges() {
        ProxyAttribution.shared.proxyPort = 8877
        ProxyAttribution.shared.exportPort = nil
        let dropped = ProxyAttribution.shared.rewrite([record(port: 4318, pid: getpid())])
        XCTAssertEqual(dropped.first?.records.count, 0)
    }
}
