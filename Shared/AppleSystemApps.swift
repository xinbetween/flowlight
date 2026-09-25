import Foundation

/// Whether an application is one of Apple's own, shipped with macOS.
///
/// Used to keep the Alerts list about the software someone chose to install. macOS itself contacts Apple
/// constantly — Software Update, iCloud, Maps tiles, Siri, push, time — on ports and to hosts that are new the
/// first time they appear, and a list that reports all of it buries the one line that matters.
///
/// The test is the bundle identifier and the path, not the code signature. Any application can claim a
/// `com.apple.` identifier, so this is a way of deciding what to show, never a way of deciding what to trust:
/// nothing here is exempt from a rule, a guardrail or an allowlist, and the traffic is still recorded and still
/// appears in Live, Reports and Ask.
enum AppleSystemApps {
    static func contains(bundleID: String, path: String = "") -> Bool {
        let id = bundleID.lowercased()
        if id.hasPrefix("com.apple.") { return true }
        // Daemons and helpers often report a bare executable name rather than a bundle identifier.
        let p = path.lowercased()
        return p.hasPrefix("/system/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/")
    }
}
