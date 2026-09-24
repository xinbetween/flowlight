import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answering with the model the operating system already has.
///
/// This is the default wherever it exists, and the reason is not performance: it costs nothing, works with the
/// network off, and sends not one byte anywhere. For a tool whose promise is no account and no cloud, anything
/// else is a compromise that has to be chosen deliberately.
///
/// Apple's Foundation Models framework arrived in macOS 26. Flowlight still runs on macOS 15, so every use of it
/// sits behind an availability check and the feature simply offers the other providers where it isn't there.
enum OnDeviceAsk {
    /// Whether this Mac can answer without sending anything. The reasons are worth keeping apart: a Mac that
    /// can't run the model at all and one where the user hasn't switched Apple Intelligence on need different
    /// sentences, not the same shrug.
    enum Readiness: Equatable {
        case ready
        case needsNewerMacOS
        case notEnabled(String)

        var explanation: String? {
            switch self {
            case .ready: return nil
            case .needsNewerMacOS:
                return "The on-device model needs macOS 26 or later. Everything else here still works: a local server "
                    + "like Ollama sends nothing off the Mac either."
            case .notEnabled(let reason): return reason
            }
        }
    }

    static var readiness: Readiness {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled("Apple Intelligence is switched off in System Settings, so the on-device model isn't there to ask.")
        case .unavailable(.modelNotReady):
            return .notEnabled("macOS is still downloading the on-device model. It'll be ready shortly.")
        case .unavailable(.deviceNotEligible):
            return .notEnabled("This Mac can't run the on-device model. A local server like Ollama sends nothing off the Mac either.")
        case .unavailable:
            return .notEnabled("The on-device model isn't available right now.")
        }
        #else
        return .needsNewerMacOS
        #endif
    }

    static var isReady: Bool { readiness == .ready }
}

#if canImport(FoundationModels)

/// The on-device provider.
@available(macOS 26, *)
struct OnDeviceProvider: AskProviding {
    let label = "On-device model"
    let sendsOffDevice = false

    func answer(_ request: AskRequest, run: @escaping @Sendable (AskCall) async -> String,
                sending: @escaping @Sendable (String) -> Void) async throws -> String {
        let session = LanguageModelSession(tools: [HistoryTool(run: run)], instructions: request.instructions)
        let response = try await session.respond(to: request.question)
        return response.content
    }
}

/// One tool rather than seven, with the query named as an argument.
///
/// The model can write any string it likes into `query`; anything that isn't one of `AskQuery`'s cases comes back
/// as an error it can read and correct. That is the same boundary the rest of the feature has — a fixed list of
/// questions — expressed in the shape this framework wants.
@available(macOS 26, *)
struct HistoryTool: Tool {
    let name = "runQuery"
    let description = "Run one of Flowlight's read-only queries against the network history recorded on this Mac."
    let run: @Sendable (AskCall) async -> String

    @Generable
    struct Arguments {
        @Guide(description: "One of: trafficTotals, topApps, topDestinations, newDestinations, alerts, agents, overTime.")
        var query: String
        @Guide(description: "Start of the window: '24h', '7d', 'today', 'yesterday', or an ISO-8601 timestamp.")
        var from: String
        @Guide(description: "End of the window. Leave empty for now.")
        var to: String
        @Guide(description: "One app, by name or bundle identifier. Leave empty for every app.")
        var app: String
        @Guide(description: "How many rows, 1-50. Leave empty for 10.")
        var limit: String
        @Guide(description: "second, minute, hour or day. Leave empty to let Flowlight choose.")
        var granularity: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let query = AskQuery(rawValue: arguments.query.trimmingCharacters(in: .whitespaces)) else {
            return "There is no query called '\(arguments.query)'. The ones that exist are: "
                + AskQuery.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
        var fields: [String: String] = ["from": arguments.from]
        for (key, value) in [("to", arguments.to), ("app", arguments.app), ("limit", arguments.limit),
                             ("granularity", arguments.granularity)] where !value.trimmingCharacters(in: .whitespaces).isEmpty {
            fields[key] = value
        }
        return await run(AskCall(query: query, arguments: fields))
    }
}

#endif
