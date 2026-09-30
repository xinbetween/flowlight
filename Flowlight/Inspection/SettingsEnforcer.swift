import Foundation

/// The pure part of writing proxy routing into an agent's JSON settings: merging a block of environment variables
/// into one top-level key and reversing it exactly. Kept free of the filesystem so the merge, and above all the
/// undo, can be tested against dictionaries rather than against files a test would have to create and clean up.
enum SettingsMerge {
    /// What one key looked like before Flowlight set it: `prior == nil` means the key was absent, so undoing means
    /// removing it; otherwise undoing means putting `prior` back.
    struct Entry: Codable, Equatable {
        var key: String
        var prior: String?
    }

    /// Merge `values` into the target dictionary — a nested object at `container`, or the JSON root itself when
    /// `container` is nil (for settings that keep the proxy in a top-level key like `"http.proxy"`). Returns the new
    /// root, what each key was before, and whether a nested container had to be created (so undo can remove it again).
    ///
    /// Throws if a key Flowlight would set already holds something other than a string, or a named container isn't a
    /// string-to-string object: that is someone else's data in a shape Flowlight doesn't understand, and the one thing
    /// it must never do is overwrite it. Keys it doesn't touch are always preserved.
    static func apply(to root: [String: Any], container: String?, values: [String: String]) throws
        -> (root: [String: Any], entries: [Entry], createdContainer: Bool) {
        var root = root
        var target: [String: String] = [:]
        var createdContainer = false
        if let container {
            switch root[container] {
            case nil: createdContainer = true
            case let existing as [String: String]: target = existing
            case let existing as [String: Any]:
                guard let strings = existing as? [String: String] else { throw EnforceError.envNotStrings }
                target = strings
            default: throw EnforceError.envNotStrings
            }
        } else {
            // Top-level keys: read the prior value of only the keys we're about to set; everything else in the root
            // is left untouched. A key we'd set that holds a non-string is refused rather than overwritten.
            for key in values.keys {
                switch root[key] {
                case nil: break
                case let value as String: target[key] = value
                default: throw EnforceError.envNotStrings
                }
            }
        }
        let entries = values.keys.sorted().map { Entry(key: $0, prior: target[$0]) }
        for (key, value) in values { target[key] = value }
        if let container {
            root[container] = target
        } else {
            for (key, value) in target { root[key] = value }
        }
        return (root, entries, createdContainer)
    }

    /// Reverse `apply`: put every key back to its prior state, and remove a container Flowlight created if nothing
    /// else was added to it. Safe to run more than once and even after the file was already restored by other means
    /// (the crash janitor), so recovery paths can't fight each other.
    static func revert(from root: [String: Any], container: String?, entries: [Entry], createdContainer: Bool) -> [String: Any] {
        var root = root
        if let container {
            var target = (root[container] as? [String: String]) ?? [:]
            for entry in entries {
                if let prior = entry.prior { target[entry.key] = prior } else { target.removeValue(forKey: entry.key) }
            }
            if target.isEmpty && createdContainer { root.removeValue(forKey: container) } else { root[container] = target }
        } else {
            for entry in entries {
                if let prior = entry.prior { root[entry.key] = prior } else { root.removeValue(forKey: entry.key) }
            }
        }
        return root
    }
}

enum EnforceError: LocalizedError {
    case envNotStrings
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .envNotStrings:
            return L("The settings file's environment block isn't in a shape Flowlight can edit safely, so it was left alone.")
        case .malformedJSON(let path):
            return L("Couldn't read %@ as JSON, so it was left alone.", path)
        }
    }
}

/// Persists proxy routing into a known agent's own settings file, so future sessions route through Flowlight
/// without being relaunched — "always monitor". Everything it changes is reversible: the original bytes are backed
/// up, every key it sets is recorded so it can be undone exactly, and a pre-staged clean copy plus a plain-text
/// manifest let the crash janitor (`ProxyJanitor`) restore the file with a single move, without parsing any JSON.
///
/// A persistent proxy pointer is only safe while the proxy is actually listening: a settings file left pointing at
/// a dead `127.0.0.1:<port>` would stop the agent reaching its API at all. So enforcement is applied when the proxy
/// comes up and stripped when it goes down or the app quits; the janitor covers the one case a clean quit can't —
/// a crash. See `InspectionController` for the lifecycle wiring.
final class SettingsEnforcer: @unchecked Sendable {
    static let shared = SettingsEnforcer()

    let directory: URL
    /// The base a recipe's `homeRelativePath` resolves against. Real home in the app; a temporary directory in tests,
    /// so a test never touches the user's actual `~/.claude/settings.json`.
    let home: URL
    private let queue = DispatchQueue(label: "flowlight.settings.enforcer")

    init(directory: URL = SettingsEnforcer.defaultDirectory,
         home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.directory = directory
        self.home = home
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flowlight/Enforcement", isDirectory: true)
    }

    /// Read by the crash janitor, which cannot parse JSON: one `port⇥livePath⇥cleanPath` line per enforced file,
    /// where `cleanPath` is `DELETE` when the file didn't exist before Flowlight created it.
    var manifestURL: URL { directory.appendingPathComponent("enforcement.manifest") }
    private var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }
    private var backupsDir: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    private var cleanDir: URL { directory.appendingPathComponent("clean", isDirectory: true) }

    static let deleteMarker = "DELETE"

    /// What Flowlight did to one agent's file, kept so it can be undone exactly.
    struct Record: Codable, Equatable {
        var livePath: String
        /// The JSON key the values were nested under, or nil when they were written at the root.
        var container: String?
        var entries: [SettingsMerge.Entry]
        var createdContainer: Bool
        var fileExisted: Bool
        var cleanPath: String?
        var backupPath: String?
        /// The proxy port this file was pointed at, so the janitor can tell a live proxy from a dead one.
        var port: UInt16
    }

    struct Ledger: Codable, Equatable {
        var records: [String: Record] = [:]
    }

    // MARK: Enforce / relax

    /// Route one agent through the proxy by writing it into its settings file, following the file's own shape. `env`
    /// carries Flowlight's full proxy environment (used whole for Claude Code's env block); `proxyURL` is the address
    /// written for the editors that take a single proxy key. Idempotent: re-applying keeps the record of what was
    /// originally there and only refreshes the proxy values (the port may have changed).
    func enforce(agent: String, recipe: ConfigRecipe, proxyURL: String, env: [String: String], proxyPort: UInt16) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let live = homeFile(recipe.homeRelativePath)
            let (container, values) = recipe.resolve(proxyURL: proxyURL, env: env)
            var ledger = loadLedger()

            if var existing = ledger.records[agent] {
                // Already enforced: don't recompute the prior state from a file we already changed, or we would
                // record our own values as if they were the user's. Just refresh the proxy values in place.
                let root = try readJSON(at: live) ?? [:]
                let merged = try SettingsMerge.apply(to: root, container: container, values: values)
                try writeJSON(merged.root, to: live)
                existing.livePath = live.path
                existing.port = proxyPort
                ledger.records[agent] = existing
                saveLedger(ledger)
                return
            }

            let fileExisted = FileManager.default.fileExists(atPath: live.path)
            let root = try readJSON(at: live) ?? [:]
            let merged = try SettingsMerge.apply(to: root, container: container, values: values)

            var backupPath: String?
            var cleanPath: String?
            if fileExisted {
                try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
                let original = try Data(contentsOf: live)
                // A timestamped backup that is never consumed, as a last resort if precise undo can't run.
                let backup = backupsDir.appendingPathComponent("\(Self.slug(agent)).\(Int(Date().timeIntervalSince1970)).bak")
                try original.write(to: backup, options: .atomic)
                backupPath = backup.path
                // The clean copy the janitor moves back into place. Separate from the backup so a restore can't
                // destroy the record of the original.
                let clean = cleanDir.appendingPathComponent("\(Self.slug(agent)).json")
                try original.write(to: clean, options: .atomic)
                cleanPath = clean.path
            }

            // Live file last, so the manifest only ever names a file whose clean copy is already staged.
            try writeJSON(merged.root, to: live)
            ledger.records[agent] = Record(livePath: live.path, container: container, entries: merged.entries,
                                           createdContainer: merged.createdContainer, fileExisted: fileExisted,
                                           cleanPath: cleanPath, backupPath: backupPath, port: proxyPort)
            saveLedger(ledger)
        }
    }

    /// Undo enforcement for one agent, restoring its settings file. Tolerant: a no-op if the agent isn't enforced,
    /// and safe even if the file was already restored (e.g. by the janitor) — it converges on the original either way.
    func relax(agent: String) {
        queue.sync {
            var ledger = loadLedger()
            guard let record = ledger.records[agent] else { return }
            restore(record)
            ledger.records.removeValue(forKey: agent)
            saveLedger(ledger)
        }
    }

    /// Undo every enforcement. Called on clean quit (synchronous, so it finishes before the process exits) and on
    /// launch to clear anything a previous run left behind before the proxy is running again.
    func relaxAll() {
        queue.sync {
            let ledger = loadLedger()
            for record in ledger.records.values { restore(record) }
            saveLedger(Ledger())
        }
    }

    /// True when at least one agent is currently enforced. Used to decide whether the crash janitor is needed.
    var isEnforcingAny: Bool {
        queue.sync { !loadLedger().records.isEmpty }
    }

    // MARK: Internals (run on `queue`)

    private func restore(_ record: Record) {
        let live = URL(fileURLWithPath: record.livePath)
        let clean = record.cleanPath.map { URL(fileURLWithPath: $0) }
        if let root = try? readJSON(at: live) {
            // Precise, JSON-aware undo of exactly the keys Flowlight set.
            let reverted = SettingsMerge.revert(from: root, container: record.container, entries: record.entries,
                                                createdContainer: record.createdContainer)
            if !record.fileExisted && reverted.isEmpty {
                try? FileManager.default.removeItem(at: live)
            } else {
                try? writeJSON(reverted, to: live)
            }
        } else if let clean, FileManager.default.fileExists(atPath: clean.path) {
            // The live file was replaced or hand-edited into something Flowlight can't parse. Fall back to the
            // staged clean copy, exactly as the crash janitor would, rather than risk a wrong precise edit.
            try? FileManager.default.removeItem(at: live)
            try? FileManager.default.copyItem(at: clean, to: live)
        } else if !record.fileExisted {
            // Nothing was there before and nothing parses now: leave nothing behind.
            try? FileManager.default.removeItem(at: live)
        }
        // The clean copy has served its purpose; the timestamped backup is kept as a last resort.
        if let clean { try? FileManager.default.removeItem(at: clean) }
    }

    private func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private func saveLedger(_ ledger: Ledger) {
        if ledger.records.isEmpty {
            try? FileManager.default.removeItem(at: ledgerURL)
            try? FileManager.default.removeItem(at: manifestURL)
            return
        }
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL, options: .atomic) }
        writeManifest(ledger)
    }

    /// Rebuilt from the ledger on every change so the janitor never reads a line for a file that is no longer enforced.
    private func writeManifest(_ ledger: Ledger) {
        let lines = ledger.records.values.map { record -> String in
            "\(record.port)\t\(record.livePath)\t\(record.cleanPath ?? Self.deleteMarker)"
        }
        let text = lines.sorted().joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: manifestURL, options: .atomic)
    }

    private func readJSON(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw EnforceError.malformedJSON(url.path) }
        guard let dict = object as? [String: Any] else { throw EnforceError.malformedJSON(url.path) }
        return dict
    }

    private func writeJSON(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func homeFile(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }

    private static func slug(_ agent: String) -> String {
        agent.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }
}
