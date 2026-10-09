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

    func clearFindings() {
        db?.async { [weak self] db in
            try db.clearPluginFindings()
            Task { @MainActor in self?.version += 1 }
        }
    }

    var officialPlugins: [PluginManifest] { manifests.filter { $0.publisher == .official } }
    var thirdPartyPlugins: [PluginManifest] { manifests.filter { $0.publisher == .thirdParty } }
}
