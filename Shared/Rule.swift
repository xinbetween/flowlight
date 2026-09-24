import Foundation

/// One rule: "Cursor may not reach `raw.githubusercontent.com`", "nothing may reach `example.com` before nine",
/// "Claude Code may reach `api.github.com` for the next hour".
///
/// A rule names a **subject** — an app or agent, a destination, a URL, or a pairing of those — and an **action**:
/// block, or allow as an exception. One rule model sits behind every screen that offers to refuse something, so
/// what Live writes and what the Rules screen lists are the same object rather than two ideas that drift.
///
/// Everything here is plain data over plain functions, like `AgentPolicy.matches` and `MockRules.match`: the whole
/// decision can be tested without a filter, a proxy or a database.
struct Rule: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var enabled = true
    var action: Action = .block

    /// A bundle identifier or a process name; empty means any app. Matched against the process that opened the
    /// connection *and* the agent it belongs to, so naming Claude Code also covers the `curl` it ran.
    var app = ""
    /// A domain (subdomains included), an IP address or a CIDR range; empty means anywhere.
    var destination = ""
    /// A path glob (`/v1/*`), empty for any path. A path can only be matched where the request can be read, which
    /// is the HTTPS inspection proxy — `engine` says so and the list shows it.
    var path = ""
    /// An HTTP method, empty for any. Like `path`, only the proxy can see it.
    var method = ""
    /// The status a request-level block answers with. A refusal the agent can read beats a dead socket.
    var status = 403

    var schedule = Schedule()
    var origin: Origin = .typed
    /// What the person called it. Empty falls back to a sentence built from the subject.
    var name = ""
    var created = Date()
    /// How many connections this rule has decided, and when it last did. The Rules screen answers "is this rule
    /// doing anything?" with these rather than with a guess.
    var hits = 0
    var lastHit: Date?
    /// Stops applying after this many decisions, for "allow once". Zero means no limit.
    var maxHits = 0

    enum Action: String, Codable, Sendable {
        case block
        /// An exception: it lets through what a broader block would have refused.
        case allow
    }

    /// Where a rule came from, so the list can answer "why is this here?" — and so a relaxation someone clicked
    /// through in a hurry is distinguishable from one they sat down and wrote.
    enum Origin: String, Codable, Sendable {
        case typed, preset, alert, allowOnce
    }

    /// Which part of Flowlight can carry this rule out.
    enum Engine: String, Codable, Sendable {
        /// The Network Extension, which refuses whole connections. It knows host, IP and port and nothing about
        /// paths, and only exists in extension mode.
        case flow
        /// The HTTPS inspection proxy, which refuses one request and answers with a status.
        case request
    }

    var engine: Engine { path.isEmpty && method.isEmpty ? .flow : .request }

    /// A sentence for the list, built from whatever the rule actually names.
    var title: String {
        if !name.isEmpty { return name }
        let verb = action == .block ? "Block" : "Allow"
        let who = app.isEmpty ? "anything" : app
        var where_ = destination.isEmpty ? "anywhere" : destination
        if !path.isEmpty { where_ += path }
        if !method.isEmpty { where_ = "\(method.uppercased()) \(where_)" }
        return "\(verb) \(who) → \(where_)"
    }

    /// How narrow this rule is. The most specific matching rule decides, so a block on a whole domain doesn't
    /// overrule the one exception someone wrote underneath it, and an exception can't be widened by accident
    /// either: it only ever wins where it actually matches.
    var specificity: Int {
        var score = 0
        if !app.isEmpty { score += 4 }
        if !destination.isEmpty {
            // An exact address or host is narrower than a domain that carries its subdomains with it.
            score += AgentPolicy.isIPAddress(destination) ? 5 : (AgentPolicy.isCIDR(destination) ? 3 : 4)
        }
        if !path.isEmpty { score += path.contains("*") ? 1 : 2 }
        if !method.isEmpty { score += 1 }
        return score
    }

    /// A rule that names nothing at all would decide every connection on the Mac. That is never what someone
    /// meant, so it is treated as unfinished rather than obeyed.
    var isComplete: Bool { !app.isEmpty || !destination.isEmpty }
}

// MARK: When a rule applies

extension Rule {
    /// Forever, until a moment, for this run of Flowlight, or between chosen hours on chosen days.
    ///
    /// Everything is judged against the wall clock at the moment a connection is made, which is the only honest
    /// answer available: a Mac that sleeps through the end of a window finds it closed when it wakes, and a clock
    /// or timezone change moves the window with it rather than leaving it where it was set.
    struct Schedule: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case always, until, session, window }

        var kind: Kind = .always
        /// `.until` — the moment it stops.
        var until: Date?
        /// `.session` — the run of Flowlight that created it. A later run doesn't recognise the token, so the
        /// rule is over; nothing has to be swept at quit, which a crash would skip anyway.
        var session = ""
        /// `.window` — Calendar weekdays (1 = Sunday). Empty means every day.
        var days: [Int] = []
        /// `.window` — minutes since local midnight. An end at or before the start crosses midnight.
        var start = 9 * 60
        var end = 17 * 60

        static func expiring(in seconds: TimeInterval, from now: Date = Date()) -> Schedule {
            Schedule(kind: .until, until: now.addingTimeInterval(seconds))
        }

        static func thisSession(_ token: String) -> Schedule {
            Schedule(kind: .session, session: token)
        }

        func isActive(at now: Date, session current: String, calendar: Calendar = .current) -> Bool {
            switch kind {
            case .always: return true
            case .until: return until.map { now < $0 } ?? true
            case .session: return !current.isEmpty && session == current
            case .window: return windowIsOpen(at: now, calendar: calendar)
            }
        }

        /// Over for good, rather than merely closed for now. A window is never over; it comes back tomorrow.
        func isExpired(at now: Date, session current: String) -> Bool {
            switch kind {
            case .always, .window: return false
            case .until: return until.map { now >= $0 } ?? false
            case .session: return session != current
            }
        }

        private func windowIsOpen(at now: Date, calendar: Calendar) -> Bool {
            let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
            guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return false }
            let minuteOfDay = hour * 60 + minute
            let today = days.isEmpty || days.contains(weekday)
            guard end <= start else { return today && minuteOfDay >= start && minuteOfDay < end }
            // A window that crosses midnight belongs to the day it opened, so the hours after midnight are
            // yesterday's window still running.
            let yesterday = days.isEmpty || days.contains(weekday == 1 ? 7 : weekday - 1)
            return (today && minuteOfDay >= start) || (yesterday && minuteOfDay < end)
        }

        /// How the schedule reads in a list.
        func describe(at now: Date = Date(), session current: String = "", calendar: Calendar = .current) -> String {
            switch kind {
            case .always: return "Always"
            case .until:
                guard let until else { return "Always" }
                if now >= until { return "Expired" }
                let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
                return "Until \(until.formatted(.dateTime.hour().minute())) (\(until.formatted(style)))"
            case .session:
                return session == current ? "Until Flowlight quits" : "Expired"
            case .window:
                let names = calendar.shortWeekdaySymbols
                let which = days.isEmpty ? "Every day" : days.sorted().compactMap { names.indices.contains($0 - 1) ? names[$0 - 1] : nil }.joined(separator: " ")
                return "\(which), \(Self.clock(start))–\(Self.clock(end))"
            }
        }

        static func clock(_ minutes: Int) -> String {
            String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
        }
    }
}

// MARK: Matching

extension Rule {
    /// Whether this rule has anything to say about a connection. Timing is asked separately, so a list can show a
    /// rule that *would* match but is outside its hours.
    func matches(_ facts: FlowFacts) -> Bool {
        guard isComplete else { return false }
        if !app.isEmpty, !Self.appMatches(app, bundleID: facts.bundleID, agentKey: facts.agentKey) { return false }
        if !destination.isEmpty {
            // An unnamed destination can't be ruled out yet; the hostname may still arrive.
            guard !facts.host.isEmpty || facts.hostSettled else { return false }
            guard AgentPolicy.matches(destination, host: facts.host, ip: facts.ip) else { return false }
        }
        return true
    }

    /// Whether this rule answers one request, once the connection it arrived on already matches. Only the proxy
    /// ever asks.
    func matches(path target: String, method verb: String) -> Bool {
        GlobMatch.path(path.isEmpty ? "*" : path, target) && GlobMatch.method(method, verb)
    }

    /// An app is named by its bundle identifier or its process name, and naming an agent covers the tools it
    /// started — the extension has already resolved which agent a flow belongs to by the time this is asked.
    static func appMatches(_ pattern: String, bundleID: String, agentKey: String) -> Bool {
        let p = pattern.lowercased()
        guard !p.isEmpty else { return true }
        return p == bundleID.lowercased() || p == agentKey.lowercased()
    }
}

// MARK: The decision

/// What the rules say about one connection, and which rule said it.
struct RuleDecision: Equatable, Sendable {
    var verdict: FlowVerdict
    var rule: Rule?

    static let none = RuleDecision(verdict: .undecided, rule: nil)
}

/// Reading the whole rule list as one answer.
enum RuleBook {
    /// The rule that decides this connection.
    ///
    /// The most specific match wins, and a tie goes to the block: an exception has to be at least as narrow as
    /// what it is excepting, so widening one by accident isn't possible. A rule that names a path is skipped here
    /// — the flow level can't see paths, and pretending otherwise would refuse a whole host in a rule's name.
    static func decide(_ facts: FlowFacts, rules: [Rule], now: Date = Date(), session: String = "",
                       pausedUntil: Date? = nil) -> RuleDecision {
        if let pausedUntil, now < pausedUntil { return .none }
        let candidates = rules.filter {
            $0.enabled && $0.engine == .flow && $0.isUsable && $0.schedule.isActive(at: now, session: session)
                && $0.matches(facts)
        }
        guard let winner = best(of: candidates) else {
            // A rule that names this app and destination but can't be read yet: wait for the hostname rather than
            // letting the connection through and calling it decided.
            let pending = rules.contains {
                $0.enabled && $0.action == .block && $0.engine == .flow && $0.isUsable && !$0.destination.isEmpty
                    && !facts.hostSettled && facts.host.isEmpty
                    && ($0.app.isEmpty || Rule.appMatches($0.app, bundleID: facts.bundleID, agentKey: facts.agentKey))
            }
            return RuleDecision(verdict: pending ? .undecided : .allow, rule: nil)
        }
        return RuleDecision(verdict: winner.action == .block ? .block : .allow, rule: winner)
    }

    /// The request-level rule that answers one request, or nil to let it go upstream. Asked by the proxy, which is
    /// the only place a path is visible.
    static func decideRequest(_ facts: FlowFacts, path: String, method: String, rules: [Rule], now: Date = Date(),
                              session: String = "", pausedUntil: Date? = nil) -> RuleDecision {
        if let pausedUntil, now < pausedUntil { return .none }
        let candidates = rules.filter {
            $0.enabled && $0.isUsable && $0.schedule.isActive(at: now, session: session)
                && $0.matches(facts) && $0.matches(path: path, method: method)
        }
        guard let winner = best(of: candidates) else { return .none }
        return RuleDecision(verdict: winner.action == .block ? .block : .allow, rule: winner)
    }

    private static func best(of candidates: [Rule]) -> Rule? {
        candidates.max { a, b in
            if a.specificity != b.specificity { return a.specificity < b.specificity }
            // Same reach: the block is the one that stands.
            if a.action != b.action { return a.action == .allow }
            return a.created < b.created
        }
    }

    /// Which rules could bite at all, given what is running. A rule the current engine can't carry out is shown as
    /// watching rather than blocking — a list that says "blocked" about traffic that sailed through would be worse
    /// than no list.
    static func unenforceable(_ rules: [Rule], extensionRunning: Bool, inspecting: Bool) -> [Rule] {
        rules.filter { rule in
            guard rule.enabled, rule.isComplete else { return false }
            return rule.engine == .flow ? !extensionRunning : !inspecting
        }
    }
}

extension Rule {
    /// Still has decisions left in it. "Allow once" is spent after the connection it let through.
    var isUsable: Bool { maxHits == 0 || hits < maxHits }

    /// What a rule can't do here, in a sentence, or nil when it is being carried out.
    func limitation(extensionRunning: Bool, inspecting: Bool) -> String? {
        switch engine {
        case .flow:
            return extensionRunning ? nil : "Watching only — the Network Extension refuses connections, and it isn't running."
        case .request:
            return inspecting ? nil : "Watching only — a path can only be matched by HTTPS inspection, and it is off."
        }
    }
}

// MARK: What a rule did

/// One connection a rule decided, on its way to be recorded. Both halves matter: a refusal nobody can see is
/// worse than no refusal, and a relaxation nobody can see is how "why is this getting through?" becomes unanswerable.
struct RuleEvent: Codable, Sendable, Equatable {
    var at: Int64
    var ruleID: UUID
    var action: Rule.Action
    var engine: Rule.Engine
    var agentKey: String
    var agentName: String
    var appName: String
    var bundleID: String
    var host: String
    var ip: String
    var port: UInt16
    /// Set for a request-level decision, empty for a whole connection.
    var path: String = ""
    var method: String = ""

    var destination: String { host.isEmpty ? ip : host }
}

/// The enforcing half of the rule list, as the extension is told it: the rules themselves plus the one global
/// escape hatch. Sent whole on every change, like `AgentPolicy`, so the extension never has to reconcile a delta.
struct RuleSet: Codable, Sendable, Equatable {
    var rules: [Rule] = []
    /// Nothing is refused before this moment. The escape hatch is what makes strict rules usable.
    var pausedUntil: Date?
    /// The token `.session` schedules are measured against.
    var session = ""
}
