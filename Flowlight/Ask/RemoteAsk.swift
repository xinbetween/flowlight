import Foundation

/// Answering with a model somewhere else — a server on this Mac, or a provider you have an account with.
///
/// The three request shapes are written out rather than abstracted into one, because they genuinely differ and a
/// wrong guess shows up as a model that silently stops calling tools. What they share is the important part: the
/// only thing that ever leaves is the question, the instructions, and the results of queries Flowlight ran — and
/// every one of those bodies goes through `sending` first, so it can be shown before it goes.
struct RemoteProvider: AskProviding {
    var kind: AskProviderKind
    var endpoint: String
    var model: String
    var apiKey: String
    /// Injected for tests; the real one is a URLSession.
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    var label: String { "\(kind.title) · \(model)" }
    var sendsOffDevice: Bool { !Self.isOnMac(URL(string: endpoint)) }

    /// How many times the model may call queries before it has to answer. A model that keeps asking is usually
    /// lost, and an unbounded loop against someone's paid API is not a thing to ship.
    static let maximumRounds = 6

    enum Failure: Error, CustomStringConvertible {
        case notConfigured(String)
        case http(Int, String)
        case stopped(String)
        case unreadable

        var description: String {
            switch self {
            case .notConfigured(let what): return what
            case .http(let code, let body):
                if code == 401 || code == 403 { return L("The provider rejected the key (HTTP %lld).", code) }
                if code == 404 { return L("Nothing answered at that endpoint (HTTP 404). Check the URL and the model name.") }
                return L("The provider returned HTTP %lld. %@", code, String(body.prefix(200)))
            case .stopped(let reason): return reason
            case .unreadable: return L("The provider's answer wasn't in a shape Flowlight could read.")
            }
        }
    }

    static func isOnMac(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" { return true }
        return ipv4Octets(host)?.first == 127
    }

    /// HTTPS anywhere, or plain HTTP only where the traffic cannot leave the machine or the local network.
    static func isSafeEndpoint(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": break
        default: return false
        }
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        guard let octets = ipv4Octets(host) else { return false }
        if octets[0] == 127 || octets[0] == 10 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    func answer(_ request: AskRequest, run: @escaping @Sendable (AskCall) async -> String,
                sending: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw Failure.notConfigured(L("No endpoint is set for %@.", kind.title))
        }
        // The request carries an API key and a question about this Mac's own traffic. Over http:// both are
        // readable by anything on the path — including, with some irony, Flowlight. A loopback or private
        // address is the exception worth keeping: that is how someone points this at a model running on their
        // own machine or LAN, where there is no network to eavesdrop on.
        guard Self.isSafeEndpoint(url) else {
            throw Failure.notConfigured(L("%@ is not an https:// address. A key and your question would cross the network in the clear, so Flowlight won't send them.", endpoint))
        }
        guard kind != .localServer || Self.isOnMac(url) else {
            throw Failure.notConfigured(L("Local server must use localhost or a loopback address. Choose OpenAI-compatible endpoint for another machine."))
        }
        guard !kind.needsKey || !apiKey.isEmpty else {
            throw Failure.notConfigured(L("%@ needs an API key. Add one in Settings — it goes to your login Keychain.", kind.title))
        }
        switch kind {
        case .anthropic: return try await anthropic(request, url: url, run: run, sending: sending)
        case .gemini: return try await gemini(request, url: url, run: run, sending: sending)
        case .openAI, .localServer, .compatible: return try await openAI(request, url: url, run: run, sending: sending)
        case .onDevice: throw Failure.notConfigured(L("The on-device model isn't reached over HTTP."))
        }
    }

    // MARK: OpenAI chat completions — also Ollama, LM Studio and anything compatible

    private func openAI(_ request: AskRequest, url: URL, run: @escaping @Sendable (AskCall) async -> String,
                        sending: @escaping @Sendable (String) -> Void) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": request.instructions],
                                         ["role": "user", "content": request.question]]
        for _ in 0..<Self.maximumRounds {
            let body: [String: Any] = ["model": model, "messages": messages, "tools": [Self.openAITool],
                                       "tool_choice": "auto"]
            let json = try await post(url: url, body: body, headers: openAIHeaders, sending: sending)
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any],
                  let finishReason = choice["finish_reason"] as? String else { throw Failure.unreadable }
            switch finishReason {
            case "stop":
                guard (message["tool_calls"] as? [[String: Any]] ?? []).isEmpty else { throw Failure.unreadable }
                return (message["content"] as? String) ?? ""
            case "tool_calls":
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                guard !calls.isEmpty, calls.allSatisfy(Self.validOpenAIToolCall) else { throw Failure.unreadable }
                messages.append(message)
                for call in calls {
                    let function = call["function"] as! [String: Any]
                    let output = await runNamed(function["name"] as! String,
                                                arguments: function["arguments"] as! String, run: run)
                    messages.append(["role": "tool", "tool_call_id": call["id"] as! String, "content": output])
                }
            case "length":
                throw Failure.stopped(L("The provider reached its output limit before finishing the answer. Try asking something narrower."))
            case "content_filter":
                throw Failure.stopped(L("The provider's safety filter stopped the answer before it finished."))
            default:
                throw Failure.stopped(L("The provider stopped before finishing the answer (%@).", finishReason))
            }
        }
        return L("I ran out of steps before I could answer that. Try asking something narrower.")
    }

    private static func validOpenAIToolCall(_ call: [String: Any]) -> Bool {
        guard let id = call["id"] as? String, !id.isEmpty,
              let function = call["function"] as? [String: Any],
              function["name"] as? String == "runQuery",
              let arguments = function["arguments"] as? String,
              !arguments.isEmpty else { return false }
        return true
    }

    private var openAIHeaders: [String: String] {
        var headers = ["Content-Type": "application/json"]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }

    private static let openAITool: [String: Any] = [
        "type": "function",
        "function": ["name": "runQuery",
                     "description": "Run one of Flowlight's read-only queries against the network history on this Mac.",
                     "parameters": schema],
    ]

    // MARK: Anthropic messages

    private func anthropic(_ request: AskRequest, url: URL, run: @escaping @Sendable (AskCall) async -> String,
                           sending: @escaping @Sendable (String) -> Void) async throws -> String {
        var messages: [[String: Any]] = [["role": "user", "content": request.question]]
        for _ in 0..<Self.maximumRounds {
            let body: [String: Any] = [
                "model": model, "max_tokens": 16_000, "system": request.instructions, "messages": messages,
                "tools": [["name": "runQuery",
                           "description": "Run one of Flowlight's read-only queries against the network history on this Mac.",
                           "input_schema": Self.schema]],
            ]
            let json = try await post(url: url, body: body, headers: anthropicHeaders, sending: sending)
            guard let stopReason = json["stop_reason"] as? String,
                  let content = json["content"] as? [[String: Any]] else { throw Failure.unreadable }
            switch stopReason {
            case "end_turn":
                guard content.allSatisfy({ $0["type"] as? String != "tool_use" }) else {
                    throw Failure.unreadable
                }
                return content.compactMap { block in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
            case "tool_use":
                let uses = content.filter { $0["type"] as? String == "tool_use" }
                guard !uses.isEmpty, uses.allSatisfy(Self.validAnthropicToolUse) else {
                    throw Failure.unreadable
                }
                messages.append(["role": "assistant", "content": content])
                var results: [[String: Any]] = []
                for use in uses {
                    let input = use["input"] as! [String: Any]
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
                    let output = await runNamed(use["name"] as! String, arguments: arguments, run: run)
                    results.append(["type": "tool_result", "tool_use_id": use["id"] as! String, "content": output])
                }
                messages.append(["role": "user", "content": results])
            case "max_tokens":
                throw Failure.stopped(L("The provider reached its output limit before finishing the answer. Try asking something narrower."))
            case "refusal":
                let details = json["stop_details"] as? [String: Any]
                let explanation = (details?["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.stopped(explanation?.isEmpty == false
                                      ? explanation!
                                      : L("The provider declined to answer that question."))
            default:
                throw Failure.stopped(L("The provider stopped before finishing the answer (%@).", stopReason))
            }
        }
        return L("I ran out of steps before I could answer that. Try asking something narrower.")
    }

    private static func validAnthropicToolUse(_ block: [String: Any]) -> Bool {
        guard let id = block["id"] as? String, !id.isEmpty,
              let name = block["name"] as? String, name == "runQuery",
              let input = block["input"] as? [String: Any],
              JSONSerialization.isValidJSONObject(input) else { return false }
        return true
    }

    private var anthropicHeaders: [String: String] {
        ["Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2026-10-21"]
    }

    // MARK: Gemini

    private func gemini(_ request: AskRequest, url: URL, run: @escaping @Sendable (AskCall) async -> String,
                        sending: @escaping @Sendable (String) -> Void) async throws -> String {
        // The model is part of the path here, not the body.
        let target = URL(string: "\(endpoint.hasSuffix("/") ? endpoint : endpoint + "/")\(model):generateContent") ?? url
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": request.question]]]]
        for _ in 0..<Self.maximumRounds {
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": request.instructions]]],
                "contents": contents,
                "tools": [["functionDeclarations": [["name": "runQuery",
                                                     "description": "Run one of Flowlight's read-only queries against the network history on this Mac.",
                                                     "parameters": Self.schema]]]],
            ]
            let json = try await post(url: target, body: body,
                                      headers: ["Content-Type": "application/json", "x-goog-api-key": apiKey],
                                      sending: sending)
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
                  let finishReason = candidate["finishReason"] as? String,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw Failure.unreadable }
            switch finishReason {
            case "MAX_TOKENS":
                throw Failure.stopped(L("The provider reached its output limit before finishing the answer. Try asking something narrower."))
            case "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "RECITATION":
                throw Failure.stopped(L("The provider's safety filter stopped the answer before it finished."))
            case "STOP":
                let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
                guard !calls.isEmpty else {
                    return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                guard calls.allSatisfy(Self.validGeminiToolCall) else { throw Failure.unreadable }
                contents.append(content)
                var responses: [[String: Any]] = []
                for call in calls {
                    let args = call["args"] as! [String: Any]
                    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                    let output = await runNamed(call["name"] as! String, arguments: arguments, run: run)
                    responses.append(["functionResponse": ["name": call["name"] as! String,
                                                           "response": ["result": output]]])
                }
                contents.append(["role": "user", "parts": responses])
            default:
                throw Failure.stopped(L("The provider stopped before finishing the answer (%@).", finishReason))
            }
        }
        return L("I ran out of steps before I could answer that. Try asking something narrower.")
    }

    private static func validGeminiToolCall(_ call: [String: Any]) -> Bool {
        guard call["name"] as? String == "runQuery",
              let args = call["args"] as? [String: Any],
              JSONSerialization.isValidJSONObject(args) else { return false }
        return true
    }

    // MARK: Shared

    /// The one tool every provider is given, in the JSON Schema they all accept. Its fields come from the canonical
    /// query contract so a new query capability cannot silently exist in the prompt but disappear at the wire.
    static let schema: [String: Any] = {
        var properties: [String: Any] = [
            "query": ["type": "string", "enum": AskQuery.allCases.map(\.rawValue),
                      "description": "Which query to run."],
        ]
        for parameter in AskQuery.allCases.flatMap(\.parameters) {
            guard properties[parameter.name] == nil else { continue }
            properties[parameter.name] = [
                "type": parameter.kind == .integer ? "integer" : "string",
                "description": parameter.detail,
            ]
        }
        return ["type": "object", "properties": properties, "required": ["query"]]
    }()

    /// Turns whatever the model wrote into a call, or into a sentence explaining why it wasn't one.
    private func runNamed(_ name: String, arguments: String,
                          run: @escaping @Sendable (AskCall) async -> String) async -> String {
        guard name == "runQuery" else { return "There is no tool called '\(name)'. The only one is runQuery." }
        guard let data = arguments.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Those arguments weren't valid JSON."
        }
        guard let raw = fields["query"] as? String, let query = AskQuery(rawValue: raw.trimmingCharacters(in: .whitespaces)) else {
            return "There is no query called '\(fields["query"] as? String ?? "")'. The ones that exist are: "
                + AskQuery.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
        var strings: [String: String] = [:]
        for (key, value) in fields where key != "query" {
            if let text = value as? String, !text.isEmpty { strings[key] = text }
            else if let number = value as? NSNumber { strings[key] = "\(number)" }
        }
        let allowed = Set(query.parameters.map(\.name))
        strings = strings.filter { allowed.contains($0.key) }
        let missing = query.parameters.filter { $0.required && strings[$0.name] == nil }.map(\.name)
        guard missing.isEmpty else {
            return "The \(query.rawValue) query requires: \(missing.joined(separator: ", "))."
        }
        return await run(AskCall(query: query, arguments: strings))
    }

    private func post(url: URL, body: [String: Any], headers: [String: String],
                      sending: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Shown before it goes, every time. This is the whole basis for trusting the feature, so it happens here
        // rather than anywhere it could be forgotten.
        sending(String(decoding: data, as: UTF8.self))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 120
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (responseData, response) = try await transport(request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure.http(code, String(decoding: responseData.prefix(400), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw Failure.unreadable
        }
        return json
    }
}
