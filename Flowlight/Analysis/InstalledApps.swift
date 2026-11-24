import AppKit
import Foundation

/// The applications on this Mac, by name and bundle identifier.
///
/// Focus matches an app by its bundle identifier, so anything that lets someone name an app has to end up with
/// one. Typing "Cursor" has to become `com.todesktop.230313mzl4w4u92` somewhere, and the only place that mapping
/// exists is the app bundles themselves.
enum InstalledApps {
    /// Evidence that the identity came from an application bundle discovered by the filesystem scan.
    enum ScanEvidence: String, Equatable, Hashable, Sendable {
        case applicationBundle
    }

    /// Evidence that version values came from the bundle's Info.plist, rather than a guessed filename or path.
    enum VersionEvidence: String, Equatable, Hashable, Sendable {
        case bundleInfoDictionary
    }

    struct App: Equatable, Identifiable, Sendable {
        var name: String
        var bundleID: String
        var path: String
        var id: String { bundleID }
        /// What the app told macOS it wants Bluetooth for, when it declares a use. This is the app saying it is
        /// built to use the radio — not macOS saying it was granted access, which no ordinary app can read.
        var bluetoothPurpose: String?
        /// The user-facing version from CFBundleShortVersionString, when the bundle provides one.
        var marketingVersion: String?
        /// The build identifier from CFBundleVersion, when the bundle provides one.
        var buildVersion: String?
        /// Identity evidence is explicit so downstream analysis never has to infer it from a path or filename.
        var scanEvidence: ScanEvidence = .applicationBundle
        /// Version evidence is nil when neither Info.plist version key contained a usable string.
        var versionEvidence: VersionEvidence? = nil
    }

    struct ScanResult: Sendable {
        var apps: [App]
        var complete: Bool
    }

    private static let condition = NSCondition()
    private static var cached: ScanResult?
    private static var scanning = false

    /// Where applications live. The system folder is included because Safari and Mail are perfectly reasonable
    /// things to focus on, and they aren't in /Applications.
    private static var searchPaths: [String] {
        ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// A complete catalog is retained for synchronous lookups. Callers that can be first to ask load off the main
    /// actor; a partial scan is returned to that caller but never poisons every later lookup.
    static func all() -> [App] { scan().apps }

    static func scan(refresh: Bool = false) -> ScanResult {
        cachedScan(refresh: refresh) {
            let result = scan(in: searchPaths)
            #if APP_STORE
            // Sandboxed Store builds cannot truthfully claim that standard roots are a complete inventory. A
            // user-selected security-scoped location can be added later without changing the advisory matcher.
            return ScanResult(apps: result.apps, complete: false)
            #else
            return result
            #endif
        }
    }

    private static func infoString(_ bundle: Bundle, key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func cachedScan(refresh: Bool = false, _ load: () -> ScanResult) -> ScanResult {
        condition.lock()
        if !refresh, let cached { condition.unlock(); return cached }
        if scanning {
            repeat { condition.wait() } while scanning
            if let cached { condition.unlock(); return cached }
        }
        scanning = true
        condition.unlock()

        let result = load()
        condition.lock()
        if result.complete { cached = result }
        scanning = false
        condition.broadcast()
        condition.unlock()
        return result
    }

    static func resetCacheForTesting() {
        condition.lock()
        cached = nil
        condition.unlock()
    }

    static func scan(in searchPaths: [String], manager: FileManager = .default) -> ScanResult {
        let result = scanAll(in: searchPaths, manager: manager)
        var unique: [String: App] = [:]
        for app in result.apps {
            if let existing = unique[app.bundleID], existing.path <= app.path { continue }
            unique[app.bundleID] = app
        }
        return ScanResult(apps: unique.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }, complete: result.complete)
    }

    /// Returns every distinct canonical bundle path for advisory inventory. The compatibility `scan` method above
    /// retains one deterministic record per bundle ID for focus and Bluetooth callers.
    static func scanAll(in searchPaths: [String], manager: FileManager = .default,
                        maximumDepth: Int = 8, maximumVisits: Int = 50_000) -> ScanResult {
        var found: [String: App] = [:]
        var complete = true
        for directory in searchPaths {
            guard manager.fileExists(atPath: directory) else { continue }
            let rootURL = URL(fileURLWithPath: directory).standardizedFileURL
            guard let enumerator = manager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in complete = false; return true }
            ) else {
                complete = false
                continue
            }
            var visits = 0
            for case let url as URL in enumerator {
                visits += 1
                if visits > maximumVisits {
                    complete = false
                    break
                }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true,
                   url.pathComponents.count - rootURL.pathComponents.count >= maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
                    continue
                }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let purpose = (bundle.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "NSBluetoothPeripheralUsageDescription") as? String)
                let marketingVersion = infoString(bundle, key: "CFBundleShortVersionString")
                let buildVersion = infoString(bundle, key: "CFBundleVersion")
                let versionEvidence: VersionEvidence? = marketingVersion != nil || buildVersion != nil
                    ? .bundleInfoDictionary : nil
                let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                let key = "\(id.lowercased()):\(canonicalPath)"
                found[key] = App(name: name, bundleID: id, path: canonicalPath, bluetoothPurpose: purpose,
                                 marketingVersion: marketingVersion, buildVersion: buildVersion,
                                 scanEvidence: .applicationBundle, versionEvidence: versionEvidence)
            }
        }
        return ScanResult(
            apps: found.values.sorted {
                let name = $0.name.localizedCaseInsensitiveCompare($1.name)
                return name == .orderedAscending || (name == .orderedSame && $0.path < $1.path)
            },
            complete: complete && !found.isEmpty
        )
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
