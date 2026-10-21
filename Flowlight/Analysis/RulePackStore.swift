import Foundation

extension RulePackOverride {
    func hasSameScope(as other: RulePackOverride) -> Bool {
        packID == other.packID
            && app.caseInsensitiveCompare(other.app) == .orderedSame
            && host.caseInsensitiveCompare(other.host) == .orderedSame
            && match == other.match
    }
}

/// The app-owned half of managed rule packs: verified definitions, user activation/scope, exceptions, and the
/// complete validated snapshot handed to the Network Extension.
@MainActor
final class RulePackStore: ObservableObject {
    enum ApplyStatus: Equatable, Sendable {
        case off, ready, applying, enforcing, watchingOnly, incompatible(String), failed(String)
    }

    enum SaveResult: Equatable, Sendable {
        case saved
        case staleReview
        case failed(String)

        var succeeded: Bool { self == .saved }
    }

    @Published private(set) var configurations: [RulePackConfiguration] = []
    @Published private(set) var overrides: [RulePackOverride] = []
    @Published private(set) var events: [RulePackEventRecord] = []
    @Published private(set) var deliveryStats = RulePackDeliveryStats(droppedHits: 0, droppedKeys: 0)
    @Published private(set) var status: ApplyStatus = .off
    @Published private(set) var version = 0
    @Published private(set) var definitions: [RulePackDefinition]

    var onChange: (RulePackSnapshot?) -> Void = { _ in }
    private weak var db: TrafficDatabase?
    private var definitionsValid = true
    private var catalogReceipt: RulePackCatalogReceipt?
    private var committedSnapshot: RulePackSnapshot?
    private var revision = 0

    init(definitions: [RulePackDefinition] = BuiltInRulePacks.all) {
        self.definitions = definitions.sorted { $0.id < $1.id }
        do { try RulePackValidator.validate(self.definitions) }
        catch {
            definitionsValid = false
            status = .failed("Built-in pack validation failed: \(error)")
        }
        rebuildSnapshot()
    }

    var enabledCount: Int { committedSnapshot?.configurations.count ?? 0 }
    var hasEnabledPacks: Bool { committedSnapshot != nil }
    var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    var snapshot: RulePackSnapshot? { committedSnapshot }

    func configuration(for packID: String) -> RulePackConfiguration {
        configurations.first { $0.packID == packID } ?? RulePackConfiguration(packID: packID)
    }

    func overrides(for packID: String) -> [RulePackOverride] {
        overrides.filter { $0.packID == packID }
    }

    func reviewReceipt(for definition: RulePackDefinition) -> RulePackReviewReceipt? {
        guard let catalogReceipt else { return nil }
        return RulePackReviewReceipt(
            packID: definition.id,
            version: definition.manifest.version,
            contentSHA256: definition.manifest.contentSHA256,
            catalogSequence: catalogReceipt.sequence,
            catalogDigest: catalogReceipt.digest
        )
    }

    func attach(db: TrafficDatabase, completion: (() -> Void)? = nil) {
        self.db = db
        reload(completion: completion)
    }

    func reload(completion: (() -> Void)? = nil) {
        guard let db else { return }
        revision += 1
        let expectedRevision = revision
        Task { [weak self, weak db] in
            guard let db else { return }
            do {
                let loaded = try await db.asyncResult { db in
                    (try db.loadRulePackConfigurations(), try db.loadRulePackOverrides(),
                     try db.rulePackEvents(limit: 300), try db.rulePackDeliveryStats(),
                     try db.loadRulePackCatalogState(catalogID: RulePackCatalogVerifier.catalogID).receipt)
                }
                guard let self, self.revision == expectedRevision else { return }
                self.catalogReceipt = loaded.4
                self.applyLoaded(configurations: loaded.0, overrides: loaded.1,
                                 events: loaded.2, deliveryStats: loaded.3)
                completion?()
            } catch {
                guard let self, self.revision == expectedRevision else { return }
                self.status = .failed("Could not load rule packs: \(String(describing: error))")
                completion?()
            }
        }
    }

    /// Prevents a higher durable watermark with missing/corrupt bytes from falling back to bundled enforcement while
    /// a recovery copy is fetched. Saved scope and consent remain in SQLite; no definition can enter a snapshot.
    func enterCatalogRecovery() {
        revision += 1
        definitions = []
        definitionsValid = true
        catalogReceipt = nil
        configurations = []
        overrides = []
        committedSnapshot = nil
        publish()
    }

    /// Installs definitions only after `acceptVerifiedRulePackCatalog` committed them. A newer local mutation bumps
    /// the revision first, so an older asynchronous install result cannot overwrite it.
    func installCommittedCatalog(_ catalog: VerifiedRulePackCatalog,
                                 acceptance: RulePackCatalogAcceptance) {
        do { try RulePackValidator.validate(catalog.definitions) }
        catch {
            status = .failed("Verified pack validation failed: \(error)")
            return
        }
        guard acceptance.state.receipt?.sequence == catalog.sequence,
              acceptance.state.receipt?.digest == catalog.digest else {
            status = .failed("Verified catalog receipt does not match committed storage.")
            return
        }
        revision += 1
        definitions = catalog.definitions.sorted { $0.id < $1.id }
        definitionsValid = true
        catalogReceipt = acceptance.state.receipt
        configurations = effectiveConfigurations(from: acceptance.configurations)
        let known = Set(definitions.map(\.id))
        overrides = overrides.filter { known.contains($0.packID) }
        events = events.filter { known.contains($0.packID) }
        publish()
    }

    /// Receipt-free writes can only narrow enforcement. Every enabling path must use the immutable-review overload.
    func save(_ configuration: RulePackConfiguration, completion: ((Bool) -> Void)? = nil) {
        guard definitions.contains(where: { $0.id == configuration.packID }), !configuration.enabled else {
            completion?(false)
            return
        }
        var cleaned = configuration
        cleaned.apps = Array(Set(configuration.apps.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        if cleaned.scope == .selectedApps && cleaned.apps.isEmpty { cleaned.enabled = false }
        let committed = cleaned
        persist({ try $0.saveRulePackConfiguration(committed) }, then: { [weak self] in
            guard let self else { completion?(false); return }
            self.revision += 1
            if let index = self.configurations.firstIndex(where: { $0.packID == committed.packID }) {
                self.configurations[index] = committed
            } else {
                self.configurations.append(committed)
                self.configurations.sort { $0.packID < $1.packID }
            }
            self.publish()
            completion?(true)
        }, onFailure: { _ in completion?(false) })
    }

    func save(_ configuration: RulePackConfiguration,
              reviewedDefinition: RulePackDefinition?,
              receipt: RulePackReviewReceipt?,
              completion: ((SaveResult) -> Void)? = nil) {
        guard let current = definitions.first(where: { $0.id == configuration.packID }) else {
            completion?(.failed("Rule pack is no longer available."))
            return
        }
        var cleaned = configuration
        cleaned.apps = Array(Set(configuration.apps.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        if cleaned.scope == .selectedApps && cleaned.apps.isEmpty { cleaned.enabled = false }

        var durableReceipt: RulePackReviewReceipt?
        if cleaned.enabled {
            guard let reviewedDefinition, reviewedDefinition == current,
                  let receipt, receipt.packID == current.id,
                  receipt.version == current.manifest.version,
                  receipt.contentSHA256 == current.manifest.contentSHA256,
                  catalogReceipt?.sequence == receipt.catalogSequence,
                  catalogReceipt?.digest == receipt.catalogDigest else {
                completion?(.staleReview)
                return
            }
            cleaned.consentedVersion = reviewedDefinition.manifest.version
            cleaned.consentedContentSHA256 = reviewedDefinition.manifest.contentSHA256
            durableReceipt = receipt
        }

        let committed = cleaned
        let committedReceipt = durableReceipt
        persist({ try $0.saveRulePackConfiguration(committed, reviewed: committedReceipt) }, then: { [weak self] in
            guard let self else {
                completion?(.failed("Rule pack storage is unavailable."))
                return
            }
            self.revision += 1
            if let index = self.configurations.firstIndex(where: { $0.packID == committed.packID }) {
                self.configurations[index] = committed
            } else {
                self.configurations.append(committed)
                self.configurations.sort { $0.packID < $1.packID }
            }
            self.publish()
            completion?(.saved)
        }, onFailure: { error in
            if error as? RulePackCatalogPersistenceError == .staleReview {
                completion?(.staleReview)
            } else {
                completion?(.failed(String(describing: error)))
            }
        })
    }

    func setEnabled(_ packID: String, _ enabled: Bool) {
        var value = configuration(for: packID)
        value.enabled = enabled
        save(value)
    }

    func addOverride(_ override: RulePackOverride, completion: ((Bool) -> Void)? = nil) {
        guard definitions.contains(where: { $0.id == override.packID }),
              let host = HostCanonicalizer.host(override.host) else {
            completion?(false)
            return
        }
        var cleaned = override
        cleaned.host = host
        cleaned.app = override.app.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = cleaned
        persist({ try $0.saveRulePackOverride(committed) }, then: { [weak self] in
            guard let self else { completion?(false); return }
            self.revision += 1
            self.overrides.removeAll { $0.id == committed.id || $0.hasSameScope(as: committed) }
            self.overrides.append(committed)
            self.publish()
            completion?(true)
        }, onFailure: { _ in completion?(false) })
    }

    func deleteOverride(_ override: RulePackOverride, completion: ((Bool) -> Void)? = nil) {
        persist({ try $0.deleteRulePackOverride(override) }, then: { [weak self] in
            self?.revision += 1
            self?.overrides.removeAll { $0.hasSameScope(as: override) }
            self?.publish()
            completion?(true)
        }, onFailure: { _ in completion?(false) })
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

    private func applyLoaded(configurations saved: [RulePackConfiguration],
                             overrides loadedOverrides: [RulePackOverride],
                             events loadedEvents: [RulePackEventRecord],
                             deliveryStats loadedStats: RulePackDeliveryStats) {
        let known = Set(definitions.map(\.id))
        configurations = effectiveConfigurations(from: saved)
        overrides = loadedOverrides.filter { known.contains($0.packID) }
        events = loadedEvents.filter { known.contains($0.packID) }
        deliveryStats = loadedStats
        publish()
    }

    private func effectiveConfigurations(from saved: [RulePackConfiguration]) -> [RulePackConfiguration] {
        definitions.map { definition in
            guard var configuration = saved.first(where: { $0.packID == definition.id }) else {
                return RulePackConfiguration(packID: definition.id)
            }
            if configuration.enabled, !configuration.isConsented(to: definition) {
                configuration.enabled = false
            }
            return configuration
        }
    }

    private func persist(_ write: @escaping @Sendable (TrafficDatabase) throws -> Void,
                         then commit: @escaping @MainActor () -> Void,
                         onFailure: (@MainActor (Error) -> Void)? = nil) {
        guard let db else {
            let error = RulePackCatalogPersistenceError.invalidReceipt
            status = .failed("Rule pack storage is unavailable.")
            onFailure?(error)
            return
        }
        Task { [weak self, weak db] in
            guard let db else {
                let error = RulePackCatalogPersistenceError.invalidReceipt
                self?.status = .failed("Rule pack storage is unavailable.")
                onFailure?(error)
                return
            }
            do {
                try await db.asyncResult { db in try write(db) }
                commit()
            } catch {
                self?.status = .failed("Could not save the rule pack change: \(String(describing: error))")
                onFailure?(error)
            }
        }
    }

    private func rebuildSnapshot() {
        guard definitionsValid else {
            committedSnapshot = nil
            return
        }
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        let active = configurations.filter { configuration in
            configuration.enabled
                && definitionsByID[configuration.packID].map(configuration.isConsented(to:)) == true
        }
        guard !active.isEmpty else {
            committedSnapshot = nil
            return
        }
        let packIDs = Set(active.map(\.packID))
        committedSnapshot = RulePackSnapshot.make(
            definitions: definitions.filter { packIDs.contains($0.id) },
            configurations: active,
            overrides: overrides.filter { packIDs.contains($0.packID) }
        )
    }

    private func publish() {
        rebuildSnapshot()
        version += 1
        guard definitionsValid else { return }
        status = hasEnabledPacks ? .ready : .off
        onChange(committedSnapshot)
    }
}
