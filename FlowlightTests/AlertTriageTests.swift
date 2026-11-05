import XCTest
@testable import Flowlight

final class AlertTriageTests: XCTestCase {
    private var databaseURL: URL!
    private var db: TrafficDatabase!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowlight-alert-triage-\(UUID().uuidString).sqlite")
        db = try TrafficDatabase(url: databaseURL)
    }

    override func tearDownWithError() throws {
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    @discardableResult
    private func add(_ app: String = "com.example.App", at: TimeInterval = 100,
                     allowPattern: String = "") throws -> AlertRecord {
        try db.addAlert(kind: "New destination", bundleID: app, appName: app, detail: "detail", severity: 2,
                        at: Date(timeIntervalSince1970: at), allowPattern: allowPattern)
    }

    func testLegacyAcknowledgedMigrationPreservesMeaning() throws {
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        var legacy: SQLiteConnection? = try SQLiteConnection(path: databaseURL.path)
        try legacy?.execute("""
            CREATE TABLE alerts (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL,
                bundle_id TEXT NOT NULL, app_name TEXT NOT NULL, detail TEXT NOT NULL,
                severity INTEGER NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO alerts (ts, kind, bundle_id, app_name, detail, severity, acknowledged)
                VALUES (100, 'one', 'new.app', 'New', '', 1, 0);
            INSERT INTO alerts (ts, kind, bundle_id, app_name, detail, severity, acknowledged)
                VALUES (101, 'two', 'seen.app', 'Seen', '', 1, 1);
            """)
        legacy = nil

        db = try TrafficDatabase(url: databaseURL)
        let migrated = try db.alerts()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: migrated.map { ($0.bundleID, $0.state) }),
                       ["new.app": .new, "seen.app": .acknowledged])
        XCTAssertEqual(migrated.first { $0.bundleID == "new.app" }?.triageUpdatedAt,
                       Date(timeIntervalSince1970: 100))
        XCTAssertEqual(migrated.first { $0.bundleID == "seen.app" }?.triageUpdatedAt,
                       Date(timeIntervalSince1970: 101))
        XCTAssertEqual(Set(try db.raw("PRAGMA table_info(alerts)", map: { $0.text(1) }))
            .intersection(["triage_state", "disposition", "triage_note", "triage_updated_at"]),
                       ["triage_state", "disposition", "triage_note", "triage_updated_at"])
    }

    func testNewAlertDefaultsSurviveReloadAndClearAllRemovesTriage() throws {
        let alert = try add(allowPattern: "api.example")
        XCTAssertEqual(alert.state, .new)
        XCTAssertEqual(alert.disposition, .unset)
        XCTAssertEqual(alert.note, "")
        XCTAssertEqual(alert.triageUpdatedAt, alert.timestamp)

        db = nil
        db = try TrafficDatabase(url: databaseURL)
        let reloaded = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(reloaded.state, .new)
        XCTAssertEqual(reloaded.disposition, .unset)
        XCTAssertEqual(reloaded.allowPattern, "api.example")

        try db.setAlertTriageState(.investigating, ids: [reloaded.id], at: Date(timeIntervalSince1970: 200))
        try db.setAlertDisposition(.truePositive, ids: [reloaded.id], at: Date(timeIntervalSince1970: 201))
        try db.setAlertNote("local note", id: reloaded.id, at: Date(timeIntervalSince1970: 202))
        db = nil
        db = try TrafficDatabase(url: databaseURL)
        let triaged = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(triaged.state, .investigating)
        XCTAssertEqual(triaged.disposition, .truePositive)
        XCTAssertEqual(triaged.note, "local note")
        XCTAssertEqual(triaged.triageUpdatedAt, Date(timeIntervalSince1970: 202))

        try db.clearAll()
        db = nil
        db = try TrafficDatabase(url: databaseURL)
        XCTAssertTrue(try db.alerts().isEmpty)
    }

    func testTransitionsAreValidatedAndTerminalAlertsCanOnlyReopenForInvestigation() throws {
        let alert = try add()
        try db.setAlertTriageState(.acknowledged, ids: [alert.id])
        try db.setAlertTriageState(.investigating, ids: [alert.id])
        try db.setAlertTriageState(.resolved, ids: [alert.id])

        XCTAssertThrowsError(try db.setAlertTriageState(.acknowledged, ids: [alert.id])) { error in
            XCTAssertEqual(error as? AlertTriageError,
                           .invalidTransition(from: .resolved, to: .acknowledged))
        }
        XCTAssertEqual(try db.alerts().first?.state, .resolved)

        try db.setAlertTriageState(.investigating, ids: [alert.id])
        XCTAssertEqual(try db.alerts().first?.state, .investigating)
    }

    func testDispositionIsIndependentAndUpdatesTimestamp() throws {
        let alert = try add()
        let changed = Date(timeIntervalSince1970: 250)
        try db.setAlertDisposition(.expectedBenign, ids: [alert.id], at: changed)

        let stored = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(stored.state, .new)
        XCTAssertEqual(stored.disposition, .expectedBenign)
        XCTAssertEqual(stored.triageUpdatedAt, changed)
    }

    func testNoteBoundAndTimestampAreEnforcedWithoutOverwritingStoredNote() throws {
        let alert = try add()
        let changed = Date(timeIntervalSince1970: 300)
        let maximum = String(repeating: "x", count: AlertRecord.maximumNoteLength)
        try db.setAlertNote(maximum, id: alert.id, at: changed)
        XCTAssertEqual(try db.alerts().first?.note.count, AlertRecord.maximumNoteLength)
        XCTAssertEqual(try db.alerts().first?.triageUpdatedAt, changed)

        XCTAssertThrowsError(try db.setAlertNote(maximum + "x", id: alert.id,
                                                 at: Date(timeIntervalSince1970: 400))) { error in
            XCTAssertEqual(error as? AlertTriageError,
                           .noteTooLong(maximum: AlertRecord.maximumNoteLength))
        }
        let unchanged = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(unchanged.note, maximum)
        XCTAssertEqual(unchanged.triageUpdatedAt, changed)
    }

    func testBulkStateAndDispositionUpdatesAreAtomic() throws {
        let first = try add("first.app")
        let second = try add("second.app")
        try db.setAlertTriageState(.resolved, ids: [second.id])

        XCTAssertThrowsError(try db.setAlertTriageState(.acknowledged, ids: [first.id, second.id]))
        let afterStateFailure = Dictionary(uniqueKeysWithValues: try db.alerts().map { ($0.id, $0.state) })
        XCTAssertEqual(afterStateFailure[first.id], .new)
        XCTAssertEqual(afterStateFailure[second.id], .resolved)

        XCTAssertThrowsError(try db.setAlertDisposition(.falsePositive, ids: [first.id, 9_999_999]))
        XCTAssertEqual(try db.alerts().first { $0.id == first.id }?.disposition, .unset)
    }

    func testLargeBulkUpdatesStayAtomicBeyondSQLiteVariableLimits() throws {
        var ids: [Int64] = []
        for index in 0..<1_200 {
            ids.append(try add("bulk.app", at: TimeInterval(1_000 + index)).id)
        }

        try db.setAlertTriageState(.acknowledged, ids: ids)
        try db.setAlertDisposition(.truePositive, ids: ids)
        let updated = try db.alerts(limit: 1_500)
        XCTAssertEqual(updated.count, ids.count)
        XCTAssertTrue(updated.allSatisfy { $0.state == .acknowledged && $0.disposition == .truePositive })
    }

    func testAcknowledgeAllNewHonorsFocusWithoutMaterializingEveryID() throws {
        for index in 0..<1_200 { _ = try add("a.app", at: TimeInterval(2_000 + index)) }
        _ = try add("b.app", at: 4_000)

        try db.acknowledgeAlerts(ids: nil, focus: FocusScope(bundleIDs: ["a.app"]))

        XCTAssertEqual(try db.newAlertCount(focus: FocusScope(bundleIDs: ["a.app"])), 0)
        XCTAssertEqual(try db.newAlertCount(focus: FocusScope(bundleIDs: ["b.app"])), 1)
    }

    func testKindFilterAppliesBeforeAlertLimit() throws {
        _ = try db.addAlert(kind: AnomalyEngine.Kind.allowlistViolation.rawValue,
                            bundleID: "agent.app", appName: "Agent", detail: "older", severity: 2,
                            at: Date(timeIntervalSince1970: 100))
        _ = try db.addAlert(kind: "New destination", bundleID: "other.app", appName: "Other",
                            detail: "newer", severity: 1, at: Date(timeIntervalSince1970: 200))

        let loaded = try db.alerts(limit: 1, kind: AnomalyEngine.Kind.allowlistViolation.rawValue)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.bundleID, "agent.app")
    }

    func testBadgeCountsOnlyNewAlertsWithinFocus() throws {
        let newA = try add("a.app")
        let acknowledgedA = try add("a.app")
        let investigatingA = try add("a.app")
        _ = try add("b.app")
        try db.setAlertTriageState(.acknowledged, ids: [acknowledgedA.id])
        try db.setAlertTriageState(.investigating, ids: [investigatingA.id])

        XCTAssertEqual(try db.newAlertCount(), 2)
        XCTAssertEqual(try db.unacknowledgedAlertCount(), 2, "compatibility count must have new-state semantics")
        XCTAssertEqual(try db.newAlertCount(focus: FocusScope(bundleIDs: ["a.app"])), 1)
        XCTAssertEqual(try db.newAlertCount(focus: FocusScope(hosts: ["example.com"])), 2)
        XCTAssertEqual(try db.alerts(triageFilter: .open).map(\.id).contains(newA.id), true)
    }

    func testFocusAndTriageFiltersCompose() throws {
        let openA = try add("a.app")
        let investigatingA = try add("a.app")
        let resolvedA = try add("a.app")
        let dismissedB = try add("b.app")
        try db.setAlertTriageState(.investigating, ids: [investigatingA.id])
        try db.setAlertTriageState(.resolved, ids: [resolvedA.id])
        try db.setAlertTriageState(.dismissed, ids: [dismissedB.id])

        let a = FocusScope(bundleIDs: ["a.app"])
        XCTAssertEqual(Set(try db.alerts(focus: a, triageFilter: .open).map(\.id)), [openA.id, investigatingA.id])
        XCTAssertEqual(try db.alerts(focus: a, triageFilter: .investigating).map(\.id), [investigatingA.id])
        XCTAssertEqual(try db.alerts(focus: a, triageFilter: .resolved).map(\.id), [resolvedA.id])
        XCTAssertTrue(try db.alerts(focus: a, triageFilter: .dismissed).isEmpty)
    }

    func testTriageDoesNotCreateOrModifyAllowRules() throws {
        let alert = try add("agent.app", allowPattern: "api.example")
        try db.setAlertTriageState(.dismissed, ids: [alert.id])
        try db.setAlertDisposition(.falsePositive, ids: [alert.id])

        XCTAssertTrue(try db.loadPolicies().isEmpty)
        let triaged = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(triaged.allowPattern, "api.example")
        XCTAssertEqual(triaged.state, .dismissed)

        try db.savePolicy(AgentPolicy(agentID: "agent.app", patterns: ["api.example"]))
        let afterAllowRule = try XCTUnwrap(db.alerts().first)
        XCTAssertEqual(afterAllowRule.state, .dismissed)
        XCTAssertEqual(afterAllowRule.disposition, .falsePositive)
    }
}
