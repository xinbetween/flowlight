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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactApp = installed.contains {
            $0.bundleID.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        let explicitIdentity = trimmed.contains(".") && !trimmed.contains(where: \.isWhitespace)
            || AgentCatalog.knownAgent(bundleID: trimmed, appName: trimmed) != nil
        guard appsLoaded || exactApp || explicitIdentity else { return .loading }
        guard let target = InstalledApps.target(forTyped: trimmed, apps: installed) else { return .ignored }
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
