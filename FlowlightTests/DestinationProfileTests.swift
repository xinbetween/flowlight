import XCTest
@testable import Flowlight

final class DestinationProfileTests: XCTestCase {
    private func row(_ bundleID: String, domain: String = "", ip: String = "1.2.3.4", protocols: String = "https",
                     owner: String = "", out: Int64 = 0, into: Int64 = 0) -> BreakdownRow {
        BreakdownRow(bundleID: bundleID, appName: bundleID.split(separator: ".").last.map(String.init) ?? bundleID,
                     appPath: "/Applications/\(bundleID).app", domain: domain, remoteIP: ip, ports: "443",
                     protocols: protocols, counters: FlowCounters(bytesIn: into, bytesOut: out, flows: 1), owner: owner)
    }

    /// A few ordinary apps talking to a handful of well-known places shouldn't produce a single finding.
    func testQuietReportProducesNothing() {
        let rows = [row("com.apple.Safari", domain: "www.apple.com", into: 5_000),
                    row("com.apple.Safari", domain: "www.wikipedia.org", into: 8_000),
                    row("com.apple.Mail", domain: "imap.mail.me.com", into: 2_000)]
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty)
    }

    func testSpreadIsJudgedAgainstTheOtherAppsInTheReport() {
        var rows = [row("com.quiet.one", domain: "a.com"), row("com.quiet.two", domain: "b.com")]
        for index in 0..<30 { rows.append(row("com.busy.app", domain: "host\(index).example\(index).com")) }
        let found = DestinationProfile.analyse(rows)
        XCTAssertEqual(found.map(\.bundleID), ["com.busy.app"])
        XCTAssertTrue(found[0].signals.contains { $0.kind == .manyDestinations })
        XCTAssertTrue(found[0].signals.first { $0.kind == .manyDestinations }?.detail.contains("30 destinations") == true,
                      "the finding has to carry the number it was based on")
    }

    /// A handful of unnamed addresses is ordinary — plenty of apps reach a CDN by IP — so on its own it stays
    /// below the floor. Ten of them is a different matter.
    func testAFewAddressesWithNoHostnameAreNotAFinding() {
        let rows = (0..<4).map { row("com.example.tool", ip: "203.0.113.\($0)", owner: "Example Hosting") }
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty)
    }

    func testManyAddressesWithNoHostnameAreReportedWithTheirOwner() {
        let rows = (0..<12).map { row("com.example.tool", ip: "203.0.113.\($0)", owner: "Example Hosting") }
        let signal = DestinationProfile.analyse(rows).first?.signals.first { $0.kind == .hostless }
        XCTAssertEqual(signal?.detail, "12 addresses with no hostname (Example Hosting)")
    }

    /// Loopback and link-local chatter is not a finding.
    func testLocalAddressesAreIgnored() {
        let rows = [row("com.example.tool", ip: "127.0.0.1"), row("com.example.tool", ip: "fe80::1"),
                    row("com.example.tool", ip: "224.0.0.251")]
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty)
    }

    func testUploadingFarMoreThanItReceives() {
        let rows = [row("com.example.agent", domain: "paste.example", out: 180_000_000, into: 2_000_000)]
        let signal = DestinationProfile.analyse(rows).first?.signals.first { $0.kind == .mostlyUploading }
        XCTAssertNotNil(signal)
        XCTAssertTrue(signal?.detail.contains("180") == true && signal?.detail.contains("sent") == true)
    }

    func testASmallUploadIsNotAFinding() {
        let rows = [row("com.example.agent", domain: "paste.example", out: 900_000, into: 1_000)]
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty, "a megabyte is normal; the threshold exists for a reason")
    }

    func testSensitiveProtocolsAreNamed() {
        let rows = [row("com.example.editor", domain: "relay.example", protocols: "ssh smtp")]
        let signal = DestinationProfile.analyse(rows).first?.signals.first { $0.kind == .sensitiveProtocol }
        XCTAssertEqual(signal?.detail, "used smtp, ssh")
    }

    /// A mail client sending mail is doing its job. Flagging it is how a list like this stops being read.
    func testAnAppIsNotFlaggedForTheProtocolItExistsToUse() {
        let rows = [row("com.apple.mail", domain: "imap.mail.me.com", protocols: "imaps", into: 50_000_000),
                    row("com.apple.mail", domain: "smtp.mail.me.com", protocols: "smtp-submission", out: 8_000_000)]
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty)
    }

    /// The same protocol as a sideline is exactly what's worth knowing about.
    func testASensitiveProtocolIsFlaggedWhenItIsNotWhatTheAppMostlyDoes() {
        let rows = [row("com.example.editor", domain: "api.example.com", protocols: "https", into: 200_000_000),
                    row("com.example.editor", domain: "relay.example", protocols: "smtp", out: 40_000)]
        let signal = DestinationProfile.analyse(rows).first?.signals.first { $0.kind == .sensitiveProtocol }
        XCTAssertEqual(signal?.detail, "used smtp")
    }

    func testFindingsAreRankedByScore() {
        var rows = [row("com.mild.app", domain: "x.example", protocols: "ssh")]
        for index in 0..<20 { rows.append(row("com.loud.app", domain: "h\(index).site\(index).com", protocols: "smtp")) }
        rows.append(row("com.loud.app", ip: "203.0.113.9"))
        rows.append(row("com.loud.app", ip: "203.0.113.8"))
        rows.append(row("com.loud.app", ip: "203.0.113.7"))
        let found = DestinationProfile.analyse(rows)
        XCTAssertEqual(found.first?.bundleID, "com.loud.app")
        XCTAssertGreaterThan(found.first!.score, found.last!.score)
    }

    // MARK: Generated-name heuristic

    func testOrdinaryHostnamesAreNotCalledGenerated() {
        for domain in ["google.com", "cloudfront.net", "githubusercontent.com", "anthropic.com", "wikipedia.org"] {
            XCTAssertFalse(DestinationProfile.looksGenerated(domain), "\(domain) is a word, not a generated string")
        }
    }

    func testMachineLookingNamesAreCaught() {
        XCTAssertTrue(DestinationProfile.looksGenerated("x7f2k9q1vz8m.com"), "no vowels")
        XCTAssertTrue(DestinationProfile.looksGenerated("a1b2c3d4e5f6.net"), "mostly digits")
    }

    func testShortNamesAreNeverGenerated() {
        XCTAssertFalse(DestinationProfile.looksGenerated("bit.ly"))
        XCTAssertFalse(DestinationProfile.looksGenerated("x.com"))
    }

    func testEntropyRanksRandomAboveWords() {
        XCTAssertLessThan(DestinationProfile.entropy(of: "cloudfront"), DestinationProfile.entropy(of: "x7f2k9q1vz"))
    }

    func testRowsWithoutABundleIDAreSkipped() {
        XCTAssertTrue(DestinationProfile.analyse([row("", domain: "a.com"), row("", ip: "203.0.113.1")]).isEmpty)
    }

    func testSubdomainsCollapseToOneDestination() {
        let rows = (0..<12).map { row("com.example.cdn", domain: "shard\($0).cdn.example.com") }
        XCTAssertEqual(DestinationProfile.distinctDomains(rows), ["example.com"])
        XCTAssertTrue(DestinationProfile.analyse(rows).isEmpty, "one CDN is one destination, not twelve")
    }
}
