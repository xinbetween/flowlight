import AppKit
import Foundation

/// Quitting and starting again, for the one setting that can't fully take effect any other way.
///
/// Most of Flowlight follows the language picker immediately — `L()` reads the chosen bundle on every call and
/// the window is rebuilt when the choice changes. What can't is everything macOS draws on Flowlight's behalf:
/// the application menu, the services menu, the open and save panels, the standard alert buttons. Those come
/// from `AppleLanguages`, which AppKit reads once at launch. Until the app starts again, the menu bar stays in
/// the previous language while the window is in the new one, which reads as a half-finished translation.
///
/// The extension is untouched by this: it runs on its own and keeps filtering across the restart. The sampler
/// stops with the app and starts again with it, so a second or two of history is missed — the price of the menu
/// bar agreeing with the window.
@MainActor
enum AppRestart {
    /// Starts a second copy and quits this one once it is on its way. Nothing is terminated if the launch
    /// fails: being left with no Flowlight at all is worse than being left with a stale menu bar.
    static func now(onFailure: @escaping (String) -> Void = { _ in }) {
        // Written before anything else: whatever happens next, the choice has to survive it.
        UserDefaults.standard.synchronize()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    onFailure(error.localizedDescription)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
