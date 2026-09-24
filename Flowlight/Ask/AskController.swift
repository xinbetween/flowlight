import Foundation

/// Asking Flowlight a question, and keeping the record of what that cost in privacy.
///
/// The controller owns three things: which provider answers, the loop that lets it call queries, and the
/// transcript — including, for anything that left the Mac, the exact body that was sent.
@MainActor
final class AskController: ObservableObject {
    enum Keys {
        static let provider = "ask.provider"
        static let endpoint = "ask.endpoint"
        static let model = "ask.model"
    }

    @Published private(set) var turns: [AskTurn] = []
    @Published private(set) var thinking = false
    /// Set while a question is in flight, so the screen can say which provider is answering.
    @Published private(set) var status = ""

    private weak var db: TrafficDatabase?

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.provider: (OnDeviceAsk.isReady ? AskProviderKind.onDevice : .localServer).rawValue,
        ])
    }

    func attach(db: TrafficDatabase) {
        self.db = db
        publishPort()
    }

    // MARK: Settings

    var provider: AskProviderKind {
        get { AskProviderKind(rawValue: UserDefaults.standard.string(forKey: Keys.provider) ?? "") ?? .onDevice }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.provider)
            objectWillChange.send()
            publishPort()
        }
    }

    var endpoint: String {
        get { UserDefaults.standard.string(forKey: Keys.endpoint).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultEndpoint }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.endpoint)
            objectWillChange.send()
            publishPort()
        }
    }

    /// Tells the inspection proxy which loopback port belongs to a model server, so asking a local model shows up
    /// in Live like anything else. Flowlight has to hold itself to its own standard, and the local case is the one
    /// where it would be easiest not to.
    func publishPort() {
        guard let url = URL(string: endpoint), let host = url.host,
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            ProxyAttribution.shared.askPort = nil
            return
        }
        ProxyAttribution.shared.askPort = url.port.map { UInt16(truncatingIfNeeded: $0) }
            ?? (url.scheme == "https" ? 443 : 80)
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: Keys.model).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: Keys.model); objectWillChange.send() }
    }

    var apiKey: String {
        get { AskSecrets.key(for: provider) }
        set { AskSecrets.save(newValue, for: provider); objectWillChange.send() }
    }

    /// Whether asking is possible at all right now, and why not when it isn't.
    var blockedReason: String? {
        switch provider {
        case .onDevice: return OnDeviceAsk.readiness.explanation
        case .localServer, .compatible:
            return endpoint.isEmpty ? "Set the endpoint of the model server you're running." : nil
        case .anthropic, .openAI, .gemini:
            return apiKey.isEmpty ? "\(provider.title) needs an API key. It goes to your login Keychain, not to Flowlight's preferences." : nil
        }
    }

    /// Whether answering this question would send anything off the Mac. The screen says so before the question is
    /// asked, not after.
    var sendsOffDevice: Bool { provider.sendsOffDevice }

    func clear() { turns = [] }

    // MARK: Asking

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !thinking, let db else { return }
        guard blockedReason == nil else { return }

        let kind = provider
        let provider = makeProvider(kind)
        var turn = AskTurn(question: trimmed, provider: provider.label)
        turns.insert(turn, at: 0)
        thinking = true
        status = "Asking \(provider.label)…"

        let request = AskRequest(question: trimmed, instructions: AskPrompt.instructions(queries: AskQuery.allCases),
                                 queries: AskQuery.allCases)
        let turnID = turn.id
        let recorder = CallRecorder()

        Task { [weak self] in
            let runner: @Sendable (AskCall) async -> String = { call in
                await recorder.record(call)
                do {
                    let result = try await Self.run(call, db: db)
                    await recorder.finish(call, summary: result.summary, filter: result.filter, from: result.from, to: result.to)
                    return result.json
                } catch {
                    let message = (error as? AskQueryRunner.Failure)?.description ?? error.localizedDescription
                    await recorder.finish(call, summary: message, failed: true)
                    return message
                }
            }
            let sender: @Sendable (String) -> Void = { body in
                Task { await recorder.sent(body) }
            }
            do {
                let answer = try await provider.answer(request, run: runner, sending: sender)
                await self?.finish(turnID, answer: answer, recorder: recorder)
            } catch {
                let message = (error as? RemoteProvider.Failure)?.description ?? error.localizedDescription
                await self?.finish(turnID, answer: "", error: message, recorder: recorder)
            }
        }
        turn.answer = ""
    }

    private func finish(_ id: UUID, answer: String, error: String? = nil, recorder: CallRecorder) async {
        let calls = await recorder.calls
        let sent = await recorder.bodies
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].answer = answer
        turns[index].error = error
        turns[index].calls = calls
        turns[index].sent = sent
        thinking = false
        status = ""
    }

    /// Runs one query off the main actor. The database work is the same work Reports does.
    private nonisolated static func run(_ call: AskCall, db: TrafficDatabase) async throws -> AskQueryRunner.Result {
        try await withCheckedThrowingContinuation { continuation in
            db.queue.async {
                do { continuation.resume(returning: try AskQueryRunner.run(call, db: db)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func makeProvider(_ kind: AskProviderKind) -> any AskProviding {
        #if canImport(FoundationModels)
        if kind == .onDevice, #available(macOS 26, *) { return OnDeviceProvider() }
        #endif
        return RemoteProvider(kind: kind == .onDevice ? .localServer : kind,
                              endpoint: endpoint, model: model, apiKey: apiKey)
    }
}

/// Collects what happened during one question, from whichever thread it happened on.
private actor CallRecorder {
    private(set) var calls: [AskRecordedCall] = []
    private(set) var bodies: [String] = []

    func record(_ call: AskCall) {
        calls.append(AskRecordedCall(call: call, summary: "running…"))
    }

    func finish(_ call: AskCall, summary: String, failed: Bool = false, filter: TrafficFilter? = nil,
                from: Date? = nil, to: Date? = nil) {
        guard let index = calls.lastIndex(where: { $0.call.id == call.id }) else { return }
        calls[index].summary = summary
        calls[index].failed = failed
        calls[index].filter = filter
        calls[index].from = from
        calls[index].to = to
    }

    func sent(_ body: String) { bodies.append(body) }
}
