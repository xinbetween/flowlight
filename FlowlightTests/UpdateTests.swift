import XCTest
@testable import Flowlight

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(VersionCompare.isNewer("0.1.2", than: "0.1.1"))
        XCTAssertTrue(VersionCompare.isNewer("0.10.0", than: "0.9.9"), "numeric, not lexical")
        XCTAssertTrue(VersionCompare.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("0.1.1", than: "0.1.1"))
        XCTAssertFalse(VersionCompare.isNewer("0.1", than: "0.1.0"), "missing parts count as zero")
        XCTAssertFalse(VersionCompare.isNewer("0.1.0", than: "0.1.1"))
        XCTAssertTrue(VersionCompare.isNewer("0.2.0-beta", than: "0.1.9"))
    }

    func testChecksumLookup() {
        let sums = """
        aa08b1c5a971ab55fa37142cc6b09df5086a770efa4988225f9731e59a1179ed  Flowlight.dmg
        77063b75d92584ecdefcd46275791f79726d854a11ae269dfef22ccd05e1e7a1  Flowlight-0.1.1.pkg
        """
        XCTAssertEqual(VersionCompare.checksum(for: "Flowlight.dmg", in: sums), "aa08b1c5a971ab55fa37142cc6b09df5086a770efa4988225f9731e59a1179ed")
        XCTAssertNil(VersionCompare.checksum(for: "Other.dmg", in: sums))
        XCTAssertEqual(VersionCompare.checksum(for: "Flowlight.dmg", in: "ABCD *Flowlight.dmg"), "abcd", "binary-mode marker")
    }

    func testReleaseNotesAreReadable() {
        let notes = "**Early preview.** Hi\n\n### What's new\n- One\n- Two\n\n### Checksums (SHA-256)\n```\nabc  Flowlight.dmg\n```"
        let text = ReleaseNotes.readable(notes)
        XCTAssertTrue(text.contains("**What's new**"))
        XCTAssertTrue(text.contains("•  One"))
        XCTAssertFalse(text.contains("Checksums"))
        XCTAssertFalse(text.contains("```"))
    }

    func testParsesGitHubReleaseAndPicksAssets() throws {
        let json = """
        {"tag_name":"v0.1.2","name":"Flowlight 0.1.2","body":"**New:** things","html_url":"https://github.com/xinbetween/flowlight/releases/tag/v0.1.2",
         "draft":false,"prerelease":false,"published_at":"2026-09-30T10:00:00Z",
         "assets":[{"name":"Flowlight-0.1.2.pkg","browser_download_url":"https://github.com/x/y/releases/download/v0.1.2/Flowlight-0.1.2.pkg"},
                   {"name":"Flowlight.dmg","browser_download_url":"https://github.com/x/y/releases/download/v0.1.2/Flowlight.dmg"},
                   {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/x/y/releases/download/v0.1.2/SHA256SUMS.txt"}]}
        """
        let release = try AppRelease.parse(Data(json.utf8))
        XCTAssertEqual(release.version, "0.1.2")
        XCTAssertEqual(release.dmgURL?.lastPathComponent, "Flowlight.dmg")
        XCTAssertEqual(release.checksumsURL?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertNotNil(release.publishedAt)

        let pre = json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
        XCTAssertThrowsError(try AppRelease.parse(Data(pre.utf8)), "pre-releases are never offered")
    }
}

final class UpdateInstallerTests: XCTestCase {
    func testInstallTargetLeavesDiskImagesAndTranslocation() {
        XCTAssertEqual(UpdateInstaller.installTarget(for: URL(fileURLWithPath: "/Applications/Flowlight.app")).path, "/Applications/Flowlight.app")
        XCTAssertEqual(UpdateInstaller.installTarget(for: URL(fileURLWithPath: "/Users/a/Apps/Flowlight.app")).path, "/Users/a/Apps/Flowlight.app")
        XCTAssertEqual(UpdateInstaller.installTarget(for: URL(fileURLWithPath: "/Volumes/Flowlight/Flowlight.app")).path, "/Applications/Flowlight.app")
        XCTAssertEqual(UpdateInstaller.installTarget(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Flowlight.app")).path,
                       "/Applications/Flowlight.app")
    }

    func testQuoting() {
        XCTAssertEqual(UpdateInstaller.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(UpdateInstaller.appleScriptQuote("say \"hi\" \\"), "\"say \\\"hi\\\" \\\\\"")
    }

    /// Runs the real swap script against a fake install: the old bundle is replaced and no backup is left behind.
    func testSwapScriptReplacesBundle() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Apps/Flowlight.app")
        let staged = root.appendingPathComponent("staging/Flowlight.app")
        for (dir, marker) in [(target, "old"), (staged, "new")] {
            try fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try marker.write(to: dir.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        }
        let script = root.appendingPathComponent("swap.sh")
        try UpdateInstaller.swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // PID 999999 doesn't exist, so the script doesn't wait.
        process.arguments = [script.path, "999999", staged.path, target.path, String(getuid()), "--no-launch"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: target.path + ".previous"))
        XCTAssertFalse(fm.fileExists(atPath: staged.deletingLastPathComponent().path))
        try? fm.removeItem(at: root)
    }
}

final class ReleaseNotesHeadlineTests: XCTestCase {
    func testTakesTheFirstMeaningfulLine() {
        let notes = """
        **Early preview.**

        ### What's new in 0.1.7
        - Setting up HTTPS inspection is one switch, not three steps.
        """
        XCTAssertEqual(ReleaseNotes.headline(notes), "Early preview.")
        XCTAssertEqual(ReleaseNotes.headline("### Fixes\n- Short windows no longer hide the header behind the title bar."),
                       "Short windows no longer hide the header behind the title bar.",
                       "a bare heading like \"Fixes\" is skipped for the line that actually says something")
        XCTAssertNil(ReleaseNotes.headline("v2\n\n- ok"), "nothing long enough to be useful")
    }
}
