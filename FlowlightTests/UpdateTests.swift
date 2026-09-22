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
