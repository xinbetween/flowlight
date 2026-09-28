import Foundation

/// What a rule would have done, worked out against traffic that has already happened.
///
/// A rule that refuses connections is easy to write and frightening to switch on, because the first thing you
/// learn about it is what it breaks — and you learn it from something failing, somewhere else, later. The data
/// needed to answer the question beforehand has been on disk the whole time; it has only ever been used to
/// explain the past.
///
/// The simulation is a *delta*, not a verdict in isolation. Asking "what does this rule match" is the wrong
/// question when other rules already exist: a broader allow rule may already cover the same traffic, in which
/// case adding this one changes nothing and saying "would refuse 4,000 connections" would be a lie. So every
/// flow is decided twice — with the rules as they are, and with the candidate added — and only the ones whose
/// answer *changes* are reported.
enum RuleSimulation {

    /// A slice of recorded traffic, already grouped. One row per app-destination pair rather than per
    /// connection: the question is "what would break", and forty identical refusals to the same host are one
    /// thing breaking, not forty.
    struct Flow: Sendable, Equatable {
        var when: Date
        var agentKey: String
        var bundleID: String
        var appName: String
        var host: String
        var ip: String
        var port: UInt16
        var bytes: Int64
        var connections: Int

        var facts: FlowFacts {
            // `hostSettled` is true: this traffic is finished, so no further hostname is coming. A live flow can
            // be undecided while it waits for one; a recorded flow is as named as it will ever be.
            FlowFacts(agentKey: agentKey, bundleID: bundleID, host: host, ip: ip, port: port, hostSettled: true)
        }
    }

    /// One thing the rule would have changed.
    struct Change: Sendable, Equatable, Identifiable {
        var id: String { "\(bundleID)|\(host)|\(ip)|\(port)" }
        var appName: String
        var bundleID: String
        var host: String
        var ip: String
        var port: UInt16
        var bytes: Int64
        var connections: Int
        var lastSeen: Date
        /// True when the candidate refuses traffic that is allowed today; false when it allows traffic that is
        /// refused today, which is what an allow rule written to carve an exception does.
        var refused: Bool

        /// "api.example:443" — what to show when the row has a name, falling back to the address when it doesn't.
        var destination: String { (host.isEmpty ? ip : host) + ":\(port)" }
    }

    struct Result: Sendable, Equatable {
        var changes: [Change] = []
        /// Every flow considered, so "would refuse 3 of 1,240" can be said rather than just "would refuse 3".
        var flowsConsidered = 0
        var connectionsConsidered = 0
        /// The oldest traffic the simulation could see. A rule tested against two hours of history has been
        /// tested against two hours of history, and the screen has to say so.
        var earliest: Date?

        var refusals: [Change] { changes.filter(\.refused) }
        var permits: [Change] { changes.filter { !$0.refused } }
        var connectionsRefused: Int { refusals.reduce(0) { $0 + $1.connections } }
        var bytesRefused: Int64 { refusals.reduce(0) { $0 + $1.bytes } }
        var appsAffected: Int { Set(refusals.map(\.bundleID)).count }
        var isEmpty: Bool { changes.isEmpty }
    }

    /// Decide each flow twice — without the candidate and with it — and keep the ones that differ.
    ///
    /// - Parameters:
    ///   - candidate: the rule being considered. Simulated as enabled even if it is not, because the question is
    ///     what it *would* do; a switched-off rule that is about to be switched on is the whole use case.
    ///   - existing: the rules already in force. The candidate is excluded by id, so re-simulating a saved rule
    ///     compares against the others rather than against itself.
    ///   - now: the moment to judge schedules at. A rule that only applies at night is asked whether it applies
    ///     at the time the traffic happened, not at the time you are reading the screen.
    static func run(candidate: Rule, existing: [Rule], flows: [Flow], now: Date = Date(), session: String = "") -> Result {
        var enabled = candidate
        enabled.enabled = true
        let others = existing.filter { $0.id != candidate.id }
        let withCandidate = others + [enabled]

        var result = Result()
        var merged: [String: Change] = [:]
        for flow in flows {
            result.flowsConsidered += 1
            result.connectionsConsidered += flow.connections
            result.earliest = min(result.earliest ?? flow.when, flow.when)

            // Schedules are judged at the time the traffic happened: a rule for weeknights should report what it
            // would have refused on weeknights, not what it would refuse if that traffic happened now.
            let before = RuleBook.decide(flow.facts, rules: others, now: flow.when, session: session)
            let after = RuleBook.decide(flow.facts, rules: withCandidate, now: flow.when, session: session)
            guard before.verdict != after.verdict else { continue }
            guard after.verdict == .block || before.verdict == .block else { continue }

            let refused = after.verdict == .block
            let key = "\(flow.bundleID)|\(flow.host)|\(flow.ip)|\(flow.port)|\(refused)"
            if var seen = merged[key] {
                seen.bytes += flow.bytes
                seen.connections += flow.connections
                seen.lastSeen = max(seen.lastSeen, flow.when)
                merged[key] = seen
            } else {
                merged[key] = Change(appName: flow.appName, bundleID: flow.bundleID, host: flow.host, ip: flow.ip,
                                     port: flow.port, bytes: flow.bytes, connections: flow.connections,
                                     lastSeen: flow.when, refused: refused)
            }
        }
        // Busiest first: the thing most likely to be noticed breaking is the thing worth reading first.
        result.changes = merged.values.sorted {
            $0.connections == $1.connections ? $0.bytes > $1.bytes : $0.connections > $1.connections
        }
        return result
    }
}
