import Foundation

/// The app-owned half of managed rule packs: built-in definitions, user activation/scope, exceptions, and the
/// complete validated snapshot handed to the Network Extension.
@MainActor
final class RulePackStore: ObservableObject {
    enum ApplyStatus: Equatable, Sendable {
        case off, ready, applying, enforcing, watchingOnly, incompatible(String), failed(String)
    }

    @Published private(set) var configurations: [RulePackConfiguration] = []
    @Published private(set) var overrides: [RulePackOverride] = []
    @Published private(set) var events: [RulePackEventRecord] = []
    @Published private(set) var deliveryStats = RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0)
    @Published private(set) var status: ApplyStatus = .off
    @Published private(set) var version = 0

    let definitions: [RulePackDefinition]
    var onChange: (RulePackSnapshot?) -> Void = { _ in }
    private weak var db: TrafficDatabase?
    private var definitionsValid = true

    init(definitions: [RulePackDefinition] = BuiltInRulePacks.all) {
        self.definitions = definitions
        do { try RulePackValidator.validate(definitions) }
        catch {
            definitionsValid = false
            status = .failed("Built-in pack validation failed: \(error)")
        }
    }

    var enabledCount: Int { configurations.filter(\.enabled).count }
    var hasEnabledPacks: Bool { enabledCount > 0 }
    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    func configuration(for packID: String) -> RulePackConfiguration {
        configurations.first { $0.packID == packID } ?? RulePackConfiguration(packID: packID)
    }

    func overrides(for packID: String) -> [RulePackOverride] {
        overrides.filter { $0.packID == packID }
    }

    func attach(db: TrafficDatabase) {
        self.db = db
        reload()
    }

    func reload() {
        guard let db else { return }
        db.async { [weak self] db in
            let saved = try db.loadRulePackConfigurations()
            let exceptions = try db.loadRulePackOverrides()
            let events = try db.rulePackEvents(limit: 300)
            let deliveryStats = try db.rulePackDeliveryStats()
            Task { @MainActor in
                guard let self else { return }
                let known = Set(self.definitions.map(\.id))
                self.configurations = self.definitions.map { definition in
                    guard var configuration = saved.first(where: { $0.packID == definition.id }) else {
                        return RulePackConfiguration(packID: definition.id)
                    }
                    if configuration.enabled, !configuration.isConsented(to: definition) {
                        configuration.enabled = false
                    }
                    return configuration
                }
                self.overrides = exceptions.filter { known.contains($0.packID) }
                self.events = events.filter { known.contains($0.packID) }
                self.deliveryStats = deliveryStats
                self.publish()
            }
        }
    }

    func save(_ configuration: RulePackConfiguration, completion: ((Bool) -> Void)? = nil) {
        guard definitions.contains(where: { $0.id == configuration.packID }) else {
            completion?(false)
            return
        }
        var cleaned = configuration
        if cleaned.enabled, let definition = definitions.first(where: { $0.id == cleaned.packID }) {
            cleaned.consentedVersion = definition.manifest.version
            cleaned.consentedContentSHA256 = definition.manifest.contentSHA256
        }
        cleaned.apps = Array(Set(configuration.apps.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        if cleaned.scope == .selectedApps && cleaned.apps.isEmpty { cleaned.enabled = false }
        persist({ try $0.saveRulePackConfiguration(cleaned) }, then: { [weak self] in
            guard let self else { completion?(false); return }
            if let index = self.configurations.firstIndex(where: { $0.packID == cleaned.packID }) {
                self.configurations[index] = cleaned
            } else {
                self.configurations.append(cleaned)
            }
            self.publish()
            completion?(true)
        }, onFailure: {
            completion?(false)
        })
    }

    func setEnabled(_ packID: String, _ enabled: Bool) {
        var value = configuration(for: packID)
        value.enabled = enabled
        save(value)
    }

    func addOverride(_ override: RulePackOverride) {
        guard definitions.contains(where: { $0.id == override.packID }),
              let host = HostCanonicalizer.host(override.host) else { return }
        var cleaned = override
        cleaned.host = host
        cleaned.app = override.app.trimmingCharacters(in: .whitespacesAndNewlines)
        persist({ try $0.saveRulePackOverride(cleaned) }) { [weak self] in
            guard let self else { return }
            self.overrides.removeAll { $0.id == cleaned.id }
            self.overrides.append(cleaned)
            self.publish()
        }
    }

    func deleteOverride(_ override: RulePackOverride) {
        persist({ try $0.deleteRulePackOverride(override.id) }) { [weak self] in
            self?.overrides.removeAll { $0.id == override.id }
            self?.publish()
        }
    }

    func updateStatus(_ newStatus: ApplyStatus) { status = newStatus }

    func markApplying() {
        guard definitionsValid else { return }
        status = .applying
    }

    func record(_ batch: RulePackEventBatch, completion: @escaping (Bool) -> Void) {
        guard let db else { completion(false); return }
        db.queue.async { [weak self, weak db] in
            guard let db else { completion(false); return }
            do {
                _ = try db.recordRulePackEventBatch(batch)
                let events = try db.rulePackEvents(limit: 300)
                let deliveryStats = try db.rulePackDeliveryStats()
                Task { @MainActor in
                    self?.events = events
                    self?.deliveryStats = deliveryStats
                    self?.version += 1
                    completion(true)
                }
            } catch {
                appLog.error("rule pack batch failed: \(String(describing: error), privacy: .public)")
                Task { @MainActor in completion(false) }
            }
        }
    }

    func events(for packID: String) -> [RulePackEventRecord] { events.filter { $0.packID == packID } }

    func clearActivity() {
        events = []
        deliveryStats = RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0)
        version += 1
    }

    var snapshot: RulePackSnapshot? {
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let active = configurations.filter { configuration in
            configuration.enabled
                && definitionsByID[configuration.packID].map(configuration.isConsented(to:)) == true
        }
        guard !active.isEmpty else { return nil }
        let packIDs = Set(active.map(\.packID))
        let included = definitions.filter { packIDs.contains($0.id) }
        let includedOverrides = overrides.filter { packIDs.contains($0.packID) }
        return RulePackSnapshot.make(definitions: included, configurations: active, overrides: includedOverrides)
    }

    private func persist(_ write: @escaping (TrafficDatabase) throws -> Void,
                         then commit: @escaping @MainActor () -> Void,
                         onFailure: (@MainActor () -> Void)? = nil) {
        guard let db else {
            status = .failed("Rule pack storage is unavailable.")
            onFailure?()
            return
        }
        db.queue.async { [weak self, weak db] in
            guard let db else {
                Task { @MainActor in
                    self?.status = .failed("Rule pack storage is unavailable.")
                    onFailure?()
                }
                return
            }
            do {
                try write(db)
                Task { @MainActor in commit() }
            } catch {
                Task { @MainActor in
                    self?.status = .failed("Could not save the rule pack change: \(error.localizedDescription)")
                    onFailure?()
                }
            }
        }
    }

    private func publish() {
        version += 1
        guard definitionsValid else { return }
        status = hasEnabledPacks ? .ready : .off
        onChange(snapshot)
    }
}
