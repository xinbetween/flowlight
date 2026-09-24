import Foundation

/// Matching a host, a method and a path against the patterns people actually write.
///
/// It lives in Shared because both halves of Flowlight need it and neither should have its own idea of what
/// `*.example.com` or `/v1/*` means: the app writes the rules, and the extension carries them out.
enum GlobMatch {
    static func host(_ pattern: String, _ host: String) -> Bool {
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

    static func method(_ pattern: String, _ method: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).uppercased()
        return p.isEmpty || p == "ANY" || p == "*" || p == method.trimmingCharacters(in: .whitespaces).uppercased()
    }

    static func path(_ pattern: String, _ target: String) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty { p = "*" }
        var subject = target
        // A pattern that says nothing about the query string is matched against the path alone, so `/v1/messages`
        // still matches `/v1/messages?stream=true`.
        if !p.contains("?"), let query = subject.firstIndex(of: "?") { subject = String(subject[..<query]) }
        if !p.hasPrefix("/"), !p.hasPrefix("*") { p = "/" + p }
        return Self.glob(p, subject)
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
