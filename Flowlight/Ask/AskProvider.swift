import Foundation
import Security

/// Who answers the question.
///
/// The order is the order of preference, and it is deliberate: the two that send nothing come first. A tool whose
/// whole promise is no account and no cloud should not need either to answer a question about itself.
enum AskProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device model, where the OS has one. Nothing leaves the Mac.
    case onDevice
    /// A model server already running on this Mac — Ollama, LM Studio, llama.cpp. Nothing leaves the Mac either,
    /// and Flowlight shows that traffic in Live like any other app's.
    case localServer
    case anthropic
    case openAI
    case gemini
    /// Anything that speaks the OpenAI chat-completions shape.
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On-device model"
        case .localServer: return "Local server (Ollama, LM Studio)"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .compatible: return "OpenAI-compatible endpoint"
        }
    }

    /// Whether choosing this means the question leaves the Mac.
    var sendsOffDevice: Bool {
        switch self {
        case .onDevice, .localServer: return false
        case .anthropic, .openAI, .gemini, .compatible: return true
        }
    }

    var needsKey: Bool { sendsOffDevice }

    var defaultEndpoint: String {
        switch self {
        case .onDevice: return ""
        case .localServer: return "http://127.0.0.1:11434/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openAI: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/models"
        case .compatible: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .onDevice: return ""
        case .localServer: return "llama3.2"
        case .anthropic: return "claude-sonnet-5"
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-2.0-flash"
        case .compatible: return ""
        }
    }
}

/// One exchange in the transcript.
struct AskTurn: Identifiable, Equatable, Sendable {
    var id = UUID()
    var question: String
    var answer: String = ""
    var calls: [AskRecordedCall] = []
    var error: String?
    var asked = Date()
    var provider: String = ""
    /// What was actually sent off the Mac, if anything, shown before it went.
    var sent: [String] = []
}

/// A query the model asked for, and what came back.
struct AskRecordedCall: Identifiable, Equatable, Sendable {
    var id = UUID()
    var call: AskCall
    var summary: String
    var failed = false
    /// Where clicking this should take you in Reports.
    var filter: TrafficFilter?
    var from: Date?
    var to: Date?
    /// Drawn under the answer when the result has a shape worth seeing.
    var chart: AskChart?
    /// Where an answer about the app itself points.
    var screen: SidebarItem?
}

/// What a provider needs to answer. The conversation is only ever the question and the results of queries
/// Flowlight ran — never a row of history, and never anything the model wasn't asked about.
struct AskRequest: Sendable {
    var question: String
    var instructions: String
    var queries: [AskQuery]
}

/// Answering a question, wherever that happens.
protocol AskProviding: Sendable {
    var label: String { get }
    var sendsOffDevice: Bool { get }
    /// `run` is the only way to reach the history. Everything a provider learns about this Mac comes through it.
    func answer(_ request: AskRequest, run: @escaping @Sendable (AskCall) async -> String,
                sending: @escaping @Sendable (String) -> Void) async throws -> String
}

/// The instructions every provider is given. Written once, here, so a local model and a hosted one are held to
/// the same rules — including the one about not inventing numbers.
enum AskPrompt {
    static func instructions(queries: [AskQuery], now: Date = Date()) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "EEEE d MMMM yyyy, HH:mm zzz"
        var text = """
        You answer questions about network activity recorded by Flowlight, a macOS network monitor, on this Mac.

        Right now it is \(clock.string(from: now)). Work out any window from that.

        You cannot see the database. You can call the queries listed below; Flowlight runs them locally and gives \
        you back totals and names. Call whatever you need, then answer in two or three sentences of plain English.

        Rules:
        - Never invent a number. If a query returns nothing, say that nothing was recorded rather than guessing.
        - Prefer a relative window — '1h', '24h', '7d', 'today', 'yesterday' — and let Flowlight resolve it. Write         an absolute timestamp only when the question names a specific date.
        - Leave an argument empty when you don't mean to narrow by it. Never write 'default', 'none' or 'all' into         one: those are read as values, not as blanks.
        - Bytes come back as whole numbers; convert them to human units in your answer (KB, MB, GB).
        - Prefer one precise query to several vague ones.
        - Questions about Flowlight itself — how to do something, what a feature is, whether something is switched         on, why nothing is showing — are yours to answer too. Call `howTo` for how a feature works and `settings`         for how this Mac is configured. Never answer those from memory: the steps differ between versions, and a         made-up menu path is worse than no answer.
        - Ask for a chart when the shape of the answer matters more than the numbers: `chart: "line"` for change         over time, `"bar"` to compare things, `"pie"` for a split of one whole. Don't ask for one when a sentence         is enough — most questions don't need a picture.
        - If the question is about neither this Mac's activity nor Flowlight, say so plainly instead of answering it.

        Queries you may call:

        """
        for query in queries {
            text += "- \(query.rawValue): \(query.summary)\n"
            for parameter in query.parameters {
                text += "    \(parameter.name)\(parameter.required ? " (required)" : ""): \(parameter.detail)\n"
            }
        }
        return text
    }
}

/// The key for a hosted provider, in the login Keychain — never in preferences, for the reason Flowlight exists
/// to point at: a plist is readable by anything running as you.
enum AskSecrets {
    static let service = "com.flowlight.app.ask"

    private static func query(_ kind: AskProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue]
    }

    static func key(for kind: AskProviderKind) -> String {
        var lookup = query(kind)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func save(_ key: String, for kind: AskProviderKind) -> OSStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(kind) }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(kind) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query(kind)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Flowlight — \(kind.title)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    static func remove(_ kind: AskProviderKind) -> OSStatus {
        SecItemDelete(query(kind) as CFDictionary)
    }
}
