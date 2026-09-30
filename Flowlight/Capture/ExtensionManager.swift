import Foundation
@preconcurrency import NetworkExtension
import Security
import SystemExtensions

/// Installs the system extension and enables the content filter configuration.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown, notInstalled, awaitingApproval, installing, enabled, disabled, failed(String)
        /// macOS accepted the replacement but will not perform it until the Mac restarts. Nothing the app does
        /// changes that: the extension's lifecycle belongs to the system, not to this process.
        case needsReboot
        var label: String {
            switch self {
            case .unknown: return L("Unknown")
            case .notInstalled: return L("Not installed")
            case .awaitingApproval: return L("Waiting for approval in System Settings › General › Login Items & Extensions")
            case .installing: return L("Installing…")
            case .enabled: return L("Filter enabled")
            case .disabled: return L("Installed, filter disabled")
            case .needsReboot: return L("Restart this Mac to finish replacing the filter")
            case .failed(let m): return L("Failed: %@", m)
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
        /// Older copies macOS is holding until the Mac restarts.
        ///
        /// This is the state that looked for a long time like a version bug and is not one. After several
        /// updates, `systemextensionsctl` shows the matching build `activated enabled` and the previous ones
        /// `terminated waiting to uninstall on reboot`. The version check is then perfectly correct — nothing is
        /// stale, so nothing is repaired — while macOS, which runs one content filter at a time, has not started
        /// the new one. The app redials an extension that cannot answer until a restart, six times, and falls
        /// back to the sampler without ever saying why.
        var awaitingReboot: [String] = []
        var installedDescription: String { installed.isEmpty ? L("unknown") : installed.joined(separator: ", ") }
        /// True when the build that matches this app is installed and enabled, but older ones are still queued
        /// for removal — which is the case a restart fixes and nothing else does.
        var needsRestart: Bool {
            !awaitingReboot.isEmpty && !appVersion.isEmpty
                && installed.contains { ExtensionVersion.compare($0, appVersion) == .orderedSame }
        }
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
    /// The in-flight deactivation, so its completion can be told apart from an activation's or a version check's.
    private var deactivation: OSSystemExtensionRequest?
    /// Set while `reinstall()` is deactivating, so the deactivation's completion re-activates instead of stopping.
    private var reinstalling = false

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
            return L("This build isn't signed with the Network Extension entitlement. Build with scripts/build-signed.sh using a team that Apple has granted content-filter-provider-systemextension.")
        }
        if !isInApplications { return L("Move Flowlight to /Applications. macOS only activates system extensions from there.") }
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
            self.deactivation = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    /// Uninstall the filter and install it again, without a restart. macOS runs one content filter at a time, and
    /// after several updates the previous copies sit `terminated waiting to uninstall on reboot`, holding the slot
    /// the current build should have. Deactivating drops those copies; activating brings the current build back —
    /// into the slot this time. It is the alternative to restarting the Mac when it is holding the old filter.
    func reinstall() {
        reinstalling = true
        deactivate()
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
        let installed = properties.filter { $0.isEnabled && !$0.isUninstalling }.map(\.bundleShortVersion)
        // Copies macOS has terminated and is holding until a restart. They still occupy the one content-filter
        // slot, so the enabled build is installed without being the one running.
        let awaitingReboot = properties.filter(\.isUninstalling).map(\.bundleShortVersion)
        Task { @MainActor in
            let appVersion = Self.appVersion
            self.versionCheckResult = VersionCheck(installed: installed, appVersion: appVersion,
                                                   awaitingReboot: awaitingReboot)
            // The matching build is installed and enabled, but macOS is holding older copies until the Mac
            // restarts, and they still occupy the one content-filter slot. Nothing is stale, so no repair helps —
            // make the state say so, authoritatively, rather than leaving the redial ladder to overwrite the one
            // message that matters with "reconnecting, try N of 6". A restart, or reinstalling the filter, is the
            // way out; the Capture screen offers both.
            if self.versionCheckResult.needsRestart { self.state = .needsReboot; return }
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
            // A deactivation finishing: on its own it is an uninstall, but as the first half of `reinstall()` it is
            // immediately followed by activation — that is the no-restart way to free the held content-filter slot.
            if self.deactivation === request {
                self.deactivation = nil
                if result == .willCompleteAfterReboot { self.reinstalling = false; self.state = .needsReboot; return }
                if self.reinstalling { self.reinstalling = false; self.activate() } else { self.refresh() }
                return
            }
            // macOS can accept a replacement and then hold it until the Mac restarts — usually because the
            // extension it is replacing is still running. Until then the old build keeps answering and the new
            // app cannot talk to it, so redialling, reinstalling and relaunching all fail the same way. Saying
            // so is the only useful thing left; the sampler keeps capturing in the meantime.
            if result == .willCompleteAfterReboot { self.state = .needsReboot; return }
            if self.state == .installing || self.state == .awaitingApproval { self.setFilterEnabled(true) }
            else { self.refresh() }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Same again: a properties request that fails says nothing about whether the filter is installed and
            // enabled. Reporting it as a failed installation replaced a true "Filter enabled" with a false one.
            if self.versionCheck === request { self.finishVersionCheck(); return }
            if self.deactivation === request { self.deactivation = nil; self.reinstalling = false }
            self.state = .failed(error.localizedDescription)
        }
    }
}
