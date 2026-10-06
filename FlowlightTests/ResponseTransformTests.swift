import Network
import XCTest
@testable import Flowlight

final class ResponseTransformRuleTests: XCTestCase {
    private func exchange(path: String = "/v1/items?token=secret") -> HTTPExchange {
        HTTPExchange(
            id: 1, started: Date(), duration: 0, scheme: "https", host: "api.example.com", port: 443,
            method: "POST", path: path, status: 200,
            requestHeaders: [
                HTTPHeader(name: "Authorization", value: "••• (12 chars)"),
                HTTPHeader(name: "X-Request-ID", value: "public"),
            ],
            requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [HTTPHeader(name: "Content-Type", value: "application/json")],
            responseBody: Data(), responseSize: 0, responseTruncated: false, contentType: "application/json",
            pid: 1, bundleID: "test", appName: "Test", agent: nil, agentName: nil, mcpServer: nil, toolCalls: []
        )
    }

    func testPrefillPopulatesMatcherAndJSONTemplateWithoutCapturingBody() {
        let draft = ResponseTransformDraft(exchange: exchange(), responseBody: Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(draft.rule.name, "Transform POST api.example.com/v1/items")
        XCTAssertEqual(draft.rule.host, "api.example.com")
        XCTAssertEqual(draft.rule.path, "/v1/items")
        XCTAssertEqual(draft.rule.method, "POST")
        XCTAssertTrue(draft.rule.script.contains("responseJSON"))
        XCTAssertNil(draft.unavailableReason)
        XCTAssertEqual(draft.representation, .json)
    }

    func testTextPrefillAndUnavailableBodyStillPopulateEveryMatcherField() {
        var textExchange = exchange(path: "/status")
        textExchange.responseHeaders = [HTTPHeader(name: "Content-Type", value: "text/plain")]
        let text = ResponseTransformDraft(exchange: textExchange, responseBody: Data("ready".utf8))
        XCTAssertEqual(text.representation, .text)
        XCTAssertTrue(text.rule.script.contains("responseText"))

        let unavailable = ResponseTransformDraft(exchange: exchange(), responseBody: nil)
        XCTAssertEqual(unavailable.rule.host, "api.example.com")
        XCTAssertEqual(unavailable.rule.path, "/v1/items")
        XCTAssertEqual(unavailable.rule.method, "POST")
        XCTAssertNotNil(unavailable.unavailableReason)

        var chunked = exchange()
        chunked.responseHeaders = [HTTPHeader(name: "Transfer-Encoding", value: "chunked")]
        XCTAssertEqual(ResponseTransformDraft(exchange: chunked, responseBody: Data("text".utf8)).unavailableReason,
                       L("This response was streamed or chunked, so Flowlight cannot safely transform it."))
    }

    func testRulesAreOrderedAndRequestContextExcludesCredentials() {
        let first = ResponseTransformRule(name: "First", host: "api.example.com", path: "/v1/*", method: "POST", script: "x")
        let second = ResponseTransformRule(name: "Second", host: "*.example.com", path: "*", script: "x")
        XCTAssertEqual(ResponseTransformRules.applicable([first, second], host: "api.example.com", method: "POST", path: "/v1/items").map(\.name), ["First", "Second"])

        let request = ResponseTransformRequest(
            head: HTTPHead(startLine: "GET /v1/items?token=abc&lang=en HTTP/1.1", headers: [
                HTTPHeader(name: "Authorization", value: "Bearer private"),
                HTTPHeader(name: "X-API-Key", value: "private"),
                HTTPHeader(name: "Accept", value: "application/json"),
            ]),
            host: "api.example.com", scheme: "https", port: 443
        )
        XCTAssertEqual(request.headers, ["Accept": "application/json"])
        XCTAssertTrue(request.url.contains("token=%E2%80%A2%E2%80%A2%E2%80%A2"))
        XCTAssertTrue(request.url.contains("lang=en"))
    }

    func testBundledRunnerAppliesJSONAndTextScripts() {
        let request = ResponseTransformRequest(
            head: HTTPHead(startLine: "GET /items HTTP/1.1", headers: []), host: "api.example.com", scheme: "https", port: 443
        )
        let jsonRule = ResponseTransformRule(host: "api.example.com", script: "function modifyResponse(args) { args.responseJSON.changed = true; return args.responseJSON; }")
        let jsonHead = HTTPHead(startLine: "HTTP/1.1 200 OK", headers: [HTTPHeader(name: "Content-Type", value: "application/json")])
        let json = ResponseScriptRunner.shared.transform(rules: [jsonRule], request: request, responseHead: jsonHead, responseBody: Data(#"{"live":true}"#.utf8))
        let jsonObject = try! XCTUnwrap(json).body
        XCTAssertEqual(try! JSONSerialization.jsonObject(with: jsonObject) as? [String: Bool], ["live": true, "changed": true])

        let textRule = ResponseTransformRule(host: "api.example.com", script: "function modifyResponse(args) { return args.responseText.toUpperCase(); }")
        let textHead = HTTPHead(startLine: "HTTP/1.1 200 OK", headers: [HTTPHeader(name: "Content-Type", value: "text/plain")])
        let text = ResponseScriptRunner.shared.transform(rules: [textRule], request: request, responseHead: textHead, responseBody: Data("ready".utf8))
        XCTAssertEqual(String(decoding: try! XCTUnwrap(text).body, as: UTF8.self), "READY")
    }

    func testRunnerWithholdsCredentialsAndFailsOpenForBrokenOrSlowScripts() {
        let secretRequest = ResponseTransformRequest(
            head: HTTPHead(startLine: "GET /items?token=secret HTTP/1.1", headers: [
                HTTPHeader(name: "Authorization", value: "Bearer private"),
                HTTPHeader(name: "Accept", value: "text/plain"),
            ]),
            host: "api.example.com", scheme: "https", port: 443
        )
        let textHead = HTTPHead(startLine: "HTTP/1.1 200 OK", headers: [HTTPHeader(name: "Content-Type", value: "text/plain")])
        let credentialProbe = ResponseTransformRule(host: "api.example.com", script: "function modifyResponse(args) { return args.requestHeaders.Authorization ? 'leaked' : args.url; }")
        let safe = ResponseScriptRunner.shared.transform(rules: [credentialProbe], request: secretRequest, responseHead: textHead, responseBody: Data("original".utf8))
        XCTAssertEqual(String(decoding: try! XCTUnwrap(safe).body, as: UTF8.self), "https://api.example.com/items?token=%E2%80%A2%E2%80%A2%E2%80%A2")

        let malformed = ResponseTransformRule(host: "api.example.com", script: "function modifyResponse( {")
        XCTAssertNil(ResponseScriptRunner.shared.transform(rules: [malformed], request: secretRequest, responseHead: textHead, responseBody: Data("original".utf8)))

        let slow = ResponseTransformRule(host: "api.example.com", script: "function modifyResponse(args) { while (true) {} }")
        let started = Date()
        XCTAssertNil(ResponseScriptRunner.shared.transform(rules: [slow], request: secretRequest, responseHead: textHead, responseBody: Data("original".utf8)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a slow response script must not stall the proxy")
    }

    func testPartialRuleDecodesAndResponseRepresentationRequiresValidBody() throws {
        let rule = try JSONDecoder().decode(ResponseTransformRule.self, from: Data(#"{"host":"api.example.com"}"#.utf8))
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.path, "*")
        XCTAssertEqual(rule.script, "")
        XCTAssertEqual(ResponseRepresentation.detect(headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: Data("not json".utf8)), nil)
        XCTAssertEqual(ResponseRepresentation.detect(headers: [HTTPHeader(name: "Content-Type", value: "text/plain")], body: Data("text".utf8)), .text)
        XCTAssertNil(ResponseRepresentation.detect(headers: [], body: Data([0xFF])))
    }
}

final class ResponseGateTests: XCTestCase {
    private func run(_ request: String, _ chunks: [String], transform: @escaping (ResponseGate.Context, HTTPHead, Data) -> ResponseGate.Replacement? = { _, _, _ in nil }) -> (wire: String, notes: [String]) {
        let gate = ResponseGate(transform: transform)
        gate.clientSent(Data(request.utf8))
        var wire = Data(), notes: [String] = []
        for chunk in chunks {
            for (bytes, note) in gate.serverSent(Data(chunk.utf8)) {
                wire.append(bytes)
                if let note { notes.append(note) }
            }
        }
        return (String(decoding: wire, as: UTF8.self), notes)
    }

    func testReframesTransformedFixedResponseAndProtectsHeaderBoundaries() {
        let request = "GET /items HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nConnection: keep-alive\r\nX-Unsafe: fine\r\n\r\nreal"
        let result = run(request, [String(response.prefix(31)), String(response.dropFirst(31))]) { _, _, body in
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "real")
            return ResponseGate.Replacement(body: Data("changed".utf8), note: "edit")
        }
        XCTAssertEqual(result.notes, ["edit"])
        XCTAssertTrue(result.wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(result.wire.contains("Content-Length: 7\r\n"))
        XCTAssertFalse(result.wire.contains("Connection:"))
        XCTAssertFalse(result.wire.contains("Content-Length: 4"))
        XCTAssertTrue(result.wire.hasSuffix("\r\n\r\nchanged"))
    }

    func testInterimResponseDoesNotConsumeRequestAndPipelinedResponsesStayOrdered() {
        let first = "GET /first HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let second = "GET /second HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let response = "HTTP/1.1 100 Continue\r\n\r\n" +
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na" +
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb"
        var paths: [String] = []
        let result = run(first + second, [response]) { context, _, body in
            paths.append(context.head.target)
            return ResponseGate.Replacement(body: Data((String(decoding: body, as: UTF8.self).uppercased()).utf8), note: context.head.target)
        }
        XCTAssertEqual(paths, ["/first", "/second"])
        XCTAssertEqual(result.notes, ["/first", "/second"])
        XCTAssertTrue(result.wire.contains("\r\n\r\nAHTTP/1.1 200 OK"))
        XCTAssertTrue(result.wire.hasSuffix("\r\n\r\nB"))
    }

    func testUnmatchedFixedResponseStreamsWithoutHoldingOrRunningScript() {
        let request = "GET /unmatched HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let head = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n"
        let gate = ResponseGate(transform: { _, _, _ in XCTFail("unmatched response must not run script"); return nil }, shouldTransform: { _ in false })
        gate.clientSent(Data(request.utf8))
        XCTAssertEqual(String(decoding: gate.serverSent(Data(head.utf8)).first!.0, as: UTF8.self), head)
        XCTAssertEqual(String(decoding: gate.serverSent(Data("real".utf8)).first!.0, as: UTF8.self), "real")
    }

    func testUnmatchedChunkedResponseWithContentLengthRemainsOpaque() {
        let request = "GET /stream HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n"
        let body = "4\r\nreal\r\n0\r\n\r\n"
        let gate = ResponseGate(transform: { _, _, _ in XCTFail("unmatched response must not run script"); return nil }, shouldTransform: { _ in false })
        gate.clientSent(Data(request.utf8))
        XCTAssertEqual(String(decoding: gate.serverSent(Data(head.utf8)).first!.0, as: UTF8.self), head)
        XCTAssertEqual(String(decoding: gate.serverSent(Data(body.utf8)).first!.0, as: UTF8.self), body)
    }

    func testChunkedResponsePassesThroughByteForByteWithoutRunningScript() {
        let request = "GET /events HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nreal\r\n0\r\nTrailer: x\r\n\r\n"
        let result = run(request, [response]) { _, _, _ in XCTFail("chunked response must not be held"); return nil }
        XCTAssertEqual(result.wire, response)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testCompressedFixedResponsePassesThroughThenLaterResponseCanTransform() {
        let first = "GET /compressed HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let second = "GET /plain HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 4\r\n\r\ngzip" +
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        let result = run(first + second, [response]) { context, _, body in
            guard context.head.target == "/plain" else { XCTFail("compressed response must not run script"); return nil }
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
            return ResponseGate.Replacement(body: Data("yes".utf8), note: "plain")
        }
        XCTAssertTrue(result.wire.hasPrefix("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 4\r\n\r\ngzip"))
        XCTAssertTrue(result.wire.hasSuffix("Content-Length: 3\r\n\r\nyes"))
        XCTAssertEqual(result.notes, ["plain"])
    }

    func testHeadAndNoContentResponsesAreNotTransformed() {
        let head = run("HEAD / HTTP/1.1\r\nHost: api.example.com\r\n\r\n", ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"]) { _, _, _ in XCTFail(); return nil }
        XCTAssertEqual(head.wire, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
        let noContent = run("GET / HTTP/1.1\r\nHost: api.example.com\r\n\r\n", ["HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"]) { _, _, _ in XCTFail(); return nil }
        XCTAssertEqual(noContent.wire, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
    }
}

final class ResponseTransformProxyTests: XCTestCase {
    private func startUpstream(reached: @escaping () -> Void) throws -> (NWListener, UInt16) {
        let queue = DispatchQueue(label: "response-transform-upstream")
        let upstream = try NWListener(using: .tcp)
        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data, !data.isEmpty { reached() }
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"live\":true}".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "upstream ready")
        upstream.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        upstream.start(queue: queue)
        wait(for: [ready], timeout: 10)
        return (upstream, upstream.port!.rawValue)
    }

    private func curl(_ url: String, proxyPort: UInt16) -> (status: String, body: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "--max-time", "20", "-x", "http://127.0.0.1:\(proxyPort)", "-w", "\\n%{http_code}", url]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try? task.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        var parts = text.components(separatedBy: "\n")
        return (parts.popLast() ?? "", parts.joined(separator: "\n"))
    }

    func testProxyReachesOriginButClientAndRecorderSeeReplacement() throws {
        var reached = false
        let (upstream, upstreamPort) = try startUpstream { reached = true }
        defer { upstream.cancel() }
        let recorder = InspectionRecorder()
        let recorded = expectation(description: "recorded transformed response")
        var exchange: HTTPExchange?
        recorder.onExchange = { exchange = $0; recorded.fulfill() }
        let proxy = InspectionProxy()
        proxy.observer = recorder
        proxy.responseInterventions = { _ in
            ResponseGate.Intervention(
                transform: { _, _, body in
                    XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"live":true}"#)
                    return ResponseGate.Replacement(body: Data(#"{"changed":true}"#.utf8), note: "Test response transform")
                },
                shouldTransform: { _ in true }
            )
        }
        let ready = expectation(description: "proxy ready")
        proxy.onStateChange = { _ in if proxy.port != nil { ready.fulfill() } }
        proxy.start(port: 0)
        wait(for: [ready], timeout: 10)
        defer { proxy.stop() }

        let result = curl("http://127.0.0.1:\(upstreamPort)/items", proxyPort: try XCTUnwrap(proxy.port))
        wait(for: [recorded], timeout: 15)
        XCTAssertTrue(reached)
        XCTAssertEqual(result.status, "200")
        XCTAssertEqual(result.body, #"{"changed":true}"#)
        XCTAssertEqual(exchange?.responseTransform, "Test response transform")
        XCTAssertEqual(String(decoding: exchange?.responseBody ?? Data(), as: UTF8.self), #"{"changed":true}"#)
    }
}

final class ResponseTransformProvenanceTests: XCTestCase {
    func testRecorderAndDatabaseKeepResponseTransformSeparateFromMockAndGuardrail() throws {
        let recorder = InspectionRecorder()
        let recorded = expectation(description: "recorded")
        var exchange: HTTPExchange?
        recorder.onExchange = { exchange = $0; recorded.fulfill() }
        let flow = ProxyFlow(host: "api.example.com", port: 443, clientPort: 1, inspected: true, scheme: "https")
        recorder.flowStarted(flow)
        recorder.flow(flow, clientSent: Data("GET /items HTTP/1.1\r\nHost: api.example.com\r\n\r\n".utf8))
        recorder.flow(flow, responseTransformedBy: "Rewrite status")
        recorder.flow(flow, serverSent: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
        wait(for: [recorded], timeout: 5)
        XCTAssertEqual(exchange?.responseTransform, "Rewrite status")
        XCTAssertNil(exchange?.mockRule)
        XCTAssertNil(exchange?.guardrail)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("response-transform-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        try db.insertExchange(try XCTUnwrap(exchange))
        let stored = try XCTUnwrap(db.exchanges(since: .distantPast).first)
        XCTAssertEqual(stored.responseTransform, "Rewrite status")
        XCTAssertNil(stored.mockRule)
        XCTAssertNil(stored.guardrail)
    }
}
