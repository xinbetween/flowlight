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
    var sendsOffDevice: Bool { kind.sendsOffDevice }

    /// How many times the model may call queries before it has to answer. A model that keeps asking is usually
    /// lost, and an unbounded loop against someone's paid API is not a thing to ship.
    static let maximumRounds = 6

    enum Failure: Error, CustomStringConvertible {
        case notConfigured(String)
        case http(Int, String)
        case unreadable

        var description: String {
            switch self {
            case .notConfigured(let what): return what
            case .http(let code, let body):
                if code == 401 || code == 403 { return "The provider rejected the key (HTTP \(code))." }
                if code == 404 { return "Nothing answered at that endpoint (HTTP 404). Check the URL and the model name." }
                return "The provider returned HTTP \(code). \(body.prefix(200))"
            case .unreadable: return "The provider's answer wasn't in a shape Flowlight could read."
            }
        }
    }

    func answer(_ request: AskRequest, run: @escaping @Sendable (AskCall) async -> String,
                sending: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw Failure.notConfigured("No endpoint is set for \(kind.title).")
        }
        guard !kind.needsKey || !apiKey.isEmpty else {
            throw Failure.notConfigured("\(kind.title) needs an API key. Add one in Settings — it goes to your login Keychain.")
        }
        switch kind {
        case .anthropic: return try await anthropic(request, url: url, run: run, sending: sending)
        case .gemini: return try await gemini(request, url: url, run: run, sending: sending)
        case .openAI, .localServer, .compatible: return try await openAI(request, url: url, run: run, sending: sending)
        case .onDevice: throw Failure.notConfigured("The on-device model isn't reached over HTTP.")
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
                  let message = choice["message"] as? [String: Any] else { throw Failure.unreadable }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            guard !calls.isEmpty else { return (message["content"] as? String) ?? "" }
            messages.append(message)
            for call in calls {
                let function = call["function"] as? [String: Any]
                let arguments = (function?["arguments"] as? String) ?? "{}"
                let output = await runNamed((function?["name"] as? String) ?? "", arguments: arguments, run: run)
                messages.append(["role": "tool", "tool_call_id": (call["id"] as? String) ?? "", "content": output])
            }
        }
        return "I ran out of steps before I could answer that. Try asking something narrower."
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
                "model": model, "max_tokens": 1024, "system": request.instructions, "messages": messages,
                "tools": [["name": "runQuery",
                           "description": "Run one of Flowlight's read-only queries against the network history on this Mac.",
                           "input_schema": Self.schema]],
            ]
            let json = try await post(url: url, body: body, headers: anthropicHeaders, sending: sending)
            let content = json["content"] as? [[String: Any]] ?? []
            let uses = content.filter { $0["type"] as? String == "tool_use" }
            guard !uses.isEmpty else {
                return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for use in uses {
                let input = use["input"] as? [String: Any] ?? [:]
                let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8), as: UTF8.self)
                let output = await runNamed((use["name"] as? String) ?? "", arguments: arguments, run: run)
                results.append(["type": "tool_result", "tool_use_id": (use["id"] as? String) ?? "", "content": output])
            }
            messages.append(["role": "user", "content": results])
        }
        return "I ran out of steps before I could answer that. Try asking something narrower."
    }

    private var anthropicHeaders: [String: String] {
        ["Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01"]
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
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw Failure.unreadable }
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !calls.isEmpty else {
                return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            contents.append(content)
            var responses: [[String: Any]] = []
            for call in calls {
                let args = call["args"] as? [String: Any] ?? [:]
                let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
                let output = await runNamed((call["name"] as? String) ?? "", arguments: arguments, run: run)
                responses.append(["functionResponse": ["name": (call["name"] as? String) ?? "runQuery",
                                                       "response": ["result": output]]])
            }
            contents.append(["role": "user", "parts": responses])
        }
        return "I ran out of steps before I could answer that. Try asking something narrower."
    }

    // MARK: Shared

    /// The one tool every provider is given, in the JSON Schema they all accept.
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "enum": AskQuery.allCases.map(\.rawValue),
                      "description": "Which query to run."],
            "from": ["type": "string", "description": "Start of the window: '24h', '7d', 'today', 'yesterday', or ISO-8601."],
            "to": ["type": "string", "description": "End of the window; omit for now."],
            "app": ["type": "string", "description": "One app, by name or bundle identifier; omit for every app."],
            "limit": ["type": "string", "description": "How many rows, 1-50; omit for 10."],
            "granularity": ["type": "string", "description": "second, minute, hour or day; omit to let Flowlight choose."],
        ],
        "required": ["query", "from"],
    ]

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
