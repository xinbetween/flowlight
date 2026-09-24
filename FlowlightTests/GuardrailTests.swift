import XCTest
@testable import Flowlight

/// Guardrails: which tools an agent may use. The strongest lever is editing the declaration the agent sends on
/// every turn, so most of this is about getting that edit exactly right — a body that comes out malformed would
/// break the agent rather than restrain it.
final class GuardrailTests: XCTestCase {
    private func body(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func parsed(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Matching

    func testAToolIsNamedDirectly() {
        let guardrail = Guardrail(agent: "claude", tool: "Bash")
        XCTAssertTrue(guardrail.refuses(agent: "claude", server: nil, tool: "bash"))
        XCTAssertFalse(guardrail.refuses(agent: "claude", server: nil, tool: "Read"))
        XCTAssertFalse(guardrail.refuses(agent: "codex", server: nil, tool: "Bash"))
    }

    func testAPatternCoversAFamilyOfTools() {
        let guardrail = Guardrail(tool: "write*")
        XCTAssertTrue(guardrail.refuses(agent: "anyone", server: nil, tool: "write_file"))
        XCTAssertTrue(guardrail.refuses(agent: "anyone", server: nil, tool: "Write"))
        XCTAssertFalse(guardrail.refuses(agent: "anyone", server: nil, tool: "read_file"))
    }

    func testAServerWithNoToolNamedRefusesAllOfIt() {
        let guardrail = Guardrail(server: "github")
        XCTAssertTrue(guardrail.refuses(agent: "claude", server: "github", tool: "create_issue"))
        XCTAssertFalse(guardrail.refuses(agent: "claude", server: "gitlab", tool: "create_issue"))
    }

    func testAGuardrailThatNamesNothingRefusesNothing() {
        let guardrail = Guardrail(agent: "claude")
        XCTAssertFalse(guardrail.isComplete)
        XCTAssertFalse(guardrail.refuses(agent: "claude", server: nil, tool: "Bash"))
    }

    // MARK: Editing the declaration

    func testAnAnthropicToolIsRemovedFromTheList() throws {
        let request = body(["model": "claude", "tools": [["name": "Bash"], ["name": "Read"]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "Bash")], agent: "claude"))
        XCTAssertEqual(filtered.removed, ["Bash"])
        let tools = parsed(filtered.body)["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["Read"])
    }

    func testAnOpenAIToolIsFoundInsideItsFunctionWrapper() throws {
        let request = body(["tools": [["type": "function", "function": ["name": "run_shell"]],
                                      ["type": "function", "function": ["name": "search"]]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "run_shell")], agent: "codex"))
        let tools = parsed(filtered.body)["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual((tools?.first?["function"] as? [String: Any])?["name"] as? String, "search")
    }

    func testGeminiDeclarationsAreFilteredInPlace() throws {
        let request = body(["tools": [["functionDeclarations": [["name": "writeFile"], ["name": "readFile"]]]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "writeFile")], agent: "gemini"))
        let declarations = (parsed(filtered.body)["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]
        XCTAssertEqual(declarations?.compactMap { $0["name"] as? String }, ["readFile"],
                       "the entry survives with fewer functions in it, rather than being dropped whole")
    }

    func testAnEmptyGeminiEntryIsDroppedRatherThanLeftEmpty() throws {
        let request = body(["tools": [["functionDeclarations": [["name": "writeFile"]]]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "writeFile")], agent: "gemini"))
        XCTAssertEqual((parsed(filtered.body)["tools"] as? [[String: Any]])?.count, 0)
    }

    func testAToolIsMatchedToItsServerByName() throws {
        let request = body(["tools": [["name": "mcp__github__create_issue"], ["name": "mcp__slack__post"]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(server: "github")], agent: "claude"))
        let tools = parsed(filtered.body)["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["mcp__slack__post"])
    }

    func testAConnectorIsNarrowedRatherThanDropped() throws {
        let request = body(["mcp_servers": [["name": "github", "url": "https://example.test",
                                             "tool_configuration": ["allowed_tools": ["create_issue", "read_issue"]]]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "create_issue")], agent: "claude"))
        let servers = parsed(filtered.body)["mcp_servers"] as? [[String: Any]]
        let allowed = (servers?.first?["tool_configuration"] as? [String: Any])?["allowed_tools"] as? [String]
        XCTAssertEqual(allowed, ["read_issue"])
    }

    func testAWholeConnectorCanBeDropped() throws {
        let request = body(["mcp_servers": [["name": "github"], ["name": "slack"]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(server: "github")], agent: "claude"))
        let servers = parsed(filtered.body)["mcp_servers"] as? [[String: Any]]
        XCTAssertEqual(servers?.compactMap { $0["name"] as? String }, ["slack"])
    }

    func testNothingChangedMeansNothingIsRewritten() {
        let request = body(["tools": [["name": "Read"]]])
        XCTAssertNil(GuardrailEngine.filter(request: request, guardrails: [Guardrail(tool: "Bash")], agent: "claude"),
                     "a request nobody has an opinion about must go out byte for byte")
        XCTAssertNil(GuardrailEngine.filter(request: request, guardrails: [], agent: "claude"))
    }

    func testAnUnrelatedAgentIsLeftAlone() {
        let request = body(["tools": [["name": "Bash"]]])
        XCTAssertNil(GuardrailEngine.filter(request: request,
                                            guardrails: [Guardrail(agent: "codex", tool: "Bash")], agent: "claude"))
    }

    func testANonJSONBodyIsNeverTouched() {
        XCTAssertNil(GuardrailEngine.filter(request: Data("not json at all".utf8),
                                            guardrails: [Guardrail(tool: "Bash")], agent: "claude"))
    }

    func testTheRestOfTheRequestSurvivesTheEdit() throws {
        let request = body(["model": "claude-opus", "max_tokens": 1024, "system": "be helpful",
                            "tools": [["name": "Bash"], ["name": "Read"]]])
        let filtered = try XCTUnwrap(GuardrailEngine.filter(request: request,
                                                            guardrails: [Guardrail(tool: "Bash")], agent: "claude"))
        let object = parsed(filtered.body)
        XCTAssertEqual(object["model"] as? String, "claude-opus")
        XCTAssertEqual(object["max_tokens"] as? Int, 1024)
        XCTAssertEqual(object["system"] as? String, "be helpful")
    }

    // MARK: Reframing

    func testTheContentLengthIsMadeToAgreeWithTheNewBody() {
        let original = Data("POST /v1/messages HTTP/1.1\r\nHost: x.test\r\nContent-Length: 99\r\n\r\n{\"a\":1}".utf8)
        let out = InspectionController.reframe(original, body: Data(#"{"a":1,"b":2}"#.utf8))
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 13"))
        XCTAssertFalse(text.contains("Content-Length: 99"), "a length that disagreed would hang the connection")
        XCTAssertTrue(text.hasSuffix(#"{"a":1,"b":2}"#))
        XCTAssertTrue(text.hasPrefix("POST /v1/messages HTTP/1.1\r\nHost: x.test\r\n"))
    }

    func testABodyIsFoundAfterTheHead() {
        let request = Data("POST / HTTP/1.1\r\nHost: x\r\n\r\nbody".utf8)
        XCTAssertEqual(InspectionController.body(of: request), Data("body".utf8))
        XCTAssertNil(InspectionController.body(of: Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
    }

    // MARK: Refusing a call

    func testARefusedToolCallComesBackAsAnErroringResult() throws {
        let request = body(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                            "params": ["name": "create_issue", "arguments": [:]]])
        let refusal = try XCTUnwrap(GuardrailEngine.refuse(jsonrpc: request, guardrails: [Guardrail(tool: "create_issue")],
                                                           agent: "claude", server: "github"))
        let object = parsed(Data(refusal.body.utf8))
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true,
                       "the protocol's own shape for a tool that failed — the model reads it and works around it")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertNil(object["error"], "a transport error would look to the agent like a broken server")
        XCTAssertEqual(refusal.subject, "create_issue")
    }

    func testARefusedResourceReadComesBackAsAJSONRPCError() throws {
        let request = body(["jsonrpc": "2.0", "id": 3, "method": "resources/read",
                            "params": ["uri": "file:///etc/passwd"]])
        let refusal = try XCTUnwrap(GuardrailEngine.refuse(jsonrpc: request,
                                                           guardrails: [Guardrail(resource: "file:///etc/*")],
                                                           agent: "claude", server: nil))
        let object = parsed(Data(refusal.body.utf8))
        XCTAssertNotNil(object["error"], "resources/read has no result shape that can carry a refusal")
        XCTAssertNil(object["result"])
    }

    func testAnUnguardedCallIsNotAnswered() {
        let request = body(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "read_issue"]])
        XCTAssertNil(GuardrailEngine.refuse(jsonrpc: request, guardrails: [Guardrail(tool: "create_issue")],
                                            agent: "claude", server: "github"))
    }

    func testAnUnrelatedMethodIsNeverAnswered() {
        let request = body(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        XCTAssertNil(GuardrailEngine.refuse(jsonrpc: request, guardrails: [Guardrail(tool: "*")],
                                            agent: "claude", server: "github"))
    }

    // MARK: Presets

    func testAPresetBecomesOneGuardrailPerPattern() {
        let readOnly = try! XCTUnwrap(Guardrail.presets.first { $0.name == "Read-only" })
        let made = Guardrail.preset(readOnly, agent: "claude")
        XCTAssertEqual(made.count, readOnly.tools.count)
        XCTAssertTrue(made.allSatisfy { $0.agent == "claude" && $0.origin == .preset && $0.isComplete })
        XCTAssertNotNil(GuardrailBook.refusing(made, agent: "claude", server: nil, tool: "bash"))
        XCTAssertNil(GuardrailBook.refusing(made, agent: "claude", server: nil, tool: "read_file"))
    }

    func testNoAgentIsAskedAboutWhenNoGuardrailNamesIt() {
        let guardrails = [Guardrail(agent: "claude", tool: "Bash")]
        XCTAssertTrue(GuardrailBook.any(guardrails, agent: "claude"))
        XCTAssertFalse(GuardrailBook.any(guardrails, agent: "cursor"))
        XCTAssertTrue(GuardrailBook.any([Guardrail(tool: "Bash")], agent: "anything"))
    }
}
