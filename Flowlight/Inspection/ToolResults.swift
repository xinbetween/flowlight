import Foundation

/// What came back from a tool: sent to the model in the agent's next request, or returned by an MCP server.
struct ToolResult: Equatable, Codable, Sendable {
    var callID: String
    var isError: Bool
    /// The output as text, truncated.
    var output: String
    /// Length of the full output, in characters.
    var outputSize: Int
}

/// One JSON-RPC exchange with an MCP server over HTTP.
struct MCPActivity: Equatable, Codable, Sendable {
    /// The server's own name from `initialize`, or the host when it hasn't been seen.
    var server: String
    /// host + path, which identifies the server.
    var endpoint: String
    /// JSON-RPC method: initialize, tools/list, tools/call, resources/read…
    var method: String
    /// For tools/call: the tool and a summary of its arguments.
    var tool: String?
    var summary: String?
    /// For tools/list: the tools the server offers.
    var tools: [String]?
    /// For initialize: the server's version.
    var version: String?
    var isError: Bool
    var output: String?
}

enum ToolResultReader {
    static let outputLimit = 2000

    // MARK: Results sent back to the model

    /// Tool results in an LLM API request body: Anthropic tool_result blocks, OpenAI role "tool" messages, Responses
    /// function_call_output items and Gemini functionResponse parts.
    static func results(inRequest body: Data) -> [ToolResult] {
        guard body.first == UInt8(ascii: "{"), let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var results: [ToolResult] = []
        // Anthropic Messages and OpenAI Chat Completions share "messages".
        for message in json["messages"] as? [[String: Any]] ?? [] {
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    results.append(make(id, isError: block["is_error"] as? Bool ?? false, output: text(of: block["content"])))
                }
            }
            if message["role"] as? String == "tool", let id = message["tool_call_id"] as? String {
                results.append(make(id, isError: false, output: text(of: message["content"])))
            }
        }
        // OpenAI Responses.
        for item in json["input"] as? [[String: Any]] ?? [] {
            guard let type = item["type"] as? String, type == "function_call_output" || type == "custom_tool_call_output",
                  let id = item["call_id"] as? String else { continue }
            results.append(make(id, isError: false, output: text(of: item["output"])))
        }
        // Gemini.
        for content in json["contents"] as? [[String: Any]] ?? [] {
            for part in content["parts"] as? [[String: Any]] ?? [] {
                guard let response = part["functionResponse"] as? [String: Any], let name = response["name"] as? String else { continue }
                let id = response["id"] as? String ?? "gemini:\(name)"
                let payload = response["response"] as? [String: Any]
                results.append(make(id, isError: payload?["error"] != nil, output: text(of: payload)))
            }
        }
        return results
    }

    /// Results the provider ran itself and returned in the response (OpenAI Responses mcp_call items).
    static func results(inResponse body: Data) -> [ToolResult] {
        LLMToolCallReader.jsonObjects(in: body).flatMap { object -> [ToolResult] in
            var items = object["output"] as? [[String: Any]] ?? []
            if let item = object["item"] as? [String: Any] { items.append(item) }
            return items.compactMap { item in
                guard item["type"] as? String == "mcp_call", let id = item["id"] as? String,
                      item["output"] != nil || item["error"] != nil else { return nil }
                let error = item["error"].flatMap { $0 is NSNull ? nil : $0 }
                return make(id, isError: error != nil, output: text(of: error ?? item["output"]))
            }
        }
    }

    // MARK: MCP over HTTP

    /// Pairs the JSON-RPC requests in `request` with the responses in `response` (JSON or an event stream).
    /// `names` maps endpoints to server names learned from earlier `initialize` responses.
    static func mcpActivity(request: Data, response: Data, host: String, path: String, knownName: String?) -> [MCPActivity] {
        guard let json = try? JSONSerialization.jsonObject(with: request) else { return [] }
        let requests = ((json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 })
            .filter { $0["jsonrpc"] as? String == "2.0" && $0["method"] is String }
        guard !requests.isEmpty else { return [] }
        var replies: [String: [String: Any]] = [:]
        for object in LLMToolCallReader.jsonObjects(in: response) {
            if let id = object["id"] { replies["\(id)"] = object }
        }
        let endpoint = host + (path.split(separator: "?").first.map(String.init) ?? "")
        return requests.compactMap { message in
            let method = message["method"] as! String
            if method.hasPrefix("notifications/") { return nil }
            let reply = message["id"].flatMap { replies["\($0)"] }
            let result = reply?["result"] as? [String: Any]
            let error = reply?["error"] as? [String: Any]
            let serverInfo = result?["serverInfo"] as? [String: Any]
            var activity = MCPActivity(server: (serverInfo?["name"] as? String) ?? knownName ?? host, endpoint: endpoint, method: method,
                                       isError: error != nil || result?["isError"] as? Bool == true)
            activity.version = serverInfo?["version"] as? String
            let params = message["params"] as? [String: Any]
            switch method {
            case "tools/call":
                activity.tool = params?["name"] as? String
                activity.summary = LLMToolCallReader.summary(of: params?["arguments"]) ?? compact(params?["arguments"])
                activity.output = clip(error?["message"] as? String ?? text(of: result?["content"] ?? result?["structuredContent"]))
            case "tools/list":
                activity.tools = (result?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            default:
                if let message = error?["message"] as? String { activity.output = clip(message) }
            }
            return activity
        }
    }

    // MARK: Helpers

    private static func make(_ id: String, isError: Bool, output: String) -> ToolResult {
        ToolResult(callID: id, isError: isError || looksLikeError(output), output: clip(output), outputSize: output.count)
    }

    /// Tools often report failure in their text rather than a flag.
    private static func looksLikeError(_ output: String) -> Bool {
        let head = output.prefix(200).lowercased()
        return head.hasPrefix("error") || head.contains("<tool_use_error>") || head.hasPrefix("exit code 1") || head.contains("command failed")
    }

    static func clip(_ s: String) -> String { s.count > outputLimit ? String(s.prefix(outputLimit)) + "…" : s }

    /// Text from the many shapes tool output takes: a string, a list of {type: text, text} blocks, or any JSON.
    static func text(of value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let blocks as [[String: Any]]:
            return blocks.map { block in
                if let t = block["text"] as? String { return t }
                if let type = block["type"] as? String, type == "image" || type == "input_image" { return "[image]" }
                return compact(block) ?? ""
            }.joined(separator: "\n")
        default:
            return compact(value) ?? "\(value!)"
        }
    }

    static func compact(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
