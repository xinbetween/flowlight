import Foundation

/// The guardrails an agent is held to, and what they have taken away from it.
///
/// Kept apart from `RuleStore` because the two answer different questions and fail in different ways: a network
/// rule works whenever the extension is running, and a guardrail only works when HTTPS inspection is on, because
/// the tool list it edits lives inside a request body.
@MainActor
final class GuardrailStore: ObservableObject {
    @Published private(set) var guardrails: [Guardrail] = []
    @Published private(set) var version = 0

    /// The guardrails as the proxy sees them, off the main actor.
    let live = LiveGuardrails()

    private weak var db: TrafficDatabase?

    func attach(db: TrafficDatabase) {
        self.db = db
        db.async { [weak self] db in
            let loaded = (try? db.loadGuardrails()) ?? []
            Task { @MainActor in
                self?.guardrails = loaded
                self?.publish()
            }
        }
    }

    func save(_ guardrail: Guardrail) {
        if let index = guardrails.firstIndex(where: { $0.id == guardrail.id }) {
            guardrails[index] = guardrail
        } else {
            guardrails.append(guardrail)
        }
        db?.async { try $0.saveGuardrail(guardrail) }
        publish()
    }

    func save(_ many: [Guardrail]) {
        for one in many { save(one) }
    }

    func delete(_ guardrail: Guardrail) {
        guardrails.removeAll { $0.id == guardrail.id }
        db?.async { try $0.deleteGuardrail(guardrail.id) }
        publish()
    }

    func setEnabled(_ guardrail: Guardrail, _ on: Bool) {
        guard var found = guardrails.first(where: { $0.id == guardrail.id }) else { return }
        found.enabled = on
        save(found)
    }

    /// One tool, refused for one agent — the switch beside a tool in the Guardrails tab.
    func refuse(agent: String, server: String?, tool: String) {
        save(Guardrail(agent: agent, server: server ?? "", tool: tool, origin: .observed))
    }

    /// The guardrail standing between this agent and this tool, if any.
    func refusing(agent: String, server: String?, tool: String) -> Guardrail? {
        GuardrailBook.refusing(guardrails, agent: agent, server: server, tool: tool)
    }

    func guardrails(for agent: String) -> [Guardrail] {
        guardrails.filter { $0.agent.isEmpty || $0.agent.caseInsensitiveCompare(agent) == .orderedSame }
    }

    /// Counted from what the guardrails themselves record, so the tab can say whether any of this is doing
    /// anything without going to the database.
    func record(_ events: [RuleEvent]) {
        for event in events {
            guard let index = guardrails.firstIndex(where: { $0.id == event.ruleID }) else { continue }
            guardrails[index].hits += 1
            guardrails[index].lastHit = Date(timeIntervalSince1970: TimeInterval(event.at))
            let updated = guardrails[index]
            db?.async { try $0.saveGuardrail(updated) }
        }
        version += 1
    }

    private func publish() {
        version += 1
        live.replace(guardrails)
    }
}

/// The guardrail list as the proxy sees it: behind a lock, because the decision happens while a request is being
/// framed and an actor hop there is a request that arrives late.
final class LiveGuardrails: @unchecked Sendable {
    private let lock = NSLock()
    private var guardrails: [Guardrail] = []

    func replace(_ guardrails: [Guardrail]) {
        lock.lock(); defer { lock.unlock() }
        self.guardrails = guardrails.filter { $0.enabled && $0.isComplete }
    }

    func all() -> [Guardrail] {
        lock.lock(); defer { lock.unlock() }
        return guardrails
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return guardrails.isEmpty
    }
}
