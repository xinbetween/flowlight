import Foundation

/// A tool an agent offered the model in a request. Tools are declared on every turn, so this is the full list an
/// agent can use, not just the ones it happened to call.
struct DeclaredTool: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A tool the agent runs itself (Bash, Read, a local MCP server's tool).
        case function
        /// A tool the provider runs on its own servers (web search, code execution, computer use).
        case provider
        /// A whole MCP server offered through the provider's connector.
        case mcpToolset
    }

    var name: String
    var kind: Kind
    /// For MCP tools: the server they belong to.
    var server: String?
    var detail: String?
}

/// An MCP server the *provider* connects to on the agent's behalf (Anthropic's MCP connector, OpenAI's mcp tool).
/// Its traffic never touches this Mac, so inspecting the agent's own request is the only way to see it.
struct MCPConnector: Equatable, Codable, Sendable {
    var label: String
    var url: String?
    var provider: String
    /// OpenAI's `require_approval` ("never", "always", or a per-tool object).
    var approval: String?
    var allowedTools: [String]?
    /// Tools the provider reported for this server (`mcp_list_tools`).
    var tools: [String]?
    var authorized: Bool = false
}

struct TokenUsage: Equatable, Codable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0

    var total: Int { input + output }
    var isEmpty: Bool { self == TokenUsage() }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs.input += rhs.input; lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead; lhs.cacheWrite += rhs.cacheWrite; lhs.reasoning += rhs.reasoning
    }
}

/// What one LLM API call says about the agent behind it.
struct LLMFacts: Equatable, Codable, Sendable {
    enum Provider: String, Codable, Sendable { case anthropic, openAIChat, openAIResponses, gemini }

    var provider: Provider
    var model: String?
    var declaredTools: [DeclaredTool] = []
    var connectors: [MCPConnector] = []
    var usage: TokenUsage?
    var stopReason: String?
    /// Error type from a failed call ("rate_limit_error", "overloaded_error", "invalid_request_error"…).
    var errorType: String?
}

/// Reads the declarations and accounting in an LLM API call: which tools the agent offers the model, which MCP
/// servers the provider connects to for it, the model, the tokens and any error.
///
/// Field names follow each provider's API reference: Anthropic Messages (`mcp_servers`, `mcp_toolset`,
/// `input_schema`, `usage.cache_read_input_tokens`), OpenAI Chat Completions (`tools[].function`,
/// `usage.prompt_tokens`) and Responses (`tools[].type == "mcp"`, `mcp_list_tools`, `usage.input_tokens`),
/// and Gemini (`tools[].functionDeclarations`, `usageMetadata.promptTokenCount`; snake_case is accepted too).
enum LLMFactsReader {
    static func facts(request: Data, response: Data, host: String) -> LLMFacts? {
        guard let body = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
              let provider = provider(request: body, host: host) else { return nil }
        var facts = LLMFacts(provider: provider, model: body["model"] as? String)
        switch provider {
        case .anthropic: readAnthropicRequest(body, into: &facts)
        case .openAIChat: readChatRequest(body, into: &facts)
        case .openAIResponses: readResponsesRequest(body, into: &facts)
        case .gemini: readGeminiRequest(body, into: &facts)
        }
        readResponse(response, into: &facts)
        return facts
    }

    /// Which API this is, from the request's own shape (so proxies and gateways are recognized too).
    static func provider(request body: [String: Any], host: String) -> LLMFacts.Provider? {
        let tools = body["tools"] as? [[String: Any]] ?? []
        if body["contents"] != nil || body["generationConfig"] != nil || body["generation_config"] != nil { return .gemini }
        if body["mcp_servers"] != nil || body["system"] != nil || body["anthropic_version"] != nil { return .anthropic }
        if tools.contains(where: { $0["input_schema"] != nil || $0["type"] as? String == "mcp_toolset" }) { return .anthropic }
        if body["input"] != nil && body["messages"] == nil { return .openAIResponses }
        if tools.contains(where: { $0["type"] as? String == "mcp" && $0["server_label"] != nil }) { return .openAIResponses }
        guard body["messages"] != nil else { return nil }
        return host.contains("anthropic") ? .anthropic : .openAIChat
    }

    // MARK: Requests

    private static func readAnthropicRequest(_ body: [String: Any], into facts: inout LLMFacts) {
        var connectors: [String: MCPConnector] = [:]
        for server in body["mcp_servers"] as? [[String: Any]] ?? [] {
            guard let name = server["name"] as? String else { continue }
            connectors[name] = MCPConnector(label: name, url: server["url"] as? String, provider: "Anthropic",
                                            authorized: server["authorization_token"] != nil)
        }
        for tool in body["tools"] as? [[String: Any]] ?? [] {
            let type = tool["type"] as? String
            if type == "mcp_toolset", let server = tool["mcp_server_name"] as? String {
                // Per-tool configuration: `configs` keys with enabled != false are the tools left on.
                let configs = tool["configs"] as? [String: [String: Any]] ?? [:]
                let defaultsOn = (tool["default_config"] as? [String: Any])?["enabled"] as? Bool ?? true
                let listed = configs.filter { ($0.value["enabled"] as? Bool ?? true) }.keys.sorted()
                if !defaultsOn, !listed.isEmpty { connectors[server]?.allowedTools = listed }
                facts.declaredTools.append(DeclaredTool(name: server, kind: .mcpToolset, server: server,
                                                        detail: defaultsOn ? nil : "only \(listed.count) tools enabled"))
            } else if let name = tool["name"] as? String {
                let isProvider = tool["input_schema"] == nil && type != nil
                facts.declaredTools.append(DeclaredTool(name: name, kind: isProvider ? .provider : .function,
                                                        server: mcpServer(of: name), detail: tool["description"] as? String))
            }
        }
        facts.connectors = connectors.values.sorted { $0.label < $1.label }
    }

    private static func readChatRequest(_ body: [String: Any], into facts: inout LLMFacts) {
        for tool in body["tools"] as? [[String: Any]] ?? [] {
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String else { continue }
            facts.declaredTools.append(DeclaredTool(name: name, kind: .function, server: mcpServer(of: name),
                                                    detail: function["description"] as? String))
        }
    }

    private static func readResponsesRequest(_ body: [String: Any], into facts: inout LLMFacts) {
        for tool in body["tools"] as? [[String: Any]] ?? [] {
            let type = tool["type"] as? String ?? ""
            if type == "mcp" {
                guard let label = tool["server_label"] as? String else { continue }
                facts.connectors.append(MCPConnector(
                    label: label, url: tool["server_url"] as? String ?? (tool["connector_id"] as? String), provider: "OpenAI",
                    approval: approval(tool["require_approval"]), allowedTools: allowedTools(tool["allowed_tools"]),
                    authorized: tool["authorization"] != nil))
                facts.declaredTools.append(DeclaredTool(name: label, kind: .mcpToolset, server: label,
                                                        detail: tool["server_description"] as? String))
            } else if let name = tool["name"] as? String, type == "function" || type == "custom" {
                facts.declaredTools.append(DeclaredTool(name: name, kind: .function, server: mcpServer(of: name),
                                                        detail: tool["description"] as? String))
            } else if !type.isEmpty {
                facts.declaredTools.append(DeclaredTool(name: type, kind: .provider, server: nil, detail: nil))
            }
        }
    }

    private static func readGeminiRequest(_ body: [String: Any], into facts: inout LLMFacts) {
        for tool in body["tools"] as? [[String: Any]] ?? [] {
            let declarations = (tool["functionDeclarations"] ?? tool["function_declarations"]) as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let name = declaration["name"] as? String else { continue }
                facts.declaredTools.append(DeclaredTool(name: name, kind: .function, server: mcpServer(of: name),
                                                        detail: declaration["description"] as? String))
            }
            for key in tool.keys where key != "functionDeclarations" && key != "function_declarations" {
                facts.declaredTools.append(DeclaredTool(name: snakeCased(key), kind: .provider, server: nil, detail: nil))
            }
        }
        if facts.model == nil, let model = body["model"] as? String { facts.model = model }
    }

    // MARK: Responses

    private static func readResponse(_ body: Data, into facts: inout LLMFacts) {
        var usage = TokenUsage()
        var listed: [String: [String]] = [:]
        for object in LLMToolCallReader.jsonObjects(in: body) {
            // Anthropic streams carry the model and usage on message_start, and the final usage on message_delta.
            let message = object["message"] as? [String: Any]
            if let model = (message?["model"] ?? object["model"]) as? String { facts.model = model }
            if let stop = ((object["delta"] as? [String: Any])?["stop_reason"] ?? object["stop_reason"]
                           ?? message?["stop_reason"]) as? String { facts.stopReason = stop }
            if let reason = object["status"] as? String, reason == "incomplete" { facts.stopReason = "incomplete" }
            for source in [object, message ?? [:], object["response"] as? [String: Any] ?? [:]] {
                if let u = source["usage"] as? [String: Any] { usage = merge(usage, tokens(u)) }
                if let u = (source["usageMetadata"] ?? source["usage_metadata"]) as? [String: Any] { usage = merge(usage, geminiTokens(u)) }
            }
            // Tools a provider-run MCP server reported.
            var items = object["output"] as? [[String: Any]] ?? []
            if let item = object["item"] as? [String: Any] { items.append(item) }
            for item in items where item["type"] as? String == "mcp_list_tools" {
                guard let label = item["server_label"] as? String else { continue }
                listed[label] = (item["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            }
            if let error = object["error"] as? [String: Any] {
                facts.errorType = (error["type"] ?? error["code"]) as? String ?? "error"
            } else if object["type"] as? String == "error" {
                facts.errorType = "error"
            }
        }
        for index in facts.connectors.indices {
            if let tools = listed[facts.connectors[index].label] { facts.connectors[index].tools = tools }
        }
        if !usage.isEmpty { facts.usage = usage }
    }

    /// Anthropic and OpenAI token counts, whichever names this response uses.
    static func tokens(_ usage: [String: Any]) -> TokenUsage {
        func int(_ keys: String...) -> Int {
            for key in keys { if let value = usage[key] as? Int { return value } }
            return 0
        }
        let inputDetails = usage["prompt_tokens_details"] as? [String: Any] ?? usage["input_tokens_details"] as? [String: Any] ?? [:]
        let outputDetails = usage["completion_tokens_details"] as? [String: Any] ?? usage["output_tokens_details"] as? [String: Any] ?? [:]
        return TokenUsage(
            input: int("input_tokens", "prompt_tokens"),
            output: int("output_tokens", "completion_tokens"),
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? inputDetails["cached_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            reasoning: outputDetails["reasoning_tokens"] as? Int ?? 0)
    }

    static func geminiTokens(_ usage: [String: Any]) -> TokenUsage {
        func int(_ camel: String, _ snake: String) -> Int { (usage[camel] ?? usage[snake]) as? Int ?? 0 }
        return TokenUsage(
            input: int("promptTokenCount", "prompt_token_count"),
            output: int("candidatesTokenCount", "candidates_token_count"),
            cacheRead: int("cachedContentTokenCount", "cached_content_token_count"),
            cacheWrite: 0,
            reasoning: int("thoughtsTokenCount", "thoughts_token_count"))
    }

    /// Streams report usage twice (start, then final); keep the larger of each count.
    private static func merge(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(a.input, b.input), output: max(a.output, b.output), cacheRead: max(a.cacheRead, b.cacheRead),
                   cacheWrite: max(a.cacheWrite, b.cacheWrite), reasoning: max(a.reasoning, b.reasoning))
    }

    // MARK: Helpers

    /// `mcp__github__create_issue` → `github`, the naming agents use for MCP tools they run themselves.
    static func mcpServer(of name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? parts[0] : nil
    }

    private static func approval(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if value is [String: Any] { return "per tool" }
        return nil
    }

    private static func allowedTools(_ value: Any?) -> [String]? {
        if let list = value as? [String] { return list }
        if let object = value as? [String: Any] { return object["tool_names"] as? [String] }
        return nil
    }

    private static func snakeCased(_ key: String) -> String {
        var out = ""
        for character in key {
            if character.isUppercase { out += "_" + character.lowercased() } else { out.append(character) }
        }
        return out
    }
}
