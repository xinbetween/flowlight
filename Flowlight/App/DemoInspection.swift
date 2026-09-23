import Foundation

/// A synthetic HTTPS-inspection session for demo mode: Claude Code reading a file, searching a remote docs MCP server,
/// filing a GitHub issue, installing packages, uploading notes with curl (the allowlist violation in the demo alerts)
/// and failing a git push. Bodies are realistic; tool calls and results are extracted by the real readers.
extension DemoData {
    static func seedInspection(_ db: TrafficDatabase, now: Date) throws {
        let start = now.addingTimeInterval(-14 * 60)
        var clock = start
        var seen = Set<String>()
        var mcpNames: [String: String] = [:]
        let claudePID: Int32 = 4127, curlPID: Int32 = 4388, codexPID: Int32 = 4512

        func record(_ offset: TimeInterval, duration: Double, pid: Int32, bundle: String, app: String, host: String,
                    method: String = "POST", path: String, status: Int = 200, request: String, response: String,
                    contentType: String = "application/json", requestHeaders: [HTTPHeader] = [], mcpServer: String? = nil,
                    agent: (id: String, name: String) = ("claude", "Claude Code")) throws {
            clock = clock.addingTimeInterval(offset)
            let req = Data(request.utf8), resp = Data(response.utf8)
            var calls = LLMToolCallReader.responseCalls(resp)
            var results = (ToolResultReader.results(inRequest: req) + ToolResultReader.results(inResponse: resp))
                .filter { seen.insert($0.callID).inserted }
            let endpoint = host + path
            let mcp = ToolResultReader.mcpActivity(request: req, response: resp, host: host, path: path, knownName: mcpNames[endpoint])
            for activity in mcp {
                if activity.method == "initialize" { mcpNames[endpoint] = activity.server }
                guard activity.method == "tools/call", let tool = activity.tool else { continue }
                let id = "mcp-demo-\(calls.count)-\(tool)"
                calls.append(ToolCall(source: .mcp, callID: id, name: tool, mcpServer: activity.server, input: activity.summary ?? "",
                                      summary: activity.summary))
                results.append(ToolResult(callID: id, isError: activity.isError, output: activity.output ?? "", outputSize: activity.output?.count ?? 0))
            }
            let llm = LLMFactsReader.facts(request: req, response: resp, host: host)
            let headers = requestHeaders.isEmpty ? [
                HTTPHeader(name: "Host", value: host), HTTPHeader(name: "Content-Type", value: "application/json"),
                HTTPHeader(name: "Content-Length", value: "\(req.count)"),
            ] : requestHeaders
            try db.insertExchange(HTTPExchange(
                id: nil, started: clock, duration: duration, scheme: "https", host: host, port: 443, method: method, path: path,
                status: status, requestHeaders: HeaderRedaction.redact(headers), requestBody: req, requestSize: req.count, requestTruncated: false,
                responseHeaders: [HTTPHeader(name: "Content-Type", value: contentType), HTTPHeader(name: "Date", value: "demo")],
                responseBody: resp, responseSize: resp.count, responseTruncated: false, contentType: contentType,
                pid: pid, bundleID: bundle, appName: app, agent: agent.id, agentName: agent.name, mcpServer: mcpServer,
                toolCalls: calls, toolResults: results, mcp: mcp, llm: llm, note: nil))
        }

        let llmHeaders = [
            HTTPHeader(name: "Host", value: "api.anthropic.com"), HTTPHeader(name: "Content-Type", value: "application/json"),
            HTTPHeader(name: "anthropic-version", value: "2023-06-01"), HTTPHeader(name: "x-api-key", value: "sk-ant-demo-000000000000"),
            HTTPHeader(name: "User-Agent", value: "claude-cli/2.1 (external, cli)"),
        ]
        var history: [String] = [#"{"role":"user","content":[{"type":"text","text":"Summarize docs/notes.md, file an issue for the TODOs, and share the summary."}]}"#]
        func messages(_ extra: String? = nil) -> String {
            if let extra { history.append(extra) }
            return """
            {"model":"claude-sonnet-demo","max_tokens":32000,"stream":true,"system":[{"type":"text","text":"You are Claude Code, an interactive CLI tool."}],"messages":[\(history.joined(separator: ","))],"tools":[{"name":"Bash","description":"Run a shell command"},{"name":"Read","description":"Read a file"},{"name":"mcp__github__create_issue","description":"Create a GitHub issue"},{"name":"mcp__docs__search_docs","description":"Search the team docs"}]}
            """
        }
        func toolUse(_ id: String, _ name: String, _ input: String, text: String) -> String {
            // Split the raw JSON, then escape each half, as the API does (it never cuts through an escape).
            let esc = { (s: Substring) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let mid = input.index(input.startIndex, offsetBy: input.count / 2)
            return """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_demo_\(id)","type":"message","role":"assistant","model":"claude-sonnet-demo","content":[],"usage":{"input_tokens":1840,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\(text)"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_demo_\(id)","name":"\(name)","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\(esc(input[..<mid]))"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\(esc(input[mid...]))"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":1}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":64}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        }
        func assistant(_ id: String, _ name: String, _ input: String) -> String {
            #"{"role":"assistant","content":[{"type":"tool_use","id":"toolu_demo_\#(id)","name":"\#(name)","input":\#(input)}]}"#
        }
        func result(_ id: String, _ text: String, error: Bool = false) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            return #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_demo_\#(id)","is_error":\#(error),"content":"\#(escaped)"}]}"#
        }
        let sse = "text/event-stream; charset=utf-8"
        func llm(_ offset: TimeInterval, _ body: String, _ response: String) throws {
            try record(offset, duration: 2.2, pid: claudePID, bundle: "claude", app: "claude",
                       host: "api.anthropic.com", path: "/v1/messages?beta=true", request: body, response: response,
                       contentType: sse, requestHeaders: llmHeaders)
        }

        // 1. Read the notes.
        let read = #"{"file_path":"docs/notes.md"}"#
        try llm(0, messages(), toolUse("01", "Read", read, text: "I'll read the notes first."))
        history.append(assistant("01", "Read", read))
        // 2. Search the team docs through a remote MCP server.
        let search = #"{"query":"release checklist"}"#
        try llm(4, messages(result("01", "# Notes\n- TODO: rotate the staging keys\n- TODO: update the release checklist\n- Launch is Friday")),
                toolUse("02", "mcp__docs__search_docs", search, text: "Let me check the release checklist in the team docs."))
        history.append(assistant("02", "mcp__docs__search_docs", search))
        let docsHost = "mcp.docs.example", docsPath = "/mcp"
        try record(3, duration: 0.3, pid: claudePID, bundle: "claude", app: "claude", host: docsHost, path: docsPath,
                   request: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2.1"}}}"#,
                   response: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"docs\",\"version\":\"1.4.2\"},\"capabilities\":{\"tools\":{}}}}\n\n",
                   contentType: "text/event-stream")
        try record(0.4, duration: 0.2, pid: claudePID, bundle: "claude", app: "claude", host: docsHost, path: docsPath,
                   request: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                   response: #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search_docs","description":"Full-text search"},{"name":"fetch_page","description":"Fetch a page"},{"name":"list_spaces","description":"List doc spaces"}]}}"#)
        try record(0.5, duration: 0.6, pid: claudePID, bundle: "claude", app: "claude", host: docsHost, path: docsPath,
                   request: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_docs","arguments":{"query":"release checklist"}}}"#,
                   response: #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Release checklist (updated 3 weeks ago): 1. Tag the build 2. Rotate staging keys 3. Post the changelog"}],"isError":false}}"#)
        // 3. File the issue with the local GitHub MCP server.
        let issue = #"{"repo":"acme/app","title":"Pre-launch TODOs","body":"Rotate the staging keys; update the release checklist."}"#
        try llm(3, messages(result("02", "Release checklist (updated 3 weeks ago): 1. Tag the build 2. Rotate staging keys 3. Post the changelog")),
                toolUse("03", "mcp__github__create_issue", issue, text: "Filing an issue for the two TODOs."))
        history.append(assistant("03", "mcp__github__create_issue", issue))
        // 4. Install dependencies.
        let npm = #"{"command":"npm install","description":"Install dependencies"}"#
        try llm(5, messages(result("03", "Created issue #42: https://github.com/acme/app/issues/42")),
                toolUse("04", "Bash", npm, text: "Installing dependencies before building the summary script."))
        history.append(assistant("04", "Bash", npm))
        // 5. Upload the summary with curl: the request the allowlist flags.
        let upload = #"{"command":"curl -s https://paste.example/up -F file=@docs/notes.md","description":"Share the summary"}"#
        try llm(9, messages(result("04", "added 128 packages, and audited 129 packages in 6s\nfound 0 vulnerabilities")),
                toolUse("05", "Bash", upload, text: "Uploading the summary so it can be shared."))
        history.append(assistant("05", "Bash", upload))
        try record(3, duration: 0.8, pid: curlPID, bundle: "curl", app: "curl", host: "paste.example", path: "/up",
                   request: "--demo-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes.md\"\r\n\r\n# Notes\n- TODO: rotate the staging keys\n--demo-boundary--\r\n",
                   response: #"{"url":"https://paste.example/p/7f3k2","expires":"never","size":1184}"#,
                   requestHeaders: [HTTPHeader(name: "Host", value: "paste.example"), HTTPHeader(name: "User-Agent", value: "curl/8.7.1"),
                                    HTTPHeader(name: "Content-Type", value: "multipart/form-data; boundary=demo-boundary")])
        // 6. Push, which fails.
        let push = #"{"command":"git push origin main","description":"Push the summary script"}"#
        try llm(2, messages(result("05", #"{"url":"https://paste.example/p/7f3k2","expires":"never","size":1184}"#)),
                toolUse("06", "Bash", push, text: "Pushing the summary script."))
        history.append(assistant("06", "Bash", push))
        try llm(6, messages(result("06", "fatal: could not read Username for 'https://github.com': terminal prompts disabled", error: true)),
                """
                event: message_start
                data: {"type":"message_start","message":{"id":"msg_demo_07","type":"message","role":"assistant","content":[]}}

                event: content_block_start
                data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done: issue #42 filed, summary shared at paste.example. The push failed: git needs credentials."}}

                event: message_stop
                data: {"type":"message_stop"}

                """)

        // A second agent, using OpenAI's Responses API with a provider-side MCP connector: that server's traffic
        // never touches this Mac, so the request is the only place it shows up.
        let codexTools = #"{"model":"gpt-demo","input":[{"role":"user","content":"Check the failing test and open a ticket"}],"tools":[{"type":"function","name":"shell","description":"Run a shell command"},{"type":"web_search"},{"type":"mcp","server_label":"sentry","server_url":"https://mcp.sentry.example/mcp","require_approval":"never","allowed_tools":["find_errors","create_issue"],"authorization":"Bearer demo"}]}"#
        let codexReply = #"{"object":"response","model":"gpt-demo","output":[{"type":"mcp_list_tools","server_label":"sentry","tools":[{"name":"find_errors"},{"name":"create_issue"},{"name":"list_projects"}]},{"type":"mcp_call","id":"mcp_demo_1","server_label":"sentry","name":"find_errors","arguments":"{\"project\":\"web\"}","output":"2 unresolved errors: TypeError in checkout (142 events), 504 at /api/pay (31 events)","error":null}],"usage":{"input_tokens":3120,"output_tokens":180,"input_tokens_details":{"cached_tokens":2048},"output_tokens_details":{"reasoning_tokens":96}}}"#
        try record(6, duration: 1.8, pid: codexPID, bundle: "codex", app: "codex", host: "api.openai.com",
                   path: "/v1/responses", request: codexTools, response: codexReply, agent: ("codex", "Codex"))
        try record(4, duration: 1.2, pid: codexPID, bundle: "codex", app: "codex", host: "api.openai.com",
                   path: "/v1/responses",
                   request: #"{"model":"gpt-demo","input":[{"type":"function_call_output","call_id":"fc_demo_1","output":"1 failed, 42 passed"}],"tools":[{"type":"function","name":"shell","description":"Run a shell command"},{"type":"web_search"}]}"#,
                   response: #"{"object":"response","model":"gpt-demo","output":[{"type":"function_call","call_id":"fc_demo_2","name":"shell","arguments":"{\"command\":\"pytest tests/test_checkout.py -x\"}"}],"usage":{"input_tokens":3400,"output_tokens":64}}"#,
                   agent: ("codex", "Codex"))
    }
}
