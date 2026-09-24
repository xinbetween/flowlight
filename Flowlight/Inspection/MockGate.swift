import Foundation

/// Splits the client's side of one inspected connection into requests and decides which of them Flowlight answers
/// itself instead of forwarding.
///
/// It frames rather than parses: it reads just enough of each request to know where it ends, so a request no rule
/// names is relayed byte for byte, exactly as it arrived. Bodies are never decoded here — the recorder already does
/// that from the same bytes. A gate is only built for a host some enabled rule names, so a connection nobody mocks
/// never goes through this code at all.
final class MockGate {
    enum Action: Equatable {
        /// Relay these bytes upstream (and record them).
        case forward(Data)
        /// Part of a request Flowlight is answering: recorded, never sent upstream.
        case hold(Data)
        /// The bytes that complete that request, the rule that answers it, and the request line it answered —
        /// which a rule refusing a request needs in order to be recorded as having refused something in particular.
        case answer(MockRule, Data, ProxyRequestHead?)
    }

    private enum State {
        case head
        case fixed(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTrailer
        /// Not a stream of HTTP/1.1 requests after all (an upgrade, or a head that never ended). Everything from
        /// here on is forwarded untouched: guessing at a protocol we don't recognise would break the connection.
        case opaque
    }

    let host: String
    let rules: [MockRule]
    private var state = State.head
    private var buffer = Data()
    /// The rule answering the request currently being read, if any.
    private var answering: (rule: MockRule, head: ProxyRequestHead?)?

    init(host: String, rules: [MockRule]) {
        self.host = host
        self.rules = rules
    }

    /// What to do with the bytes the client just sent, in order. Together the actions account for every byte, so a
    /// caller that records them all still sees the stream as the client wrote it.
    func clientSent(_ data: Data) -> [Action] {
        if case .opaque = state { return data.isEmpty ? [] : [.forward(data)] }
        buffer.append(data)
        var actions: [Action] = []
        while step(&actions) {}
        return actions
    }

    /// Advances one message part; returns true while there's more to take from the buffer.
    private func step(_ actions: inout [Action]) -> Bool {
        switch state {
        case .opaque:
            if !buffer.isEmpty { actions.append(.forward(take(buffer.count))) }
            return false
        case .head:
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { state = .opaque; return true }
                return false
            }
            let length = buffer.distance(from: buffer.startIndex, to: end.upperBound)
            let head = ProxyRequestHead.parse(buffer[buffer.startIndex..<end.upperBound])
            answering = head.flatMap { h in MockRules.match(rules, host: host, method: h.method, path: h.target).map { ($0, h) } }
            let next = head.map(Self.bodyState(for:)) ?? .opaque
            let complete = Self.endsMessage(next)
            state = next
            push(take(length), complete: complete, into: &actions)
            return true
        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let n = min(remaining, buffer.count)
            let complete = remaining - n == 0
            state = complete ? .head : .fixed(remaining: remaining - n)
            push(take(n), complete: complete, into: &actions)
            return true
        case .chunkSize:
            guard let end = buffer.range(of: Data("\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { state = .opaque; return true }
                return false
            }
            let length = buffer.distance(from: buffer.startIndex, to: end.upperBound)
            let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            let size = Int(line.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) ?? 0
            state = size == 0 ? .chunkTrailer : .chunkData(remaining: size + 2)   // data + CRLF
            push(take(length), complete: false, into: &actions)
            return true
        case .chunkData(let remaining):
            guard !buffer.isEmpty else { return false }
            let n = min(remaining, buffer.count)
            state = remaining - n == 0 ? .chunkSize : .chunkData(remaining: remaining - n)
            push(take(n), complete: false, into: &actions)
            return true
        case .chunkTrailer:
            guard let end = buffer.range(of: Data("\r\n".utf8)) else { return false }
            let length = buffer.distance(from: buffer.startIndex, to: end.upperBound)
            let complete = end.lowerBound == buffer.startIndex   // the empty line that ends the trailer
            if complete { state = .head }
            push(take(length), complete: complete, into: &actions)
            return true
        }
    }

    /// Routes settled bytes to the right action. The rule travels with the bytes that *complete* the request, so a
    /// recorder reading the same stream can label the exchange before it finishes parsing it.
    private func push(_ bytes: Data, complete: Bool, into actions: inout [Action]) {
        guard let answering else {
            if !bytes.isEmpty { actions.append(.forward(bytes)) }
            return
        }
        if complete {
            actions.append(.answer(answering.rule, bytes, answering.head))
            self.answering = nil
        } else if !bytes.isEmpty {
            actions.append(.hold(bytes))
        }
    }

    private func take(_ n: Int) -> Data {
        let end = buffer.index(buffer.startIndex, offsetBy: n)
        let out = Data(buffer[buffer.startIndex..<end])
        buffer.removeSubrange(buffer.startIndex..<end)
        return out
    }

    private static func endsMessage(_ state: State) -> Bool {
        switch state {
        case .head, .opaque: return true
        default: return false
        }
    }

    /// How long this request's body is, from its own headers — the same rules `HTTPStreamParser` uses, kept here
    /// because framing has to happen before a byte is relayed rather than after it's been read.
    private static func bodyState(for head: ProxyRequestHead) -> State {
        func value(_ name: String) -> String? {
            head.headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
        if value("Upgrade") != nil { return .opaque }   // WebSocket and friends: no more requests follow
        if value("Transfer-Encoding")?.lowercased().contains("chunked") == true { return .chunkSize }
        if let length = value("Content-Length").flatMap({ Int($0) }), length > 0 { return .fixed(remaining: length) }
        return .head
    }
}
