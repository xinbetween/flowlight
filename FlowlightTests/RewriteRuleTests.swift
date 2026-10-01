import XCTest
@testable import Flowlight

/// Rewriting an outgoing request is pure data work — these exercise it without a proxy. The framing has to stay
/// correct (Content-Length must agree with the body) or the connection would hang, so several checks assert on it.
final class RewriteRuleTests: XCTestCase {
    private func request(_ method: String, _ target: String, headers: [String] = [], body: String = "") -> Data {
        var s = "\(method) \(target) HTTP/1.1\r\n"
        for h in headers { s += h + "\r\n" }
        if !body.isEmpty { s += "Content-Length: \(body.utf8.count)\r\n" }
        s += "\r\n" + body
        return Data(s.utf8)
    }

    private func parts(_ data: Data) -> (head: [String], body: String) {
        let sep = data.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: data[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        return (head, String(decoding: data[sep.upperBound...], as: UTF8.self))
    }

    private func bodyJSON(_ data: Data) -> [String: Any] {
        let sep = data.range(of: Data("\r\n\r\n".utf8))!
        return (try? JSONSerialization.jsonObject(with: Data(data[sep.upperBound...]))) as? [String: Any] ?? [:]
    }

    private func apply(_ rule: RewriteRule, _ data: Data, host: String = "api.example.com", method: String = "POST", path: String = "/v1/messages") -> Data? {
        RewriteRules.apply([rule], to: data, host: host, method: method, path: path)?.data
    }

    // MARK: Headers

    /// `set` replaces an existing header rather than duplicating it.
    func testHeaderSetReplaces() throws {
        let rule = RewriteRule(host: "api.example.com", headers: [HeaderEdit(op: .set, name: "Authorization", value: "Bearer new")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", headers: ["Authorization: Bearer old"])))
        let auth = parts(out).head.filter { $0.lowercased().hasPrefix("authorization:") }
        XCTAssertEqual(auth, ["Authorization: Bearer new"])
    }

    /// `add` appends and keeps what was there.
    func testHeaderAddAppends() throws {
        let rule = RewriteRule(host: "api.example.com", headers: [HeaderEdit(op: .add, name: "X-Trace", value: "1")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", headers: ["X-Trace: 0"])))
        XCTAssertEqual(parts(out).head.filter { $0.hasPrefix("X-Trace:") }, ["X-Trace: 0", "X-Trace: 1"])
    }

    /// `remove` drops the header.
    func testHeaderRemove() throws {
        let rule = RewriteRule(host: "api.example.com", headers: [HeaderEdit(op: .remove, name: "Cookie")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", headers: ["Cookie: a=b"])))
        XCTAssertFalse(parts(out).head.contains { $0.lowercased().hasPrefix("cookie:") })
    }

    /// A newline in a header value can't forge a second header or request.
    func testHeaderValueIsSanitised() throws {
        let rule = RewriteRule(host: "api.example.com", headers: [HeaderEdit(op: .set, name: "X-Evil", value: "ok\r\nInjected: yes")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages")))
        XCTAssertFalse(parts(out).head.contains { $0.lowercased().hasPrefix("injected:") })
    }

    // MARK: Body

    /// Setting a scalar parses it as JSON (a number stays a number), and Content-Length is recomputed.
    func testBodySetNumberAndReframes() throws {
        let rule = RewriteRule(host: "api.example.com", body: [BodyEdit(op: .set, path: "temperature", value: "0.2")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", body: #"{"model":"x","temperature":0.9}"#)))
        XCTAssertEqual(bodyJSON(out)["temperature"] as? Double, 0.2)
        let cl = parts(out).head.first { $0.lowercased().hasPrefix("content-length:") }!
        let declared = Int(cl.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))!
        let actual = String(decoding: out[out.range(of: Data("\r\n\r\n".utf8))!.upperBound...], as: UTF8.self).utf8.count
        XCTAssertEqual(declared, actual, "Content-Length must agree with the rewritten body")
    }

    /// An unquoted value that isn't valid JSON is taken as a plain string.
    func testBodySetStringFallback() throws {
        let rule = RewriteRule(host: "api.example.com", body: [BodyEdit(op: .set, path: "model", value: "claude-opus")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", body: #"{"model":"x"}"#)))
        XCTAssertEqual(bodyJSON(out)["model"] as? String, "claude-opus")
    }

    /// A nested path is created if it isn't there.
    func testBodySetNestedCreatesPath() throws {
        let rule = RewriteRule(host: "api.example.com", body: [BodyEdit(op: .set, path: "metadata.user", value: #""alice""#)])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", body: #"{"model":"x"}"#)))
        XCTAssertEqual((bodyJSON(out)["metadata"] as? [String: Any])?["user"] as? String, "alice")
    }

    /// `remove` deletes the leaf.
    func testBodyRemove() throws {
        let rule = RewriteRule(host: "api.example.com", body: [BodyEdit(op: .remove, path: "stream")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/v1/messages", body: #"{"model":"x","stream":true}"#)))
        XCTAssertNil(bodyJSON(out)["stream"])
        XCTAssertEqual(bodyJSON(out)["model"] as? String, "x")
    }

    /// A non-JSON body is left alone while header edits still apply.
    func testNonJSONBodyKeepsBodyButEditsHeaders() throws {
        let rule = RewriteRule(host: "api.example.com",
                               headers: [HeaderEdit(op: .set, name: "X-Tag", value: "1")],
                               body: [BodyEdit(op: .set, path: "model", value: "y")])
        let out = try XCTUnwrap(apply(rule, request("POST", "/form", headers: [], body: "a=1&b=2"), path: "/form"))
        XCTAssertEqual(parts(out).body, "a=1&b=2")
        XCTAssertTrue(parts(out).head.contains("X-Tag: 1"))
    }

    // MARK: Matching

    /// A rule for another host, method or path doesn't touch the request.
    func testNonMatchIsNil() {
        let rule = RewriteRule(host: "other.example.com", headers: [HeaderEdit(op: .set, name: "X", value: "1")])
        XCTAssertNil(apply(rule, request("POST", "/v1/messages")))
        let m = RewriteRule(host: "api.example.com", method: "GET", headers: [HeaderEdit(op: .set, name: "X", value: "1")])
        XCTAssertNil(apply(m, request("POST", "/v1/messages")))
        let p = RewriteRule(host: "api.example.com", path: "/other/*", headers: [HeaderEdit(op: .set, name: "X", value: "1")])
        XCTAssertNil(apply(p, request("POST", "/v1/messages")))
    }

    /// A disabled rule, or one with no effective edits, changes nothing.
    func testNoChangeIsNil() {
        let disabled = RewriteRule(enabled: false, host: "api.example.com", headers: [HeaderEdit(op: .set, name: "X", value: "1")])
        XCTAssertNil(apply(disabled, request("POST", "/v1/messages")))
        let empty = RewriteRule(host: "api.example.com")
        XCTAssertNil(apply(empty, request("POST", "/v1/messages")))
    }

    /// Old stored rules with fields missing still decode.
    func testDecodesWithMissingFields() throws {
        let json = Data(#"{"host":"api.example.com"}"#.utf8)
        let rule = try JSONDecoder().decode(RewriteRule.self, from: json)
        XCTAssertEqual(rule.host, "api.example.com")
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.path, "*")
        XCTAssertTrue(rule.headers.isEmpty)
    }
}
