import Foundation

/// App-owned advisory catalog state. It has no enforcement hooks: advisories are display/analysis context only.
@MainActor
final class AdvisoryStore: ObservableObject {
    @Published private(set) var advisories: [SecurityAdvisory] = []
    @Published private(set) var catalogState: AdvisoryCatalogState?
    @Published private(set) var catalogReady = false
    @Published private(set) var isRecovering = false
    @Published private(set) var version = 0

    private weak var db: TrafficDatabase?
    private var revision = 0

    func attach(db: TrafficDatabase, completion: (() -> Void)? = nil) {
        self.db = db
        reload(completion: completion)
    }

    func reload(completion: (() -> Void)? = nil) {
        guard let db else { completion?(); return }
        revision += 1
        let expected = revision
        Task { [weak self, weak db] in
            guard let db else { completion?(); return }
            do {
                let loaded = try await db.asyncResult { db in
                    (try db.loadAdvisoryCatalogState(catalogID: AdvisoryCatalogVerifier.catalogID),
                     try db.loadAdvisories(catalogID: AdvisoryCatalogVerifier.catalogID))
                }
                guard let self, self.revision == expected else { completion?(); return }
                self.catalogState = loaded.0
                if loaded.0.receipt != nil {
                    self.advisories = loaded.1
                    self.catalogReady = true
                    self.isRecovering = false
                }
                self.version += 1
                completion?()
            } catch {
                completion?()
            }
        }
    }

    @discardableResult
    func install(_ catalog: VerifiedAdvisoryCatalog, acceptance: AdvisoryCatalogAcceptance) -> Bool {
        guard acceptance.state.receipt?.sequence == catalog.sequence,
              acceptance.state.receipt?.digest == catalog.digest else { return false }
        revision += 1
        advisories = catalog.advisories
        catalogState = acceptance.state
        catalogReady = true
        isRecovering = false
        version += 1
        return true
    }

    func enterRecovery() {
        revision += 1
        advisories = []
        catalogState = nil
        catalogReady = false
        isRecovering = true
        version += 1
    }

    func matches(_ app: AdvisoryAppVersion) -> [SecurityAdvisory] {
        advisories.filter { $0.matches(app) }.sorted { $0.id < $1.id }
    }

    func matches(_ artifact: AdvisoryArtifact) -> [SecurityAdvisory] {
        advisories.filter { $0.matches(artifact) }.sorted { $0.id < $1.id }
    }
}
