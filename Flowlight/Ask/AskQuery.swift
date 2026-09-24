import Foundation

/// The complete list of questions a model may ask of the local history.
///
/// This enum is the privacy boundary of the whole feature. A model is never handed the database, a table, or a
/// query language — it is handed this list, and Flowlight runs whichever of these the model names and gives back
/// the numbers. There is no `sql` case and there will not be one: a model that can write its own query can read
/// anything, and then "the model never gets your history" stops being true the first time someone is clever.
///
/// Every one of these is read-only by construction, because every one of them is a method on this file that ends
/// in a `SELECT`.
enum AskQuery: String, Codable, CaseIterable, Sendable {
    /// How much moved, in total, optionally for one app.
    case trafficTotals
    /// The busiest apps in a window.
    case topApps
    /// The busiest destinations, optionally for one app.
    case topDestinations
    /// Destinations an app reached in this window that it had never reached before it.
    case newDestinations
    /// What Flowlight flagged, and why.
    case alerts
    /// The AI agents seen in a window, with where they went besides their model provider.
    case agents
    /// A series over time, for "when did it happen" rather than "how much".
    case overTime

    var summary: String {
        switch self {
        case .trafficTotals: return "Total bytes in and out, and the number of connections, for a time window — optionally for one app."
        case .topApps: return "The apps that moved the most data in a window, with their totals."
        case .topDestinations: return "The destinations that received or sent the most, with the network that owns each address."
        case .newDestinations: return "Destinations reached in this window that had never been reached before it."
        case .alerts: return "Alerts raised in a window: which rule fired, for which app, and the sentence explaining it."
        case .agents: return "AI agents active in a window, their model providers, and where else they went."
        case .overTime: return "Bytes per second, minute, hour or day across a window, for spotting when something happened."
        }
    }

    /// What the model is allowed to fill in. Kept deliberately small: a window, sometimes an app, sometimes a
    /// limit. Anything more expressive is another way of saying "write your own query".
    var parameters: [Parameter] {
        let window = [Parameter(name: "from", kind: .time, required: true,
                                detail: "Start of the window: an ISO-8601 timestamp, or a shorthand like '24h', '7d', 'today', 'yesterday'."),
                      Parameter(name: "to", kind: .time, required: false,
                                detail: "End of the window; defaults to now.")]
        let app = Parameter(name: "app", kind: .string, required: false,
                            detail: "Restrict to one app, by bundle identifier or by the name shown in Flowlight.")
        let limit = Parameter(name: "limit", kind: .integer, required: false,
                              detail: "How many rows to return, 1–50. Defaults to 10.")
        switch self {
        case .trafficTotals: return window + [app]
        case .topApps: return window + [limit]
        case .topDestinations: return window + [app, limit]
        case .newDestinations: return window + [app, limit]
        case .alerts: return window + [limit]
        case .agents: return window
        case .overTime:
            return window + [app, Parameter(name: "granularity", kind: .string, required: false,
                                            detail: "second, minute, hour, day, week, month or year. Defaults to a sensible fit for the window.")]
        }
    }

    struct Parameter: Equatable, Sendable {
        enum Kind: String, Sendable { case time, string, integer }
        var name: String
        var kind: Kind
        var required: Bool
        var detail: String
    }
}

/// One call the model asked for, before it is run.
struct AskCall: Equatable, Sendable, Identifiable {
    var id = UUID()
    var query: AskQuery
    var arguments: [String: String]

    /// Words models write when they mean "nothing".
    ///
    /// Tool arguments are often non-optional strings, so a model asked for an app it doesn't want to name will
    /// write `default`, `none`, `all` or `null` rather than leave the field out. Taken literally those become a
    /// filter for an app called "default", and the answer comes back as a confident zero. They mean the field was
    /// not filled in, so that is what they are treated as.
    static let placeholders: Set<String> = ["", "none", "null", "nil", "default", "all", "any", "n/a", "na",
                                            "unspecified", "undefined", "empty", "-", "string"]

    static func cleaned(_ arguments: [String: String]) -> [String: String] {
        arguments.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return placeholders.contains(trimmed.lowercased()) ? nil : trimmed
        }
    }

    init(id: UUID = UUID(), query: AskQuery, arguments: [String: String]) {
        self.id = id
        self.query = query
        self.arguments = Self.cleaned(arguments)
    }

    /// How the call reads in the transcript — and, more to the point, in the panel that shows what is about to
    /// leave the Mac.
    var sentence: String {
        let parts = arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return parts.isEmpty ? query.rawValue : "\(query.rawValue)(\(parts))"
    }
}

/// What a window like "24h" or "yesterday" means, resolved on this Mac rather than by the model.
///
/// The model proposes a window in words; Flowlight decides what those words mean. That keeps the range bounded —
/// there is no way to express "everything" — and it keeps time zones the Mac's business.
enum AskWindow {
    static let maximum: TimeInterval = 60 * 60 * 24 * 366

    /// Returns nil for anything unparseable, which the caller reports back to the model as a bad argument rather
    /// than quietly guessing at a window.
    static func resolve(from: String, to: String?, now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date)? {
        guard let start = moment(from, now: now, calendar: calendar) else { return nil }
        let end = to.flatMap { moment($0, now: now, calendar: calendar) } ?? now
        guard end > start else { return nil }
        // A window longer than a year is almost certainly a model reaching for "all of it"; history is pruned
        // long before that anyway, so clamping costs nothing and bounds the work.
        let clamped = end.timeIntervalSince(start) > maximum ? end.addingTimeInterval(-maximum) : start
        return (clamped, end)
    }

    static func moment(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        switch raw {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "week", "this week": return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case "month", "this month": return calendar.dateInterval(of: .month, for: now)?.start
        default: break
        }
        // "24h", "90m", "7d", "3w" — a duration back from now.
        if let unit = raw.last, let value = Double(raw.dropLast()), value > 0 {
            let seconds: Double?
            switch unit {
            case "s": seconds = value
            case "m": seconds = value * 60
            case "h": seconds = value * 3600
            case "d": seconds = value * 86_400
            case "w": seconds = value * 604_800
            default: seconds = nil
            }
            if let seconds { return now.addingTimeInterval(-seconds) }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        // A bare date, which is what a model usually writes.
        let plain = DateFormatter()
        plain.calendar = calendar
        plain.timeZone = calendar.timeZone
        plain.dateFormat = "yyyy-MM-dd"
        return plain.date(from: raw)
    }
}
