import Foundation

/// The managed-pack editor is a draft until an explicit Save succeeds. Keeping these transitions outside SwiftUI
/// makes keyboard actions and sheet dismissal incapable of changing enforcement by accident.
struct RulePackEditorDraft {
    enum Intent {
        case review
        case activate
    }

    enum AppSubmission: Equatable {
        case ignored
        case added(String)
    }

    enum SaveAction: Equatable {
        case commit(RulePackConfiguration)
        case confirmBroadening
    }

    let originalConfiguration: RulePackConfiguration
    var configuration: RulePackConfiguration
    var typedApp = ""
    private(set) var saveAction: SaveAction?

    init(saved: RulePackConfiguration, intent: Intent) {
        originalConfiguration = saved
        configuration = saved
        if intent == .activate { configuration.enabled = true }
    }

    var canSave: Bool {
        configuration.scope != .selectedApps || !configuration.apps.isEmpty
    }

    mutating func submitApp(installed: [InstalledApps.App]) -> AppSubmission {
        addApp(typedApp, installed: installed)
    }

    mutating func addApp(_ value: String, installed: [InstalledApps.App]) -> AppSubmission {
        guard let target = InstalledApps.target(forTyped: value, apps: installed) else { return .ignored }
        if !configuration.apps.contains(where: { $0.caseInsensitiveCompare(target.value) == .orderedSame }) {
            configuration.apps.append(target.value)
            configuration.apps.sort()
        }
        typedApp = ""
        return .added(target.value)
    }

    mutating func requestSave() -> SaveAction? {
        guard canSave else { saveAction = nil; return nil }
        if originalConfiguration.enabled,
           originalConfiguration.scope == .selectedApps,
           configuration.scope == .allApps {
            saveAction = .confirmBroadening
        } else {
            saveAction = .commit(configuration)
        }
        return saveAction
    }

    mutating func clearSaveAction() { saveAction = nil }
}
