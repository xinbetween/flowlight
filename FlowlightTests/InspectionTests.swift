import Security
import XCTest
@testable import Flowlight

final class CertificateAuthorityTests: XCTestCase {
    func testCreatesCAAndLeafIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = CertificateAuthority(directory: dir)
        try ca.ensure()
        XCTAssertTrue(ca.exists)
        XCTAssertNotNil(ca.fingerprint)
        let bundle = try String(contentsOf: ca.bundleURL, encoding: .utf8)
        XCTAssertTrue(bundle.contains(try String(contentsOf: ca.caCertificateURL, encoding: .utf8)))

        let identity = try ca.identity(for: "api.example.com")
        var cert: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &cert), errSecSuccess)
        XCTAssertEqual(SecCertificateCopySubjectSummary(cert!) as String?, "api.example.com")
        // Cached: the same identity object comes back.
        XCTAssertTrue(try ca.identity(for: "API.example.com") === identity)
        XCTAssertNoThrow(try ca.identity(for: "203.0.113.7"))
    }

    func testConfigSafeStripsInjection() {
        XCTAssertEqual(CertificateAuthority.configSafe("evil.com\n[v3_ca]\nbasicConstraints=CA:TRUE"), "evil.comv3_cabasicConstraintsCA:TRUE")
    }
}
