import XCTest
@testable import Flowlight

/// The repair runs once, unattended, against a database that may hold years of history — on the machine this was
/// found on, four gigabytes of it. Fixing the naming stops new rows going in wrong and does nothing for the rows
/// already there, and daily totals are kept indefinitely, so without this the agent stays split forever.
///
/// It merges identities, which means it rewrites part of the unique key. That is the risky shape: a rename can
/// collide with a row already under the real name, and the two are the same traffic counted twice.
final class VersionNameRepairTests: XCTestCase {

    private func database() throws -> TrafficDatabase {
        try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("repair-\(UUID()).sqlite"))
    }

    private func batch(at ts: Int64, bundleID: String, name: String, path: String, host: String = "api.example",
                       bytesIn: Int64 = 100, bytesOut: Int64 = 200, flows: Int64 = 1) -> TrafficBatch {
        let key = FlowKey(pid: 1, bundleID: bundleID, appName: name, appPath: path, remoteIP: "1.2.3.4",
                          domain: host, port: 443, transport: .tcp, appProtocol: "https")
        return TrafficBatch(timestamp: ts, records: [
            TrafficRecord(key: key, counters: FlowCounters(bytesIn: bytesIn, bytesOut: bytesOut, flows: flows))
        ])
    }

    private func rows(_ db: TrafficDatabase) throws -> [(bundle: String, name: String, bytes: Int64, flows: Int64)] {
        try db.raw("SELECT bundle_id, app_name, bytes_in + bytes_out, flows FROM flows_1s ORDER BY bundle_id") {
            ($0.text(0), $0.text(1), $0.int(2), $0.int(3))
        }
    }

    func testAVersionNamedAgentIsGivenItsRealName() throws {
        let db = try database()
        try db.insert([batch(at: 1000, bundleID: "2.1.283", name: "2.1.283",
                             path: "/Users/x/.local/share/claude/versions/2.1.283")])
        try db.repairVersionedNames()

        let all = try rows(db)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.bundle, "claude")
        XCTAssertEqual(all.first?.name, "Claude Code", "the identity is the executable, the label is the tool's name")
    }

    /// The case that makes this more than an UPDATE: the same second, the same destination, under two identities.
    /// Renaming one onto the other collides on the unique key, and the byte counts have to be added rather than
    /// one silently replacing the other.
    func testCollidingRowsAreMergedRatherThanOverwritten() throws {
        let db = try database()
        let path = "/Users/x/.local/share/claude/versions/2.1.283"
        try db.insert([batch(at: 1000, bundleID: "claude", name: "Claude Code", path: path,
                             bytesIn: 10, bytesOut: 20, flows: 1)])
        try db.insert([batch(at: 1000, bundleID: "2.1.283", name: "2.1.283", path: path,
                             bytesIn: 100, bytesOut: 200, flows: 3)])

        try db.repairVersionedNames()

        let all = try rows(db)
        XCTAssertEqual(all.count, 1, "the two identities should now be one row")
        XCTAssertEqual(all.first?.bytes, 330, "no bytes may be lost or double-counted in the merge")
        XCTAssertEqual(all.first?.flows, 4)
    }

    /// Seven versions of one agent were found in a real database. They have to collapse to one identity, not seven.
    func testManyVersionsCollapseToOneIdentity() throws {
        let db = try database()
        for (offset, version) in ["2.1.260", "2.1.267", "2.1.274", "2.1.283"].enumerated() {
            try db.insert([batch(at: 1000 + Int64(offset), bundleID: version, name: version,
                                 path: "/Users/x/.local/share/claude/versions/\(version)")])
        }
        try db.repairVersionedNames()

        let identities = Set(try rows(db).map(\.bundle))
        XCTAssertEqual(identities, ["claude"])
    }

    /// A version with no path anywhere is not guessable, and inventing an owner for it would be worse than
    /// leaving it alone — the repair must not touch what it cannot justify.
    func testAVersionWithNoEvidenceIsLeftAlone() throws {
        let db = try database()
        try db.insert([batch(at: 1000, bundleID: "3.3.3", name: "3.3.3", path: "")])
        try db.repairVersionedNames()
        XCTAssertEqual(try rows(db).first?.bundle, "3.3.3")
    }

    func testOrdinaryAppsAreUntouched() throws {
        let db = try database()
        try db.insert([batch(at: 1000, bundleID: "com.google.Chrome", name: "Google Chrome",
                             path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")])
        try db.insert([batch(at: 1001, bundleID: "python3.13", name: "python3.13",
                             path: "/Users/x/.pyenv/versions/3.13.5/bin/python3.13")])
        try db.repairVersionedNames()

        let identities = Set(try rows(db).map(\.bundle))
        XCTAssertEqual(identities, ["com.google.Chrome", "python3.13"],
                       "python3.13 is a name that contains digits, not a version")
    }

    /// Running twice must be a no-op. The marker should prevent it, but a repair that corrupts data when repeated
    /// is one bad marker away from doing so.
    func testRepairingTwiceChangesNothing() throws {
        let db = try database()
        try db.insert([batch(at: 1000, bundleID: "2.1.283", name: "2.1.283",
                             path: "/Users/x/.local/share/claude/versions/2.1.283")])
        try db.repairVersionedNames()
        let once = try rows(db)
        try db.repairVersionedNames()
        let twice = try rows(db)

        XCTAssertEqual(once.map(\.bytes), twice.map(\.bytes))
        XCTAssertEqual(once.count, twice.count)
    }
}
