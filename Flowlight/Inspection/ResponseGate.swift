import Foundation

/// Frames the upstream side of an inspected HTTP/1.1 connection. Only a bounded, fixed-length identity response is
/// held; all other responses retain their original bytes and streaming behaviour.
final class ResponseGate {
    struct Context: Sendable { var head: HTTPHead }
    struct Replacement: Sendable { var body: Data; var note: String }
    struct Intervention {
        var transform: (Context, HTTPHead, Data) -> Replacement?
        var shouldTransform: (Context) -> Bool
    }

    static let holdLimit = 4 * 1024 * 1024
    var transform: (Context, HTTPHead, Data) -> Replacement?
    /// Evaluated as soon as a final response is paired to its request, so unrelated fixed responses preserve their
    /// streaming behaviour instead of being buffered merely because another endpoint on this host has a rule.
    var shouldTransform: (Context) -> Bool

    private let request = HTTPStreamParser(direction: .request, limit: 64 * 1024)
    private var requests: [Context] = []
    private var buffer = Data()
    private var state = State.head
    private var responseHead: HTTPHead?
    private var current: Context?
    private var held = Data()

    private enum State { case head, fixed(Int), passthroughFixed(Int), opaque }

    init(transform: @escaping (Context, HTTPHead, Data) -> Replacement?, shouldTransform: @escaping (Context) -> Bool = { _ in true }) {
        self.transform = transform
        self.shouldTransform = shouldTransform
        request.onHead = { [weak self] in self?.requests.append(Context(head: $0)) }
    }

    func clientSent(_ data: Data) { request.feed(data) }

    /// Returns client-visible bytes plus the transform provenance associated with replacement bytes.
    func serverSent(_ data: Data) -> [(Data, String?)] {
        guard !data.isEmpty else { return [] }
        if case .opaque = state { return [(data, nil)] }
        buffer.append(data)
        var out: [(Data, String?)] = []
        while step(&out) {}
        return out
    }

    private func step(_ out: inout [(Data, String?)]) -> Bool {
        switch state {
        case .opaque:
            if !buffer.isEmpty { out.append((take(buffer.count), nil)) }
            return false
        case .head:
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { out.append((take(buffer.count), nil)); state = .opaque; return true }
                return false
            }
            let rawHead = take(buffer.distance(from: buffer.startIndex, to: end.upperBound))
            let head = Self.parseHead(rawHead)
            guard let head else { out.append((rawHead, nil)); state = .opaque; return true }
            let status = head.status ?? 0
            // 1xx aside from switching protocols does not consume a request context.
            if (100..<200).contains(status), status != 101 { out.append((rawHead, nil)); return true }
            guard let context = requests.isEmpty ? nil : requests.removeFirst() else {
                out.append((rawHead, nil)); state = .opaque; return true
            }
            current = context; responseHead = head
            if status == 101 || context.head.method == "CONNECT" && (200..<300).contains(status) {
                out.append((rawHead, nil)); state = .opaque; return true
            }
            if context.head.method == "HEAD" || status == 204 || status == 304 {
                out.append((rawHead, nil)); clear(); return true
            }
            guard shouldTransform(context) else {
                out.append((rawHead, nil))
                // Transfer-Encoding defines framing when present. A conflicting Content-Length must not make an
                // untouched chunked response look fixed-length, or later bytes could be mistaken for a new head.
                if head.value("Transfer-Encoding") != nil {
                    state = .opaque
                } else if let length = head.value("Content-Length").flatMap(Int.init), length >= 0 {
                    state = .passthroughFixed(length)
                } else {
                    state = .opaque
                }
                return true
            }
            let encoding = head.value("Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "identity"
            if head.value("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                // Chunk boundaries and trailers are part of the original wire representation. Keeping them intact
                // means this connection cannot safely return to HTTP framing after an unsupported streamed reply.
                out.append((rawHead, nil)); state = .opaque; return true
            }
            guard let length = head.value("Content-Length").flatMap(Int.init), length >= 0 else {
                out.append((rawHead, nil)); state = .opaque; return true
            }
            guard length <= Self.holdLimit, encoding == "identity" else {
                // A known fixed-size response can still be skipped without losing later keep-alive responses.
                out.append((rawHead, nil)); state = .passthroughFixed(length); return true
            }
            // A candidate must be held as a whole. If no rule ultimately changes it, the same exact bytes are emitted.
            held = rawHead
            state = .fixed(length)
            if length == 0 { finish(&out) }
            return true
        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = min(remaining, buffer.count)
            held.append(take(count))
            if remaining == count { finish(&out) } else { state = .fixed(remaining - count) }
            return true
        case .passthroughFixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = min(remaining, buffer.count)
            out.append((take(count), nil))
            if remaining == count { clear() } else { state = .passthroughFixed(remaining - count) }
            return true
        }
    }

    private func finish(_ out: inout [(Data, String?)]) {
        guard let head = responseHead, let context = current,
              let separator = held.range(of: Data("\r\n\r\n".utf8)) else {
            out.append((held, nil)); clear(); return
        }
        let body = Data(held[separator.upperBound...])
        if let replacement = transform(context, head, body) {
            out.append((Self.reframe(head: head, body: replacement.body), replacement.note))
        } else {
            out.append((held, nil))
        }
        clear()
    }

    private func clear() { state = .head; responseHead = nil; current = nil; held.removeAll(keepingCapacity: true) }
    private func take(_ n: Int) -> Data { let end = buffer.index(buffer.startIndex, offsetBy: n); let value = Data(buffer[..<end]); buffer.removeSubrange(..<end); return value }

    private static func parseHead(_ raw: Data) -> HTTPHead? {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let start = lines.first, start.hasPrefix("HTTP/") else { return nil }
        lines.removeFirst()
        return HTTPHead(startLine: start, headers: lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return HTTPHeader(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        })
    }

    private static func reframe(head: HTTPHead, body: Data) -> Data {
        var lines = [head.startLine]
        for header in head.headers {
            let name = MockRule.headerSafe(header.name)
            guard !name.isEmpty else { continue }
            let lower = name.lowercased()
            guard lower != "content-length" && lower != "transfer-encoding" && lower != "connection" else { continue }
            lines.append("\(name): \(MockRule.headerSafe(header.value))")
        }
        lines.append("Content-Length: \(body.count)")
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(body)
        return out
    }
}
