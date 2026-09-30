import XCTest
@testable import Flowlight

/// The crash guarantee this feature makes — "a crash won't leave an agent bricked" — is exactly what the janitor
/// delivers, so these run its real recovery shell against a temporary manifest. Port 1 stands in for a dead proxy:
/// a connection to it is refused at once, which is the state the janitor treats as "the proxy is gone".
final class ProxyJanitorTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fl-janitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    private func runJanitor(manifest: String, appRunning: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", ProxyJanitor.restoreScript]
        var env = ProcessInfo.processInfo.environment
        env["FL_MANIFEST"] = manifest
        env["FL_APP_RUNNING"] = appRunning
        task.environment = env
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func write(_ text: String, to url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }

    /// App gone, proxy dead, a clean copy staged: the janitor moves the clean copy back over the live file and drops
    /// the manifest. This is the crash case.
    func testRestoresCleanCopyWhenAppGoneAndProxyDead() throws {
        let live = tmp.appendingPathComponent("settings.json")
        let clean = tmp.appendingPathComponent("clean.json")
        let manifest = tmp.appendingPathComponent("manifest")
        try write("ENFORCED", to: live)
        try write("ORIGINAL", to: clean)
        try write("1\t\(live.path)\t\(clean.path)\n", to: manifest)

        runJanitor(manifest: manifest.path, appRunning: "0")

        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "ORIGINAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    /// While Flowlight is still running it manages its own cleanup, so the janitor must keep its hands off even if a
    /// port check would have failed.
    func testDoesNothingWhileAppRunning() throws {
        let live = tmp.appendingPathComponent("settings.json")
        let clean = tmp.appendingPathComponent("clean.json")
        let manifest = tmp.appendingPathComponent("manifest")
        try write("ENFORCED", to: live)
        try write("ORIGINAL", to: clean)
        try write("1\t\(live.path)\t\(clean.path)\n", to: manifest)

        runJanitor(manifest: manifest.path, appRunning: "1")

        XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "ENFORCED")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    /// When the file was one Flowlight created (no clean copy), recovery removes it rather than leaving a settings
    /// file pointing at a dead proxy.
    func testDeleteMarkerRemovesFileCreatedByFlowlight() throws {
        let live = tmp.appendingPathComponent("settings.json")
        let manifest = tmp.appendingPathComponent("manifest")
        try write("ENFORCED", to: live)
        try write("1\t\(live.path)\t\(SettingsEnforcer.deleteMarker)\n", to: manifest)

        runJanitor(manifest: manifest.path, appRunning: "0")

        XCTAssertFalse(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    /// No manifest means nothing is enforced, so the janitor exits cleanly without touching anything.
    func testNoManifestIsANoOp() {
        XCTAssertEqual(runJanitor(manifest: tmp.appendingPathComponent("absent").path, appRunning: "0"), 0)
    }
}
