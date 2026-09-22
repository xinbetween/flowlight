import Foundation

/// Links requests made by an agent's tools back to the tool call the model asked for.
///
/// When the model answers with `Bash: curl https://paste.example/up`, the agent starts `curl`, and a moment later
/// the proxy sees curl's own request. The request is matched to the most recent earlier tool call from the same
/// agent that names its host (or, failing that, that runs the same program shortly before).
enum ToolCallLinks {
    struct Link: Equatable {
        var call: ToolCall
        var requestedAt: Date
    }

    static let window: TimeInterval = 10 * 60

    /// Exchange id → the tool call that caused it. `exchanges` may be in any order.
    static func link(_ exchanges: [HTTPExchange]) -> [Int64: Link] {
        let calls = exchanges
            .filter { !$0.toolCalls.isEmpty && $0.agent != nil }
            .flatMap { e in e.toolCalls.map { (agent: e.agent!, at: e.started.addingTimeInterval(e.duration), call: $0) } }
            .sorted { $0.at > $1.at }
        guard !calls.isEmpty else { return [:] }
        var links: [Int64: Link] = [:]
        for exchange in exchanges {
            guard let id = exchange.id, let agent = exchange.agent, exchange.via != nil else { continue }
            let candidates = calls.filter {
                $0.agent == agent && $0.at <= exchange.started.addingTimeInterval(1)
                    && exchange.started.timeIntervalSince($0.at) < window
            }
            let host = exchange.host.lowercased()
            let program = exchange.appName.lowercased()
            if let match = candidates.first(where: { mentions($0.call, host: host) }) {
                links[id] = Link(call: match.call, requestedAt: match.at)
            } else if let match = candidates.first(where: {
                // Only for calls that don't name a URL: a call that names another host didn't cause this request
                // (it may come from a hook or a background task that happens to use the same program).
                exchange.started.timeIntervalSince($0.at) < 60 && runs($0.call, program: program) && !namesURL($0.call)
            }) {
                links[id] = Link(call: match.call, requestedAt: match.at)
            }
        }
        return links
    }

    static func mentions(_ call: ToolCall, host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let text = ((call.summary ?? "") + " " + call.input).lowercased()
        return text.contains(host)
    }

    static func namesURL(_ call: ToolCall) -> Bool {
        ((call.summary ?? "") + " " + call.input).contains("://")
    }

    /// The call runs `program` (the first word of its command, or any word after a pipe or `&&`).
    static func runs(_ call: ToolCall, program: String) -> Bool {
        guard !program.isEmpty, let command = call.summary?.lowercased() else { return false }
        let words = command.split(whereSeparator: { " |;&()\n".contains($0) }).map { $0.split(separator: "/").last.map(String.init) ?? "" }
        return words.contains(program)
    }
}
