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
        // Group calls once by agent and keep them newest-first. The old implementation rebuilt a filtered copy of
        // every call for every exchange, making a busy inspection window quadratic before any activity was shown.
        let callsByAgent = Dictionary(grouping: exchanges
            .filter { !$0.toolCalls.isEmpty && $0.agent != nil }
            .flatMap { exchange in
                exchange.toolCalls.map {
                    (agent: exchange.agent!, at: exchange.started.addingTimeInterval(exchange.duration), call: $0)
                }
            }, by: \.agent)
            .mapValues { $0.sorted { $0.at > $1.at } }
        guard !callsByAgent.isEmpty else { return [:] }
        var links: [Int64: Link] = [:]
        for exchange in exchanges {
            guard let id = exchange.id, let agent = exchange.agent, exchange.via != nil else { continue }
            let upper = exchange.started.addingTimeInterval(1)
            let lower = exchange.started.addingTimeInterval(-window)
            let candidates = callsByAgent[agent] ?? []
            var hostMatch: Link?
            var programMatch: Link?
            let program = exchange.appName.lowercased()
            let host = exchange.host.lowercased()
            // The array is descending by request time, so skip future calls and stop once the ten-minute window is
            // exhausted. Matching predicates remain the source of truth, including URL safety.
            for candidate in candidates {
                if candidate.at > upper { continue }
                if candidate.at <= lower { break }
                if hostMatch == nil && mentions(candidate.call, host: host) {
                    hostMatch = Link(call: candidate.call, requestedAt: candidate.at)
                    break
                }
                if programMatch == nil,
                   exchange.started.timeIntervalSince(candidate.at) < 60,
                   runs(candidate.call, program: program), !namesURL(candidate.call) {
                    programMatch = Link(call: candidate.call, requestedAt: candidate.at)
                }
            }
            if let hostMatch { links[id] = hostMatch }
            else if let programMatch { links[id] = programMatch }
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
