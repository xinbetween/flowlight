import Foundation

/// The managed-pack editor is a draft until an explicit Save succeeds. Keeping these transitions outside SwiftUI
/// makes keyboard actions and sheet dismissal incapable of changing enforcement by accident.
struct RulePackEditorDraft {
    enum Intent {
        case review
        case activate
    }

    enum AppSubmission: Equatable {
        case loading
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

    init(saved: RulePackConfiguration, intent: Intent) {
        originalConfiguration = saved
        configuration = saved
        if intent == .activate { configuration.enabled = true }
    }

    var canSave: Bool {
        configuration.scope != .selectedApps || !configuration.apps.isEmpty
    }

    mutating func submitApp(installed: [InstalledApps.App], appsLoaded: Bool = true) -> AppSubmission {
        addApp(typedApp, installed: installed, appsLoaded: appsLoaded)
    }

    mutating func addApp(_ value: String, installed: [InstalledApps.App], appsLoaded: Bool = true) -> AppSubmission {
        guard appsLoaded else { return .loading }
        guard let target = InstalledApps.target(forTyped: value, apps: installed) else { return .ignored }
        if !configuration.apps.contains(where: { $0.caseInsensitiveCompare(target.value) == .orderedSame }) {
            configuration.apps.append(target.value)
            configuration.apps.sort()
        }
        typedApp = ""
        return .added(target.value)
    }

    func requestSave() -> SaveAction? {
        guard canSave else { return nil }
        if originalConfiguration.enabled,
           originalConfiguration.scope == .selectedApps,
           configuration.scope == .allApps {
            return .confirmBroadening
        }
        return .commit(configuration)
    }
}
