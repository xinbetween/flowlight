import Foundation

/// A script that changes an eligible upstream response after the real server answered it.
///
/// Unlike `MockRule`, this never answers a request locally: the matching request reaches its origin first. The
/// response-side gate only asks a script runner to change complete, bounded HTTP/1.1 replies it can safely reframe.
struct ResponseTransformRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var enabled = true
    var name = ""
    /// `api.example.com` matches that host alone; `*.example.com` matches the domain and its subdomains.
    var host = ""
    /// A glob where `*` stands for any run of characters. A pattern containing `?` also matches the query string.
    var path = "*"
    /// Empty (or `ANY`) matches any method.
    var method = ""
    /// A synchronous JavaScript function named `modifyResponse(args)`.
    var script = ""

    static let methods = MockRule.methods

    var title: String {
        name.isEmpty ? "\(method.isEmpty ? "ANY" : method.uppercased()) \(host)\(path)" : name
    }

    /// A complete, editable starting rule for an inspected exchange. Captured payload bytes are deliberately not
    /// copied into a setting: the script receives the response that is live when the rule later runs.
    init(transforming exchange: HTTPExchange, representation: ResponseRepresentation) {
        let endpoint = exchange.path.split(separator: "?").first.map(String.init) ?? "/"
        name = "Transform \(exchange.method.uppercased()) \(exchange.host)\(endpoint)"
        host = exchange.host
        path = endpoint
        method = exchange.method
        script = Self.template(for: representation)
    }

    init(id: UUID = UUID(), enabled: Bool = true, name: String = "", host: String = "", path: String = "*",
         method: String = "", script: String = "") {
        self.id = id; self.enabled = enabled; self.name = name; self.host = host; self.path = path
        self.method = method; self.script = script
    }

    enum CodingKeys: String, CodingKey { case id, enabled, name, host, path, method, script }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "*"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
    }

    static func template(for representation: ResponseRepresentation) -> String {
        switch representation {
        case .json:
            return """
            function modifyResponse(args) {
              const { method, url, responseJSON, requestHeaders } = args;

              // Change responseJSON in place, or return a replacement JSON value.
              return responseJSON;
            }
            """
        case .text:
            return """
            function modifyResponse(args) {
              const { method, url, responseText, requestHeaders } = args;

              // Return the text the app should receive.
              return responseText;
            }
            """
        }
    }
}

/// The only two body representations the first response-transform release accepts.
enum ResponseRepresentation: String, Codable, Equatable, Sendable {
    case json
    case text

    static func detect(headers: [HTTPHeader], body: Data) -> ResponseRepresentation? {
        let type = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            .split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type == "application/json" || type.hasSuffix("+json") {
            return (try? JSONSerialization.jsonObject(with: body)) == nil ? nil : .json
        }
        guard String(data: body, encoding: .utf8) != nil else { return nil }
        return .text
    }
}

/// The small, credential-free request context a response script can inspect.
struct ResponseTransformRequest: Equatable, Sendable {
    var method: String
    var url: String
    var headers: [String: String]

    init(head: HTTPHead, host: String, scheme: String, port: Int) {
        method = head.method
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        url = "\(scheme)://\(host)\(defaultPort ? "" : ":\(port)")\(Self.redactedTarget(head.target))"
        var safe: [String: String] = [:]
        for header in head.headers where !HeaderRedaction.isSecret(header.name) {
            // HTTP permits repeated headers. A script gets the last public value, which is predictable and avoids
            // inventing a delimiter that could alter the meaning of a value.
            safe[header.name] = header.value
        }
        headers = safe
    }

    /// Query values often carry credentials too. Keep their names and replace only values whose names are known to
    /// be credentials, so scripts can branch on public routing parameters without receiving a token by accident.
    private static func redactedTarget(_ target: String) -> String {
        guard var parts = URLComponents(string: "http://flowlight.invalid\(target)") else { return target }
        if let items = parts.queryItems {
            parts.queryItems = items.map { item in
                HeaderRedaction.isSecret(item.name) ? URLQueryItem(name: item.name, value: "•••") : item
            }
        }
        let rendered = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        return rendered.isEmpty ? "/" : rendered
    }
}

enum ResponseTransformRules {
    static func matching(_ rules: [ResponseTransformRule], host: String) -> [ResponseTransformRule] {
        rules.filter { $0.enabled && GlobMatch.host($0.host, host) }
    }

    static func applicable(_ rules: [ResponseTransformRule], host: String, method: String, path: String) -> [ResponseTransformRule] {
        rules.filter {
            $0.enabled && GlobMatch.host($0.host, host) && GlobMatch.method($0.method, method) && GlobMatch.path($0.path, path)
        }
    }
}

/// The selected exchange plus only display-safe data for a prefilled editor. It intentionally contains no retained
/// request/response body: transform rules are settings and must not silently outlive captured traffic.
struct ResponseTransformDraft: Identifiable, Equatable, Sendable {
    var id: UUID { rule.id }
    var rule: ResponseTransformRule
    var method: String
    var url: String
    var status: Int?
    var requestHeaders: [HTTPHeader]
    var responseHeaders: [HTTPHeader]
    var representation: ResponseRepresentation?
    var unavailableReason: String?

    init(exchange: HTTPExchange, responseBody: Data?) {
        let representation: ResponseRepresentation?
        let unavailableReason: String?
        if exchange.note != nil || exchange.mockRule != nil {
            representation = nil
            unavailableReason = L("Only a real upstream response can be modified.")
        } else if exchange.responseTruncated {
            representation = nil
            unavailableReason = L("This response was only partially retained, so Flowlight cannot safely prepare a transform.")
        } else if exchange.responseHeaders.contains(where: { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }) {
            representation = nil
            unavailableReason = L("This response was streamed or chunked, so Flowlight cannot safely transform it.")
        } else if let encoding = exchange.responseHeaders.first(where: { $0.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame })?.value,
                  !encoding.trimmingCharacters(in: .whitespaces).isEmpty,
                  encoding.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("identity") != .orderedSame {
            representation = nil
            unavailableReason = L("This response was compressed, so Flowlight cannot safely transform it.")
        } else if let responseBody {
            representation = ResponseRepresentation.detect(headers: exchange.responseHeaders, body: responseBody)
            unavailableReason = representation == nil ? L("This response is not a complete JSON or UTF-8 text response.") : nil
        } else {
            representation = nil
            unavailableReason = L("The captured response body is unavailable.")
        }
        self.representation = representation
        self.unavailableReason = unavailableReason
        rule = ResponseTransformRule(transforming: exchange, representation: representation ?? .text)
        method = exchange.method
        url = exchange.url
        status = exchange.status
        requestHeaders = exchange.requestHeaders
        responseHeaders = exchange.responseHeaders
    }
}
