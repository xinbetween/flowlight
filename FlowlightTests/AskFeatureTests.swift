import XCTest
@testable import Flowlight

/// Ask now answers two kinds of question: what happened on the network, and how Flowlight itself works. The second
/// kind is the one where a model would otherwise invent a menu path, so the guide it reads from is checked here.
final class FeatureGuideTests: XCTestCase {

    func testEveryFeatureSaysWhatItIsAndHowToUseIt() {
        for guide in FeatureGuide.all {
            XCTAssertFalse(guide.title.isEmpty, guide.id)
            XCTAssertFalse(guide.summary.isEmpty, "\(guide.id) has no summary")
            XCTAssertFalse(guide.steps.isEmpty, "\(guide.id) has no steps — an answer from it couldn't tell anyone what to do")
        }
    }

    func testIdentifiersAreUnique() {
        XCTAssertEqual(Set(FeatureGuide.all.map(\.id)).count, FeatureGuide.all.count)
    }

    func testTheFeaturesSomeoneIsMostLikelyToAskAboutAreCovered() {
        // If one of these disappears the panel silently stops being able to answer a common question.
        for id in ["capture", "inspection", "rules", "guardrails", "focus", "export", "devices", "ask", "alerts"] {
            XCTAssertTrue(FeatureGuide.all.contains { $0.id == id }, "no guide for \(id)")
        }
    }

    func testSearchFindsTheFeatureFromHowSomeoneWouldAskForIt() {
        let cases: [(String, String)] = [
            ("how do I turn on https inspection", "inspection"),
            ("block an app from reaching a domain", "rules"),
            ("stop an agent using its shell tool", "guardrails"),
            ("why am I not seeing any traffic", "capture"),
            ("send my data to splunk", "export"),
            ("watch bluetooth devices", "devices"),
            ("keep it running in the menu bar", "background"),
        ]
        for (question, expected) in cases {
            let found = FeatureGuide.search(question).map(\.id)
            XCTAssertTrue(found.contains(expected), "'\(question)' found \(found), expected \(expected) among them")
        }
    }

    func testAQuestionAboutNothingInParticularComesBackEmptyRatherThanWrong() {
        XCTAssertTrue(FeatureGuide.search("zzzzqqqq wibble").isEmpty,
                      "a confident wrong feature is worse than admitting no match")
    }

    func testWhatTheModelReceivesCarriesTheSteps() {
        let inspection = FeatureGuide.all.first { $0.id == "inspection" }!
        let payload = inspection.asDictionary
        XCTAssertNotNil(payload["what"])
        XCTAssertTrue(payload["how"]?.contains("1.") == true, "steps should arrive numbered")
        XCTAssertEqual(payload["where"], "Inspect")
        XCTAssertNotNil(payload["limits"], "the caveats are the part people find out the hard way")
    }
}

/// The queries that describe Flowlight rather than the network.
final class AskSettingsQueryTests: XCTestCase {
    private var db: TrafficDatabase!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-env-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
    }

    private var environment: AskEnvironment {
        AskEnvironment(appVersion: "0.5.1", captureSource: "Network Extension", captureStatus: "Connected",
                       receiving: true, extensionState: "Filter enabled", canBlock: true,
                       inspecting: false, exportEnabled: false, exportConfigured: false,
                       watchingBluetooth: true, rules: ["Block example.com — on, Always, fired 2×"],
                       guardrails: [], agentAllowlists: 1, askProvider: "On-device model")
    }

    func testSettingsNeedNoTimeWindow() throws {
        // A question about how the app is configured has no "when", and demanding one would make the model
        // invent a window to get past the validation.
        let result = try AskQueryRunner.run(AskCall(query: .settings, arguments: [:]), db: db, environment: environment)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["captureSource"] as? String, "Network Extension")
        XCTAssertEqual(json["httpsInspection"] as? String, "off")
        XCTAssertEqual(json["canRefuseConnections"] as? String, "yes")
        XCTAssertEqual(result.screen, .capture)
    }

    func testSettingsCarryNoSecrets() throws {
        let result = try AskQueryRunner.run(AskCall(query: .settings, arguments: [:]), db: db, environment: environment)
        // Keys and endpoints live in the Keychain and have no business answering "is export on?".
        for forbidden in ["token", "authorization", "http://", "https://"] {
            XCTAssertFalse(result.json.lowercased().contains(forbidden), "settings leaked \(forbidden)")
        }
    }

    func testHowToAnswersFromTheGuide() throws {
        let result = try AskQueryRunner.run(AskCall(query: .howTo, arguments: ["topic": "turn on https inspection"]),
                                            db: db, environment: environment)
        XCTAssertTrue(result.json.contains("HTTPS inspection"))
        XCTAssertEqual(result.screen, .inspect, "the answer should be able to offer to take you there")
    }

    func testHowToWithNoMatchListsWhatThereIsInsteadOfGuessing() throws {
        let result = try AskQueryRunner.run(AskCall(query: .howTo, arguments: ["topic": "zzzzqqqq"]),
                                            db: db, environment: environment)
        XCTAssertTrue(result.json.contains("features"))
        XCTAssertTrue(result.summary.contains("nothing matched"))
    }

    func testRulesAndGuardrailsComeFromTheSnapshot() throws {
        let rules = try AskQueryRunner.run(AskCall(query: .rules, arguments: [:]), db: db, environment: environment)
        XCTAssertTrue(rules.json.contains("Block example.com"))
        XCTAssertEqual(rules.screen, .rules)
        let guardrails = try AskQueryRunner.run(AskCall(query: .guardrails, arguments: [:]), db: db, environment: environment)
        XCTAssertEqual(guardrails.summary, "no guardrails")
    }
}

/// Charts are built by Flowlight from the rows a query returned, never by the model, so the picture and the
/// sentence come from one source and cannot disagree.
final class AskChartTests: XCTestCase {
    private var db: TrafficDatabase!
    private let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86_400)

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-chart-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
        let key = { (app: String) in
            FlowKey(pid: 1, bundleID: app, appName: app, appPath: "", remoteIP: "1.2.3.4", domain: "\(app).test",
                    port: 443, transport: .tcp, appProtocol: "https")
        }
        try db.insert((0..<120).map { second in
            TrafficBatch(timestamp: t0 + Int64(second), records: [
                TrafficRecord(key: key("alpha"), counters: FlowCounters(bytesIn: 100, bytesOut: 900, flows: 0)),
                TrafficRecord(key: key("beta"), counters: FlowCounters(bytesIn: 10, bytesOut: 5, flows: 0)),
            ])
        })
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(t0 + 300)), timeZone: TimeZone(identifier: "UTC")!)
    }

    private var window: [String: String] {
        let iso = ISO8601DateFormatter()
        return ["from": iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0))),
                "to": iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0 + 3600)))]
    }

    func testEachQueryGetsTheShapeThatSuitsIt() throws {
        let overTime = try AskQueryRunner.run(AskCall(query: .overTime, arguments: window), db: db)
        XCTAssertEqual(overTime.chart?.kind, .line, "change over time is a line")
        let topApps = try AskQueryRunner.run(AskCall(query: .topApps, arguments: window), db: db)
        XCTAssertEqual(topApps.chart?.kind, .bar, "comparing things is bars")
        let totals = try AskQueryRunner.run(AskCall(query: .trafficTotals, arguments: window), db: db)
        XCTAssertEqual(totals.chart?.kind, .pie, "one whole split in two is a pie")
    }

    func testTheModelCanAskForADifferentShape() throws {
        var arguments = window
        arguments["chart"] = "pie"
        let result = try AskQueryRunner.run(AskCall(query: .topApps, arguments: arguments), db: db)
        XCTAssertEqual(result.chart?.kind, .pie)
    }

    func testTheModelCanSuppressAChartEntirely() throws {
        var arguments = window
        arguments["chart"] = "none"
        let result = try AskQueryRunner.run(AskCall(query: .topApps, arguments: arguments), db: db)
        XCTAssertTrue(result.chart?.isEmpty ?? true, "not every question wants a picture")
    }

    func testChartValuesMatchTheNumbersInTheAnswer() throws {
        let result = try AskQueryRunner.run(AskCall(query: .topApps, arguments: window), db: db)
        let chart = try XCTUnwrap(result.chart)
        let alpha = try XCTUnwrap(chart.points.first { $0.label == "alpha" })
        XCTAssertEqual(alpha.value, Double(120 * 900), "the bar is the same number the sentence quotes")
        XCTAssertEqual(alpha.secondary, Double(120 * 100))
    }

    func testAnEmptyWindowDrawsNothing() throws {
        let iso = ISO8601DateFormatter()
        let later = iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0 + 86_400)))
        let result = try AskQueryRunner.run(AskCall(query: .topApps, arguments: ["from": later]), db: db)
        XCTAssertTrue(result.chart?.isEmpty ?? true)
    }

    func testTooManySlicesAreGatheredIntoOther() {
        let points = (0..<20).map { AskChart.Point(label: "app\($0)", value: Double(20 - $0)) }
        let pie = AskChart.trimmed(points, kind: .pie)
        XCTAssertEqual(pie.count, 6, "a pie of twenty slices is a colour-matching exercise")
        XCTAssertTrue(pie.last?.label.hasPrefix("Other") == true)
        XCTAssertEqual(pie.last?.value, points.dropFirst(5).reduce(0) { $0 + $1.value })
        XCTAssertEqual(AskChart.trimmed(points, kind: .bar).count, 12, "bars tolerate more")
    }
}

/// A word that means "nothing" in one argument can be a real value in another.
final class AskLiteralArgumentTests: XCTestCase {
    func testNoneIsABlankForAnAppButAValueForAChart() {
        // "none" is how a model declines a chart. Treating it as an unfilled field handed the chart straight back.
        let call = AskCall(query: .topApps, arguments: ["from": "24h", "app": "none", "chart": "none"])
        XCTAssertNil(call.arguments["app"], "for an app, 'none' means the field was left blank")
        XCTAssertEqual(call.arguments["chart"], "none", "for a chart, 'none' means don't draw one")
    }

    func testAnEmptyChartArgumentIsStillABlank() {
        let call = AskCall(query: .topApps, arguments: ["from": "24h", "chart": "  "])
        XCTAssertNil(call.arguments["chart"])
    }
}
