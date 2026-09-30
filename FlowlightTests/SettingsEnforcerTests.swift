import XCTest
@testable import Flowlight

/// The undo path is the load-bearing one: a wrong merge is a cosmetic bug, but a wrong undo leaves someone's agent
/// pointing at a dead proxy — bricked. So most of these pin what enforcement leaves behind after it is reversed.
final class SettingsEnforcerTests: XCTestCase {
    private var tmp: URL!
    private var enforcer: SettingsEnforcer!
    private let recipe = ConfigRecipe(homeRelativePath: ".claude/settings.json", envKey: "env")
    private let values = ["HTTPS_PROXY": "http://127.0.0.1:8877", "NODE_EXTRA_CA_CERTS": "/tmp/ca.pem"]

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fl-enforce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        enforcer = SettingsEnforcer(directory: tmp.appendingPathComponent("state"),
                                    home: tmp.appendingPathComponent("home"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var live: URL { tmp.appendingPathComponent("home/.claude/settings.json") }

    private func writeLive(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: live)
    }

    private func readLive() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: live.path) else { return nil }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: live)) as? [String: Any]
    }

    // MARK: Pure merge

    /// Merge sets the proxy keys and reports what each was before, so undo has what it needs.
    func testApplyRecordsPriorStateOfEachKey() throws {
        let root: [String: Any] = ["env": ["EXISTING": "1", "HTTPS_PROXY": "http://old"]]
        let result = try SettingsMerge.apply(to: root, envKey: "env", values: values)
        let env = result.root["env"] as? [String: String]
        XCTAssertEqual(env?["HTTPS_PROXY"], "http://127.0.0.1:8877")
        XCTAssertEqual(env?["EXISTING"], "1")
        XCTAssertFalse(result.createdEnv)
        // The key that already had a value is remembered with it; the new one is remembered as absent.
        XCTAssertEqual(result.entries.first { $0.key == "HTTPS_PROXY" }?.prior, "http://old")
        XCTAssertNil(result.entries.first { $0.key == "NODE_EXTRA_CA_CERTS" }?.prior ?? nil)
    }

    /// Revert is the exact inverse of apply: prior values return, keys that were absent go away, and an env block
    /// Flowlight created disappears again.
    func testRevertUndoesApplyExactly() throws {
        let root: [String: Any] = ["model": "opus", "env": ["EXISTING": "1"]]
        let applied = try SettingsMerge.apply(to: root, envKey: "env", values: values)
        let reverted = SettingsMerge.revert(from: applied.root, envKey: "env",
                                            entries: applied.entries, createdEnv: applied.createdEnv)
        XCTAssertTrue(NSDictionary(dictionary: reverted).isEqual(to: root))
    }

    /// When there was no env block at all, reverting removes the one Flowlight added rather than leaving it empty.
    func testRevertRemovesEnvBlockItCreated() throws {
        let root: [String: Any] = ["model": "opus"]
        let applied = try SettingsMerge.apply(to: root, envKey: "env", values: values)
        XCTAssertTrue(applied.createdEnv)
        let reverted = SettingsMerge.revert(from: applied.root, envKey: "env",
                                            entries: applied.entries, createdEnv: applied.createdEnv)
        XCTAssertNil(reverted["env"])
        XCTAssertEqual(reverted["model"] as? String, "opus")
    }

    /// An env block whose values aren't all strings is someone else's data in a shape Flowlight doesn't understand.
    /// It must refuse rather than overwrite it.
    func testApplyRefusesNonStringEnv() {
        let root: [String: Any] = ["env": ["NESTED": ["a": "b"]]]
        XCTAssertThrowsError(try SettingsMerge.apply(to: root, envKey: "env", values: values))
    }

    // MARK: Enforce / relax against files

    /// Enforcing writes the proxy keys and preserves every unrelated setting; relaxing restores the file byte-for-byte.
    func testEnforceThenRelaxRestoresOriginal() throws {
        let original: [String: Any] = ["model": "opus", "permissions": ["allow": ["Bash"]], "env": ["FOO": "bar"]]
        try writeLive(original)

        try enforcer.enforce(agent: "Claude Code", recipe: recipe, values: values, proxyPort: 8877)
        let enforced = try readLive()
        XCTAssertEqual((enforced?["env"] as? [String: String])?["HTTPS_PROXY"], "http://127.0.0.1:8877")
        XCTAssertEqual((enforced?["env"] as? [String: String])?["FOO"], "bar")
        XCTAssertNotNil(enforced?["permissions"])

        enforcer.relax(agent: "Claude Code")
        let restored = try readLive()
        XCTAssertTrue(NSDictionary(dictionary: restored ?? [:]).isEqual(to: original))
    }

    /// A file that didn't exist is created on enforce and removed again on relax, so nothing is left behind for an
    /// agent that never had a settings file.
    func testEnforceCreatesFileAndRelaxRemovesIt() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        try enforcer.enforce(agent: "Claude Code", recipe: recipe, values: values, proxyPort: 8877)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        enforcer.relax(agent: "Claude Code")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
    }

    /// Re-enforcing (e.g. after the port changed) must not record Flowlight's own values as the user's. Applying
    /// twice and relaxing once still restores the true original.
    func testReapplyingKeepsTheTruePriorState() throws {
        let original: [String: Any] = ["env": ["HTTPS_PROXY": "http://mine:1"]]
        try writeLive(original)
        try enforcer.enforce(agent: "Claude Code", recipe: recipe, values: values, proxyPort: 8877)
        try enforcer.enforce(agent: "Claude Code", recipe: recipe,
                             values: ["HTTPS_PROXY": "http://127.0.0.1:9999"], proxyPort: 9999)
        enforcer.relax(agent: "Claude Code")
        let restored = try readLive()
        XCTAssertEqual((restored?["env"] as? [String: String])?["HTTPS_PROXY"], "http://mine:1")
    }

    /// A settings file that isn't valid JSON is left untouched: better to not route the agent than to destroy a file
    /// Flowlight can't safely edit.
    func testMalformedJSONIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json ".write(to: live, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try enforcer.enforce(agent: "Claude Code", recipe: recipe, values: values, proxyPort: 8877))
        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "{ not json ")
    }

    /// The manifest the crash janitor reads names the live file, its clean copy and the port, so the janitor can
    /// recover without parsing any JSON. relaxAll clears it.
    func testManifestTracksEnforcedFilesAndClears() throws {
        try writeLive(["env": ["FOO": "bar"]])
        try enforcer.enforce(agent: "Claude Code", recipe: recipe, values: values, proxyPort: 8877)
        let manifest = try String(contentsOf: enforcer.manifestURL, encoding: .utf8)
        let fields = manifest.split(separator: "\n").first!.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(String(fields[0]), "8877")
        XCTAssertEqual(String(fields[1]), live.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: String(fields[2])))   // clean copy is staged

        enforcer.relaxAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: enforcer.manifestURL.path))
    }
}
