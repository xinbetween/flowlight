import Foundation

/// A canned answer for one endpoint: "reply to `POST api.example.com/v1/items` with a 503, after eight seconds".
///
/// It exists to watch an agent cope with an API that fails, stalls or answers with something odd, without breaking
/// the real service or waiting for it to misbehave on its own. Rules are ordered and the first enabled one that
/// matches answers; everything else is relayed untouched. Only requests Flowlight decrypts can be mocked — a
/// tunnelled connection is ciphertext to the proxy, so there's nothing to match on.
struct MockRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var enabled = true
    /// What to call it in the list and on the recorded exchange; falls back to the endpoint it matches.
    var name = ""
    /// `api.example.com` matches that host alone; `*.example.com` matches the domain and its subdomains.
    var host = ""
    /// A glob where `*` stands for any run of characters (`/v1/*`). Matched against the path alone, unless the
    /// pattern contains a `?`, in which case the query string is part of the comparison.
    var path = "*"
    /// Empty (or `ANY`) matches any method.
    var method = ""
    var status = 500
    var headers: [HTTPHeader] = []
    var body = ""
    /// Seconds to wait before answering, so "the API stalls" is testable. The recorded exchange shows the wait as
    /// its duration.
    var delay: Double = 0

    /// Methods offered in the editor. `ANY` is the empty method.
    static let methods = ["ANY", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var title: String {
        if !name.isEmpty { return name }
        return "\(method.isEmpty ? "ANY" : method.uppercased()) \(host)\(path)"
    }

    /// A rule prefilled from a recorded exchange, so "mock this" starts from the request that was actually made.
    init(mocking exchange: HTTPExchange) {
        host = exchange.host
        path = exchange.path.split(separator: "?").first.map(String.init) ?? "/"
        method = exchange.method
        status = 500
        body = #"{"error": "mocked by Flowlight"}"#
    }

    init(id: UUID = UUID(), enabled: Bool = true, name: String = "", host: String = "", path: String = "*",
         method: String = "", status: Int = 500, headers: [HTTPHeader] = [], body: String = "", delay: Double = 0) {
        self.id = id; self.enabled = enabled; self.name = name; self.host = host; self.path = path
        self.method = method; self.status = status; self.headers = headers; self.body = body; self.delay = delay
    }
}

extension MockRule {
    /// Written out rather than synthesized so a rule stored by an older build still decodes, and a hand-edited
    /// defaults file with a field missing loads as the safest value rather than failing the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "*"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 500
        headers = try c.decodeIfPresent([HTTPHeader].self, forKey: .headers) ?? []
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
    }
}

// MARK: Matching

/// Whether a request is answered by a rule, and which one. Plain functions over plain data, like `AgentPolicy`:
/// nothing here knows about sockets, so the whole decision is testable without a proxy.
enum MockRules {
    /// The first enabled rule that answers this request, or nil when it should go upstream untouched.
    static func match(_ rules: [MockRule], host: String, method: String, path: String) -> MockRule? {
        rules.first { $0.enabled && matches($0, host: host, method: method, path: path) }
    }

    static func matches(_ rule: MockRule, host: String, method: String, path: String) -> Bool {
        hostMatches(rule.host, host) && methodMatches(rule.method, method) && pathMatches(rule.path, path)
    }

    /// The enabled rules that could answer for this host. The proxy asks once per connection, before anything is
    /// framed, so a host nobody mocks never pays for the feature.
    static func mocks(_ rules: [MockRule], host: String) -> [MockRule] {
        rules.filter { $0.enabled && hostMatches($0.host, host) }
    }

    static func hostMatches(_ pattern: String, _ host: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        // A half-written rule matches nothing rather than everything: an empty host is a rule in progress, and
        // answering every request on the Mac from it would be the worst possible surprise.
        guard !p.isEmpty, !h.isEmpty else { return false }
        if p.hasPrefix("*.") || p.hasPrefix(".") {
            let domain = String(p.drop { $0 == "*" || $0 == "." })
            return !domain.isEmpty && (h == domain || h.hasSuffix("." + domain))
        }
        return h == p
    }

    static func methodMatches(_ pattern: String, _ method: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).uppercased()
        return p.isEmpty || p == "ANY" || p == "*" || p == method.trimmingCharacters(in: .whitespaces).uppercased()
    }

    static func pathMatches(_ pattern: String, _ target: String) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { p = "*" }
        var subject = target
        // A pattern that says nothing about the query string is matched against the path alone, so `/v1/messages`
        // still matches `/v1/messages?stream=true`.
        if !p.contains("?"), let query = subject.firstIndex(of: "?") { subject = String(subject[..<query]) }
        if !p.hasPrefix("/"), !p.hasPrefix("*") { p = "/" + p }
        return glob(p, subject)
    }

    /// `*` matches any run of characters, including `/`; everything else is literal. One wildcard is enough for
    /// the endpoints people actually mock, and it can't be mistaken for a regular expression.
    static func glob(_ pattern: String, _ subject: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        guard parts.count > 1 else { return pattern == subject }
        var rest = Substring(subject)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for (index, part) in parts.enumerated().dropFirst() where !part.isEmpty {
            if index == parts.count - 1 {
                // The last literal has to land at the end, and can't overlap what an earlier one already matched.
                guard rest.count >= part.count, rest.hasSuffix(part) else { return false }
                rest = rest.dropLast(part.count)
            } else {
                guard let found = rest.range(of: part) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        return true
    }
}

// MARK: The answer

extension MockRule {
    /// The canned response as it goes on the wire.
    ///
    /// Flowlight writes the framing headers itself: a mock whose `Content-Length` disagreed with its body would
    /// hang the client rather than test it. The connection is closed afterwards because nothing was sent upstream,
    /// so there's no real response behind this one to keep a reused connection in step with.
    func responseBytes() -> Data {
        let bodyAllowed = status != 204 && status != 304 && !(100..<200).contains(status)
        let payload = bodyAllowed ? Data(body.utf8) : Data()
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        let written = Set(["content-length", "connection", "transfer-encoding"])
        for header in headers {
            let name = Self.headerSafe(header.name)
            guard !name.isEmpty, !written.contains(name.lowercased()) else { continue }
            text += "\(name): \(Self.headerSafe(header.value))\r\n"
        }
        if bodyAllowed, !headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            text += "Content-Type: \(body.hasPrefix("{") || body.hasPrefix("[") ? "application/json" : "text/plain; charset=utf-8")\r\n"
        }
        if bodyAllowed { text += "Content-Length: \(payload.count)\r\n" }
        // Named in the response as well as in Flowlight, so an app or a log elsewhere on the Mac can also tell that
        // this answer didn't come from the server.
        text += "X-Flowlight-Mock: \(Self.headerSafe(title))\r\n"
        text += "Connection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(payload)
        return data
    }

    /// Strips anything that would end the header line. Header values come from a text field, and a stray newline
    /// there would let a rule forge extra headers or a second response.
    static func headerSafe(_ s: String) -> String {
        s.filter { !$0.isNewline && $0 != "\0" }.trimmingCharacters(in: .whitespaces)
    }

    private static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found",
        304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        408: "Request Timeout", 409: "Conflict", 418: "I'm a teapot", 422: "Unprocessable Content",
        429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout",
    ]

    static func reason(_ status: Int) -> String { reasons[status] ?? "Mocked" }

    /// Headers as one `Name: value` per line, which is how they're edited and how anyone reading an HTTP request
    /// already expects to see them.
    static func parseHeaders(_ text: String) -> [HTTPHeader] {
        text.split(whereSeparator: \.isNewline).compactMap { (line: Substring) -> HTTPHeader? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = headerSafe(String(line[..<colon]))
            guard !name.isEmpty else { return nil }
            return HTTPHeader(name: name, value: headerSafe(String(line[colon...].dropFirst())))
        }
    }

    static func headerText(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }
}
