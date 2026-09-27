import XCTest
@testable import Flowlight

final class CoverageTests: XCTestCase {
    private func row(_ bundleID: String, _ name: String, domain: String, bytes: Int64) -> BreakdownRow {
        BreakdownRow(bundleID: bundleID, appName: name, appPath: "", domain: domain, remoteIP: "203.0.113.7",
                     ports: "443", protocols: "https",
                     counters: FlowCounters(bytesIn: 0, bytesOut: bytes, flows: 1))
    }

    private func build(_ rows: [BreakdownRow], inspected: Set<String> = [], excluded: Set<String> = [],
                       mode: CaptureMode = .networkExtension, fellBack: Bool = false,
                       inspectionOn: Bool = true) -> [AppCoverage] {
        CoverageReport.build(rows: rows, inspected: inspected, excluded: excluded, mode: mode,
                             fellBack: fellBack, inspectionOn: inspectionOn, isDemo: false)
    }

    /// Naming is measured in bytes, not connections. One unnamed connection carrying a gigabyte is a bigger
    /// hole than a hundred carrying a kilobyte, and counting rows ranks them the other way round.
    func testNamingIsWeightedByBytes() {
        let rows = [row("a", "App", domain: "example.com", bytes: 100),
                    row("a", "App", domain: "", bytes: 900)]
        let coverage = try? XCTUnwrap(build(rows).first)
        XCTAssertEqual(coverage?.named ?? 0, 0.1, accuracy: 0.001)
    }

    /// The three questions fail independently: an app can be fully seen and entirely unnamed. A row is only
    /// complete when nothing is missing, so "covered" can't quietly mean "mostly".
    func testAnUnnamedAppIsNotComplete() {
        let seen = build([row("a", "App", domain: "example.com", bytes: 100)], inspected: ["a"])
        XCTAssertTrue(seen[0].isComplete)
        let unnamed = build([row("b", "Other", domain: "", bytes: 100)], inspected: ["b"])
        XCTAssertFalse(unnamed[0].isComplete)
    }

    /// Inspection has four answers and only one of them is a gap. Being on the never-inspect list is a choice
    /// someone made, not a failure, and must not be reported as one.
    func testInspectionStatesAreDistinguished() {
        let rows = [row("a", "Read", domain: "x.com", bytes: 10), row("b", "Skipped", domain: "x.com", bytes: 10),
                    row("c", "Missed", domain: "x.com", bytes: 10)]
        let coverage = build(rows, inspected: ["a"], excluded: ["b"])
        let byID = Dictionary(uniqueKeysWithValues: coverage.map { ($0.bundleID, $0.inspection) })
        XCTAssertEqual(byID["a"], .reading)
        XCTAssertEqual(byID["b"], .excluded)
        XCTAssertEqual(byID["c"], .notRouted)
        XCTAssertTrue(build(rows, inspectionOn: false).allSatisfy { $0.inspection == .off })
    }

    /// With inspection off, nothing is decrypted for anyone — which is a setting, not a per-app gap, so those
    /// rows still count as complete. Otherwise every app on a default install would be flagged.
    func testInspectionOffIsNotAPerAppGap() {
        XCTAssertTrue(build([row("a", "App", domain: "x.com", bytes: 10)], inspectionOn: false)[0].isComplete)
    }

    /// The sampler misses whole connections rather than some bytes of them, so no percentage can express it.
    /// Falling back to it counts the same way: what is on screen came from the sampler either way.
    func testTheSamplerAndAFallbackBothCountAsSampled() {
        XCTAssertEqual(build([row("a", "App", domain: "x.com", bytes: 10)], mode: .nettop)[0].capture, .sampler)
        XCTAssertEqual(build([row("a", "App", domain: "x.com", bytes: 10)], fellBack: true)[0].capture, .fellBack)
        XCTAssertFalse(build([row("a", "App", domain: "x.com", bytes: 10)], inspected: ["a"], mode: .nettop)[0].isComplete)
    }

    /// The overall figure is a share of bytes, not an average of percentages: an app moving a gigabyte and one
    /// moving a kilobyte are not half the picture each.
    func testOverallIsWeightedByTraffic() {
        let rows = [row("big", "Big", domain: "", bytes: 999_000), row("small", "Small", domain: "x.com", bytes: 1_000)]
        let coverage = build(rows, inspected: ["big", "small"])
        XCTAssertEqual(CoverageReport.overall(coverage), 0.001, accuracy: 0.0005)
    }

    func testEmptyInputIsZeroRatherThanACrash() {
        XCTAssertTrue(build([]).isEmpty)
        XCTAssertEqual(CoverageReport.overall([]), 0)
    }
}
