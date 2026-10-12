import Foundation

@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var manifests: [PluginManifest] = []
    @Published private(set) var version = 0

    private weak var db: TrafficDatabase?

    func attach(db: TrafficDatabase) {
        self.db = db
        reload()
    }

    func reload() {
        guard let db else { return }
        db.async { [weak self] db in
            let merged = PluginEngine.mergedManifests((try? db.loadPluginManifests()) ?? [])
            for manifest in merged where manifest.source == .builtIn {
                try? db.savePluginManifest(manifest)
            }
            Task { @MainActor in
                self?.manifests = merged
                self?.version += 1
            }
        }
    }

    func setEnabled(_ manifest: PluginManifest, _ enabled: Bool) {
        guard var updated = manifests.first(where: { $0.id == manifest.id }) else { return }
        updated.enabled = enabled
        if let index = manifests.firstIndex(where: { $0.id == updated.id }) {
            manifests[index] = updated
        }
        db?.async { try $0.setPluginEnabled(id: updated.id, enabled: enabled) }
        version += 1
    }

    func updateConfiguration(_ manifest: PluginManifest, configuration: [String: String]) {
        guard let index = manifests.firstIndex(where: { $0.id == manifest.id }) else { return }
        manifests[index].configuration = configuration
        db?.async { try $0.updatePluginConfiguration(id: manifest.id, configuration: configuration) }
        version += 1
    }

    func reviewPackage(data: Data) throws -> PluginPackageReview {
        try PluginPackageVerifier.review(data: data)
    }

    func installReviewedPackage(_ review: PluginPackageReview, completion: @escaping @MainActor (Result<PluginImportResult, Error>) -> Void) {
        guard let db else { return }
        db.async { [weak self] db in
            do {
                var manifest = review.manifest
                manifest.source = .installed
                manifest.enabled = true
                try db.savePluginManifest(manifest)
                let merged = PluginEngine.mergedManifests(try db.loadPluginManifests())
                Task { @MainActor in
                    self?.manifests = merged
                    self?.version += 1
                    completion(.success(PluginImportResult(manifest: manifest, installed: true)))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    func importPackage(data: Data, completion: @escaping @MainActor (Result<PluginImportResult, Error>) -> Void) {
        do {
            installReviewedPackage(try reviewPackage(data: data), completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    func exportPackage(_ manifest: PluginManifest) throws -> Data {
        var copy = manifest
        copy.enabled = true
        copy.configuration = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PluginPackage(manifest: copy))
    }

    func removeInstalled(_ manifest: PluginManifest) {
        guard manifest.source == .installed else { return }
        manifests.removeAll { $0.id == manifest.id }
        db?.async { try $0.deleteInstalledPlugin(id: manifest.id) }
        version += 1
    }

    func backfill(_ manifest: PluginManifest? = nil, completion: @escaping @MainActor (Result<PluginBackfillResult, Error>) -> Void) {
        guard let db else { return }
        db.async { [weak self] db in
            do {
                let count = try db.backfillPluginFindings(pluginID: manifest?.id)
                Task { @MainActor in
                    self?.version += 1
                    completion(.success(PluginBackfillResult(pluginID: manifest?.id, findingCount: count)))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    func clearFindings() {
        db?.async { [weak self] db in
            try db.clearPluginFindings()
            Task { @MainActor in self?.version += 1 }
        }
    }

    var officialPlugins: [PluginManifest] { manifests.filter { $0.publisher == .official } }
    var thirdPartyPlugins: [PluginManifest] { manifests.filter { $0.publisher == .thirdParty } }
}
