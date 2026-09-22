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

final class ProxyRequestHeadTests: XCTestCase {
    func testConnectAuthority() throws {
        let head = try XCTUnwrap(ProxyRequestHead.parse(Data("CONNECT API.Anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n".utf8)))
        XCTAssertEqual(head.method, "CONNECT")
        XCTAssertEqual(head.authority?.0, "api.anthropic.com")
        XCTAssertEqual(head.authority?.1, 443)
        XCTAssertEqual(ProxyRequestHead.parse(Data("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n".utf8))?.authority?.0, "2001:db8::1")
        XCTAssertEqual(ProxyRequestHead.parse(Data("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n".utf8))?.authority?.1, 8443)
        XCTAssertNil(ProxyRequestHead.parse(Data("CONNECT :0 HTTP/1.1\r\n\r\n".utf8))?.authority)
        XCTAssertNil(ProxyRequestHead.parse(Data("garbage\r\n\r\n".utf8)))
    }

    func testOriginFormDropsProxyHeaders() throws {
        let head = try XCTUnwrap(ProxyRequestHead.parse(Data(
            "GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\nAccept: */*\r\n\r\n".utf8)))
        XCTAssertEqual(String(decoding: head.originForm(), as: UTF8.self),
                       "GET /a/b?q=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n")
    }
}
