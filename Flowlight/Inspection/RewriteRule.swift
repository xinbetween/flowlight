import Foundation

/// An edit to one outgoing header: replace it (`set`), append another copy (`add`), or drop it (`remove`).
struct HeaderEdit: Codable, Equatable, Identifiable, Sendable {
    enum Op: String, Codable, Sendable, CaseIterable { case set, add, remove }
    var id = UUID()
    var op: Op = .set
    var name = ""
    var value = ""

    init(id: UUID = UUID(), op: Op = .set, name: String = "", value: String = "") {
        self.id = id; self.op = op; self.name = name; self.value = value
    }

    enum CodingKeys: String, CodingKey { case id, op, name, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        op = try c.decodeIfPresent(Op.self, forKey: .op) ?? .set
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// An edit to the request's body. For a JSON body, `path` is a dotted key path into objects (`metadata.user`):
/// `set` creates the path if needed, `remove` deletes the leaf, and the value is parsed as JSON when it can be
/// (`0.7`, `true`, `{"a":1}`) and taken as a plain string otherwise. For a form body
/// (`application/x-www-form-urlencoded`), `path` is a field name taken whole and the value is used as typed.
struct BodyEdit: Codable, Equatable, Identifiable, Sendable {
    enum Op: String, Codable, Sendable, CaseIterable { case set, remove }
    var id = UUID()
    var op: Op = .set
    var path = ""
    var value = ""

    init(id: UUID = UUID(), op: Op = .set, path: String = "", value: String = "") {
        self.id = id; self.op = op; self.path = path; self.value = value
    }

    enum CodingKeys: String, CodingKey { case id, op, path, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        op = try c.decodeIfPresent(Op.self, forKey: .op) ?? .set
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// A rule that rewrites a matching outgoing request before it is forwarded upstream — changing headers or the body (JSON or form). Like a mock, but it edits the request and lets it through rather than answering it: add an `Authorization`
/// header, pin `model`, strip a tracking field. Matched like a mock (host / path glob / method), and applied by the
/// same intervention path the guardrails use. Only requests Flowlight decrypts and can buffer (bodies up to a few MB,
/// not chunked or streamed) can be rewritten.
struct RewriteRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var enabled = true
    var name = ""
    /// `api.example.com` matches that host alone; `*.example.com` matches the domain and its subdomains.
    var host = ""
    /// A glob where `*` stands for any run of characters.
    var path = "*"
    /// Empty (or `ANY`) matches any method.
    var method = ""
    var headers: [HeaderEdit] = []
    var body: [BodyEdit] = []

    static let methods = MockRule.methods

    var title: String {
        name.isEmpty ? "\(method.isEmpty ? "ANY" : method.uppercased()) \(host)\(path)" : name
    }

    init(id: UUID = UUID(), enabled: Bool = true, name: String = "", host: String = "", path: String = "*",
         method: String = "", headers: [HeaderEdit] = [], body: [BodyEdit] = []) {
        self.id = id; self.enabled = enabled; self.name = name; self.host = host; self.path = path
        self.method = method; self.headers = headers; self.body = body
    }

    enum CodingKeys: String, CodingKey { case id, enabled, name, host, path, method, headers, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "*"
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        headers = try c.decodeIfPresent([HeaderEdit].self, forKey: .headers) ?? []
        body = try c.decodeIfPresent([BodyEdit].self, forKey: .body) ?? []
    }
}

// MARK: Matching & applying

/// Pure functions over plain data — no sockets — so the whole rewrite is testable without a proxy.
enum RewriteRules {
    /// The enabled rules that could touch this host. Asked once per connection, so a host no rule names never pays.
    static func matching(_ rules: [RewriteRule], host: String) -> [RewriteRule] {
        rules.filter { $0.enabled && GlobMatch.host($0.host, host) }
    }

    /// Apply every rule that matches this request to the framed bytes (full head + body). Returns the rewritten
    /// request and a short note of what changed, or nil when nothing matched or nothing changed.
    static func apply(_ rules: [RewriteRule], to request: Data, host: String, method: String, path: String)
        -> (data: Data, note: String)? {
        let applicable = rules.filter {
            $0.enabled && GlobMatch.host($0.host, host) && GlobMatch.method($0.method, method) && GlobMatch.path($0.path, path)
        }
        guard !applicable.isEmpty else { return nil }
        guard let sep = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headText = String(decoding: request[request.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()   // method/target/version are never rewritten
        var headerLines = lines
        var bodyData = Data(request[sep.upperBound...])
        var notes: [String] = []

        for edit in applicable.flatMap(\.headers) {
            // Sanitise both halves: a stray newline in a header value would forge extra headers or a second request.
            let name = MockRule.headerSafe(edit.name)
            guard !name.isEmpty else { continue }
            let value = MockRule.headerSafe(edit.value)
            let prefix = name.lowercased() + ":"
            switch edit.op {
            case .remove:
                let before = headerLines.count
                headerLines.removeAll { $0.lowercased().hasPrefix(prefix) }
                if headerLines.count != before { notes.append("removed \(name)") }
            case .set:
                headerLines.removeAll { $0.lowercased().hasPrefix(prefix) }
                headerLines.append("\(name): \(value)")
                notes.append("set \(name)")
            case .add:
                headerLines.append("\(name): \(value)")
                notes.append("added \(name)")
            }
        }

        let bodyEdits = applicable.flatMap(\.body)
        if !bodyEdits.isEmpty, !bodyData.isEmpty {
            if var json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                var changed = false
                for edit in bodyEdits {
                    let comps = edit.path.split(separator: ".").map(String.init)
                    guard !comps.isEmpty else { continue }
                    switch edit.op {
                    case .set: setJSON(&json, path: comps, value: parseValue(edit.value)); changed = true; notes.append("set \(edit.path)")
                    case .remove: removeJSON(&json, path: comps); changed = true; notes.append("removed \(edit.path)")
                    }
                }
                if changed, let out = try? JSONSerialization.data(withJSONObject: json) { bodyData = out }
            } else if isFormEncoded(headerLines), var form = FormBody(bodyData) {
                // A form body is flat, so a path is a field name taken whole — `a.b` means a field literally
                // named `a.b`, not a nested one. The value is always text; forms have no types, so it is used
                // verbatim rather than through `parseValue`.
                var changed = false
                for edit in bodyEdits {
                    let field = edit.path
                    guard !field.isEmpty else { continue }
                    switch edit.op {
                    case .set:
                        form.set(field, to: edit.value); changed = true; notes.append("set \(field)")
                    case .remove:
                        if form.remove(field) { changed = true; notes.append("removed \(field)") }
                    }
                }
                if changed { bodyData = form.encoded() }
            }
        }

        guard !notes.isEmpty else { return nil }

        // Reframe with a Content-Length that agrees with the final body, or the connection would hang.
        headerLines.removeAll { $0.lowercased().hasPrefix("content-length:") }
        if !bodyData.isEmpty { headerLines.append("Content-Length: \(bodyData.count)") }
        var out = Data(([requestLine] + headerLines).joined(separator: "\r\n").utf8)
        out.append(Data("\r\n\r\n".utf8))
        out.append(bodyData)
        return (out, notes.joined(separator: ", "))
    }

    /// Parse a value cell as JSON when it can be (number, bool, null, object, array, quoted string); otherwise take
    /// it literally as a string. Wrapped in an array so a bare scalar parses.
    static func parseValue(_ s: String) -> Any {
        if let data = "[\(s)]".data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = array.first {
            return first
        }
        return s
    }

    /// Whether the request carries an `application/x-www-form-urlencoded` body, from its Content-Type header.
    ///
    /// A `charset` or other parameter may follow (`...; charset=utf-8`), so this matches the media type as a
    /// prefix rather than the whole value.
    static func isFormEncoded(_ headerLines: [String]) -> Bool {
        for line in headerLines where line.lowercased().hasPrefix("content-type:") {
            let value = line.drop(while: { $0 != ":" }).dropFirst()
                .trimmingCharacters(in: .whitespaces).lowercased()
            return value.hasPrefix("application/x-www-form-urlencoded")
        }
        return false
    }

    private static func setJSON(_ object: inout [String: Any], path: [String], value: Any) {
        guard let key = path.first else { return }
        if path.count == 1 { object[key] = value; return }
        var child = object[key] as? [String: Any] ?? [:]
        setJSON(&child, path: Array(path.dropFirst()), value: value)
        object[key] = child
    }

    private static func removeJSON(_ object: inout [String: Any], path: [String]) {
        guard let key = path.first else { return }
        if path.count == 1 { object.removeValue(forKey: key); return }
        guard var child = object[key] as? [String: Any] else { return }
        removeJSON(&child, path: Array(path.dropFirst()))
        object[key] = child
    }
}

/// An `application/x-www-form-urlencoded` body as its ordered `name=value` pairs.
///
/// Ordered rather than a dictionary, and able to hold the same name twice, because a form can — and a rewrite
/// that silently collapsed `tag=a&tag=b` into one field would change a request in a way nobody asked for. Set
/// edits the first pair of that name in place (or appends when there is none); remove drops every pair of that
/// name. Decoding and re-encoding follow the form rules: `+` is a space, everything else is percent-encoded.
struct FormBody {
    private var pairs: [(name: String, value: String)]

    /// Parses a form body. Fails only if the bytes are not UTF-8; an empty or shapeless body parses to no pairs,
    /// which is a body a `set` can still add a field to.
    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        pairs = []
        guard !text.isEmpty else { return }
        for part in text.components(separatedBy: "&") where !part.isEmpty {
            if let eq = part.firstIndex(of: "=") {
                let name = Self.decode(String(part[part.startIndex..<eq]))
                let value = Self.decode(String(part[part.index(after: eq)...]))
                pairs.append((name, value))
            } else {
                // A field with no `=` is a name with an empty value, which is how browsers send a checkbox.
                pairs.append((Self.decode(part), ""))
            }
        }
    }

    /// Replaces the first pair of this name, or appends one when there is none.
    mutating func set(_ name: String, to value: String) {
        if let index = pairs.firstIndex(where: { $0.name == name }) {
            pairs[index].value = value
        } else {
            pairs.append((name, value))
        }
    }

    /// Drops every pair of this name. Returns whether anything was dropped.
    @discardableResult
    mutating func remove(_ name: String) -> Bool {
        let before = pairs.count
        pairs.removeAll { $0.name == name }
        return pairs.count != before
    }

    /// Re-encodes the pairs. Field order is preserved so a diff reads as the one change that was made.
    func encoded() -> Data {
        let body = pairs.map { "\(Self.encode($0.name))=\(Self.encode($0.value))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// Form-decode one component: `+` is a space, then `%XX` is a byte. A malformed `%` is left as written
    /// rather than dropped, so a value is never silently truncated.
    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? s.replacingOccurrences(of: "+", with: " ")
    }

    /// Form-encode one component. Everything outside the unreserved set is percent-encoded and space becomes
    /// `+`, which is what a browser emits — so `http://localhost/admin` becomes `http%3A%2F%2Flocalhost%2Fadmin`.
    private static func encode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._ ")
        let percent = s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
        return percent.replacingOccurrences(of: " ", with: "+")
    }
}
