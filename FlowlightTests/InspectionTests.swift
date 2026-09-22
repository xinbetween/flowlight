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

final class HTTPStreamParserTests: XCTestCase {
    private func collect(_ parser: HTTPStreamParser) -> () -> [(HTTPHead, HTTPBody)] {
        var out: [(HTTPHead, HTTPBody)] = []
        parser.onMessage = { out.append(($0, $1)) }
        return { out }
    }

    func testContentLengthAndPipelining() {
        let parser = HTTPStreamParser(direction: .request)
        let messages = collect(parser)
        let raw = "POST /v1/messages HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhelloGET /x HTTP/1.1\r\nHost: a\r\n\r\n"
        // Byte by byte, to exercise every split point.
        for byte in Data(raw.utf8) { parser.feed(Data([byte])) }
        XCTAssertEqual(messages().count, 2)
        XCTAssertEqual(messages()[0].0.method, "POST")
        XCTAssertEqual(String(decoding: messages()[0].1.data, as: UTF8.self), "hello")
        XCTAssertEqual(messages()[1].0.target, "/x")
    }

    func testChunkedResponseAndHead() {
        let parser = HTTPStreamParser(direction: .response)
        parser.requestMethods = ["HEAD", "POST"]
        let messages = collect(parser)
        parser.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n".utf8))   // HEAD: no body despite the length
        parser.feed(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nda".utf8))
        parser.feed(Data("ta\r\n6;ext=1\r\n: ping\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(messages().count, 2)
        XCTAssertEqual(messages()[0].1.data.count, 0)
        XCTAssertEqual(String(decoding: messages()[1].1.data, as: UTF8.self), "data: ping")
    }

    func testGzipBodyAndTruncation() throws {
        let text = String(repeating: "{\"type\":\"tool_use\"}", count: 200)
        let gz = try gzip(Data(text.utf8))
        let parser = HTTPStreamParser(direction: .response)
        let messages = collect(parser)
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: \(gz.count)\r\n\r\n".utf8)
        raw.append(gz)
        parser.feed(raw)
        XCTAssertEqual(String(decoding: messages()[0].1.data, as: UTF8.self), text)
        XCTAssertEqual(messages()[0].1.wireSize, gz.count)

        let small = HTTPStreamParser(direction: .request, limit: 4)
        let smallMessages = collect(small)
        small.feed(Data("PUT / HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789".utf8))
        XCTAssertEqual(smallMessages()[0].1.data, Data("0123".utf8))
        XCTAssertTrue(smallMessages()[0].1.truncated)
        XCTAssertEqual(smallMessages()[0].1.wireSize, 10)
    }

    func testUntilCloseAndUpgrade() {
        let parser = HTTPStreamParser(direction: .response)
        let messages = collect(parser)
        parser.feed(Data("HTTP/1.0 200 OK\r\n\r\npartial".utf8))
        XCTAssertEqual(messages().count, 0)
        parser.finish()
        XCTAssertEqual(String(decoding: messages()[0].1.data, as: UTF8.self), "partial")

        let ws = HTTPStreamParser(direction: .response)
        let wsMessages = collect(ws)
        ws.feed(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n\u{81}\u{05}hello".utf8))
        ws.feed(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        XCTAssertEqual(wsMessages().count, 1)
    }

    func testRedaction() {
        let headers = HeaderRedaction.redact([
            HTTPHeader(name: "Authorization", value: "Bearer sk-ant-secret"),
            HTTPHeader(name: "x-api-key", value: "sk-123"),
            HTTPHeader(name: "Cookie", value: "a=b"),
            HTTPHeader(name: "anthropic-version", value: "2023-06-01"),
        ])
        XCTAssertEqual(headers[0].value, "Bearer ••• redacted (20 characters)")
        XCTAssertEqual(headers[1].value, "••• redacted (6 characters)")
        XCTAssertFalse(headers.map(\.value).joined().contains("sk-"))
        XCTAssertEqual(headers[3].value, "2023-06-01")
    }

    private func gzip(_ data: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }
}
