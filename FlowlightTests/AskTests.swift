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
                        "overTime", "deviceActivity", "settings", "howTo", "rules", "guardrails"])
        // Every argument a model may fill in, listed once. A new name here should be a deliberate decision taken
        // in the open, which is what this assertion is for — not a thing that slipped in with a feature.
        for query in AskQuery.allCases {
            let names = Set(query.parameters.map(\.name))
            XCTAssertTrue(names.isSubset(of: ["from", "to", "app", "limit", "granularity", "chart", "topic", "kind"]),
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
        XCTAssertEqual((properties["kind"] as? [String: String])?["type"], "string")
        XCTAssertTrue((properties["kind"] as? [String: String])?["description"]?.contains("camera") == true)
        let canonical = Set(AskQuery.allCases.flatMap(\.parameters).map(\.name))
        XCTAssertEqual(Set(properties.keys), canonical.union(["query"]))
        XCTAssertEqual((properties["chart"] as? [String: String])?["type"], "string")
        XCTAssertEqual((properties["topic"] as? [String: String])?["type"], "string")
        XCTAssertEqual(RemoteProvider.schema["required"] as? [String], ["query"])
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

    func testUnscopedTrafficAnswersKeepAnEmptyReportsFilter() throws {
        try seed()
        for query in [AskQuery.trafficTotals, .topApps, .topDestinations, .newDestinations, .alerts, .agents] {
            let result = try AskQueryRunner.run(
                AskCall(query: query, arguments: ["from": window.from, "to": window.to]), db: db
            )
            XCTAssertNotNil(result.filter, "\(query.rawValue) should remain openable in Reports")
            XCTAssertTrue(result.filter?.isEmpty == true, "\(query.rawValue) should show every row in its window")
        }
    }

    func testAgentsIgnoreQuarantinedParentsButKeepCorrectedAttribution() throws {
        db = try TrafficDatabase(url: makePreviouslyPromotedKey4Database(named: "ask-attribution"))
        var child = key("node", "api.github.com")
        child.parentAgent = "claude"
        child.parentAgentName = "Claude Code"
        child.mcpServer = "github"
        try db.setRollupWatermarks(1_700_000_040)
        try db.insert([TrafficBatch(timestamp: 1_700_000_060, records: [
            TrafficRecord(key: child, counters: FlowCounters(bytesOut: 5, flows: 1))
        ])])
        try db.rollup(now: Date(timeIntervalSince1970: 1_700_000_186),
                      timeZone: TimeZone(secondsFromGMT: 0)!)
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: Date(timeIntervalSince1970: 1_699_999_900))
        let to = iso.string(from: Date(timeIntervalSince1970: 1_700_000_300))

        let result = try AskQueryRunner.run(
            AskCall(query: .agents, arguments: ["from": from, "to": to]),
            db: db
        )

        XCTAssertFalse(result.json.contains("Fabricated Parent"))
        XCTAssertFalse(result.json.contains("fabricated-parent"))
        XCTAssertTrue(result.json.contains("Claude Code"), "corrected epoch-1 child attribution remains visible")
    }

    func testAgentsFallBackWhenCoarseTrafficContainsNoAgentEvidence() throws {
        let url = try makePreviouslyPromotedKey4Database(named: "ask-agent-tier-fallback")
        let coarse = try SQLiteConnection(path: url.path)
        try coarse.execute("""
            DELETE FROM agg_1h;
            INSERT INTO agg_1h (
                ts, pid, bundle_id, app_name, app_path, remote_ip, domain, port, transport, protocol,
                bytes_in, bytes_out, flows, agent_parent, agent_parent_name, mcp_server, channel,
                attribution_exact
            ) VALUES (
                1699999200, 10, 'python', 'python', '/usr/bin/python', '203.0.113.10', 'api.openai.com', 443,
                'tcp', 'https', 0, 7, 1, '', '', '', '', 0
            );
            """)
        db = try TrafficDatabase(url: url)
        try db.setRollupWatermarks(1_700_000_040)
        var recent = key("node", "api.github.com")
        recent.parentAgent = "claude"
        recent.parentAgentName = "Claude Code"
        recent.mcpServer = "github"
        try db.insert([TrafficBatch(timestamp: 1_700_000_060, records: [
            TrafficRecord(key: recent, counters: FlowCounters(bytesOut: 5, flows: 1))
        ])])
        let iso = ISO8601DateFormatter()
        let from = iso.string(from: Date(timeIntervalSince1970: 1_699_999_000))
        let to = iso.string(from: Date(timeIntervalSince1970: 1_700_025_000))

        let result = try AskQueryRunner.run(
            AskCall(query: .agents, arguments: ["from": from, "to": to]),
            db: db
        )

        XCTAssertTrue(result.json.contains("python"), "the completed hourly prefix remains in the answer")
        XCTAssertTrue(result.json.contains("Claude Code"),
                      "an older coarse agent must not hide a different agent in the recent minute tail")
        XCTAssertFalse(result.json.contains("Fabricated Parent"))
    }

    func testTopDestinationsNamesWhereItWent() throws {
        try seed()
        let result = try AskQueryRunner.run(AskCall(query: .topDestinations, arguments: ["from": window.from, "to": window.to]), db: db)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.first?["destination"], "api.anthropic.com")
    }

    func testDeviceActivityIsBoundedAggregateHistoryWithoutStableIDs() throws {
        let start = Date(timeIntervalSince1970: TimeInterval(t0 + 60))
        let stop = Date(timeIntervalSince1970: TimeInterval(t0 + 120))
        try db.recordDeviceEvents([
            DeviceEvent(at: start, kind: .camera, deviceID: "private-camera-uid", name: "Desk Camera",
                        detail: "Acme", change: .started),
            DeviceEvent(at: stop, kind: .camera, deviceID: "private-camera-uid", name: "Desk Camera",
                        detail: "Acme", change: .stopped),
            DeviceEvent(at: stop, kind: .usb, deviceID: "private-usb-serial", name: "Backup Drive",
                        detail: "Storage", change: .connected),
        ])

        let result = try AskQueryRunner.run(
            AskCall(query: .deviceActivity,
                    arguments: ["from": window.from, "to": window.to, "kind": "camera", "limit": "1"]),
            db: db
        )
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["kind"] as? String, "camera")
        XCTAssertEqual(rows.first?["device"] as? String, "Desk Camera")
        XCTAssertEqual(rows.first?["started"] as? Int, 1)
        XCTAssertEqual(rows.first?["stopped"] as? Int, 1)
        XCTAssertEqual(result.screen, .devices)
        XCTAssertFalse(result.json.contains("private-camera-uid"), "stable hardware identifiers never leave the Mac")
        XCTAssertFalse(result.json.contains("private-usb-serial"))
    }

    func testDeviceActivityKeepsOneIdentityTogetherAcrossRenames() throws {
        try db.recordDeviceEvents([
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 60)), kind: .bluetooth,
                        deviceID: "renamed-device", name: "Old Name", detail: "", change: .connected),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 120)), kind: .bluetooth,
                        deviceID: "renamed-device", name: "New Name", detail: "", change: .disconnected),
        ])

        let result = try AskQueryRunner.run(
            AskCall(query: .deviceActivity,
                    arguments: ["from": window.from, "to": window.to, "kind": "bluetooth"]),
            db: db
        )
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["device"] as? String, "New Name")
        XCTAssertEqual(rows.first?["connected"] as? Int, 1)
        XCTAssertEqual(rows.first?["disconnected"] as? Int, 1)
        XCTAssertFalse(result.json.contains("renamed-device"))
    }

    func testDeviceActivityRejectsUnknownKindsInsteadOfGuessing() throws {
        XCTAssertThrowsError(try AskQueryRunner.run(
            AskCall(query: .deviceActivity, arguments: ["from": window.from, "to": window.to, "kind": "microphone"]),
            db: db
        )) { error in
            XCTAssertTrue("\(error)".contains("kind"))
        }
    }

    func testDeviceActivityRoundsTimesAndBoundsRowsAcrossChannels() throws {
        try db.recordDeviceEvents([
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 61)), kind: .camera,
                        deviceID: "camera-a", name: "Desk Camera", detail: "", change: .started),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 119)), kind: .camera,
                        deviceID: "camera-a", name: "Desk Camera", detail: "", change: .stopped),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 121)), kind: .usb,
                        deviceID: "usb-b", name: "Backup Drive", detail: "", change: .connected),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 122)), kind: .camera,
                        deviceID: "camera-b", name: "Desk Camera", detail: "", change: .started),
        ])

        let result = try AskQueryRunner.run(
            AskCall(query: .deviceActivity,
                    arguments: ["from": window.from, "to": window.to, "limit": "2"]),
            db: db
        )
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap { $0["kind"] as? String }), ["camera", "usb"])
        XCTAssertEqual(rows.first?["firstAt"] as? String,
                       ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(t0 + 120))))
        XCTAssertFalse(result.json.contains("camera-a"))
        XCTAssertFalse(result.json.contains("camera-b"))
        XCTAssertFalse(result.json.contains("usb-b"))
    }

    func testDeviceActivityUsesTheRequestedWindow() throws {
        try db.recordDeviceEvents([
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 - 1)), kind: .camera,
                        deviceID: "before", name: "Before", detail: "", change: .started),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0)), kind: .camera,
                        deviceID: "inside", name: "Inside", detail: "", change: .started),
            DeviceEvent(at: Date(timeIntervalSince1970: TimeInterval(t0 + 3600)), kind: .camera,
                        deviceID: "end", name: "At End", detail: "", change: .stopped),
        ])

        let result = try AskQueryRunner.run(
            AskCall(query: .deviceActivity, arguments: ["from": window.from, "to": window.to]), db: db
        )
        XCTAssertTrue(result.json.contains("Inside"))
        XCTAssertFalse(result.json.contains("Before"))
        XCTAssertFalse(result.json.contains("At End"), "windows are half-open just like traffic queries")
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

    @MainActor
    func testProviderSettingsDoNotLeakAcrossProviderSwitches() {
        let suite = "flowlight-ask-provider-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AskController(defaults: defaults)

        controller.provider = .anthropic
        controller.endpoint = "https://gateway.example/v1/messages"
        controller.model = "hosted-model"
        controller.provider = .localServer

        XCTAssertEqual(controller.endpoint, AskProviderKind.localServer.defaultEndpoint)
        XCTAssertEqual(controller.model, AskProviderKind.localServer.defaultModel)
        XCTAssertFalse(controller.sendsOffDevice)
        XCTAssertNil(controller.blockedReason)

        controller.endpoint = "https://gateway.example/v1/chat/completions"
        XCTAssertTrue(controller.sendsOffDevice)
        XCTAssertNotNil(controller.blockedReason, "a remote URL must never be labelled Local server")

        controller.provider = .anthropic
        XCTAssertEqual(controller.endpoint, "https://gateway.example/v1/messages")
        XCTAssertEqual(controller.model, "hosted-model")

        controller.provider = .compatible
        controller.endpoint = "https://gateway.example/v1/chat/completions"
        XCTAssertNotNil(controller.blockedReason, "Compatible requires the API key enforced by RemoteProvider")
    }

    @MainActor
    func testLegacyModelWithoutExplicitEndpointMigratesToSelectedProvider() {
        let suite = "flowlight-ask-model-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AskProviderKind.localServer.rawValue, forKey: AskController.Keys.provider)
        defaults.set("custom-local-model", forKey: AskController.Keys.legacyModel)

        let controller = AskController(defaults: defaults)

        XCTAssertEqual(controller.model, "custom-local-model")
        XCTAssertNil(defaults.object(forKey: AskController.Keys.legacyModel))
    }

    @MainActor
    func testLegacyGlobalSettingsMigrateToTheirEndpointOwner() {
        let suite = "flowlight-ask-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AskProviderKind.localServer.rawValue, forKey: AskController.Keys.provider)
        defaults.set(AskProviderKind.anthropic.defaultEndpoint, forKey: AskController.Keys.legacyEndpoint)
        defaults.set("legacy-claude", forKey: AskController.Keys.legacyModel)

        let controller = AskController(defaults: defaults)
        XCTAssertEqual(controller.endpoint, AskProviderKind.localServer.defaultEndpoint)
        controller.provider = .anthropic
        XCTAssertEqual(controller.endpoint, AskProviderKind.anthropic.defaultEndpoint)
        XCTAssertEqual(controller.model, "legacy-claude")
        XCTAssertNil(defaults.object(forKey: AskController.Keys.legacyEndpoint))
        XCTAssertNil(defaults.object(forKey: AskController.Keys.legacyModel))
    }

    func testEndpointLocalityReflectsWhereTheQuestionActuallyGoes() {
        XCTAssertTrue(RemoteProvider.isOnMac(URL(string: "http://127.0.0.1:11434/v1")))
        XCTAssertTrue(RemoteProvider.isOnMac(URL(string: "https://localhost:8443/v1")))
        XCTAssertFalse(RemoteProvider.isOnMac(URL(string: "http://127.attacker.example/v1")),
                       "a DNS name that starts like loopback is not on this Mac")
        XCTAssertFalse(RemoteProvider.isOnMac(URL(string: "http://192.168.1.20:11434/v1")),
                       "another machine on the LAN is still off this Mac")
        XCTAssertFalse(RemoteProvider.isOnMac(URL(string: "https://gateway.example/v1")))
    }

    func testPlainHTTPEndpointRequiresALiteralPrivateAddressOrLocalName() {
        XCTAssertTrue(RemoteProvider.isSafeEndpoint(URL(string: "http://10.0.0.2/v1")!))
        XCTAssertTrue(RemoteProvider.isSafeEndpoint(URL(string: "http://172.16.0.2/v1")!))
        XCTAssertTrue(RemoteProvider.isSafeEndpoint(URL(string: "http://192.168.1.20/v1")!))
        XCTAssertFalse(RemoteProvider.isSafeEndpoint(URL(string: "http://10.attacker.example/v1")!))
        XCTAssertFalse(RemoteProvider.isSafeEndpoint(URL(string: "http://172.16.attacker.example/v1")!))
        XCTAssertFalse(RemoteProvider.isSafeEndpoint(URL(string: "http://192.168.attacker.example/v1")!))
        XCTAssertFalse(RemoteProvider.isSafeEndpoint(URL(string: "http://127.attacker.example/v1")!))
    }

    func testAnthropicEndTurnUsesCurrentOutputBudgetAndReturnsText() async throws {
        let fixture = AskTransportFixture(responses: [[
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "Nothing unusual was recorded."]],
        ]])
        let answer = try await anthropicProvider(fixture).answer(
            askRequest,
            run: { _ in XCTFail("an end turn must not run a query"); return "" },
            sending: { _ in }
        )

        XCTAssertEqual(answer, "Nothing unusual was recorded.")
        let captured = await fixture.request(at: 0)
        let body = try XCTUnwrap(captured)
        XCTAssertEqual(body["model"] as? String, AskProviderKind.anthropic.defaultModel)
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
    }

    func testAnthropicRunsEveryToolUseThenReturnsTheFinalTurn() async throws {
        let fixture = AskTransportFixture(responses: [
            [
                "stop_reason": "tool_use",
                "content": [
                    ["type": "tool_use", "id": "toolu_settings", "name": "runQuery",
                     "input": ["query": "settings"]],
                    ["type": "tool_use", "id": "toolu_rules", "name": "runQuery",
                     "input": ["query": "rules"]],
                ],
            ],
            [
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": "Blocking is on."]],
            ],
        ])
        let calls = AskCallCapture()
        let answer = try await anthropicProvider(fixture).answer(
            askRequest,
            run: { call in await calls.record(call); return "result for \(call.query.rawValue)" },
            sending: { _ in }
        )

        XCTAssertEqual(answer, "Blocking is on.")
        let queries = await calls.queries()
        XCTAssertEqual(queries, [.settings, .rules])
        let captured = await fixture.request(at: 1)
        let secondBody = try XCTUnwrap(captured)
        let messages = try XCTUnwrap(secondBody["messages"] as? [[String: Any]])
        let resultBlocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(Set(resultBlocks.compactMap { $0["tool_use_id"] as? String }),
                       ["toolu_settings", "toolu_rules"])
    }

    func testAnthropicMaxTokensNeverRunsOrPresentsPartialOutput() async {
        let fixture = AskTransportFixture(responses: [[
            "stop_reason": "max_tokens",
            "content": [
                ["type": "text", "text": "The largest app was"],
                ["type": "tool_use", "id": "toolu_partial", "name": "runQuery",
                 "input": ["query": "settings"]],
            ],
        ]])
        let calls = AskCallCapture()

        do {
            _ = try await anthropicProvider(fixture).answer(
                askRequest,
                run: { call in await calls.record(call); return "must not run" },
                sending: { _ in }
            )
            XCTFail("a truncated response must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("output limit"))
        }
        let queries = await calls.queries()
        XCTAssertTrue(queries.isEmpty)
    }

    func testAnthropicRefusalUsesStopDetailsAndNeverRunsTools() async {
        let fixture = AskTransportFixture(responses: [[
            "stop_reason": "refusal",
            "stop_details": ["category": "cyber", "explanation": "That request is not available."],
            "content": [["type": "tool_use", "id": "toolu_cut_off", "name": "runQuery",
                         "input": ["query": "settings"]]],
        ]])
        let calls = AskCallCapture()

        do {
            _ = try await anthropicProvider(fixture).answer(
                askRequest,
                run: { call in await calls.record(call); return "must not run" },
                sending: { _ in }
            )
            XCTFail("a refusal must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("That request is not available."))
        }
        let queries = await calls.queries()
        XCTAssertTrue(queries.isEmpty)
    }

    func testOpenAILengthAndContentFilterStopsAreNotPresentedAsAnswers() async {
        for (reason, expected) in [("length", "output limit"), ("content_filter", "safety filter")] {
            let fixture = AskTransportFixture(responses: [[
                "choices": [[
                    "finish_reason": reason,
                    "message": [
                        "content": "A partial answer",
                        "tool_calls": [["id": "partial", "function": [
                            "name": "runQuery", "arguments": "{\"query\":\"settings\"}",
                        ]]],
                    ],
                ]],
            ]])
            let calls = AskCallCapture()
            do {
                _ = try await openAIProvider(fixture).answer(
                    askRequest,
                    run: { call in await calls.record(call); return "must not run" },
                    sending: { _ in }
                )
                XCTFail("\(reason) must fail")
            } catch {
                XCTAssertTrue("\(error)".contains(expected))
            }
            let queries = await calls.queries()
            XCTAssertTrue(queries.isEmpty)
        }
    }

    func testOpenAIToolCallsRequireValidIdentity() async {
        let fixture = AskTransportFixture(responses: [[
            "choices": [[
                "finish_reason": "tool_calls",
                "message": ["tool_calls": [["id": "", "function": [
                    "name": "runQuery", "arguments": "{\"query\":\"settings\"}",
                ]]]],
            ]],
        ]])
        let calls = AskCallCapture()
        do {
            _ = try await openAIProvider(fixture).answer(
                askRequest,
                run: { call in await calls.record(call); return "must not run" },
                sending: { _ in }
            )
            XCTFail("a tool call without an ID must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("shape"))
        }
        let queries = await calls.queries()
        XCTAssertTrue(queries.isEmpty)
    }

    func testGeminiTokenAndSafetyStopsAreNotPresentedAsAnswers() async {
        for (reason, expected) in [("MAX_TOKENS", "output limit"), ("SAFETY", "safety filter")] {
            let fixture = AskTransportFixture(responses: [[
                "candidates": [[
                    "finishReason": reason,
                    "content": ["role": "model", "parts": [
                        ["text": "A partial answer"],
                        ["functionCall": ["name": "runQuery", "args": ["query": "settings"]]],
                    ]],
                ]],
            ]])
            let calls = AskCallCapture()
            do {
                _ = try await geminiProvider(fixture).answer(
                    askRequest,
                    run: { call in await calls.record(call); return "must not run" },
                    sending: { _ in }
                )
                XCTFail("\(reason) must fail")
            } catch {
                XCTAssertTrue("\(error)".contains(expected))
            }
            let queries = await calls.queries()
            XCTAssertTrue(queries.isEmpty)
        }
    }

    func testAnthropicMalformedToolIdentityNeverRunsAQuery() async {
        let fixture = AskTransportFixture(responses: [[
            "stop_reason": "tool_use",
            "content": [["type": "tool_use", "id": "", "name": "runQuery",
                         "input": ["query": "settings"]]],
        ]])
        let calls = AskCallCapture()

        do {
            _ = try await anthropicProvider(fixture).answer(
                askRequest,
                run: { call in await calls.record(call); return "must not run" },
                sending: { _ in }
            )
            XCTFail("a tool call without an ID must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("shape"))
        }
        let queries = await calls.queries()
        XCTAssertTrue(queries.isEmpty)
    }

    private var askRequest: AskRequest {
        AskRequest(question: "Is blocking on?", instructions: "Use Flowlight's query.", queries: [.settings, .rules])
    }

    private func anthropicProvider(_ fixture: AskTransportFixture) -> RemoteProvider {
        RemoteProvider(kind: .anthropic, endpoint: AskProviderKind.anthropic.defaultEndpoint,
                       model: AskProviderKind.anthropic.defaultModel, apiKey: "test-key",
                       transport: { request in try await fixture.send(request) })
    }

    private func openAIProvider(_ fixture: AskTransportFixture) -> RemoteProvider {
        RemoteProvider(kind: .openAI, endpoint: AskProviderKind.openAI.defaultEndpoint,
                       model: AskProviderKind.openAI.defaultModel, apiKey: "test-key",
                       transport: { request in try await fixture.send(request) })
    }

    private func geminiProvider(_ fixture: AskTransportFixture) -> RemoteProvider {
        RemoteProvider(kind: .gemini, endpoint: AskProviderKind.gemini.defaultEndpoint,
                       model: AskProviderKind.gemini.defaultModel, apiKey: "test-key",
                       transport: { request in try await fixture.send(request) })
    }
}

private actor AskTransportFixture {
    private var responses: [[String: Any]]
    private var requests: [[String: Any]] = []

    init(responses: [[String: Any]]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              !responses.isEmpty,
              let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        requests.append(json)
        return (try JSONSerialization.data(withJSONObject: responses.removeFirst()), response)
    }

    func request(at index: Int) -> [String: Any]? {
        requests.indices.contains(index) ? requests[index] : nil
    }
}

private actor AskCallCapture {
    private var calls: [AskCall] = []

    func record(_ call: AskCall) {
        calls.append(call)
    }

    func queries() -> [AskQuery] {
        calls.map(\.query)
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
