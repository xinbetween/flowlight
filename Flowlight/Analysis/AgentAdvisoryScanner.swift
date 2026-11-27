import Darwin
import Foundation

/// A bounded local finding from an agent-ecosystem file. Raw contents and credential values are never retained.
struct AgentAdvisoryFinding: Identifiable, Equatable, Hashable, Sendable {
    enum Category: String, CaseIterable, Codable, Sendable {
        case artifact, instructions, hooks, permissions, mcp, plugins, gateway, credentials, provenance
    }

    enum Severity: Int, CaseIterable, Codable, Sendable, Comparable {
        case info = 0, low, medium, high, critical

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
        var title: String {
            switch self {
            case .info: return L("Informational")
            case .low: return L("Low")
            case .medium: return L("Medium")
            case .high: return L("High")
            case .critical: return L("Critical")
            }
        }
        var colorName: String {
            switch self {
            case .info: return "secondary"
            case .low: return "accent"
            case .medium: return "warning"
            case .high, .critical: return "critical"
            }
        }
    }

    enum Surface: String, CaseIterable, Codable, Sendable {
        case direct, indirect, internalThreat, resource, oversight, compound

        var title: String {
            switch self {
            case .direct: return L("Direct")
            case .indirect: return L("Indirect")
            case .internalThreat: return L("Internal")
            case .resource: return L("Resource")
            case .oversight: return L("Oversight")
            case .compound: return L("Compound")
            }
        }
    }

    var id: String
    /// Stable only within one scan; never contains the raw selected path.
    var sourceID: String = ""
    var agent: String
    var category: Category
    var severity: Severity
    var surface: Surface
    var source: String
    var title: String
    var explanation: String
    var remediation: String
    var hasPrivateDataAccess: Bool
    var hasUntrustedContent: Bool
    var hasExternalEgress: Bool
}

struct AgentAdvisorySourceResult: Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case complete, incomplete, capped, permissionDenied, cancelled
    }

    /// Stable only within one scan; the display root may be redacted or repeated.
    var id: String { sourceID.isEmpty ? root : sourceID }
    var sourceID: String = ""
    var root: String
    var status: Status
    var directoriesVisited: Int
    var candidateFiles: Int
    var filesRead: Int
    var bytesRead: Int
    var findings: Int
    var reasons: [String]
    // Targets are registered files and directory trees. Checked includes probes for absent targets.
    // An unavailable root or intermediate component can prevent verifying whether its targets are present.
    var settingsChecked: Int = 0
    var settingsPresent: Int = 0
    var settingsInspected: Int = 0
    var settingsInaccessible: Int = 0
    var settingsCapped: Int = 0
    var settingsCancelled: Int = 0
    var truncatedFiles: Int = 0
    var omittedFindings: Int = 0
    var inaccessibleFiles: Int = 0
}

struct AgentAdvisoryObservedEvidence: Equatable, Sendable {
    var category: AgentAdvisoryFinding.Category
    var severity: AgentAdvisoryFinding.Severity
    var count: Int
    var hasPrivateDataAccess: Bool
    var hasUntrustedContent: Bool
    var hasExternalEgress: Bool
}

struct AgentAdvisoryScanResult: Equatable, Sendable {
    var findings: [AgentAdvisoryFinding]
    var sources: [AgentAdvisorySourceResult]
    var privateDataAccess: Bool
    var untrustedContent: Bool
    var externalEgress: Bool
    var observedEvidence: [AgentAdvisoryObservedEvidence] = []
    var inspectedEcosystems: [String] = []

    var complete: Bool { sources.allSatisfy { $0.status == .complete } }
    var incompleteSourceCount: Int { sources.filter { $0.status != .complete }.count }
    var highestSeverity: AgentAdvisoryFinding.Severity? {
        observedEvidence.map(\.severity).max() ?? findings.map(\.severity).max()
    }
    var settingsChecked: Int { total(\.settingsChecked) }
    var settingsPresent: Int { total(\.settingsPresent) }
    var settingsInspected: Int { total(\.settingsInspected) }
    var settingsInaccessible: Int { total(\.settingsInaccessible) }
    var settingsCapped: Int { total(\.settingsCapped) }
    var settingsCancelled: Int { total(\.settingsCancelled) }
    var truncatedFiles: Int { total(\.truncatedFiles) }
    var omittedFindings: Int { total(\.omittedFindings) }
    var inaccessibleFiles: Int { total(\.inaccessibleFiles) }
    var totalFindingCount: Int { findings.count + omittedFindings }

    private func total(_ key: KeyPath<AgentAdvisorySourceResult, Int>) -> Int {
        sources.reduce(0) { $0 + $1[keyPath: key] }
    }
}

struct AgentAdvisoryScanConfiguration: Equatable, Sendable {
    var roots: [URL]
    var maximumDepth: Int = 8
    var maximumDirectoryVisits: Int = 50_000
    var maximumCandidateFiles: Int = 10_000
    var maximumBytesPerFile: Int = 256 * 1024
    var maximumTotalBytes: Int = 64 * 1024 * 1024
    var maximumFindings: Int = 2_000
    var maximumDirectoryEntries: Int = 250_000
    var unavailableRoots: [URL] = []

    static var homeRoot: AgentAdvisoryScanConfiguration {
        AgentAdvisoryScanConfiguration(roots: [FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL])
    }

    /// Compatibility name for older callers. The default is the user's home folder.
    static var systemRoot: AgentAdvisoryScanConfiguration { homeRoot }
}

/// Persisted, explicitly selected Agent advisory roots. This namespace is separate from software package roots.
enum AgentAdvisoryRootPreferences {
    static let rootsKey = "agentAdvisoryScan.selectedRoots"
    static let bookmarksKey = "agentAdvisoryScan.selectedBookmarks"

    static var selectedRoots: [AdvisoryInventoryRoot] { selectedRoots(defaults: .standard) }

    static func selectedRoots(defaults: UserDefaults) -> [AdvisoryInventoryRoot] {
        let paths = defaults.stringArray(forKey: rootsKey) ?? []
        let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        var seen = Set<String>()
        return paths.compactMap { path in
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
            guard canonical != "/", seen.insert(canonical).inserted else { return nil }
            return AdvisoryInventoryRoot(path: canonical, userSelected: true, bookmarkData: bookmarks[path] ?? bookmarks[canonical])
        }
    }

    static func save(_ roots: [AdvisoryInventoryRoot], defaults: UserDefaults = .standard) {
        var unique: [AdvisoryInventoryRoot] = []
        var seen = Set<String>()
        for root in roots {
            let canonical = URL(fileURLWithPath: root.path).standardizedFileURL.path
            guard canonical != "/", seen.insert(canonical).inserted else { continue }
            unique.append(AdvisoryInventoryRoot(path: canonical, userSelected: true, bookmarkData: root.bookmarkData))
        }
        defaults.set(unique.map(\.path), forKey: rootsKey)
        let bookmarks = Dictionary(uniqueKeysWithValues: unique.compactMap { root in
            root.bookmarkData.map { (root.path, $0) }
        })
        defaults.set(bookmarks, forKey: bookmarksKey)
    }
}

/// Static inspection of local metadata. Files and directories are opened relative to an authorized directory descriptor.
struct AgentAdvisoryScanner {
    var configuration: AgentAdvisoryScanConfiguration
    private let fileManager: FileManager

    init(configuration: AgentAdvisoryScanConfiguration = .homeRoot, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    private static let directoryAgents = AgentWorkspaceScanner.directories
    private static let candidateNames: Set<String> = [
        "CLAUDE.md", "AGENTS.md", "GEMINI.md", "MCP.md", ".mcp.json", "mcp.json", "mcp_servers.json",
        "settings.json", "settings.local.json", "config.toml", "manifest.json", "plugin.json", "SKILL.md",
        "permissions.json", "hooks.json", "allowlist.json", "rules.md", "instructions.md"
    ]
    private static let candidateExtensions: Set<String> = ["md", "json", "toml", "yaml", "yml", "plist"]
    private static let prunedNames: Set<String> = [
        ".git", "node_modules", "vendor", "target", "build", "deriveddata", ".next", "dist", "venv", ".venv",
        "pods", "carthage", "__pycache__", "library", ".trash", "applications",
        "desktop", "documents", "downloads", "movies", "music", "pictures", "icloud drive"
    ]
    private static let privateDataWords: Set<String> = [
        "transcript", "transcripts", "session", "sessions", "history", "histories", "log", "logs", "cache", "caches",
        "chat", "chats", "conversation", "conversations"
    ]
    private static let prunedExtensions: Set<String> = ["jsonl", "ndjson", "log", "app", "bundle", "framework", "photoslibrary"]
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private struct SettingsFile {
        var components: [String]
        var agent: String
        var mcpKeys: [String] = []
    }

    private static let settingsFiles: [SettingsFile] = {
        let anchor = URL(fileURLWithPath: "/", isDirectory: true)
        let mcpAgents = ["Claude Code": "claude", "Claude": "claude", "Cursor": "cursor",
                         "Windsurf": "windsurf", "Visual Studio Code": "vscode", "Codex": "codex",
                         "Zed": "zed", "Gemini CLI": "gemini"]
        var files: [String: SettingsFile] = [:]
        for file in AgentGatewayConfigReader.settingsPaths {
            files[file.path] = SettingsFile(components: file.path.split(separator: "/").map(String.init), agent: file.agent)
        }
        for file in MCPConfigReader.knownFiles(home: anchor) {
            guard let agent = mcpAgents[file.client] else { continue }
            let components = Array(file.url.pathComponents.dropFirst())
            let keys: [String]
            switch file.format {
            case .json(let names): keys = names
            case .claudeCode: keys = ["mcpServers"]
            case .codexTOML: keys = []
            }
            files[components.joined(separator: "/")] = SettingsFile(components: components, agent: agent, mcpKeys: keys)
        }
        return files.values.sorted { $0.components.lexicographicallyPrecedes($1.components) }
    }()

    private enum Outcome: Int {
        case complete, capped, inaccessible, cancelled

        mutating func include(_ other: Self) {
            if other.rawValue > rawValue { self = other }
        }
    }

    private enum Lookup {
        case missing, inaccessible, present(mode_t)
    }

    private final class ScanSource {
        let root: URL
        let exact: [SettingsFile]
        let directories: [(path: [String], agent: String)]
        let exactPaths: Set<[String]>
        let rootAgent: String?
        var report: AgentAdvisorySourceResult
        var descriptor: Int32 = -1
        var entriesListed = 0
        var attemptedReads = 0
        var reasons = Set<String>()
        var outcome: Outcome = .complete

        init(root: URL, sourceID: String, displayRoot: String) {
            self.root = root
            let selected = root.pathComponents
            let rebased: [(file: SettingsFile, matched: Bool, library: Bool)] = AgentAdvisoryScanner.settingsFiles.map { file in
                var rebased = file
                // Require the named app component in Library so an unrelated folder named User never matches.
                let library = file.components.first == "Library"
                let minimum = library ? 3 : 1
                let maximum = file.components.count - 1
                if maximum >= minimum,
                   let prefix = (minimum...maximum).reversed().first(where: {
                       selected.suffix($0).elementsEqual(file.components.prefix($0))
                   }) {
                    rebased.components.removeFirst(prefix)
                    return (rebased, true, library)
                }
                return (rebased, false, library)
            }
            let agent = AgentAdvisoryScanner.directoryAgents[root.lastPathComponent]
                ?? rebased.first { $0.matched && ($0.library || $0.file.components.count == 1) }?.file.agent
            rootAgent = agent
            exact = rebased.filter { agent == nil || $0.matched }.map(\.file)
            exactPaths = Set(exact.map(\.components))
            if let agent {
                // Even a selected Library settings folder remains limited to registered files.
                directories = rebased.contains { $0.matched && $0.library } ? [] : [([], agent)]
            } else {
                directories = AgentAdvisoryScanner.directoryAgents.sorted { $0.key < $1.key }.map { ([$0.key], $0.value) }
            }
            report = AgentAdvisorySourceResult(sourceID: sourceID, root: displayRoot, status: .complete,
                                                directoriesVisited: 0, candidateFiles: 0, filesRead: 0,
                                                bytesRead: 0, findings: 0, reasons: [])
        }

        deinit { if descriptor >= 0 { close(descriptor) } }

        func note(_ outcome: Outcome, _ reason: String) {
            self.outcome.include(outcome)
            reasons.insert(reason)
        }

        func recordSetting(_ outcome: Outcome) {
            self.outcome.include(outcome)
            switch outcome {
            case .complete: report.settingsInspected += 1
            case .capped: report.settingsCapped += 1
            case .inaccessible: report.settingsInaccessible += 1
            case .cancelled: report.settingsCancelled += 1
            }
        }

        func result() -> AgentAdvisorySourceResult {
            report.reasons = reasons.sorted()
            if report.status != .permissionDenied {
                switch outcome {
                case .complete: break
                case .capped: report.status = .capped
                case .inaccessible: report.status = .incomplete
                case .cancelled: report.status = .cancelled
                }
            }
            return report
        }
    }

    private struct EvidenceKey: Hashable {
        var category: AgentAdvisoryFinding.Category
        var severity: AgentAdvisoryFinding.Severity
        var privateData: Bool
        var untrusted: Bool
        var egress: Bool

        var signalOrder: Int { (privateData ? 4 : 0) + (untrusted ? 2 : 0) + (egress ? 1 : 0) }
    }

    private struct ScanState {
        var findings: [AgentAdvisoryFinding] = []
        var evidence: [EvidenceKey: Int] = [:]
        var ecosystems = Set<String>()
        var totalBytes = 0

        var observedEvidence: [AgentAdvisoryObservedEvidence] {
            evidence.keys.sorted {
                ($0.category.rawValue, $0.severity.rawValue, $0.signalOrder) <
                    ($1.category.rawValue, $1.severity.rawValue, $1.signalOrder)
            }.map { key in
                AgentAdvisoryObservedEvidence(category: key.category, severity: key.severity, count: evidence[key, default: 0],
                                              hasPrivateDataAccess: key.privateData, hasUntrustedContent: key.untrusted,
                                              hasExternalEgress: key.egress)
            }
        }
    }

    func scan() -> AgentAdvisoryScanResult {
        var state = ScanState()
        var seen = Set<String>()
        var sources: [ScanSource] = []
        let homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        for (roots, unavailable) in [(configuration.roots, false), (configuration.unavailableRoots, true)] {
            for requested in roots {
                let root = requested.standardizedFileURL
                guard seen.insert(root.path).inserted else { continue }
                let source = ScanSource(root: root, sourceID: "root-\(sources.count + 1)", displayRoot: displayRoot(root))
                sources.append(source)
                if unavailable || !root.isFileURL || root.path == "/" {
                    source.report.status = .permissionDenied
                    source.note(.inaccessible, "Scan root is unavailable.")
                } else if Task.isCancelled {
                    source.note(.cancelled, "Scan cancelled before this root was inspected.")
                } else {
                    source.descriptor = open(root.path, Self.directoryFlags)
                    if source.descriptor < 0 {
                        source.report.status = .permissionDenied
                        source.note(.inaccessible, "Scan root is unavailable.")
                    } else if root.path == homePath {
                        source.note(.inaccessible, "Privacy-protected and system-library folders were intentionally skipped.")
                    }
                }
            }
        }
        // Finish exact probes across all roots before any disk budget is spent on a directory listing.
        for source in sources {
            for file in source.exact { inspectExact(file, source: source, state: &state) }
        }
        for source in sources {
            for directory in source.directories {
                inspectSettingsDirectory(directory.path, agent: directory.agent, source: source, state: &state)
            }
        }
        for source in sources where source.descriptor >= 0 && source.rootAgent == nil {
            guard !Self.shouldPrune(source.root.lastPathComponent) else { continue }
            _ = walkDirectory(source.descriptor, relative: [], agent: nil, source: source, state: &state)
        }
        let evidence = state.observedEvidence
        return AgentAdvisoryScanResult(findings: state.findings, sources: sources.map { $0.result() },
                                       privateDataAccess: evidence.contains(where: \.hasPrivateDataAccess),
                                       untrustedContent: evidence.contains(where: \.hasUntrustedContent),
                                       externalEgress: evidence.contains(where: \.hasExternalEgress),
                                       observedEvidence: evidence, inspectedEcosystems: state.ecosystems.sorted())
    }

    private func unavailableOutcome(_ source: ScanSource) -> Outcome? {
        if source.report.status == .permissionDenied { return .inaccessible }
        if Task.isCancelled {
            source.note(.cancelled, "Scan cancelled before all accessible files were inspected.")
            return .cancelled
        }
        return nil
    }

    private func inspectExact(_ file: SettingsFile, source: ScanSource, state: inout ScanState) {
        if let outcome = unavailableOutcome(source) {
            source.recordSetting(outcome)
            return
        }
        source.report.settingsChecked += 1
        var directory = source.descriptor
        defer { if directory != source.descriptor { close(directory) } }
        for name in file.components.dropLast() {
            switch lookup(directory, name) {
            case .missing: return
            case .present(let mode) where (mode & S_IFMT) == S_IFDIR:
                let next = openat(directory, name, Self.directoryFlags)
                guard next >= 0 else { recordInaccessibleSetting(source); return }
                if directory != source.descriptor { close(directory) }
                directory = next
            case .present, .inaccessible:
                recordInaccessibleSetting(source)
                return
            }
        }
        guard let name = file.components.last else { return }
        switch lookup(directory, name) {
        case .missing: break
        case .inaccessible: recordInaccessibleSetting(source)
        case .present(let mode):
            source.report.settingsPresent += 1
            source.recordSetting(inspectFile(directory, relative: file.components, mode: mode, agent: file.agent,
                                             mcpKeys: file.mcpKeys, source: source, state: &state))
        }
    }

    private func inspectSettingsDirectory(_ relative: [String], agent: String,
                                          source: ScanSource, state: inout ScanState) {
        if let outcome = unavailableOutcome(source) {
            source.recordSetting(outcome)
            return
        }
        source.report.settingsChecked += 1
        let directory: Int32
        if let name = relative.first {
            switch lookup(source.descriptor, name) {
            case .missing: return
            case .inaccessible: recordInaccessibleSetting(source); return
            case .present(let mode):
                source.report.settingsPresent += 1
                guard (mode & S_IFMT) == S_IFDIR else { recordInaccessibleSetting(source); return }
            }
            guard relative.count <= max(0, configuration.maximumDepth) else {
                source.note(.capped, "Directory depth limit reached.")
                source.recordSetting(.capped)
                return
            }
            directory = openat(source.descriptor, name, Self.directoryFlags)
            guard directory >= 0 else { recordInaccessibleSetting(source); return }
        } else {
            source.report.settingsPresent += 1
            directory = source.descriptor
        }
        defer { if directory != source.descriptor { close(directory) } }
        source.recordSetting(walkDirectory(directory, relative: relative, agent: agent, source: source, state: &state))
    }

    private func lookup(_ directory: Int32, _ name: String) -> Lookup {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .present(info.st_mode) }
        return errno == ENOENT ? .missing : .inaccessible
    }

    private func recordInaccessibleSetting(_ source: ScanSource) {
        source.recordSetting(.inaccessible)
        source.note(.inaccessible, "Some settings paths could not be opened safely.")
    }

    private func walkDirectory(_ directory: Int32, relative: [String], agent: String?,
                               source: ScanSource, state: inout ScanState) -> Outcome {
        if let outcome = unavailableOutcome(source) { return outcome }
        guard source.report.directoriesVisited < max(0, configuration.maximumDirectoryVisits) else {
            source.note(.capped, "Directory visit limit reached.")
            return .capped
        }
        guard source.entriesListed < max(0, configuration.maximumDirectoryEntries) else {
            source.note(.capped, "Directory listing limit reached.")
            return .capped
        }
        source.report.directoriesVisited += 1
        let (entries, listingOutcome) = directoryEntries(directory, source: source)
        var outcome = listingOutcome
        for entry in entries {
            if let stopped = unavailableOutcome(source) { return stopped }
            // Claude Code stores conversation state under projects; project settings are discovered separately.
            if agent == "claude" && entry.name.lowercased() == "projects" { continue }
            let components = relative + [entry.name]
            if source.exactPaths.contains(components) { continue }
            let childAgent = Self.directoryAgents[entry.name] ?? agent
            if relative.isEmpty && agent == nil && childAgent != nil { continue }
            let candidate = isCandidate(entry.name, agent: agent)
            let mayDescend = !entry.name.hasPrefix(".") || childAgent != nil
            guard candidate || (mayDescend && (entry.type == Int32(DT_DIR) || entry.type == Int32(DT_UNKNOWN))) else { continue }
            guard case .present(let mode) = lookup(directory, entry.name) else {
                if candidate { source.report.inaccessibleFiles += 1 }
                source.note(.inaccessible, "Some directory entries could not be inspected safely.")
                outcome.include(.inaccessible)
                continue
            }
            if (mode & S_IFMT) == S_IFDIR {
                guard mayDescend else { continue }
                guard components.count <= max(0, configuration.maximumDepth) else {
                    source.note(.capped, "Directory depth limit reached.")
                    outcome.include(.capped)
                    continue
                }
                let child = openat(directory, entry.name, Self.directoryFlags)
                guard child >= 0 else {
                    source.note(.inaccessible, "Some folders could not be opened safely.")
                    outcome.include(.inaccessible)
                    continue
                }
                outcome.include(walkDirectory(child, relative: components, agent: childAgent, source: source, state: &state))
                close(child)
            } else if candidate {
                outcome.include(inspectFile(directory, relative: components, mode: mode, agent: agent, source: source, state: &state))
            }
        }
        return outcome
    }

    private func directoryEntries(_ directory: Int32, source: ScanSource) -> ([(name: String, type: Int32)], Outcome) {
        let listing = openat(directory, ".", Self.directoryFlags)
        guard listing >= 0 else {
            source.note(.inaccessible, "Some folders could not be listed safely.")
            return ([], .inaccessible)
        }
        guard let stream = fdopendir(listing) else {
            close(listing)
            source.note(.inaccessible, "Some folders could not be listed safely.")
            return ([], .inaccessible)
        }
        defer { closedir(stream) }
        var entries: [(name: String, type: Int32)] = []
        var outcome: Outcome = .complete
        while true {
            if let stopped = unavailableOutcome(source) { return ([], stopped) }
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    source.note(.inaccessible, "Some folders could not be listed safely.")
                    outcome.include(.inaccessible)
                }
                break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
            }
            if name == "." || name == ".." { continue }
            guard source.entriesListed < max(0, configuration.maximumDirectoryEntries) else {
                source.note(.capped, "Directory listing limit reached.")
                outcome.include(.capped)
                break
            }
            source.entriesListed += 1
            // Apply exclusions before inspecting entry metadata or opening a child descriptor.
            guard let name else {
                source.note(.inaccessible, "Some directory entries could not be inspected safely.")
                outcome.include(.inaccessible)
                continue
            }
            if !Self.shouldPrune(name) { entries.append((name, Int32(entry.pointee.d_type))) }
        }
        return (entries.sorted { $0.name < $1.name }, outcome)
    }

    private static func shouldPrune(_ name: String) -> Bool {
        let lower = name.lowercased()
        if prunedNames.contains(lower) { return true }
        if prunedExtensions.contains((lower as NSString).pathExtension) { return true }
        return lower.split(whereSeparator: { ".-_ ".contains($0) }).contains { privateDataWords.contains(String($0)) }
    }

    private func isCandidate(_ name: String, agent: String?) -> Bool {
        if Self.candidateNames.contains(name) { return true }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if agent != nil && (Self.candidateExtensions.contains(ext) || lower.contains("hook")) { return true }
        if lower.hasPrefix("settings") && ext == "json" { return true }
        return Self.candidateExtensions.contains(ext) && ["mcp", "plugin", "skill"].contains { lower.contains($0) }
    }

    private func inspectFile(_ parent: Int32, relative: [String], mode: mode_t, agent: String?, mcpKeys: [String] = [],
                             source: ScanSource, state: inout ScanState) -> Outcome {
        if let stopped = unavailableOutcome(source) { return stopped }
        guard let name = relative.last, !Self.shouldPrune(name) else { return .complete }
        source.report.candidateFiles += 1
        func inaccessible() -> Outcome {
            source.report.inaccessibleFiles += 1
            source.note(.inaccessible, "Some candidate files could not be read safely.")
            return .inaccessible
        }
        guard (mode & S_IFMT) == S_IFREG else { return inaccessible() }
        guard source.attemptedReads < max(0, configuration.maximumCandidateFiles) else {
            source.note(.capped, "Candidate file limit reached.")
            return .capped
        }
        source.attemptedReads += 1
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return inaccessible() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return inaccessible() }
        let perFile = max(0, configuration.maximumBytesPerFile)
        let remaining = max(0, configuration.maximumTotalBytes - state.totalBytes)
        let limit = min(perFile, remaining)
        let capReason = limit == remaining ? "Total scan byte limit reached." : "File byte limit reached."
        if limit == 0 && info.st_size != 0 {
            source.note(.capped, capReason)
            return .capped
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, limit))
        while data.count < limit {
            if let stopped = unavailableOutcome(source) { return stopped }
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                return inaccessible()
            }
            if count == 0 { break }
            source.report.bytesRead += count
            state.totalBytes += count
            data.append(contentsOf: buffer[0..<count])
        }
        if let stopped = unavailableOutcome(source) { return stopped }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0 else { return inaccessible() }
        let truncated = finalInfo.st_size > data.count || (data.count == limit && info.st_size > data.count)
        source.report.filesRead += 1
        if let agent { state.ecosystems.insert(agent) }
        classify(name: name, path: "scan-root/" + relative.joined(separator: "/"), data: data, agent: agent,
                 mcpKeys: mcpKeys, source: source, state: &state)
        if truncated {
            source.report.truncatedFiles += 1
            source.note(.capped, capReason)
            return .capped
        }
        return .complete
    }

    private func classify(name: String, path: String, data: Data, agent: String?, mcpKeys: [String],
                          source: ScanSource, state: inout ScanState) {
        let lower = String(decoding: data, as: UTF8.self).lowercased()
        let lowerName = name.lowercased()
        var categories = Set<AgentAdvisoryFinding.Category>()
        var privateData = false
        var untrusted = false
        var egress = false
        if Self.candidateNames.contains(name) || lowerName.hasSuffix(".md") {
            categories.insert(.instructions)
            untrusted = true
        }
        if lowerName.contains("hook") || lower.contains("\"hooks\"") || lower.contains("pretooluse") || lower.contains("posttooluse") {
            categories.insert(.hooks)
            untrusted = true
        }
        if lowerName.contains("permission") || lower.contains("permission") || lower.contains("allowlist") || lower.contains("\"allow\"") {
            categories.insert(.permissions)
            privateData = lower.contains("filesystem") || lower.contains("home") || lower.contains("credential")
        }
        if lowerName.contains("mcp") || lower.contains("mcpservers") || lower.contains("mcp_servers")
            || lower.contains("\"context_servers\"") || mcpKeys.contains(where: { lower.contains("\"\($0.lowercased())\"") }) {
            categories.insert(.mcp)
            untrusted = true
        }
        if lowerName.contains("plugin") || lower.contains("enabledplugins") || lower.contains("\"plugins\"") {
            categories.insert(.plugins)
            untrusted = true
        }
        if lower.contains("http://") || lower.contains("https://") || lower.contains("base_url") || lower.contains("proxy") {
            categories.insert(.gateway)
            egress = true
        }
        if Self.credentialPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            categories.insert(.credentials)
            privateData = true
        }
        if categories.isEmpty { categories.insert(.artifact) }

        for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            let severity = severity(for: category, text: lower)
            let key = EvidenceKey(category: category, severity: severity, privateData: privateData, untrusted: untrusted, egress: egress)
            state.evidence[key, default: 0] += 1
            guard state.findings.count < max(0, configuration.maximumFindings) else {
                source.report.omittedFindings += 1
                continue
            }
            let (surface, title, explanation, remediation) = presentation(for: category)
            let agent = agent ?? L("Unknown agent")
            let sourceID = source.report.sourceID
            state.findings.append(AgentAdvisoryFinding(id: "\(sourceID):\(category.rawValue):\(agent):\(path)",
                                                      sourceID: sourceID, agent: agent, category: category,
                                                      severity: severity, surface: surface, source: path,
                                                      title: title, explanation: explanation, remediation: remediation,
                                                      hasPrivateDataAccess: privateData, hasUntrustedContent: untrusted,
                                                      hasExternalEgress: egress))
            source.report.findings += 1
        }
    }

    private static let credentialPattern = try! NSRegularExpression(
        pattern: #"\b(api[_-]?key|access[_-]?key|secret|token|password|private[_-]?key|authorization)\b["']?\s*[=:]"#
    )

    private func presentation(for category: AgentAdvisoryFinding.Category) -> (AgentAdvisoryFinding.Surface, String, String, String) {
        switch category {
        case .artifact:
            return (.internalThreat, L("Agent artifact discovered"),
                    L("This bounded scan found agent-related metadata. Its contents were not executed."),
                    L("Review the source and its provenance before enabling it."))
        case .instructions:
            return (.indirect, L("Instruction or skill content"),
                    L("Instructions and skill metadata can influence an agent through an indirect trust boundary."),
                    L("Review project-local instructions and keep untrusted content separate from trusted policy."))
        case .hooks:
            return (.internalThreat, L("Automation hook declared"),
                    L("A hook can run as part of an agent lifecycle and may become a confused deputy."),
                    L("Use least privilege and require review for hooks that can execute commands or access data."))
        case .permissions:
            return (.resource, L("Agent permission declaration"),
                    L("This metadata declares agent capabilities or allow/deny rules that affect its trust boundary."),
                    L("Prefer explicit approval, scoped credentials, and a minimal filesystem and network scope."))
        case .mcp:
            return (.compound, L("MCP configuration discovered"),
                    L("Tool descriptions and server metadata are part of the agent supply chain and may be untrusted."),
                    L("Review server provenance, tool descriptions, hashes, and egress scope before enabling it."))
        case .plugins:
            return (.compound, L("Agent plugin metadata"),
                    L("Plugins and extensions can change agent behavior and should be reviewed as supply-chain inputs."),
                    L("Pin provenance and content hashes; do not enable an unreviewed plugin."))
        case .gateway:
            return (.resource, L("External endpoint configured"),
                    L("A normalized endpoint suggests this agent can send data outside its local boundary."),
                    L("Use an infrastructure-level egress allowlist and verify the endpoint independently."))
        case .credentials:
            return (.resource, L("Credential-like material present"),
                    L("A credential-like key or value was detected; the value is hidden and was not retained."),
                    L("Move secrets to scoped secure storage and rotate any exposed credential."))
        case .provenance:
            return (.oversight, L("Provenance is unavailable"),
                    L("The artifact has no bounded provenance or hash evidence in the inspected metadata."),
                    L("Verify the source, version, and content hash before use."))
        }
    }

    private func severity(for category: AgentAdvisoryFinding.Category, text: String) -> AgentAdvisoryFinding.Severity {
        switch category {
        case .credentials: return .critical
        case .hooks: return text.contains("allow") || text.contains("shell") || text.contains("command") ? .high : .medium
        case .mcp: return text.contains("command") || text.contains("http") ? .high : .medium
        case .permissions: return text.contains("allow") ? .high : .medium
        case .gateway, .plugins, .provenance: return .medium
        case .instructions: return .low
        case .artifact: return .info
        }
    }

    private func displayRoot(_ url: URL) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let users = components.firstIndex(of: "Users"), components.count > users + 1 {
            components[users + 1] = "<user>"
            return "/" + components.joined(separator: "/")
        }
        return path
    }
}
