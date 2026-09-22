import Foundation

/// A parsed JSON value that keeps object keys in their original order (JSONSerialization doesn't), so a body reads the
/// way the app sent it.
indirect enum JSONValue: Equatable, Sendable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)   // kept as written
    case bool(Bool)
    case null

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): return x.map(\.key) == y.map(\.key) && x.map(\.value) == y.map(\.value)
        case (.array(let x), .array(let y)): return x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    var isContainer: Bool {
        switch self { case .object, .array: return true; default: return false }
    }

    var count: Int {
        switch self {
        case .object(let pairs): return pairs.count
        case .array(let items): return items.count
        default: return 0
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    /// Pretty-printed text with two-space indentation, in original key order.
    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent), inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{\n" + pairs.map { "\(inner)\(Self.quote($0.key)): \($0.value.pretty(indent: indent + 1))" }.joined(separator: ",\n") + "\n\(pad)}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n\(pad)]"
        case .string(let s): return Self.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    /// Parses a complete JSON document; nil if it isn't one.
    static func parse(_ data: Data) -> JSONValue? {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth < 512, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<(index + w.count)]) == w else { return nil }
            index += w.count
            return value
        }

        mutating func number() -> JSONValue? {
            let start = index
            while index < bytes.count, "-+.eE0123456789".utf8.contains(bytes[index]) { index += 1 }
            guard index > start else { return nil }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            return Double(text) != nil ? .number(text) : nil
        }

        mutating func string() -> String? {
            index += 1   // opening quote
            var out = [UInt8]()
            var scalars = ""
            func flush() { if !out.isEmpty { scalars += String(decoding: out, as: UTF8.self); out.removeAll() } }
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") { index += 1; flush(); return scalars }
                if b == UInt8(ascii: "\\") {
                    guard index + 1 < bytes.count else { return nil }
                    let e = bytes[index + 1]
                    index += 2
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        // Surrogate pair.
                        if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                           bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            guard let low = hex4() else { return nil }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        flush()
                        scalars.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: out.append(e)   // \" \\ \/
                    }
                } else {
                    out.append(b)
                    index += 1
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16) else { return nil }
            index += 4
            return v
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var pairs: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while index < bytes.count {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipWhitespace()
                guard let v = value(depth: depth + 1) else { return nil }
                pairs.append((key, v))
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                return nil
            }
            return nil
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while index < bytes.count {
                skipWhitespace()
                guard let v = value(depth: depth + 1) else { return nil }
                items.append(v)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
            return nil
        }
    }
}

/// How a body is best shown: one JSON document, a stream of JSON events (SSE or NDJSON), or text.
enum BodyContent: Equatable {
    case json(JSONValue)
    /// Server-sent events or JSON lines: each event's name (if any) and its JSON.
    case events([(event: String?, value: JSONValue)])
    case text(String)
    case binary(Int)
    case empty

    static func == (a: BodyContent, b: BodyContent) -> Bool {
        switch (a, b) {
        case (.json(let x), .json(let y)): return x == y
        case (.events(let x), .events(let y)): return x.map(\.event) == y.map(\.event) && x.map(\.value) == y.map(\.value)
        case (.text(let x), .text(let y)): return x == y
        case (.binary(let x), .binary(let y)): return x == y
        case (.empty, .empty): return true
        default: return false
        }
    }

    static func classify(_ data: Data) -> BodyContent {
        guard !data.isEmpty else { return .empty }
        if let json = JSONValue.parse(data) { return .json(json) }
        guard let text = String(data: data, encoding: .utf8) else { return .binary(data.count) }
        var events: [(String?, JSONValue)] = []
        var pendingEvent: String?
        var nonJSONLines = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("event:") { pendingEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix(":") || line.hasPrefix("id:") || line.hasPrefix("retry:") { continue }
            let payload = line.hasPrefix("data:") ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) : line
            if payload == "[DONE]" { continue }
            if let value = JSONValue.parse(payload) {
                events.append((pendingEvent, value))
                pendingEvent = nil
            } else {
                nonJSONLines += 1
            }
        }
        if !events.isEmpty && nonJSONLines <= events.count / 10 { return .events(events) }
        return .text(text)
    }
}
