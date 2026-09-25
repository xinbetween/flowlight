import Foundation

/// What Flowlight is currently set to do, as the model is allowed to see it.
///
/// Someone asking "is HTTPS inspection on?" or "why am I not seeing any traffic?" is asking about the app, not
/// about their history, and until now there was nothing in the tool list that could answer. This is that: a
/// snapshot of the switches, taken on the main actor when a question starts, so the query that reads it runs off
/// the main thread like every other one.
///
/// It carries settings, never secrets. There are no API keys here, no export headers and no endpoint URLs — those
/// live in the Keychain and have no business travelling to a model to answer a question about whether a feature is
/// switched on.
struct AskEnvironment: Sendable, Equatable {
    var appVersion = ""
    var captureSource = ""
    var captureStatus = ""
    var receiving = false
    var extensionState = ""
    var fellBackToSampler = false
    var canBlock = false
    var inspecting = false
    var inspectionScope = ""
    var exportEnabled = false
    var exportConfigured = false
    var focus = ""
    var backgroundOnly = false
    var watchingBluetooth = false
    var watchingUSB = false
    var rules: [String] = []
    var guardrails: [String] = []
    var agentAllowlists = 0
    var askProvider = ""
    var askSendsOffDevice = false

    static let empty = AskEnvironment()
}
