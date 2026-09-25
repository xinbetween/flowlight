import XCTest
@testable import Flowlight

/// Asking Flowlight a question. The part worth testing hardest is the boundary: a model may name a query and fill
/// in a window, and nothing else. There is no way to express "give me the database", because there is no query
/// that means it.
final class AskTests: XCTestCase {
    private var db: TrafficDatabase!
    private let t0: Int64 = 1_700_000_000 - (1_700_000_000 % 86_400)

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-ask-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
    }

    private func key(_ app: String, _ domain: String, name: String? = nil) -> FlowKey {
        FlowKey(pid: 10, bundleID: app, appName: name ?? app, appPath: "", remoteIP: "1.2.3.4", domain: domain,
                port: 443, transport: .tcp, appProtocol: "https")
    }

    private func seed() throws {
        var batches: [TrafficBatch] = []
        for second in 0..<120 {
            batches.append(TrafficBatch(timestamp: t0 + Int64(second), records: [
                TrafficRecord(key: key("com.claude", "api.anthropic.com", name: "claude"),
                              counters: FlowCounters(bytesIn: 100, bytesOut: 900, flows: second == 0 ? 1 : 0)),
                TrafficRecord(key: key("com.other", "example.com", name: "Other"),
                              counters: FlowCounters(bytesIn: 10, bytesOut: 1, flows: 0)),
            ]))
        }
        try db.insert(batches)
        // The app rolls up continuously; a question about an hour ago reads the minute tier, so the fixture has
        // to have been through the same fold.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        try db.rollup(now: Date(timeIntervalSince1970: TimeInterval(t0 + 300)), timeZone: utc.timeZone)
    }

    private var window: (from: String, to: String) {
        let iso = ISO8601DateFormatter()
        return (iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0))),
                iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0 + 3600))))
    }

    // MARK: The boundary

    func testEveryQueryIsAFixedNameWithNoRoomForSQL() {
        // If a case ever appears that takes free text and runs it, this is the test that should fail.
        XCTAssertEqual(Set(AskQuery.allCases.map(\.rawValue)),
                       ["trafficTotals", "topApps", "topDestinations", "newDestinations", "alerts", "agents",
                        "overTime", "settings", "howTo", "rules", "guardrails"])
        // Every argument a model may fill in, listed once. A new name here should be a deliberate decision taken
        // in the open, which is what this assertion is for — not a thing that slipped in with a feature.
        for query in AskQuery.allCases {
            let names = Set(query.parameters.map(\.name))
            XCTAssertTrue(names.isSubset(of: ["from", "to", "app", "limit", "granularity", "chart", "topic"]),
                          "\(query.rawValue) takes an argument nobody vetted: \(names)")
        }
        // The queries about the app take no window: they describe how it is set up, not when.
        for query in [AskQuery.settings, .rules, .guardrails] {
            XCTAssertTrue(query.parameters.isEmpty, "\(query.rawValue) should need no arguments")
        }
    }

    func testTheToolSchemaOffersOnlyTheQueriesThatExist() throws {
        let properties = try XCTUnwrap(RemoteProvider.schema["properties"] as? [String: Any])
        let allowed = try XCTUnwrap((properties["query"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(Set(allowed), Set(AskQuery.allCases.map(\.rawValue)))
        XCTAssertEqual(RemoteProvider.schema["required"] as? [String], ["query", "from"])
    }

    // MARK: Windows

    func testShorthandWindowsResolveLocally() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AskWindow.moment("24h", now: now)?.timeIntervalSince1970, now.timeIntervalSince1970 - 86_400)
        XCTAssertEqual(AskWindow.moment("90m", now: now)?.timeIntervalSince1970, now.timeIntervalSince1970 - 5_400)
        XCTAssertEqual(AskWindow.moment("now", now: now), now)
        XCTAssertNotNil(AskWindow.moment("2026-09-24", now: now))
        XCTAssertNotNil(AskWindow.moment("2026-09-24T10:00:00Z", now: now))
    }

    func testAnUnreadableWindowIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(AskWindow.moment("whenever"))
        XCTAssertNil(AskWindow.moment(""))
        XCTAssertNil(AskWindow.resolve(from: "whenever", to: nil))
    }

    func testAWindowMustRunForwards() {
        XCTAssertNil(AskWindow.resolve(from: "now", to: "24h"), "an end before its start is not a window")
    }

    func testAnEnormousWindowIsClamped() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = try XCTUnwrap(AskWindow.resolve(from: "2000-01-01", to: nil, now: now))
        XCTAssertEqual(resolved.to.timeIntervalSince(resolved.from), AskWindow.maximum, accuracy: 1)
    }

    // MARK: Arguments

    func testRowLimitsAreBounded() throws {
        XCTAssertEqual(try AskQueryRunner.rowLimit(nil), 10)
        XCTAssertEqual(try AskQueryRunner.rowLimit("3"), 3)
        XCTAssertEqual(try AskQueryRunner.rowLimit("5000"), AskQueryRunner.maximumRows)
        XCTAssertEqual(try AskQueryRunner.rowLimit("-4"), 1)
        XCTAssertThrowsError(try AskQueryRunner.rowLimit("lots"))
    }

    func testGranularityIsTheOneThatCanActuallyAnswer() {
        let hour = (from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600))
        let week = (from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 604_800))
        XCTAssertEqual(AskQueryRunner.granularity(for: hour, requested: nil), .minute)
        XCTAssertEqual(AskQueryRunner.granularity(for: week, requested: nil), .day)
        XCTAssertEqual(AskQueryRunner.granularity(for: week, requested: "second"), .minute,
                       "a week of seconds is millions of rows nobody asked for")
        XCTAssertEqual(AskQueryRunner.granularity(for: hour, requested: "hour"), .hour)
    }

    // MARK: Running them

    func testTotalsComeBackAsAggregatesNotRows() throws {
        try seed()
        let result = try AskQueryRunner.run(AskCall(query: .trafficTotals, arguments: ["from": window.from, "to": window.to]), db: db)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["sent"] as? Int64, 120 * 901)
        XCTAssertEqual(json["received"] as? Int64, 120 * 110)
        XCTAssertEqual(json["apps"] as? Int64, 2)
        XCTAssertFalse(result.json.contains("1.2.3.4"), "totals are totals; an address is not one")
    }

    func testOneAppCanBeNamedByItsDisplayName() throws {
        try seed()
        let result = try AskQueryRunner.run(AskCall(query: .trafficTotals,
                                                    arguments: ["from": window.from, "to": window.to, "app": "claude"]), db: db)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["sent"] as? Int64, 120 * 900)
        XCTAssertEqual(result.filter?.bundleID, "com.claude", "the answer links back to the rows behind it")
    }

    func testTopAppsIsOrderedAndLimited() throws {
        try seed()
        let result = try AskQueryRunner.run(AskCall(query: .topApps,
                                                    arguments: ["from": window.from, "to": window.to, "limit": "1"]), db: db)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["app"], "claude")
    }

    func testTopDestinationsNamesWhereItWent() throws {
        try seed()
        let result = try AskQueryRunner.run(AskCall(query: .topDestinations, arguments: ["from": window.from, "to": window.to]), db: db)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.first?["destination"], "api.anthropic.com")
    }

    func testAnEmptyWindowSaysNothingHappenedRatherThanFailing() throws {
        try seed()
        let iso = ISO8601DateFormatter()
        let later = iso.string(from: Date(timeIntervalSince1970: TimeInterval(t0 + 86_400)))
        let result = try AskQueryRunner.run(AskCall(query: .topApps, arguments: ["from": later]), db: db)
        XCTAssertEqual(result.json, "[]")
        XCTAssertEqual(result.summary, "nothing moved")
    }

    func testABadWindowComesBackAsASentenceTheModelCanRead() throws {
        try seed()
        XCTAssertThrowsError(try AskQueryRunner.run(AskCall(query: .topApps, arguments: ["from": "whenever"]), db: db)) { error in
            XCTAssertTrue("\(error)".contains("time window"), "the model has to be told what to fix")
        }
    }

    func testAMissingWindowIsRefused() throws {
        try seed()
        XCTAssertThrowsError(try AskQueryRunner.run(AskCall(query: .topApps, arguments: [:]), db: db))
    }

    // MARK: What the model is told

    func testTheInstructionsListEveryQueryAndForbidInvention() {
        let text = AskPrompt.instructions(queries: AskQuery.allCases)
        for query in AskQuery.allCases {
            XCTAssertTrue(text.contains(query.rawValue), "the model isn't told about \(query.rawValue)")
        }
        XCTAssertTrue(text.contains("Never invent a number"))
        XCTAssertTrue(text.contains("cannot see the database"))
    }

    func testOnlyTheLocalProvidersClaimToSendNothing() {
        XCTAssertFalse(AskProviderKind.onDevice.sendsOffDevice)
        XCTAssertFalse(AskProviderKind.localServer.sendsOffDevice)
        for kind in [AskProviderKind.anthropic, .openAI, .gemini, .compatible] {
            XCTAssertTrue(kind.sendsOffDevice, "\(kind.rawValue) sends a question off the Mac and must say so")
            XCTAssertTrue(kind.needsKey || kind == .compatible)
        }
    }
}

/// The small print of tool calling: models fill in every field they are given, whether or not they mean to.
final class AskArgumentTests: XCTestCase {
    func testPlaceholderWordsAreTreatedAsBlanks() {
        // Seen in the wild from an on-device model: `app: default` for a question about every app, which taken
        // literally filters for an app called "default" and answers a confident zero.
        for word in ["default", "none", "all", "null", "N/A", " ", "string"] {
            let call = AskCall(query: .trafficTotals, arguments: ["from": "1h", "app": word])
            XCTAssertNil(call.arguments["app"], "'\(word)' means the field was left blank")
        }
    }

    func testRealValuesSurviveAndAreTrimmed() {
        let call = AskCall(query: .trafficTotals, arguments: ["from": " 24h ", "app": " Claude Code "])
        XCTAssertEqual(call.arguments["from"], "24h")
        XCTAssertEqual(call.arguments["app"], "Claude Code")
    }

    func testTheModelIsToldWhatTimeItIs() {
        // Without this it guesses a date, and a question about "the last hour" comes back about some day in 2025.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let text = AskPrompt.instructions(queries: AskQuery.allCases, now: now)
        XCTAssertTrue(text.contains("Right now it is"))
        XCTAssertTrue(text.contains("2026"))
        XCTAssertTrue(text.contains("Prefer a relative window"))
        XCTAssertTrue(text.contains("Never write 'default'"))
    }
}

/// History is folded upwards on a timer. An answer must not depend on whether that timer has fired.
final class AskTierTests: XCTestCase {
    private var db: TrafficDatabase!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowlight-tier-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: url)
    }

    func testRecentTrafficIsFoundEvenBeforeItHasBeenRolledUp() throws {
        // Exactly the state a running Mac is in for the first minutes of any hour: rows in the per-second table,
        // nothing folded into the hourly one yet.
        let now = Date()
        let start = Int64(now.timeIntervalSince1970) - 120
        let key = FlowKey(pid: 1, bundleID: "com.example", appName: "Example", appPath: "", remoteIP: "1.2.3.4",
                          domain: "example.com", port: 443, transport: .tcp, appProtocol: "https")
        try db.insert((0..<60).map { offset in
            TrafficBatch(timestamp: start + Int64(offset),
                         records: [TrafficRecord(key: key, counters: FlowCounters(bytesIn: 10, bytesOut: 20, flows: 0))])
        })

        // An hourly window, which without a fallback would read an empty agg_1h and answer "nothing".
        let result = try AskQueryRunner.run(AskCall(query: .trafficTotals, arguments: ["from": "1h", "granularity": "hour"]),
                                            db: db, now: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(json["sent"] as? Int64, 60 * 20, "the answer must not depend on whether a rollup has run")
    }

    func testTheFallbackOnlyGoesFiner() {
        XCTAssertEqual(AskQueryRunner.finer(than: .day), .hour)
        XCTAssertEqual(AskQueryRunner.finer(than: .hour), .minute)
        XCTAssertEqual(AskQueryRunner.finer(than: .minute), .second)
        XCTAssertNil(AskQueryRunner.finer(than: .second), "there is nothing finer than a second to fall back to")
    }
}
