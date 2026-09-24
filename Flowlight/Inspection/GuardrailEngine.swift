import Foundation

/// Carrying out a guardrail, in the two places it can actually be carried out.
///
/// **The declaration.** Agents re-send their whole tool list on every turn, so removing a refused tool from that
/// list means the model is never offered it: no refusal to argue with, no retry loop, no tool call to intercept.
/// It is the strongest lever available and the only one that works the same for a local server and a remote one.
/// It is also the reason guardrails need HTTPS inspection: the list is inside the request body.
///
/// **The call**, for MCP servers reached over HTTP. A refused `tools/call` comes back as a *result* carrying
/// `isError: true` and a plain sentence, because that is what the protocol says an erroring tool looks like — the
/// model reads it and works around it, where a transport error would look like a broken server. `resources/read`
/// has no such result shape, so it gets a JSON-RPC error instead.
///
/// Everything here is bytes in, bytes out. No sockets, no state.
enum GuardrailEngine {
    /// A request body with refused tools taken out of it.
    struct Filtered: Equatable {
        var body: Data
        /// What was removed, for the record and for the exchange's label.
        var removed: [String]
    }

    /// Removes every refused tool from an LLM API request, and narrows the connectors it declares. Returns nil
    /// when nothing changed — which is the common case, and the one that must cost nothing.
    static func filter(request body: Data, guardrails: [Guardrail], agent: String) -> Filtered? {
        guard !guardrails.isEmpty, GuardrailBook.any(guardrails, agent: agent),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        var result = object
        var removed: [String] = []

        if let tools = object["tools"] as? [[String: Any]] {
            let kept = tools.compactMap { tool -> [String: Any]? in
                filterTool(tool, guardrails: guardrails, agent: agent, removed: &removed)
            }
            if kept.count != tools.count || removed.count > 0 { result["tools"] = kept }
        }
        // Anthropic's MCP connector: the provider reaches the server, so the only lever is the request that sets
        // it up — narrow what it is allowed to call, or drop it entirely.
        if let servers = object["mcp_servers"] as? [[String: Any]] {
            let kept = servers.compactMap { server -> [String: Any]? in
                narrow(connector: server, guardrails: guardrails, agent: agent, removed: &removed)
            }
            if kept.count != servers.count || !removed.isEmpty { result["mcp_servers"] = kept }
        }

        guard !removed.isEmpty else { return nil }
        guard let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        else { return nil }
        return Filtered(body: encoded, removed: removed)
    }

    /// One entry of a `tools` array, kept or dropped. The shape differs per provider, so each is read on its own
    /// terms rather than guessed at.
    private static func filterTool(_ tool: [String: Any], guardrails: [Guardrail], agent: String,
                                   removed: inout [String]) -> [String: Any]? {
        // Gemini nests its declarations one level down, so the entry survives with fewer functions in it.
        if let declarations = tool["functionDeclarations"] as? [[String: Any]] ?? tool["function_declarations"] as? [[String: Any]] {
            let kept = declarations.filter { declaration in
                guard let name = declaration["name"] as? String else { return true }
                return !refused(name, guardrails: guardrails, agent: agent, removed: &removed)
            }
            guard !kept.isEmpty else { return nil }
            var copy = tool
            copy[tool["functionDeclarations"] != nil ? "functionDeclarations" : "function_declarations"] = kept
            return copy
        }
        // OpenAI Chat Completions wraps the name in `function`.
        if let function = tool["function"] as? [String: Any], let name = function["name"] as? String {
            return refused(name, guardrails: guardrails, agent: agent, removed: &removed) ? nil : tool
        }
        // A whole MCP server offered through a connector, named by its label rather than a tool name.
        if let label = tool["server_label"] as? String ?? tool["mcp_server_name"] as? String {
            if let hit = GuardrailBook.refusing(guardrails, agent: agent, server: label, tool: "") {
                removed.append(hit.tool.isEmpty ? label : "\(label) › \(hit.tool)")
                return nil
            }
            // Narrow the list it is allowed to call rather than dropping the server.
            if let allowed = tool["allowed_tools"] as? [String] {
                let kept = allowed.filter {
                    !refused($0, server: label, guardrails: guardrails, agent: agent, removed: &removed)
                }
                guard kept.count != allowed.count else { return tool }
                var copy = tool
                copy["allowed_tools"] = kept
                return copy
            }
            return tool
        }
        guard let name = tool["name"] as? String else { return tool }
        return refused(name, guardrails: guardrails, agent: agent, removed: &removed) ? nil : tool
    }

    private static func narrow(connector: [String: Any], guardrails: [Guardrail], agent: String,
                               removed: inout [String]) -> [String: Any]? {
        guard let label = connector["name"] as? String else { return connector }
        if let hit = GuardrailBook.refusing(guardrails, agent: agent, server: label, tool: ""), hit.tool.isEmpty {
            removed.append(label)
            return nil
        }
        guard var configuration = connector["tool_configuration"] as? [String: Any],
              let allowed = configuration["allowed_tools"] as? [String] else { return connector }
        let kept = allowed.filter { !refused($0, server: label, guardrails: guardrails, agent: agent, removed: &removed) }
        guard kept.count != allowed.count else { return connector }
        var copy = connector
        configuration["allowed_tools"] = kept
        copy["tool_configuration"] = configuration
        return copy
    }

    private static func refused(_ name: String, server: String? = nil, guardrails: [Guardrail], agent: String,
                                removed: inout [String]) -> Bool {
        let owner = server ?? LLMFactsReader.mcpServer(of: name)
        guard let hit = GuardrailBook.refusing(guardrails, agent: agent, server: owner, tool: name) else { return false }
        _ = hit
        removed.append(name)
        return true
    }

    // MARK: The call

    /// A refusal, as the answer the agent gets back.
    struct Refusal: Equatable {
        var guardrail: Guardrail
        /// The tool or resource that was refused, for the record.
        var subject: String
        /// The whole HTTP response, body included.
        var body: String
    }

    /// A JSON-RPC request to an MCP server, refused where a guardrail names it.
    ///
    /// `tools/call` is answered as a result with `isError: true`, which is how the protocol says a tool reports a
    /// failure: the model reads the sentence and works around it. `resources/read` and `prompts/get` have no such
    /// result shape, so they get a JSON-RPC error.
    static func refuse(jsonrpc body: Data, guardrails: [Guardrail], agent: String, server: String?) -> Refusal? {
        guard !guardrails.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return nil }
        let id = object["id"]

        switch method {
        case "tools/call":
            guard let name = params["name"] as? String,
                  let hit = GuardrailBook.refusing(guardrails, agent: agent, server: server ?? LLMFactsReader.mcpServer(of: name),
                                                   tool: name) else { return nil }
            let text = "Refused by Flowlight: this agent is not allowed to use \(name)."
            let payload: [String: Any] = [
                "jsonrpc": "2.0", "id": id ?? NSNull(),
                "result": ["content": [["type": "text", "text": text]], "isError": true],
            ]
            return Refusal(guardrail: hit, subject: name, body: json(payload))
        case "resources/read":
            guard let uri = params["uri"] as? String,
                  let hit = GuardrailBook.refusing(guardrails, agent: agent, resource: uri) else { return nil }
            let payload: [String: Any] = [
                "jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": -32600, "message": "Refused by Flowlight: this agent is not allowed to read \(uri)."],
            ]
            return Refusal(guardrail: hit, subject: uri, body: json(payload))
        case "prompts/get":
            guard let name = params["name"] as? String,
                  let hit = GuardrailBook.refusing(guardrails, agent: agent, server: server, tool: name) else { return nil }
            let payload: [String: Any] = [
                "jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": -32600, "message": "Refused by Flowlight: this agent is not allowed to use \(name)."],
            ]
            return Refusal(guardrail: hit, subject: name, body: json(payload))
        default:
            return nil
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"Refused by Flowlight."}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
