import XCTest
@testable import Flowlight

final class UpdateVerificationTests: XCTestCase {
    private let sums = """
    a3f1c2d4e5b6a7980123456789abcdef0123456789abcdef0123456789abcdef  Flowlight.dmg
    0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff  Flowlight-0.8.2.pkg
    """

    func testAChecksumIsFoundByFileName() {
        XCTAssertEqual(VersionCompare.checksum(for: "Flowlight.dmg", in: sums),
                       "a3f1c2d4e5b6a7980123456789abcdef0123456789abcdef0123456789abcdef")
    }

    /// The case that made the old check useless: a checksum file that says nothing about this file. It used to
    /// read as "no expectation, so anything matches"; the download path now treats nil as a refusal.
    func testAMissingEntryIsNilRatherThanAMatch() {
        XCTAssertNil(VersionCompare.checksum(for: "Flowlight.dmg", in: "not a checksum file at all"))
        XCTAssertNil(VersionCompare.checksum(for: "Something-Else.dmg", in: sums))
    }

    /// An update signed by somebody else is the attack this exists to stop, so the two failures have to be
    /// distinguishable — "signed by another team" is a different event from "signature damaged".
    func testTheTeamMismatchIsReportedAsItself() throws {
        let failure = CodeSignatureCheck.Failure.wrongTeam(found: "ATTACKER99", expected: "ABCDE12345")
        XCTAssertEqual(failure, .wrongTeam(found: "ATTACKER99", expected: "ABCDE12345"))
        XCTAssertNotEqual(failure, .notSigned)
        let description = try XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(description.contains("ATTACKER99"))
        XCTAssertTrue(description.contains("ABCDE12345"))
    }

    /// Verification has to fail on a bundle that isn't signed at all, rather than passing it for lack of a
    /// signature to disagree with. `/bin` is a real path that is not a signed app bundle.
    func testAnUnsignedPathDoesNotVerify() {
        XCTAssertThrowsError(try CodeSignatureCheck.verify(URL(fileURLWithPath: "/bin"), expectedTeam: "ABCDE12345"))
    }

    /// The running app is what decides which team an update must carry. On a signed build this is the Team ID;
    /// on an ad-hoc local build it is nil, and the installer refuses rather than guessing.
    func testTheExpectedTeamComesFromTheRunningApp() {
        // Either answer is correct depending on how the tests were built; what matters is that asking is safe
        // and that nil is an answer the caller has to handle rather than a crash.
        let team = CodeSignatureCheck.runningTeamIdentifier()
        if let team { XCTAssertFalse(team.isEmpty) }
    }
}
