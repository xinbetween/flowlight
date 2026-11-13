import Foundation
@preconcurrency import NetworkExtension
import Security
#if !APP_STORE
import SystemExtensions
#endif

/// Coalesces callers that ask the same in-flight system question. Every waiter receives the one authoritative reply;
/// an overlapping retry must not be handed an empty placeholder and consume the only version probe it will make.
struct InFlightResultWaiters<Value> {
    private var completions: [(Value) -> Void] = []

    mutating func join(_ completion: @escaping (Value) -> Void) {
        completions.append(completion)
    }

    mutating func finish(with value: Value) {
        let waiting = completions
        completions.removeAll(keepingCapacity: true)
        for completion in waiting { completion(value) }
    }
}

/// Installs the system extension and enables the content filter configuration.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    enum ReinstallResult: Equatable {
        case started
        case rebootRequired
        case failed(String)
    }

    private enum FilterChangeResult {
        case succeeded
        case failed(String)
    }

    enum State: Equatable {
        case unknown, notInstalled, awaitingApproval, installing, enabled, disabled, failed(String)
        /// macOS accepted the replacement but will not perform it until the Mac restarts. Nothing the app does
        /// changes that: the extension's lifecycle belongs to the system, not to this process.
        case needsReboot
        var showsMenuBarNotice: Bool { self == .needsReboot }

        var label: String {
            switch self {
            case .unknown: return L("Unknown")
            case .notInstalled:
                #if APP_STORE
                return L("Filter disabled")
                #else
                return L("Not installed")
                #endif
            case .awaitingApproval: return L("Waiting for approval in System Settings › General › Login Items & Extensions")
            case .installing:
                #if APP_STORE
                return L("Enabling…")
                #else
                return L("Installing…")
                #endif
            case .enabled: return L("Filter enabled")
            case .disabled:
                #if APP_STORE
                return L("Filter disabled")
                #else
                return L("Installed, filter disabled")
                #endif
            case .needsReboot: return L("Restart this Mac to finish replacing the filter")
            case .failed(let m): return L("Failed: %@", m)
            }
        }
    }

    /// What a version check found. `installed` holds the versions macOS reports for the enabled copies of the
    /// extension — usually one, occasionally two while a replacement is pending.
    struct VersionCheck: Equatable {
        var installed: [String] = []
        /// The version the installed extension is expected to be: the version of the extension *embedded in this
        /// app bundle*. The release keeps that identity equal to the app's version and build.
        var expectedVersion: String = ""
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
            !awaitingReboot.isEmpty && !expectedVersion.isEmpty
                && installed.contains { ExtensionVersion.compare($0, expectedVersion) == .orderedSame }
        }
    }

    @Published private(set) var state: State = .unknown
    #if APP_STORE
    private var storeReinstalling = false
    #endif

    /// The instance the app owns. Capture has to be able to ask for a version repair when the connection to the
    /// extension keeps being refused, and it doesn't sit in the view tree where this manager is handed around.
    /// One app, one manager — nothing makes a second, and a test process makes none at all.
    private(set) static weak var current: ExtensionManager?

    override init() {
        super.init()
        Self.current = self
    }

    #if !APP_STORE
    /// The properties request in flight, if any. The delegate callbacks are shared with installation requests
    /// and a version check is otherwise indistinguishable from one.
    private var versionCheck: OSSystemExtensionRequest?
    private var versionCheckResult = VersionCheck()
    private var versionCheckWaiters = InFlightResultWaiters<VersionCheck>()
    /// The in-flight deactivation, so its completion can be told apart from an activation's or a version check's.
    private var deactivation: OSSystemExtensionRequest?
    /// Set while `reinstall()` is deactivating, so the deactivation's completion re-activates instead of stopping.
    private var reinstalling = false
    /// The activation half of an explicit reinstall. Keeping its identity separate from an ordinary install lets the
    /// caller hear the actual lifecycle result instead of a hopeful "started" before macOS has answered.
    private var reinstallActivation: OSSystemExtensionRequest?
    private var reinstallApprovalRequired: (() -> Void)?
    private var reinstallCompletion: ((ReinstallResult) -> Void)?
    #endif

    /// This app's version — the one the extension it ships was built alongside.
    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The version of the extension embedded in this app bundle — what the installed one should match.
    ///
    /// Read from the embedded product instead of reconstructing the value from app metadata. The release contract keeps
    /// both identities equal, while this remains the authoritative binary macOS actually installs. Falls back to the app
    /// version if the embedded copy cannot be read, which errs towards not incorrectly reporting a stale extension.
    nonisolated static var expectedExtensionVersion: String {
        #if APP_STORE
        let directory = "Contents/PlugIns"
        let product = "\(FlowlightConstants.extensionBundleIdentifier).appex"
        #else
        let directory = "Contents/Library/SystemExtensions"
        let product = "\(FlowlightConstants.extensionBundleIdentifier).systemextension"
        #endif
        let url = Bundle.main.bundleURL
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(product, isDirectory: true)
        guard let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return appVersion }
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version)/\(build)"
    }

    /// Whether this build carries the content-filter entitlement (false for ad-hoc/local builds).
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.networking.networkextension" as CFString, nil)
        #if APP_STORE
        let required = "content-filter-provider"
        #else
        let required = "content-filter-provider-systemextension"
        #endif
        return (value as? [String])?.contains(required) == true
    }()

    var hasEntitlement: Bool { Self.isEntitled }

    /// Developer ID system extensions must live in /Applications; Store app extensions have no such requirement.
    var isInApplications: Bool {
        #if APP_STORE
        true
        #else
        Bundle.main.bundlePath.hasPrefix("/Applications/")
        #endif
    }

    /// Why activation cannot work right now, if anything.
    var blocker: String? {
        if !hasEntitlement {
            #if APP_STORE
            return L("This build isn't signed with the Network Extension entitlement.")
            #else
            return L("This build isn't signed with the Network Extension entitlement. Build with scripts/build-signed.sh using a team that Apple has granted content-filter-provider-systemextension.")
            #endif
        }
        #if !APP_STORE
        if !isInApplications { return L("Move Flowlight to /Applications. macOS only activates system extensions from there.") }
        #endif
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
        #if APP_STORE
        completion?(VersionCheck(expectedVersion: Self.expectedExtensionVersion))
        #else
        guard hasEntitlement, isInApplications else { completion?(VersionCheck(expectedVersion: Self.expectedExtensionVersion)); return }
        // One request at a time. Startup, Refresh, and the retry ladder can converge here; every caller waits for
        // the same authoritative answer instead of receiving an empty placeholder that consumes its only probe.
        if let completion { versionCheckWaiters.join(completion) }
        guard versionCheck == nil else { return }
        versionCheckResult = VersionCheck(expectedVersion: Self.expectedExtensionVersion)
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                 queue: .main)
        request.delegate = self
        versionCheck = request
        OSSystemExtensionManager.shared.submitRequest(request)
        #endif
    }

    #if !APP_STORE
    /// Ends the one properties request and hands its authoritative answer to every caller that joined it.
    private func finishVersionCheck() {
        versionCheck = nil
        versionCheckWaiters.finish(with: versionCheckResult)
    }
    #endif

    func refresh() {
        guard hasEntitlement else { state = .notInstalled; return }
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.state = .failed(error.localizedDescription); return }
                let manager = NEFilterManager.shared()
                if manager.providerConfiguration == nil { self.state = .notInstalled }
                else if manager.isEnabled {
                    self.state = .enabled
                    #if !APP_STORE
                    self.upgradeToNeedsRebootIfHeld()
                    #endif
                } else { self.state = .disabled }
            }
        }
    }

    /// `NEFilterManager` says "enabled" whenever the filter's configuration is present and on — even when macOS is
    /// actually running a previous copy that's holding the one content-filter slot until a restart, so nothing
    /// arrives. That is the case a plain refresh would hide behind "Filter enabled". This confirms it against the
    /// ground truth `systemextensionsctl` reports and upgrades the state to `.needsReboot`, which the Capture banner
    /// turns into the restart-or-reinstall tip. Run after settling on `.enabled`, and only upgrades from it, so it
    /// can't fight a state the user just changed.
    #if !APP_STORE
    private func upgradeToNeedsRebootIfHeld() {
        Task { @MainActor in
            let extensions = await SystemExtensionScan.read()
            guard self.state == .enabled,
                  Self.isHoldingSlotPendingReboot(extensions, expected: Self.expectedExtensionVersion) else { return }
            self.state = .needsReboot
        }
    }
    #endif

    /// Whether the scan shows *our* previous copies holding the slot until a restart: the current build enabled and
    /// at least one earlier copy "waiting to uninstall on reboot". This is the reliable signal — read from what
    /// `systemextensionsctl list` actually prints — rather than the `OSSystemExtensionProperties` uninstalling flag,
    /// which does not mark copies deferred to a reboot. Pure, so the decision is tested against parsed output.
    nonisolated static func isHoldingSlotPendingReboot(_ extensions: [InstalledSystemExtension], expected: String) -> Bool {
        let ours = extensions.filter(\.isOurs)
        let rebootPending = ours.contains { $0.state.lowercased().contains("reboot") }
        let currentEnabled = ours.contains {
            $0.state.contains("activated") && ExtensionVersion.compare($0.version, expected) == .orderedSame
        }
        return rebootPending && currentEnabled
    }

    func activate() {
        if let blocker { state = .failed(blocker); return }
        state = .installing
        #if APP_STORE
        setFilterEnabled(true)
        #else
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        #endif
    }

    func deactivate() {
        #if APP_STORE
        setFilterEnabled(false)
        #else
        setFilterEnabled(false) { [weak self] result in
            guard let self, case .succeeded = result else { return }
            let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                                                                       queue: .main)
            request.delegate = self
            self.deactivation = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
        #endif
    }

    /// Uninstall the filter and install it again, without a restart. macOS runs one content filter at a time, and
    /// after several updates the previous copies sit `terminated waiting to uninstall on reboot`, holding the slot
    /// the current build should have. Deactivating drops those copies; activating brings the current build back —
    /// into the slot this time. It is the alternative to restarting the Mac when it is holding the old filter.
    func reinstall(
        approvalRequired: @escaping () -> Void = {},
        completion: @escaping (ReinstallResult) -> Void = { _ in }
    ) {
        if let blocker { completion(.failed(blocker)); return }
        #if APP_STORE
        guard !storeReinstalling else {
            completion(.failed(L("A filter reinstall is already in progress.")))
            return
        }
        state = .installing
        storeReinstalling = true
        setFilterEnabled(false) { [weak self] result in
            guard let self else { return }
            guard case .succeeded = result else {
                self.storeReinstalling = false
                if case .failed(let message) = result { completion(.failed(message)) }
                return
            }
            self.setFilterEnabled(true) { enabledResult in
                self.storeReinstalling = false
                switch enabledResult {
                case .succeeded: completion(.started)
                case .failed(let message): completion(.failed(message))
                }
            }
        }
        #else
        guard !reinstalling, deactivation == nil, reinstallActivation == nil else {
            completion(.failed(L("A filter reinstall is already in progress.")))
            return
        }
        state = .installing
        reinstalling = true
        reinstallApprovalRequired = approvalRequired
        reinstallCompletion = completion
        setFilterEnabled(false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .succeeded:
                let request = OSSystemExtensionRequest.deactivationRequest(
                    forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
                    queue: .main
                )
                request.delegate = self
                self.deactivation = request
                OSSystemExtensionManager.shared.submitRequest(request)
            case .failed(let message):
                self.finishReinstall(.failed(message))
            }
        }
        #endif
    }

    #if !APP_STORE
    private func submitReinstallActivation() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FlowlightConstants.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        reinstallActivation = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finishReinstall(_ result: ReinstallResult) {
        reinstalling = false
        let completion = reinstallCompletion
        reinstallApprovalRequired = nil
        reinstallCompletion = nil
        completion?(result)
    }
    #endif

    func setFilterEnabled(_ enabled: Bool) {
        setFilterEnabled(enabled, completion: nil)
    }

    private func setFilterEnabled(_ enabled: Bool, completion: ((FilterChangeResult) -> Void)?) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] loadError in
            Task { @MainActor in
                guard let self else { return }
                if let loadError {
                    self.state = .failed(loadError.localizedDescription)
                    completion?(.failed(loadError.localizedDescription))
                    return
                }
                let config = manager.providerConfiguration ?? NEFilterProviderConfiguration()
                #if APP_STORE
                config.filterDataProviderBundleIdentifier = FlowlightConstants.extensionBundleIdentifier
                #endif
                config.filterSockets = true
                config.filterPackets = false
                manager.providerConfiguration = config
                manager.localizedDescription = "Flowlight"
                manager.isEnabled = enabled
                manager.saveToPreferences { saveError in
                    Task { @MainActor in
                        if let saveError {
                            self.state = .failed(saveError.localizedDescription)
                            completion?(.failed(saveError.localizedDescription))
                        } else {
                            self.state = enabled ? .enabled : .disabled
                            completion?(.succeeded)
                        }
                    }
                }
            }
        }
    }
}

#if !APP_STORE
extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated private static func versionIdentity(_ properties: OSSystemExtensionProperties) -> String {
        let version = properties.bundleShortVersion
        let build = properties.bundleVersion
        return build.isEmpty ? version : "\(version)/\(build)"
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    /// The reply to `matchExtensionToApp`: re-activate when what's installed isn't what this app ships.
    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        // Only the enabled copies count. A disabled one holds nothing and replacing it would quietly switch the
        // filter back on for someone who turned it off on purpose.
        let installed = properties.filter { $0.isEnabled && !$0.isUninstalling }.map(Self.versionIdentity)
        // Copies macOS has terminated and is holding until a restart. They still occupy the one content-filter
        // slot, so the enabled build is installed without being the one running.
        let awaitingReboot = properties.filter(\.isUninstalling).map(Self.versionIdentity)
        Task { @MainActor in
            let expected = Self.expectedExtensionVersion
            self.versionCheckResult = VersionCheck(installed: installed, expectedVersion: expected,
                                                   awaitingReboot: awaitingReboot)
            // The matching build is installed and enabled, but macOS is holding older copies until the Mac
            // restarts, and they still occupy the one content-filter slot. Nothing is stale, so no repair helps —
            // make the state say so, authoritatively, rather than leaving the redial ladder to overwrite the one
            // message that matters with "reconnecting, try N of 6". A restart, or reinstalling the filter, is the
            // way out; the Capture screen offers both.
            if self.versionCheckResult.needsRestart { self.state = .needsReboot; return }
            guard ExtensionVersion.isStale(installed: installed, appVersion: expected) else { return }
            self.versionCheckResult.repairing = true
            self.state = .installing
            self.activate()
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .awaitingApproval
            if self.reinstallActivation === request || self.deactivation === request {
                // Approval pauses the same lifecycle; it does not finish it. Report progress once through its own
                // callback and reserve the completion for exactly one terminal activation, reboot, or failure result.
                let approvalRequired = self.reinstallApprovalRequired
                self.reinstallApprovalRequired = nil
                approvalRequired?()
            }
        }
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
                if result == .willCompleteAfterReboot {
                    self.state = .needsReboot
                    self.finishReinstall(.rebootRequired)
                    return
                }
                if self.reinstalling {
                    self.submitReinstallActivation()
                } else {
                    self.refresh()
                }
                return
            }
            if self.reinstallActivation === request {
                self.reinstallActivation = nil
                if result == .willCompleteAfterReboot {
                    self.state = .needsReboot
                    self.finishReinstall(.rebootRequired)
                    return
                }
                self.setFilterEnabled(true) { result in
                    switch result {
                    case .succeeded: self.finishReinstall(.started)
                    case .failed(let message): self.finishReinstall(.failed(message))
                    }
                }
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
            if self.deactivation === request {
                self.deactivation = nil
                self.finishReinstall(.failed(error.localizedDescription))
            }
            if self.reinstallActivation === request {
                self.reinstallActivation = nil
                self.finishReinstall(.failed(error.localizedDescription))
            }
            self.state = .failed(error.localizedDescription)
        }
    }
}
#endif
