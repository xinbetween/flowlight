import Foundation

/// The limits on what HTTPS inspection is allowed to keep.
///
/// Inspection records request and response bodies, which is the most sensitive thing Flowlight ever holds — and
/// what protected them until now was a guess at which headers carry credentials. A guess is the wrong shape for
/// this. It can only know the headers somebody thought of, it fails silently when it is wrong, and the failure
/// is a secret written to disk under a promise that it wouldn't be.
///
/// So the guess stops being the only defence. Headers are kept because they are on a list, not discarded
/// because they looked dangerous; the amount recorded per app has a ceiling; and the session ends on its own,
/// because "until someone remembers" is not a limit. The denylist is still here, because someone reading an
/// unfamiliar API needs to see headers nobody has thought to allow yet — it is a choice now rather than the
/// only behaviour.
struct InspectionBudget: Sendable, Equatable {

    /// What happens to a header's value before it is written down.
    enum HeaderPolicy: String, CaseIterable, Identifiable, Sendable {
        /// Keep only the values of headers on the allowlist. Everything else is replaced by its length.
        case allowlist
        /// Keep every value except those that look like credentials. How Flowlight behaved before 0.9.3.
        case redactSecrets
        /// Keep no header values at all. The names still appear, so you can see what was sent.
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .allowlist: return L("Keep only headers I allow")
            case .redactSecrets: return L("Keep everything except credentials")
            case .none: return L("Keep no header values")
            }
        }

        var detail: String {
            switch self {
            case .allowlist:
                return L("The safest of the three: a header nobody has thought about yet is hidden rather than stored.")
            case .redactSecrets:
                return L("Matches names and words against a built-in list. Useful for reading an unfamiliar API, but a credential under a name nothing recognises is recorded.")
            case .none:
                return L("Names are still recorded, so you can see which headers were sent without keeping any of their values.")
            }
        }
    }

    var headerPolicy: HeaderPolicy = .allowlist
    var allowedHeaders: Set<String> = Self.defaultAllowedHeaders
    /// Extra fragments that, found in a header's *name*, mark it as carrying a credential — on top of the
    /// built-in list, which cannot know a particular vendor's spelling.
    ///
    /// Patterns, not secrets. The old name for this was `extraSecretWords`, which read as "words that are
    /// secret" rather than "words that indicate one", and CodeQL misread it the same way a person would:
    /// it reported storing them in UserDefaults as cleartext storage of credentials. The value is a list of
    /// substrings like `entitlement`; nothing sensitive is kept here, and the name now says so.
    var extraRedactionPatterns: [String] = []
    /// Bytes of request and response body kept per app per day. 0 means no ceiling.
    ///
    /// Over the ceiling, the exchange is still recorded — its time, host, path, status and headers — and only the
    /// bodies are dropped. A missing body is a gap you can see; a missing exchange looks like nothing happened,
    /// which is the one thing Flowlight must never imply.
    var dailyBodyBytesPerApp: Int64 = 0
    /// How long recorded exchanges are kept.
    var retentionDays = 3
    /// Minutes after which inspection turns itself off. 0 means it runs until switched off by hand.
    var sessionMinutes = 480

    /// Headers worth reading that never carry a credential.
    ///
    /// `referer` is deliberately absent: a URL in it can carry a token in its query string, which is exactly the
    /// kind of secret that arrives somewhere nobody was watching for one.
    static let defaultAllowedHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language", "accept-ranges", "age", "allow", "cache-control",
        "connection", "content-disposition", "content-encoding", "content-language", "content-length",
        "content-range", "content-type", "date", "etag", "expires", "host", "if-modified-since",
        "if-none-match", "last-modified", "location", "origin", "pragma", "range", "retry-after", "server",
        "transfer-encoding", "user-agent", "vary", "via",
        // Sent by the AI SDKs, and the reason an agent's exchange is readable at all: the model, the API
        // version and what the rate limiter said. None of them authenticate anything.
        "anthropic-version", "anthropic-beta", "openai-version", "openai-organization", "openai-processing-ms",
        "x-request-id", "x-correlation-id", "x-trace-id",
        "x-ratelimit-limit-requests", "x-ratelimit-limit-tokens", "x-ratelimit-remaining-requests",
        "x-ratelimit-remaining-tokens", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens",
        "x-stainless-lang", "x-stainless-package-version", "x-stainless-os", "x-stainless-runtime",
        "x-stainless-runtime-version", "x-stainless-retry-count",
    ]

    enum Keys {
        static let headerPolicy = "inspection.headerPolicy"
        static let allowedHeaders = "inspection.allowedHeaders"
        static let extraRedactionPatterns = "inspection.extraRedactionPatterns"
        static let dailyBodyMBPerApp = "inspection.dailyBodyMBPerApp"
        static let retentionDays = "inspection.retentionDays"
        static let sessionMinutes = "inspection.sessionMinutes"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.headerPolicy: HeaderPolicy.allowlist.rawValue,
            Keys.dailyBodyMBPerApp: 0,
            Keys.retentionDays: 3,
            Keys.sessionMinutes: 480,
        ])
    }

    static func load(_ defaults: UserDefaults = .standard) -> InspectionBudget {
        var budget = InspectionBudget()
        if let raw = defaults.string(forKey: Keys.headerPolicy), let policy = HeaderPolicy(rawValue: raw) {
            budget.headerPolicy = policy
        }
        // An empty stored allowlist is a real choice — "allow nothing" — and has to survive a relaunch, so the
        // absence of the key is what falls back to the defaults, not an empty array.
        if let stored = defaults.array(forKey: Keys.allowedHeaders) as? [String] {
            budget.allowedHeaders = Set(stored.map { $0.lowercased() })
        }
        budget.extraRedactionPatterns = (defaults.array(forKey: Keys.extraRedactionPatterns) as? [String]) ?? []
        budget.dailyBodyBytesPerApp = Int64(max(0, defaults.integer(forKey: Keys.dailyBodyMBPerApp))) * 1_000_000
        budget.retentionDays = max(1, defaults.integer(forKey: Keys.retentionDays))
        budget.sessionMinutes = max(0, defaults.integer(forKey: Keys.sessionMinutes))
        return budget
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(headerPolicy.rawValue, forKey: Keys.headerPolicy)
        defaults.set(allowedHeaders.sorted(), forKey: Keys.allowedHeaders)
        defaults.set(extraRedactionPatterns, forKey: Keys.extraRedactionPatterns)
        defaults.set(Int(dailyBodyBytesPerApp / 1_000_000), forKey: Keys.dailyBodyMBPerApp)
        defaults.set(retentionDays, forKey: Keys.retentionDays)
        defaults.set(sessionMinutes, forKey: Keys.sessionMinutes)
    }

    /// The sentence the Inspect screen shows about what it is keeping. Built from the settings rather than
    /// written out, because the hardcoded version said "kept for 3 days" long after the period became a setting,
    /// and "credential headers are never stored" when what happens is that their length is stored instead.
    var summary: String {
        let headers: String
        switch headerPolicy {
        case .allowlist:
            headers = L("Only the %lld header names you allow keep their values; the rest are replaced by their length.",
                        allowedHeaders.count)
        case .redactSecrets:
            headers = L("Headers that look like credentials are replaced by their length — a heuristic, not a guarantee.")
        case .none:
            headers = L("No header values are kept at all.")
        }
        // Whole sentences joined, never fragments concatenated: a sentence spliced from translated pieces comes
        // out in English word order in every other language, which this project has already shipped once.
        // The period is written into each sentence rather than handed in as a finished phrase. A `%@` that will
        // receive "3 days" tells the translator nothing: Japanese needs 日間 rather than 日 here, and no space
        // before it, neither of which is visible from the outer sentence.
        var sentences = [retentionSentence, headers]
        if dailyBodyBytesPerApp > 0 {
            sentences.append(L("Bodies are no longer kept once an app has recorded %@ in a day.",
                               ByteFormat.string(dailyBodyBytesPerApp)))
        }
        if let session = sessionSentence { sentences.append(session) }
        return sentences.joined(separator: " ")
    }

    private var retentionSentence: String {
        retentionDays == 1 ? L("Recorded requests are kept for 1 day.")
                           : L("Recorded requests are kept for %lld days.", retentionDays)
    }

    private var sessionSentence: String? {
        guard sessionMinutes > 0 else { return nil }
        let hours = sessionMinutes / 60, minutes = sessionMinutes % 60
        if hours == 0 { return L("Inspection turns itself off after %lld minutes.", minutes) }
        if minutes == 0 {
            return hours == 1 ? L("Inspection turns itself off after 1 hour.")
                              : L("Inspection turns itself off after %lld hours.", hours)
        }
        return L("Inspection turns itself off after %lld hours %lld minutes.", hours, minutes)
    }

    /// "90 minutes", "8 hours", "1 hour 30 minutes" — whichever reads as the period someone chose.
    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return L("%lld minutes", minutes) }
        let hours = minutes / 60, rest = minutes % 60
        let hoursText = hours == 1 ? L("1 hour") : L("%lld hours", hours)
        guard rest > 0 else { return hoursText }
        return hoursText + " " + L("%lld minutes", rest)
    }
}
