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

    enum Confirmation: Equatable, Hashable {
        case replacement(String)
        case aggressiveRisk
        case broadening
    }

    enum SaveAction: Equatable {
        case commit(RulePackConfiguration, RulePackReviewReceipt?)
        case confirm(Confirmation)
    }

    let originalConfiguration: RulePackConfiguration
    let reviewedDefinition: RulePackDefinition?
    let reviewReceipt: RulePackReviewReceipt?
    var configuration: RulePackConfiguration
    var typedApp = ""
    private var confirmed: Set<Confirmation> = []

    init(saved: RulePackConfiguration, intent: Intent,
         reviewedDefinition: RulePackDefinition? = nil,
         reviewReceipt: RulePackReviewReceipt? = nil) {
        originalConfiguration = saved
        self.reviewedDefinition = reviewedDefinition
        self.reviewReceipt = reviewReceipt
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

    func requestSave(exclusivePeerConfiguration: RulePackConfiguration? = nil) -> SaveAction? {
        guard canSave else { return nil }
        for confirmation in requiredConfirmations(exclusivePeerConfiguration: exclusivePeerConfiguration)
        where !confirmed.contains(confirmation) {
            return .confirm(confirmation)
        }
        return .commit(configuration, reviewReceipt)
    }

    mutating func confirm(_ confirmation: Confirmation,
                          exclusivePeerConfiguration: RulePackConfiguration? = nil) -> SaveAction? {
        let required = requiredConfirmations(exclusivePeerConfiguration: exclusivePeerConfiguration)
        guard required.contains(confirmation) else {
            return requestSave(exclusivePeerConfiguration: exclusivePeerConfiguration)
        }
        confirmed.insert(confirmation)
        return requestSave(exclusivePeerConfiguration: exclusivePeerConfiguration)
    }

    private func requiredConfirmations(
        exclusivePeerConfiguration: RulePackConfiguration?
    ) -> [Confirmation] {
        guard configuration.enabled else { return [] }
        var result: [Confirmation] = []
        if let peer = exclusivePeerConfiguration,
           peer.enabled,
           AdvertisingPackTierPolicy.exclusivePeer(of: configuration.packID) == peer.packID {
            result.append(.replacement(peer.packID))
        }
        if configuration.packID == AdvertisingPackTierPolicy.aggressiveID,
           !originalConfiguration.enabled {
            result.append(.aggressiveRisk)
        }
        if originalConfiguration.scope == .selectedApps,
           configuration.scope == .allApps {
            result.append(.broadening)
        }
        return result
    }
}
