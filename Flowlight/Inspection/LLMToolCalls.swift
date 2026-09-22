import Foundation

/// A tool the model asked an agent to run, read from an inspected LLM API response, or a tool call an agent made to a
/// remote MCP server over HTTP.
struct ToolCall: Equatable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case anthropic, openAIChat, openAIResponses, gemini, mcp
    }

    var source: Source
    var callID: String?
    /// The tool's own name ("Bash", "create_issue").
    var name: String
    /// The MCP server the tool belongs to, when known ("github" from `mcp__github__create_issue`).
    var mcpServer: String?
    /// Arguments as compact JSON, truncated.
    var input: String
    /// The single most telling argument: the shell command, URL, file path or query.
    var summary: String?

    var displayName: String { mcpServer.map { "\($0) › \(name)" } ?? name }
}

enum LLMToolCallReader {
    static let inputLimit = 4000

    // MARK: Responses

    static func responseCalls(_ body: Data) -> [ToolCall] {
        let objects = jsonObjects(in: body)
        guard !objects.isEmpty else { return [] }
        var anthropic = AnthropicStream(), chat = ChatStream()
        var calls: [ToolCall] = []
        for object in objects {
            // Anthropic Messages: whole message or stream events.
            if let content = object["content"] as? [[String: Any]], object["role"] as? String == "assistant" {
                calls += content.compactMap(anthropicBlock)
            }
            anthropic.consume(object)
            // OpenAI Chat Completions.
            if let choices = object["choices"] as? [[String: Any]] {
                for choice in choices {
                    if let message = choice["message"] as? [String: Any], let toolCalls = message["tool_calls"] as? [[String: Any]] {
                        calls += toolCalls.compactMap { chatCall($0) }
                    }
                    if let delta = choice["delta"] as? [String: Any], let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                        chat.consume(toolCalls, choice: choice["index"] as? Int ?? 0)
                    }
                }
            }
            // OpenAI Responses: final object, or output_item.done events.
            if let output = object["output"] as? [[String: Any]], object["object"] as? String == "response" {
                calls += output.compactMap(responsesItem)
            }
            if object["type"] as? String == "response.output_item.done", let item = object["item"] as? [String: Any],
               let call = responsesItem(item) {
                calls.append(call)
            }
            // Gemini generateContent / streamGenerateContent.
            if let candidates = object["candidates"] as? [[String: Any]] {
                for candidate in candidates {
                    let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    calls += parts.compactMap { part in
                        guard let fn = part["functionCall"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                        return make(.gemini, id: fn["id"] as? String, name: name, input: fn["args"])
                    }
                }
            }
        }
        calls += anthropic.finished()
        calls += chat.finished()
        return dedupe(calls)
    }

    private static func anthropicBlock(_ block: [String: Any]) -> ToolCall? {
        guard let type = block["type"] as? String, ["tool_use", "server_tool_use", "mcp_tool_use"].contains(type),
              let name = block["name"] as? String else { return nil }
        var call = make(.anthropic, id: block["id"] as? String, name: name, input: block["input"])
        if let server = block["server_name"] as? String { call.mcpServer = server; call.name = name }
        return call
    }

    /// Rebuilds tool_use blocks from content_block_start + input_json_delta events.
    private struct AnthropicStream {
        var blocks: [Int: (block: [String: Any], json: String)] = [:]
        var order: [Int] = []
        var done: [ToolCall] = []

        mutating func consume(_ event: [String: Any]) {
            switch event["type"] as? String {
            case "message_start":
                blocks.removeAll(); order.removeAll()
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                      let type = block["type"] as? String, ["tool_use", "server_tool_use", "mcp_tool_use"].contains(type) else { return }
                blocks[index] = (block, "")
                order.append(index)
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "input_json_delta", let part = delta["partial_json"] as? String else { return }
                blocks[index]?.json += part
            case "content_block_stop":
                guard let index = event["index"] as? Int, let entry = blocks.removeValue(forKey: index) else { return }
                var block = entry.block
                if !entry.json.isEmpty, let data = entry.json.data(using: .utf8), let input = try? JSONSerialization.jsonObject(with: data) {
                    block["input"] = input
                } else if !entry.json.isEmpty {
                    block["input"] = entry.json
                }
                if let call = LLMToolCallReader.anthropicBlock(block) { done.append(call) }
            default: break
            }
        }

        func finished() -> [ToolCall] { done }
    }

    private static func chatCall(_ call: [String: Any]) -> ToolCall? {
        guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
        return make(.openAIChat, id: call["id"] as? String, name: name, input: parseArguments(fn["arguments"]))
    }

    /// Chat Completions streams send a tool call's name once and its arguments in fragments, keyed by index.
    private struct ChatStream {
        var calls: [String: (id: String?, name: String, args: String)] = [:]
        var order: [String] = []

        mutating func consume(_ deltas: [[String: Any]], choice: Int) {
            for delta in deltas {
                let key = "\(choice):\(delta["index"] as? Int ?? 0)"
                let fn = delta["function"] as? [String: Any] ?? [:]
                if calls[key] == nil { calls[key] = (nil, "", ""); order.append(key) }
                if let id = delta["id"] as? String { calls[key]!.id = id }
                if let name = fn["name"] as? String { calls[key]!.name += name }
                if let args = fn["arguments"] as? String { calls[key]!.args += args }
            }
        }

        func finished() -> [ToolCall] {
            order.compactMap { key in
                guard let c = calls[key], !c.name.isEmpty else { return nil }
                return LLMToolCallReader.make(.openAIChat, id: c.id, name: c.name, input: LLMToolCallReader.parseArguments(c.args))
            }
        }
    }

    private static func responsesItem(_ item: [String: Any]) -> ToolCall? {
        guard let type = item["type"] as? String, let name = item["name"] as? String else { return nil }
        switch type {
        case "function_call", "custom_tool_call":
            return make(.openAIResponses, id: item["call_id"] as? String, name: name, input: parseArguments(item["arguments"] ?? item["input"]))
        case "mcp_call":
            var call = make(.openAIResponses, id: item["id"] as? String, name: name, input: parseArguments(item["arguments"]))
            call.mcpServer = item["server_label"] as? String
            return call
        default:
            return nil
        }
    }

    // MARK: MCP over HTTP

    /// JSON-RPC `tools/call` requests to a remote MCP server (Streamable HTTP transport).
    static func mcpRequestCalls(_ body: Data, host: String) -> [ToolCall] {
        guard body.first.map({ $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) == true,
              let json = try? JSONSerialization.jsonObject(with: body) else { return [] }
        let messages = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
        return messages.compactMap { message in
            guard message["method"] as? String == "tools/call", let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String else { return nil }
            var call = make(.mcp, id: (message["id"]).map { "\($0)" }, name: name, input: params["arguments"])
            call.mcpServer = host
            return call
        }
    }

    // MARK: Helpers

    static func make(_ source: ToolCall.Source, id: String?, name: String, input: Any?) -> ToolCall {
        var server: String?
        var tool = name
        // Claude Code, Cursor and others name MCP tools "mcp__<server>__<tool>".
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { server = parts[0]; tool = parts.dropFirst().joined(separator: "__") }
        }
        let json = compactJSON(input)
        return ToolCall(source: source, callID: id, name: tool, mcpServer: server,
                        input: String(json.prefix(inputLimit)), summary: summary(of: input))
    }

    static func summary(of input: Any?) -> String? {
        guard let object = input as? [String: Any] else { return (input as? String).map { String($0.prefix(300)) } }
        for key in ["command", "cmd", "url", "file_path", "path", "query", "pattern", "q", "prompt", "title"] {
            if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(300)) }
            if let value = object[key] as? [String], !value.isEmpty { return String(value.joined(separator: " ").prefix(300)) }
        }
        return nil
    }

    static func parseArguments(_ value: Any?) -> Any? {
        guard let text = value as? String else { return value }
        if let data = text.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) { return parsed }
        return text
    }

    private static func compactJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dedupe(_ calls: [ToolCall]) -> [ToolCall] {
        var seen = Set<String>()
        return calls.filter { seen.insert(($0.callID ?? UUID().uuidString) + $0.name).inserted }
    }

    /// Every JSON object in a body: the body itself, or each `data:` line of an event stream, or each line of NDJSON.
    static func jsonObjects(in body: Data) -> [[String: Any]] {
        guard !body.isEmpty else { return [] }
        if let whole = try? JSONSerialization.jsonObject(with: body) {
            if let object = whole as? [String: Any] { return [object] }
            if let array = whole as? [[String: Any]] { return array }   // Gemini streams can be one JSON array
        }
        let text = String(decoding: body, as: UTF8.self)
        var objects: [[String: Any]] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("data:") { line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            objects.append(object)
        }
        return objects
    }
}
