import Compression
import Foundation

/// A request or response head.
struct HTTPHead: Equatable, Sendable {
    var startLine: String
    var headers: [HTTPHeader]

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Request line parts, or response status.
    var method: String { String(startLine.split(separator: " ").first ?? "") }
    var target: String { startLine.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
    var status: Int? { startLine.hasPrefix("HTTP/") ? Int(startLine.split(separator: " ").dropFirst().first ?? "") : nil }
}

struct HTTPHeader: Equatable, Codable, Sendable {
    var name: String
    var value: String
}

/// A decoded message body, capped at `limit` bytes.
struct HTTPBody: Equatable, Sendable {
    var data = Data()
    /// Bytes on the wire (before decompression, including anything past the cap).
    var wireSize = 0
    var truncated = false
}

/// Incremental HTTP/1.1 parser for one direction of a connection. Feed it bytes as they arrive; it calls `onMessage`
/// for each complete message. Bodies are de-chunked, kept up to `limit` bytes, and decompressed at the end.
final class HTTPStreamParser {
    enum Direction { case request, response }

    let direction: Direction
    let limit: Int
    var onHead: (HTTPHead) -> Void = { _ in }
    var onMessage: (HTTPHead, HTTPBody) -> Void = { _, _ in }
    /// Response parsing needs each request's method (HEAD has no body); the request side pushes them here.
    var requestMethods: [String] = []

    private enum State {
        case head
        case fixed(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTrailer
        case untilClose
        case opaque   // after a protocol upgrade (WebSocket); stop parsing
    }

    private var state = State.head
    private var buffer = Data()
    private var head: HTTPHead?
    private var body = HTTPBody()

    init(direction: Direction, limit: Int = 2 << 20) {
        self.direction = direction
        self.limit = limit
    }

    func feed(_ data: Data) {
        if case .opaque = state { return }
        buffer.append(data)
        while step() {}
    }

    /// The connection closed: a response read "until close" is complete now.
    func finish() {
        if case .untilClose = state, let head { emit(head) }
    }

    /// Advances the state machine; returns true while there's more to do with the buffer.
    private func step() -> Bool {
        switch state {
        case .opaque:
            buffer.removeAll()
            return false
        case .head:
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 256 * 1024 { state = .opaque }   // not HTTP
                return false
            }
            let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            var lines = text.components(separatedBy: "\r\n")
            let start = lines.removeFirst()
            let headers = lines.compactMap { line -> HTTPHeader? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return HTTPHeader(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let parsed = HTTPHead(startLine: start, headers: headers)
            // Interim 1xx responses (except 101) carry no body and aren't the final answer.
            if let status = parsed.status, (100..<200).contains(status), status != 101 { return true }
            head = parsed
            body = HTTPBody()
            onHead(parsed)
            state = bodyState(for: parsed)
            switch state {
            case .head, .opaque: emit(parsed)
            default: break
            }
            return true
        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let n = min(remaining, buffer.count)
            take(n)
            if remaining - n == 0 { emit(head!) } else { state = .fixed(remaining: remaining - n) }
            return true
        case .chunkSize:
            guard let end = buffer.range(of: Data("\r\n".utf8)) else { return false }
            let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            body.wireSize += buffer.distance(from: buffer.startIndex, to: end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            let size = Int(line.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) ?? 0
            state = size == 0 ? .chunkTrailer : .chunkData(remaining: size + 2)   // data + CRLF
            return true
        case .chunkData(let remaining):
            guard !buffer.isEmpty else { return false }
            let n = min(remaining, buffer.count)
            // The chunk's trailing CRLF isn't body.
            let payload = max(0, min(n, remaining - 2))
            take(payload)
            let rest = n - payload
            if rest > 0 { body.wireSize += rest; buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: rest)) }
            state = remaining - n == 0 ? .chunkSize : .chunkData(remaining: remaining - n)
            return true
        case .chunkTrailer:
            guard let end = buffer.range(of: Data("\r\n".utf8)) else { return false }
            let empty = end.lowerBound == buffer.startIndex
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if empty { emit(head!) }
            return true
        case .untilClose:
            guard !buffer.isEmpty else { return false }
            take(buffer.count)
            return false
        }
    }

    private func bodyState(for head: HTTPHead) -> State {
        if direction == .response {
            let method = requestMethods.isEmpty ? "GET" : requestMethods.removeFirst()
            let status = head.status ?? 200
            if status == 101 { return .opaque }
            if method == "HEAD" || status == 204 || status == 304 { return .head }
            if method == "CONNECT" && (200..<300).contains(status) { return .opaque }
        }
        if head.value("Transfer-Encoding")?.lowercased().contains("chunked") == true { return .chunkSize }
        if let length = head.value("Content-Length").flatMap({ Int($0) }) { return length > 0 ? .fixed(remaining: length) : .head }
        return direction == .response ? .untilClose : .head
    }

    private func take(_ n: Int) {
        guard n > 0 else { return }
        let end = buffer.index(buffer.startIndex, offsetBy: n)
        let room = limit - body.data.count
        if room > 0 { body.data.append(buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: min(n, room))]) }
        if n > room { body.truncated = true }
        body.wireSize += n
        buffer.removeSubrange(buffer.startIndex..<end)
    }

    private func emit(_ head: HTTPHead) {
        var decoded = body
        if !decoded.truncated, let encoding = head.value("Content-Encoding"), let plain = HTTPDecoding.decode(decoded.data, encoding: encoding) {
            decoded.data = plain.count > limit ? plain.prefix(limit) : plain
            if plain.count > limit { decoded.truncated = true }
        }
        onMessage(head, decoded)
        self.head = nil
        body = HTTPBody()
        if case .opaque = state { return }
        if case .untilClose = state { return }
        state = .head
    }
}

enum HTTPDecoding {
    /// Decodes gzip, deflate and br bodies. Returns nil for encodings it can't read (such as zstd).
    static func decode(_ data: Data, encoding: String) -> Data? {
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "", "identity": return data
        case "gzip", "x-gzip": return gunzip(data)
        case "deflate": return inflate(zlibStripped(data)) ?? inflate(data)
        case "br": return decompress(data, algorithm: COMPRESSION_BROTLI)
        default: return nil
        }
    }

    /// Skips the gzip header (RFC 1952) and inflates the raw deflate stream behind it.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0, i + 2 <= b.count { i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }   // FEXTRA
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }             // FNAME
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }             // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                                                      // FHCRC
        guard i < b.count - 8 else { return nil }
        return inflate(Data(b[i..<(b.count - 8)]))
    }

    /// zlib-wrapped deflate: drop the 2-byte header and 4-byte checksum.
    private static func zlibStripped(_ data: Data) -> Data {
        guard data.count > 6, let first = data.first, first & 0x0f == 8 else { return data }
        return data.dropFirst(2).dropLast(4)
    }

    private static func inflate(_ data: Data) -> Data? { decompress(data, algorithm: COMPRESSION_ZLIB) }

    private static func decompress(_ data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var output = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = data.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: if output.count > 64 << 20 { return nil }   // runaway
                default: return nil
                }
            }
        }
    }
}

enum HeaderRedaction {
    /// Headers that carry credentials. Their values are never stored.
    static let secretNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-goog-api-key",
        "x-auth-token", "x-amz-security-token", "x-csrf-token", "x-xsrf-token", "openai-organization-key",
    ]

    static func redact(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        headers.map { header in
            let name = header.name.lowercased()
            guard secretNames.contains(name) || name.hasSuffix("-token") || name.hasSuffix("-secret") || name.contains("api-key") else {
                return header
            }
            // Keep the scheme ("Bearer") so the kind of credential is still visible.
            let scheme = header.value.split(separator: " ").first.map(String.init)
            let keepScheme = name.hasSuffix("authorization") && header.value.contains(" ") ? scheme.map { $0 + " " } ?? "" : ""
            return HTTPHeader(name: header.name, value: "\(keepScheme)••• redacted (\(header.value.count) characters)")
        }
    }
}
