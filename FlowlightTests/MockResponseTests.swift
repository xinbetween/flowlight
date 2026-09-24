import Network
import XCTest
@testable import Flowlight

final class MockRuleMatchingTests: XCTestCase {
    private func rule(_ host: String, _ path: String = "*", _ method: String = "", enabled: Bool = true) -> MockRule {
        MockRule(enabled: enabled, host: host, path: path, method: method)
    }

    func testHostExactAndWildcard() {
        XCTAssertTrue(MockRules.hostMatches("api.example.com", "api.example.com"))
        XCTAssertTrue(MockRules.hostMatches("API.Example.com", "api.example.com"))
        // An exact host is exactly that host: a rule for the API must not answer for the marketing site.
        XCTAssertFalse(MockRules.hostMatches("example.com", "api.example.com"))
        XCTAssertFalse(MockRules.hostMatches("api.example.com", "api.example.com.evil.test"))
        XCTAssertTrue(MockRules.hostMatches("*.example.com", "api.example.com"))
        XCTAssertTrue(MockRules.hostMatches("*.example.com", "example.com"))
        XCTAssertTrue(MockRules.hostMatches("*.example.com", "a.b.example.com"))
        XCTAssertFalse(MockRules.hostMatches("*.example.com", "notexample.com"))
        // A rule in progress answers nothing rather than everything.
        XCTAssertFalse(MockRules.hostMatches("", "api.example.com"))
        XCTAssertFalse(MockRules.hostMatches("*.", "api.example.com"))
    }

    func testPathGlob() {
        XCTAssertTrue(MockRules.pathMatches("/v1/messages", "/v1/messages"))
        XCTAssertFalse(MockRules.pathMatches("/v1/messages", "/v1/messages/2"))
        XCTAssertTrue(MockRules.pathMatches("/v1/*", "/v1/messages/2"))
        XCTAssertTrue(MockRules.pathMatches("*", "/anything?at=all"))
        XCTAssertTrue(MockRules.pathMatches("/v1/*/items", "/v1/42/items"))
        XCTAssertFalse(MockRules.pathMatches("/v1/*/items", "/v1/42/items/7"))
        XCTAssertTrue(MockRules.pathMatches("*/items", "/v1/42/items"))
        // A wildcard may match nothing at all.
        XCTAssertTrue(MockRules.pathMatches("/a*b", "/ab"))
        XCTAssertFalse(MockRules.pathMatches("/aa*aa", "/aaa"))
        // The query string is only compared when the pattern mentions it.
        XCTAssertTrue(MockRules.pathMatches("/v1/messages", "/v1/messages?stream=true"))
        XCTAssertTrue(MockRules.pathMatches("/v1/messages?stream=true", "/v1/messages?stream=true"))
        XCTAssertFalse(MockRules.pathMatches("/v1/messages?stream=false", "/v1/messages?stream=true"))
        // A leading slash is optional; an empty pattern means any path.
        XCTAssertTrue(MockRules.pathMatches("v1/messages", "/v1/messages"))
        XCTAssertTrue(MockRules.pathMatches("", "/v1/messages"))
    }

    func testMethod() {
        XCTAssertTrue(MockRules.methodMatches("", "POST"))
        XCTAssertTrue(MockRules.methodMatches("ANY", "DELETE"))
        XCTAssertTrue(MockRules.methodMatches("post", "POST"))
        XCTAssertFalse(MockRules.methodMatches("POST", "GET"))
    }

    func testFirstEnabledMatchWins() {
        let rules = [
            rule("api.example.com", "/v1/items", "GET", enabled: false),
            rule("api.example.com", "/v1/*", "GET"),
            rule("*.example.com", "*"),
        ]
        // The disabled rule is skipped even though it's the most specific.
        XCTAssertEqual(MockRules.match(rules, host: "api.example.com", method: "GET", path: "/v1/items")?.path, "/v1/*")
        // A GET-only rule doesn't answer a POST; the catch-all below it does.
        XCTAssertEqual(MockRules.match(rules, host: "api.example.com", method: "POST", path: "/v1/items")?.host, "*.example.com")
        // Nothing names this host, so the request is untouched.
        XCTAssertNil(MockRules.match(rules, host: "api.other.test", method: "GET", path: "/v1/items"))
        XCTAssertNil(MockRules.match([], host: "api.example.com", method: "GET", path: "/"))
        XCTAssertTrue(MockRules.mocks(rules, host: "api.other.test").isEmpty)
        XCTAssertEqual(MockRules.mocks(rules, host: "api.example.com").count, 2)
    }

    func testTitleAndPrefillFromExchange() {
        XCTAssertEqual(rule("api.example.com", "/v1/*", "GET").title, "GET api.example.com/v1/*")
        XCTAssertEqual(MockRule(name: "Rate limited", host: "a.test").title, "Rate limited")
        let exchange = HTTPExchange(
            id: 1, started: Date(), duration: 0, scheme: "https", host: "api.example.com", port: 443, method: "POST",
            path: "/v1/items?page=2", status: 200, requestHeaders: [], requestBody: Data(), requestSize: 0,
            requestTruncated: false, responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false,
            contentType: "", pid: 1, bundleID: "b", appName: "a", agent: nil, agentName: nil, mcpServer: nil, toolCalls: [])
        let prefilled = MockRule(mocking: exchange)
        XCTAssertEqual(prefilled.host, "api.example.com")
        XCTAssertEqual(prefilled.path, "/v1/items")   // the query is dropped: it rarely identifies the endpoint
        XCTAssertEqual(prefilled.method, "POST")
        XCTAssertTrue(MockRules.matches(prefilled, host: "api.example.com", method: "POST", path: "/v1/items?page=9"))
    }

    func testDecodesAPartialRule() throws {
        let rule = try JSONDecoder().decode(MockRule.self, from: Data(#"{"host": "api.example.com"}"#.utf8))
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.path, "*")
        XCTAssertEqual(rule.status, 500)
        XCTAssertEqual(rule.delay, 0)
        let roundTrip = try JSONDecoder().decode([MockRule].self, from: JSONEncoder().encode([rule]))
        XCTAssertEqual(roundTrip, [rule])
    }
}

final class MockResponseBytesTests: XCTestCase {
    func testWritesItsOwnFraming() {
        let rule = MockRule(host: "a.test", status: 503, headers: [HTTPHeader(name: "Retry-After", value: "30"),
                                                                  HTTPHeader(name: "Content-Length", value: "999")],
                            body: #"{"error":"busy"}"#)
        let text = String(decoding: rule.responseBytes(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        XCTAssertTrue(text.contains("Retry-After: 30\r\n"))
        // Flowlight's own Content-Length replaces whatever the rule said, or the client would hang.
        XCTAssertFalse(text.contains("999"))
        XCTAssertTrue(text.contains("Content-Length: 16\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + #"{"error":"busy"}"#))
    }

    func testStatusesWithoutABodyGetNone() {
        let text = String(decoding: MockRule(host: "a.test", status: 304, body: "ignored").responseBytes(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
        XCTAssertFalse(text.contains("Content-Length"))
        XCTAssertFalse(text.contains("ignored"))
    }

    func testHeaderInjectionIsStripped() {
        let rule = MockRule(name: "evil\r\nX-Injected: 1", host: "a.test", status: 200,
                            headers: [HTTPHeader(name: "X-A\r\nX-B", value: "1\r\nX-C: 2")], body: "")
        let text = String(decoding: rule.responseBytes(), as: UTF8.self)
        // The newlines are gone, so neither the name, the value nor the rule's own title can start a header line.
        XCTAssertFalse(text.contains("\r\nX-Injected"))
        XCTAssertFalse(text.contains("\r\nX-C: 2"))
        XCTAssertTrue(text.contains("X-AX-B: 1X-C: 2\r\n"))
        XCTAssertTrue(text.contains("X-Flowlight-Mock: evilX-Injected: 1\r\n"))
    }

    func testHeaderTextRoundTrip() {
        let headers = MockRule.parseHeaders("Retry-After: 30\nX-Empty:\nnot a header\n: novalue")
        XCTAssertEqual(headers, [HTTPHeader(name: "Retry-After", value: "30"), HTTPHeader(name: "X-Empty", value: "")])
        XCTAssertEqual(MockRule.headerText(headers), "Retry-After: 30\nX-Empty: ")
    }
}

final class MockGateTests: XCTestCase {
    private let rule = MockRule(name: "down", host: "api.example.com", path: "/v1/items", method: "POST", status: 503)

    private func gate(_ rules: [MockRule]? = nil) -> MockGate {
        MockGate(host: "api.example.com", rules: rules ?? [rule])
    }

    /// The bytes a gate would relay upstream, and the rules that answered anything.
    private func run(_ gate: MockGate, _ chunks: [String]) -> (forwarded: String, answered: [String], recorded: String) {
        var forwarded = Data(), answered: [String] = [], recorded = Data()
        for chunk in chunks {
            for action in gate.clientSent(Data(chunk.utf8)) {
                switch action {
                case .forward(let d): forwarded.append(d); recorded.append(d)
                case .hold(let d): recorded.append(d)
                case .answer(let rule, let d, _): answered.append(rule.title); recorded.append(d)
                }
            }
        }
        return (String(decoding: forwarded, as: UTF8.self), answered, String(decoding: recorded, as: UTF8.self))
    }

    func testNonMatchingRequestIsUntouched() {
        let request = "GET /v1/other HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let result = run(gate(), [request])
        XCTAssertEqual(result.forwarded, request)
        XCTAssertTrue(result.answered.isEmpty)
    }

    func testMatchingRequestIsHeldAndAnswered() {
        let request = "POST /v1/items HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 7\r\n\r\nhello!!"
        let result = run(gate(), [request])
        XCTAssertEqual(result.forwarded, "")
        XCTAssertEqual(result.answered, ["down"])
        // Every byte still reaches the recorder, so the request is inspectable even though it never left the Mac.
        XCTAssertEqual(result.recorded, request)
    }

    func testMixedKeepAliveConnection() {
        let first = "GET /v1/other HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let second = "POST /v1/items HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 2\r\n\r\nhi"
        let third = "GET /v1/more HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        // Arriving in one read, split across reads, and split mid-header: the framing has to survive all three.
        let combined = first + second + third
        let split = [String(combined.prefix(30)), String(combined.dropFirst(30).prefix(80)), String(combined.dropFirst(110))]
        for chunks in [[combined], split] {
            let result = run(gate(), chunks)
            XCTAssertEqual(result.forwarded, first + third)
            XCTAssertEqual(result.answered, ["down"])
            XCTAssertEqual(result.recorded, combined)
        }
    }

    func testChunkedBodyIsSwallowedWhole() {
        let mocked = "POST /v1/items HTTP/1.1\r\nHost: api.example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        let next = "GET /v1/after HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let result = run(gate(), [mocked + next])
        XCTAssertEqual(result.forwarded, next)
        XCTAssertEqual(result.answered, ["down"])
        XCTAssertEqual(result.recorded, mocked + next)
    }

    func testDisabledAndOtherHostRulesNeverAnswer() {
        var off = rule
        off.enabled = false
        let request = "POST /v1/items HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 2\r\n\r\nhi"
        let result = run(gate([off]), [request])
        XCTAssertEqual(result.forwarded, request)
        XCTAssertTrue(result.answered.isEmpty)

        // A gate is only built for a host with rules, but one that slips through matches nothing either.
        let elsewhere = MockGate(host: "other.test", rules: [rule])
        XCTAssertEqual(run(elsewhere, [request]).forwarded, request)
    }

    func testUpgradedConnectionIsForwardedUntouched() {
        let upgrade = "GET /socket HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: websocket\r\n\r\n"
        let frames = "\u{81}\u{05}hello"
        let result = run(gate(), [upgrade, frames])
        XCTAssertEqual(result.forwarded, upgrade + frames)
        XCTAssertTrue(result.answered.isEmpty)
    }

    func testMockedRequestIsRecordedAsAnExchange() {
        // The recorder sees the same bytes the gate accounted for, plus the canned response, so the pairing it
        // does for real traffic works unchanged for a mock.
        let recorder = InspectionRecorder()
        var exchanges: [HTTPExchange] = []
        let done = expectation(description: "exchange")
        recorder.onExchange = { exchanges.append($0); done.fulfill() }
        let flow = ProxyFlow(host: "api.example.com", port: 443, clientPort: 1, inspected: true, scheme: "https")
        recorder.flowStarted(flow)
        let answer = MockRule(name: "down", host: "api.example.com", status: 503, body: "nope")
        recorder.flow(flow, mockedBy: answer.title)
        recorder.flow(flow, clientSent: Data("POST /v1/items HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 2\r\n\r\nhi".utf8))
        recorder.flow(flow, serverSent: answer.responseBytes())
        wait(for: [done], timeout: 5)
        XCTAssertEqual(exchanges.first?.mockRule, "down")
        XCTAssertEqual(exchanges.first?.status, 503)
        XCTAssertEqual(exchanges.first?.path, "/v1/items")
    }
}

final class MockRuleStorageTests: XCTestCase {
    func testExchangeRemembersWhichRuleAnsweredIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try TrafficDatabase(url: url)
        var exchange = HTTPExchange(
            id: nil, started: Date(), duration: 0.1, scheme: "https", host: "api.example.com", port: 443, method: "POST",
            path: "/v1/items", status: 503, requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(), responseSize: 0, responseTruncated: false, contentType: "", pid: 1,
            bundleID: "b", appName: "a", agent: nil, agentName: nil, mcpServer: nil, toolCalls: [])
        exchange.mockRule = "down"
        try db.insertExchange(exchange)
        try db.insertExchange(exchange)   // a second row, left real
        var real = exchange
        real.mockRule = nil
        try db.insertExchange(real)
        let rows = try db.exchanges(since: .distantPast)
        XCTAssertEqual(rows.compactMap(\.mockRule), ["down", "down"])
        XCTAssertEqual(rows.count, 3)
    }

    func testControllerReadsWhatItWrote() {
        let defaults = UserDefaults.standard
        let key = InspectionController.Keys.mockRules
        let previous = defaults.data(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        XCTAssertTrue(InspectionController.decodeMockRules(nil).isEmpty)
        XCTAssertTrue(InspectionController.decodeMockRules(Data("not json".utf8)).isEmpty)
        let rules = [MockRule(host: "api.example.com", path: "/v1/*", status: 429)]
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
        XCTAssertEqual(InspectionController.decodeMockRules(defaults.data(forKey: key)), rules)
    }
}

/// The whole path, from a request made by another process to the answer it gets back: the unit tests above cover
/// the decision, this covers the wiring that acts on it.
final class MockProxyTests: XCTestCase {
    /// A stand-in server that answers "real" to anything that reaches it, and says whether anything did.
    private func startUpstream(reached: @escaping () -> Void) throws -> (NWListener, UInt16) {
        // Not the main queue: the test blocks its own thread waiting for curl, which would deadlock the stub.
        let queue = DispatchQueue(label: "test.upstream")
        let upstream = try NWListener(using: .tcp)
        upstream.newConnectionHandler = { conn in
            conn.start(queue: queue)
            // "Reached" means request bytes arrived: the proxy opens the upstream socket either way.
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, !data.isEmpty { reached() }
                conn.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nreal".utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let ready = expectation(description: "upstream ready")
        upstream.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        upstream.start(queue: queue)
        wait(for: [ready], timeout: 10)
        return (upstream, upstream.port!.rawValue)
    }

    private func startProxy(rules: [MockRule], recorder: InspectionRecorder) throws -> (InspectionProxy, UInt16) {
        let proxy = InspectionProxy()
        proxy.observer = recorder
        proxy.mockRules = { _, _ in rules }
        let ready = expectation(description: "proxy ready")
        proxy.onStateChange = { _ in if proxy.port != nil { ready.fulfill() } }
        proxy.start(port: 0)   // any free port: a fixed one would collide with a real Flowlight on this Mac
        wait(for: [ready], timeout: 10)
        return (proxy, try XCTUnwrap(proxy.port))
    }

    /// curl, because the proxy refuses to proxy its own process — as it should, or it would loop.
    private func curl(_ url: String, through proxyPort: UInt16) -> (status: String, body: String, seconds: Double) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "--max-time", "20", "-x", "http://127.0.0.1:\(proxyPort)", "-w", "\n%{http_code}", url]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let started = Date()
        try? task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        var lines = out.components(separatedBy: "\n")
        let status = lines.popLast() ?? ""
        return (status, lines.joined(separator: "\n"), Date().timeIntervalSince(started))
    }

    func testAMatchingRequestIsAnsweredAndRecordedAsMocked() throws {
        var reached = false
        let (upstream, upstreamPort) = try startUpstream { reached = true }
        defer { upstream.cancel() }
        let recorder = InspectionRecorder()
        var recorded: [HTTPExchange] = []
        let seen = expectation(description: "recorded")
        recorder.onExchange = { recorded.append($0); seen.fulfill() }
        let rule = MockRule(name: "down", host: "127.0.0.1", path: "/v1/items", method: "GET", status: 503,
                            headers: [HTTPHeader(name: "Retry-After", value: "30")], body: "mocked!", delay: 0.4)
        let (proxy, proxyPort) = try startProxy(rules: [rule], recorder: recorder)
        defer { proxy.stop() }

        let result = curl("http://127.0.0.1:\(upstreamPort)/v1/items", through: proxyPort)
        wait(for: [seen], timeout: 15)
        XCTAssertEqual(result.status, "503")
        XCTAssertEqual(result.body, "mocked!")
        XCTAssertGreaterThan(result.seconds, 0.3, "the delay is real")
        XCTAssertFalse(reached, "the request must never reach the server")
        XCTAssertEqual(recorded.first?.mockRule, "down")
        XCTAssertEqual(recorded.first?.status, 503)
        XCTAssertEqual(recorded.first?.path, "/v1/items")
        XCTAssertEqual(recorded.first?.responseHeaders.first { $0.name == "Retry-After" }?.value, "30")
    }

    func testEverythingElseOnTheSameHostStillGoesToTheServer() throws {
        var reached = false
        let (upstream, upstreamPort) = try startUpstream { reached = true }
        defer { upstream.cancel() }
        let recorder = InspectionRecorder()
        var recorded: [HTTPExchange] = []
        let seen = expectation(description: "recorded")
        recorder.onExchange = { recorded.append($0); seen.fulfill() }
        let (proxy, proxyPort) = try startProxy(rules: [MockRule(host: "127.0.0.1", path: "/v1/items", status: 503)],
                                                recorder: recorder)
        defer { proxy.stop() }

        let result = curl("http://127.0.0.1:\(upstreamPort)/other", through: proxyPort)
        wait(for: [seen], timeout: 15)
        XCTAssertEqual(result.status, "200")
        XCTAssertEqual(result.body, "real")
        XCTAssertTrue(reached)
        XCTAssertNil(recorded.first?.mockRule)
    }
}
