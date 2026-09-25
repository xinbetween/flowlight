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

    /// What a version check found. `installed` holds the versions macOS reports for the enabled copies of the
    /// extension — usually one, occasionally two while a replacement is pending.
    struct VersionCheck: Equatable {
        var installed: [String] = []
        var appVersion: String = ""
        /// Whether a re-activation was started to put the two back in step.
        var repairing = false
        var installedDescription: String { installed.isEmpty ? "unknown" : installed.joined(separator: ", ") }
    }

    @Published private(set) var state: State = .unknown

    /// The instance the app owns. Capture has to be able to ask for a version repair when the connection to the
    /// extension keeps being refused, and it doesn't sit in the view tree where this manager is handed around.
    /// One app, one manager — nothing makes a second, and a test process makes none at all.
    private(set) static weak var current: ExtensionManager?

    override init() {
        super.init()
        Self.current = self
    }

    /// The properties request in flight, if any. The delegate callbacks are shared with installation requests
    /// and a version check is otherwise indistinguishable from one.
    private var versionCheck: OSSystemExtensionRequest?
    private var versionCheckResult = VersionCheck()
    private var versionCheckCompletion: ((VersionCheck) -> Void)?

    /// This app's version — the one the extension it ships was built alongside.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Whether this build carries the content-filter entitlement (false for ad-hoc/local builds).
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil)
        return (value as? [String])?.contains("content-filter-provider-systemextension") == true
    }()

    var hasEntitlement: Bool { Self.isEntitled }

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

    /// macOS keeps running whichever build of the extension was last activated. After the app updates, that is
    /// the previous version, and the connection between them is refused — the app looks like it can't reach an
    /// extension that is plainly running. Asking for the installed version and re-activating on a mismatch is
    /// what keeps the two in step; a matching version makes this a no-op.
    ///
    /// `completion` is called once, when macOS has finished answering, with what it said. Capture uses it to
    /// report a repair it has just asked for rather than going quiet for another thirty seconds.
    func matchExtensionToApp(completion: ((VersionCheck) -> Void)? = nil) {
        guard hasEntitlement, isInApplications else { completion?(VersionCheck(appVersion: Self.appVersion)); return }
        // One at a time. The ladder in ExtensionRecovery asks for this once per session, but a user pressing
        // Refresh while it is in flight shouldn't start a second conversation with the same delegate.
        guard versionCheck == nil else { completion?(VersionCheck(appVersion: Self.appVersion)); return }
        versionCheckResult = VersionCheck(appVersion: Self.appVersion)
        versionCheckCompletion = completion
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                 queue: .main)
        request.delegate = self
        versionCheck = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Ends the version check, whichever way it went, and hands the answer back exactly once.
    private func finishVersionCheck() {
        versionCheck = nil
        let completion = versionCheckCompletion
        versionCheckCompletion = nil
        completion?(versionCheckResult)
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

    /// The reply to `matchExtensionToApp`: re-activate when what's installed isn't what this app ships.
    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        // Only the enabled copies count. A disabled one holds nothing and replacing it would quietly switch the
        // filter back on for someone who turned it off on purpose.
        let installed = properties.filter(\.isEnabled).map(\.bundleShortVersion)
        Task { @MainActor in
            let appVersion = Self.appVersion
            self.versionCheckResult = VersionCheck(installed: installed, appVersion: appVersion)
            guard ExtensionVersion.isStale(installed: installed, appVersion: appVersion) else { return }
            self.versionCheckResult.repairing = true
            self.state = .installing
            self.activate()
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            // A version check finishing is a question having been answered, not an installation having landed.
            // Treating the two alike switched the filter on off the back of a background lookup, and did it
            // before the replacement it had just asked for was anywhere near installed.
            if self.versionCheck === request { self.finishVersionCheck(); return }
            if self.state == .installing || self.state == .awaitingApproval { self.setFilterEnabled(true) }
            else { self.refresh() }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Same again: a properties request that fails says nothing about whether the filter is installed and
            // enabled. Reporting it as a failed installation replaced a true "Filter enabled" with a false one.
            if self.versionCheck === request { self.finishVersionCheck(); return }
            self.state = .failed(error.localizedDescription)
        }
    }
}
