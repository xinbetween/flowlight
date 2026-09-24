import AppKit
import Foundation

/// The applications on this Mac, by name and bundle identifier.
///
/// Focus matches an app by its bundle identifier, so anything that lets someone name an app has to end up with
/// one. Typing "Cursor" has to become `com.todesktop.230313mzl4w4u92` somewhere, and the only place that mapping
/// exists is the app bundles themselves.
enum InstalledApps {
    struct App: Equatable, Identifiable, Sendable {
        var name: String
        var bundleID: String
        var path: String
        var id: String { bundleID }
        /// What the app told macOS it wants Bluetooth for, when it declares a use. This is the app saying it is
        /// built to use the radio — not macOS saying it was granted access, which no ordinary app can read.
        var bluetoothPurpose: String?
    }

    private static let lock = NSLock()
    private static var cached: [App]?

    /// Where applications live. The system folder is included because Safari and Mail are perfectly reasonable
    /// things to focus on, and they aren't in /Applications.
    private static var searchPaths: [String] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         NSHomeDirectory() + "/Applications"]
    }

    /// Scanned once and kept. A Mac doesn't gain applications while a popover is open, and re-reading several
    /// hundred Info.plists on every keystroke would be felt.
    static func all() -> [App] {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()

        var found: [String: App] = [:]
        let manager = FileManager.default
        for directory in searchPaths {
            guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, !id.isEmpty else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(entry.dropLast(4))
                let purpose = (bundle.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "NSBluetoothPeripheralUsageDescription") as? String)
                found[id] = App(name: name, bundleID: id, path: path, bluetoothPurpose: purpose)
            }
        }
        let sorted = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.lock(); cached = sorted; lock.unlock()
        return sorted
    }

    /// The applications built to use Bluetooth, as they say so themselves in their Info.plist.
    ///
    /// macOS records which of them you actually granted access to in a database an app cannot read, so this is the
    /// nearest honest answer: who asked, not who was allowed. The UI says which of the two it is showing.
    static func bluetoothUsers(_ apps: [App] = all()) -> [App] {
        apps.filter { $0.bluetoothPurpose != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Matches on name or identifier, so "cursor" and "com.todesktop" both find the same app.
    static func search(_ query: String, in apps: [App]) -> [App] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        return apps.filter { $0.name.lowercased().contains(term) || $0.bundleID.lowercased().contains(term) }
    }

    /// What someone typed, as an app worth focusing on. A bundle identifier is taken at its word — a command-line
    /// agent has no application bundle to find, and refusing to focus on one you can name would be daft.
    static func target(forTyped text: String, apps: [App] = all()) -> FocusTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = apps.first(where: { $0.bundleID.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return FocusTarget.app(exact.bundleID, name: exact.name)
        }
        if let named = apps.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return FocusTarget.app(named.bundleID, name: named.name)
        }
        // Not an app on this Mac. A dotted, space-free string is an identifier someone knows; anything else is a
        // process name, which is how Flowlight records command-line agents like `claude` and `codex`.
        return FocusTarget.app(trimmed, name: trimmed)
    }
}
