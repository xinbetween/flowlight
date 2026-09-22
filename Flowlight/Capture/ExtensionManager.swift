import Foundation
@preconcurrency import NetworkExtension
import Security
import SystemExtensions

/// Installs the system extension and enables the content filter configuration.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown, notInstalled, awaitingApproval, installing, enabled, disabled, failed(String)
        var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .notInstalled: return "Not installed"
            case .awaitingApproval: return "Waiting for approval in System Settings › General › Login Items & Extensions"
            case .installing: return "Installing…"
            case .enabled: return "Filter enabled"
            case .disabled: return "Installed, filter disabled"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    @Published private(set) var state: State = .unknown

    /// Whether this build carries the content-filter entitlement (false for ad-hoc/local builds).
    let hasEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil)
        return (value as? [String])?.contains("content-filter-provider-systemextension") == true
    }()

    /// macOS only activates system extensions from apps in /Applications.
    var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// Why activation cannot work right now, if anything.
    var blocker: String? {
        if !hasEntitlement {
            return "This build isn't signed with the Network Extension entitlement. Build with scripts/build-signed.sh using a team that Apple has granted content-filter-provider-systemextension."
        }
        if !isInApplications { return "Move Flowlight to /Applications. macOS only activates system extensions from there." }
        return nil
    }

    func refresh() {
        guard hasEntitlement else { state = .notInstalled; return }
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                let manager = NEFilterManager.shared()
                if manager.providerConfiguration == nil { self.state = .notInstalled }
                else { self.state = manager.isEnabled ? .enabled : .disabled }
            }
        }
    }

    func activate() {
        if let blocker { state = .failed(blocker); return }
        state = .installing
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        setFilterEnabled(false) { [weak self] in
            guard let self else { return }
            let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                       queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func setFilterEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] loadError in
            Task { @MainActor in
                guard let self else { return }
                if let loadError { self.state = .failed(loadError.localizedDescription); completion?(); return }
                if manager.providerConfiguration == nil {
                    let config = NEFilterProviderConfiguration()
                    config.filterSockets = true
                    config.filterPackets = false
                    manager.providerConfiguration = config
                }
                manager.localizedDescription = "Flowlight"
                manager.isEnabled = enabled
                manager.saveToPreferences { saveError in
                    Task { @MainActor in
                        if let saveError { self.state = .failed(saveError.localizedDescription) }
                        else { self.state = enabled ? .enabled : .disabled }
                        completion?()
                    }
                }
            }
        }
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if self.state == .installing || self.state == .awaitingApproval { self.setFilterEnabled(true) }
            else { self.refresh() }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.state = .failed(error.localizedDescription) }
    }
}
