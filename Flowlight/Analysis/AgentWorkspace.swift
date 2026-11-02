import Foundation

/// Something an agent is set up to do, found in its configuration on this Mac.
struct AgentCapability: Equatable, Identifiable, Sendable, Codable {
    enum Kind: String, Sendable, Codable {
        case skill, subagent, command, hook, plugin, permission, instructions
    }

    var kind: Kind
    var name: String
    /// A description, a hook's command, or a permission rule.
    var detail: String?
    /// Where it came from, relative to the home folder.
    var source: String
    /// True for project-level configuration, false for the user's own.
    var isProject: Bool
    /// Hooks and permissions that let an agent run commands or reach the network.
    var isSensitive = false
    var id: String { "\(kind.rawValue):\(name):\(source)" }
}

/// One agent's configuration directory (`~/.claude`, a project's `.codex`, …).
struct AgentWorkspace: Equatable, Sendable, Codable {
    /// Matches `AgentCatalog` process names: claude, codex, cursor, gemini…
    var agent: String
    var root: String
    var isProject: Bool
    var capabilities: [AgentCapability] = []
    var mcpServers: [MCPServerConfig] = []
    /// Endpoints declared by this agent's documented proxy or LLM-gateway settings.
    var gateways: [AgentGatewayConfig] = []

    private enum CodingKeys: String, CodingKey {
        case agent, root, isProject, capabilities, mcpServers, gateways
    }

    init(agent: String, root: String, isProject: Bool, capabilities: [AgentCapability] = [],
         mcpServers: [MCPServerConfig] = [], gateways: [AgentGatewayConfig] = []) {
        self.agent = agent
        self.root = root
        self.isProject = isProject
        self.capabilities = capabilities
        self.mcpServers = mcpServers
        self.gateways = gateways
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agent = try values.decode(String.self, forKey: .agent)
        root = try values.decode(String.self, forKey: .root)
        isProject = try values.decode(Bool.self, forKey: .isProject)
        capabilities = try values.decodeIfPresent([AgentCapability].self, forKey: .capabilities) ?? []
        mcpServers = try values.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        gateways = try values.decodeIfPresent([AgentGatewayConfig].self, forKey: .gateways) ?? []
    }

    func of(_ kind: AgentCapability.Kind) -> [AgentCapability] { capabilities.filter { $0.kind == kind } }
}

/// Finds agent configuration on this Mac and reads what it declares: skills, subagents, slash commands, hooks,
/// plugins, permission rules and MCP servers.
///
/// Everything stays local: Flowlight keeps names, descriptions and the commands hooks run, so the AI Agents view can
/// show what an agent is set up to do even before it makes a single request.
enum AgentWorkspaceScanner {
    /// Directory names that identify an agent, and the agent they belong to.
    static let directories: [String: String] = [
        ".claude": "claude", ".codex": "codex", ".cursor": "cursor", ".gemini": "gemini",
        ".windsurf": "windsurf", ".continue": "continue", ".aider": "aider", ".opencode": "opencode",
        ".goose": "goose", ".agents": "agents",
    ]

    /// Folders that never hold agent configuration, and would make the scan slow or nosy.
    static let skipped: Set<String> = [
        "Library", "Applications", "Pictures", "Music", "Movies", "Public", ".Trash", "node_modules", ".git",
        "Photos Library.photoslibrary", "venv", ".venv", "vendor", "target", "build", "DerivedData", ".next", "dist",
    ]

    /// Folders macOS protects behind a privacy prompt. Flowlight never walks into them on its own; a project folder
    /// inside one is scanned only if the person picks it themselves.
    static let protected: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "iCloud Drive"]

    /// Scans the agent configuration folders in the home folder itself (`~/.claude`, `~/.codex`, …) plus any project
    /// folders the person added. It deliberately does not walk the whole home folder: that crosses Desktop, Documents
    /// and Downloads, which makes macOS ask for permission Flowlight doesn't need.
    static func scan(home rawHome: URL = FileManager.default.homeDirectoryForCurrentUser, extraRoots: [URL] = [],
                     maxDepth: Int = 4, maxVisits: Int = 4000, fm: FileManager = .default) -> [AgentWorkspace] {
        let home = rawHome.standardizedFileURL
        var workspaces: [AgentWorkspace] = []
        var visits = 0
        // Depth `maxDepth` is used for folders the person picked; the home folder itself is read one level deep.
        var queue: [(url: URL, depth: Int)] = [(home, maxDepth)] + extraRoots.map { ($0.standardizedFileURL, 0) }
        while !queue.isEmpty, visits < maxVisits {
            let (directory, depth) = queue.removeFirst()
            visits += 1
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsPackageDescendants]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if let agent = directories[name] {
                    let parent = entry.deletingLastPathComponent().standardizedFileURL.path
                    workspaces.append(read(root: entry, agent: agent, isProject: parent != home.path, home: home, fm: fm))
                } else if depth < maxDepth, !skipped.contains(name), !protected.contains(name), !name.hasPrefix(".") {
                    queue.append((entry, depth + 1))
                }
            }
        }
        // Some documented settings live outside an agent-named folder (Cursor and Windsurf under Library/Application
        // Support). Read only those explicit files, then merge them into the matching user workspace without walking
        // Library or any privacy-protected folder.
        for gateway in AgentGatewayConfigReader.load(home: home, fm: fm) {
            if let index = workspaces.firstIndex(where: { $0.agent == gateway.agent && !$0.isProject }) {
                if !workspaces[index].gateways.contains(gateway) { workspaces[index].gateways.append(gateway) }
            } else {
                workspaces.append(AgentWorkspace(agent: gateway.agent, root: gateway.source,
                                                 isProject: false, gateways: [gateway]))
            }
        }
        // Project files that sit next to a workspace rather than inside one.
        return workspaces.filter { !$0.capabilities.isEmpty || !$0.mcpServers.isEmpty || !$0.gateways.isEmpty }
            .sorted { ($0.agent, $0.root) < ($1.agent, $1.root) }
    }

    /// Reads one configuration directory.
    static func read(root: URL, agent: String, isProject: Bool, home: URL, fm: FileManager = .default) -> AgentWorkspace {
        var workspace = AgentWorkspace(agent: agent, root: display(root, home: home), isProject: isProject)
        func add(_ kind: AgentCapability.Kind, _ name: String, _ detail: String?, _ source: URL, sensitive: Bool = false) {
            workspace.capabilities.append(AgentCapability(kind: kind, name: name, detail: detail?.nilIfEmpty,
                                                          source: display(source, home: home), isProject: isProject,
                                                          isSensitive: sensitive))
        }

        // Skills: a folder per skill with SKILL.md carrying name and description.
        for skills in ["skills", "skills-cursor"] {
            for entry in contents(root.appendingPathComponent(skills), fm: fm) {
                let file = entry.appendingPathComponent("SKILL.md")
                guard let front = frontMatter(of: file, fm: fm) else { continue }
                add(.skill, front["name"] ?? entry.lastPathComponent, front["description"], file)
            }
        }
        // Subagents and slash commands: one Markdown file each.
        for (directory, kind) in [("agents", AgentCapability.Kind.subagent), ("commands", .command), ("rules", .instructions)] {
            for file in contents(root.appendingPathComponent(directory), fm: fm) where file.pathExtension == "md" {
                let front = frontMatter(of: file, fm: fm) ?? [:]
                let detail = front["description"] ?? front["tools"].map { "tools: \($0)" }
                add(kind, front["name"] ?? file.deletingPathExtension().lastPathComponent, detail, file)
            }
        }
        // Settings: hooks, permissions and plugins.
        for file in contents(root, fm: fm) where file.lastPathComponent.hasPrefix("settings") && file.pathExtension == "json" {
            guard let settings = json(at: file, fm: fm) else { continue }
            for (event, command) in hooks(in: settings) {
                add(.hook, event, command, file, sensitive: true)
            }
            for (rule, decision) in permissions(in: settings) {
                add(.permission, rule, decision, file, sensitive: decision == "allow" && isSensitiveRule(rule))
            }
            for (plugin, enabled) in (settings["enabledPlugins"] as? [String: Bool] ?? [:]) where enabled {
                add(.plugin, plugin, nil, file)
            }
        }
        // Project instructions.
        for name in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
            let file = root.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { add(.instructions, name, nil, file) }
        }
        workspace.mcpServers = mcpServers(in: root, client: agent, fm: fm)
        workspace.gateways = gatewaySettings(in: root, agent: agent, home: home, fm: fm)
        return workspace
    }

    /// MCP servers configured beside this workspace: `mcp.json` or `settings.json` inside it, Codex's `config.toml`,
    /// and a project's `.mcp.json` next to it.
    static func gatewaySettings(in root: URL, agent: String, home: URL,
                                fm: FileManager) -> [AgentGatewayConfig] {
        let keys: [AgentGatewayConfigReader.JSONKey]
        switch agent {
        case "claude":
            keys = [
                .nested(["env", "ANTHROPIC_BASE_URL"]),
                .nested(["env", "HTTP_PROXY"]),
                .nested(["env", "HTTPS_PROXY"]),
            ]
        case "gemini":
            keys = [
                .nested(["general", "proxy"]),
                .nested(["env", "GOOGLE_GEMINI_BASE_URL"]),
                .nested(["env", "GOOGLE_VERTEX_BASE_URL"]),
                .nested(["env", "HTTP_PROXY"]),
                .nested(["env", "HTTPS_PROXY"]),
            ]
        case "zed": keys = [.literal("proxy")]
        default: return []
        }
        var effective: [String: AgentGatewayConfig] = [:]
        for name in ["settings.json", "settings.local.json"] {
            let file = root.appendingPathComponent(name)
            guard let data = fm.contents(atPath: file.path) else { continue }
            for gateway in AgentGatewayConfigReader.parseJSON(
                data, agent: agent, source: display(file, home: home), keys: keys
            ) {
                effective[gateway.sourceKey] = gateway
            }
        }
        return effective.values.sorted { $0.sourceKey < $1.sourceKey }
    }

    static func mcpServers(in root: URL, client: String, fm: FileManager) -> [MCPServerConfig] {
        var servers: [MCPServerConfig] = []
        for name in ["mcp.json", "settings.json", "mcp_servers.json"] {
            guard let data = fm.contents(atPath: root.appendingPathComponent(name).path) else { continue }
            servers += MCPConfigReader.parseJSON(data, client: client, keys: ["mcpServers", "servers", "mcp_servers"])
        }
        if let data = fm.contents(atPath: root.appendingPathComponent("config.toml").path) {
            servers += MCPConfigReader.parseCodexTOML(String(decoding: data, as: UTF8.self))
        }
        if let data = fm.contents(atPath: root.deletingLastPathComponent().appendingPathComponent(".mcp.json").path) {
            servers += MCPConfigReader.parseJSON(data, client: client, keys: ["mcpServers", "servers"])
        }
        var seen = Set<String>()
        return servers.filter { seen.insert($0.name).inserted }
    }

    // MARK: Parsing

    /// `hooks: { PreToolUse: [ { matcher, hooks: [ { type, command } ] } ] }` → (event · matcher, command).
    static func hooks(in settings: [String: Any]) -> [(String, String)] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        for (event, value) in hooks.sorted(by: { $0.key < $1.key }) {
            for matcher in value as? [[String: Any]] ?? [] {
                let label = (matcher["matcher"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                for hook in matcher["hooks"] as? [[String: Any]] ?? [] {
                    guard let command = hook["command"] as? String else { continue }
                    out.append((event + label, command))
                }
            }
        }
        return out
    }

    /// `permissions: { allow: [...], deny: [...], ask: [...] }` → (rule, decision).
    static func permissions(in settings: [String: Any]) -> [(String, String)] {
        guard let permissions = settings["permissions"] as? [String: Any] else { return [] }
        return ["deny", "ask", "allow"].flatMap { decision in
            (permissions[decision] as? [String] ?? []).map { ($0, decision) }
        }
    }

    /// Rules that let an agent run commands or reach the network without asking.
    static func isSensitiveRule(_ rule: String) -> Bool {
        let lower = rule.lowercased()
        if lower.hasPrefix("bash(") { return !lower.contains("git status") && !lower.contains("ls") }
        return ["websearch", "webfetch", "mcp__", "write(", "edit("].contains { lower.hasPrefix($0) }
    }

    /// The `name:` and `description:` lines of a Markdown file's YAML front matter.
    static func frontMatter(of file: URL, fm: FileManager = .default) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard head.hasPrefix("---") else { return nil }
        var fields: [String: String] = [:]
        for line in head.components(separatedBy: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func contents(_ directory: URL, fm: FileManager) -> [URL] {
        ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func json(at file: URL, fm: FileManager) -> [String: Any]? {
        guard let data = fm.contents(atPath: file.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `~/.claude/skills/x/SKILL.md`, so paths shown in the UI don't spell out the home folder.
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}

struct WorkspaceBookmarkRestoration {
    /// Keep every original bookmark until a resolved URL has successfully renewed it. An OS update can make a
    /// bookmark temporarily unresolvable; dropping its bytes here would turn that transient failure into permanent
    /// loss of a folder the person explicitly selected.
    static func restore(
        _ bookmarks: [Data],
        excluding removedPaths: Set<String> = [],
        resolve: (Data) -> (url: URL, stale: Bool)?,
        startAccessing: (URL) -> Bool,
        renew: (URL) -> Data?
    ) -> (roots: [URL], scopedRoots: [URL], bookmarks: [Data], deferred: [Data]) {
        var roots: [URL] = []
        var scopedRoots: [URL] = []
        var stored: [Data] = []
        var deferred: [Data] = []
        var seen = Set<String>()

        for bookmark in bookmarks {
            guard let resolved = resolve(bookmark) else {
                stored.append(bookmark)
                deferred.append(bookmark)
                continue
            }
            let url = resolved.url.standardizedFileURL
            guard !removedPaths.contains(url.path) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            guard startAccessing(url) else {
                stored.append(bookmark)
                deferred.append(bookmark)
                continue
            }
            roots.append(url)
            scopedRoots.append(url)
            stored.append(resolved.stale ? renew(url) ?? bookmark : bookmark)
        }
        return (roots, scopedRoots, stored, deferred)
    }
}

/// Keeps what the last scan found, so Flowlight doesn't walk the disk again on every launch.
///
/// By default it looks only at the agent folders in the home folder itself (`~/.claude`, `~/.codex`, …), which macOS
/// doesn't gate behind a privacy prompt. Project folders are scanned only when the person adds them, and the result
/// is remembered until they ask for a rescan.
@MainActor
final class AgentWorkspaceStore: ObservableObject {
    static let shared = AgentWorkspaceStore()

    enum Keys {
        static let workspaces = "agents.workspaces"
        static let scannedAt = "agents.scannedAt"
        static let roots = "agents.roots"
        static let rootBookmarks = "agents.rootBookmarks"
        static let removedRootPaths = "agents.removedRootPaths"
        static let scanSchema = "agents.scanSchema"
    }

    private static let currentScanSchema = 2

    @Published private(set) var workspaces: [AgentWorkspace] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    /// Extra folders the person picked, usually where their projects live.
    @Published private(set) var roots: [URL] = []

    /// After this long, the view offers a rescan in case agents or projects were added.
    static let staleAfter: TimeInterval = 14 * 86400

    private let defaults: UserDefaults
    #if APP_STORE
    private var securityScopedRoots: [URL] = []
    private var deferredBookmarks: [Data] = []
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if APP_STORE
        let removedPaths = Set(defaults.stringArray(forKey: Keys.removedRootPaths) ?? [])
        let restored = Self.restoreBookmarks(defaults.data(forKey: Keys.rootBookmarks), excluding: removedPaths)
        roots = restored.roots
        securityScopedRoots = restored.scopedRoots
        deferredBookmarks = restored.deferred
        if let data = try? PropertyListEncoder().encode(restored.bookmarks) {
            defaults.set(data, forKey: Keys.rootBookmarks)
        }
        #else
        roots = (defaults.array(forKey: Keys.roots) as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        #endif
        scannedAt = defaults.object(forKey: Keys.scannedAt) as? Date
        if let data = defaults.data(forKey: Keys.workspaces),
           let stored = try? JSONDecoder().decode([AgentWorkspace].self, from: data) {
            workspaces = stored
        }
    }

    var isStale: Bool {
        guard let scannedAt else { return true }
        return defaults.integer(forKey: Keys.scanSchema) < Self.currentScanSchema
            || Date().timeIntervalSince(scannedAt) > Self.staleAfter
    }

    var hasScanned: Bool {
        scannedAt != nil && defaults.integer(forKey: Keys.scanSchema) >= Self.currentScanSchema
    }

    /// Scans in the background. Without `force` it only runs if nothing has been scanned yet, so opening AI Agents
    /// never kicks off disk work on its own.
    func refresh(force: Bool = false) {
        guard !scanning, !DemoData.isEnabled else { return }
        guard force || !hasScanned else { return }
        scanning = true
        let extraRoots = roots
        Task.detached(priority: .utility) {
            #if APP_STORE
            let found = AgentWorkspaceScanner.scan(home: FileManager.default.temporaryDirectory, extraRoots: extraRoots)
            #else
            let found = AgentWorkspaceScanner.scan(extraRoots: extraRoots)
            #endif
            await MainActor.run { self.store(found) }
        }
    }

    func addRoot(_ url: URL) {
        let root = url.standardizedFileURL
        guard !roots.contains(root) else { return }
        #if APP_STORE
        guard let bookmark = try? root.bookmarkData(options: .withSecurityScope) else { return }
        guard root.startAccessingSecurityScopedResource() else { return }
        var removedPaths = Set(defaults.stringArray(forKey: Keys.removedRootPaths) ?? [])
        removedPaths.remove(root.path)
        defaults.set(removedPaths.sorted(), forKey: Keys.removedRootPaths)
        securityScopedRoots.append(root)
        roots.append(root)
        saveBookmarks(adding: bookmark)
        #else
        roots.append(root)
        defaults.set(roots.map(\.path), forKey: Keys.roots)
        #endif
        refresh(force: true)
    }

    func removeRoot(_ url: URL) {
        #if APP_STORE
        let root = url.standardizedFileURL
        var removedPaths = Set(defaults.stringArray(forKey: Keys.removedRootPaths) ?? [])
        removedPaths.insert(root.path)
        defaults.set(removedPaths.sorted(), forKey: Keys.removedRootPaths)
        securityScopedRoots.filter { $0 == root }.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedRoots.removeAll { $0 == root }
        roots.removeAll { $0 == root }
        saveBookmarks()
        #else
        roots.removeAll { $0 == url }
        defaults.set(roots.map(\.path), forKey: Keys.roots)
        #endif
        refresh(force: true)
    }

    /// Forgets everything found on disk, for someone who would rather Flowlight didn't look at all.
    func forget() {
        workspaces = []
        scannedAt = nil
        defaults.removeObject(forKey: Keys.workspaces)
        defaults.removeObject(forKey: Keys.scannedAt)
        defaults.removeObject(forKey: Keys.scanSchema)
    }

    private func store(_ found: [AgentWorkspace]) {
        workspaces = found
        scannedAt = Date()
        scanning = false
        defaults.set(try? JSONEncoder().encode(found), forKey: Keys.workspaces)
        defaults.set(scannedAt, forKey: Keys.scannedAt)
        defaults.set(Self.currentScanSchema, forKey: Keys.scanSchema)
    }

    #if APP_STORE
    private static func restoreBookmarks(_ data: Data?, excluding removedPaths: Set<String> = [])
        -> (roots: [URL], scopedRoots: [URL], bookmarks: [Data], deferred: [Data]) {
        guard let data,
              let bookmarks = try? PropertyListDecoder().decode([Data].self, from: data) else {
            return ([], [], [], [])
        }
        return WorkspaceBookmarkRestoration.restore(
            bookmarks,
            excluding: removedPaths,
            resolve: { bookmark in
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { return nil }
                return (url, stale)
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            renew: { try? $0.bookmarkData(options: .withSecurityScope) }
        )
    }

    private func saveBookmarks(adding bookmark: Data? = nil) {
        let persistedRoots = bookmark == nil ? roots : Array(roots.dropLast())
        var bookmarks = persistedRoots.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope)
        }
        if let bookmark { bookmarks.append(bookmark) }
        bookmarks.append(contentsOf: deferredBookmarks)
        defaults.set(try? PropertyListEncoder().encode(bookmarks), forKey: Keys.rootBookmarks)
        defaults.removeObject(forKey: Keys.roots)
    }
    #endif

    /// Workspaces belonging to an agent, its own first, then the projects it's configured in.
    func workspaces(bundleID: String, name: String) -> [AgentWorkspace] {
        let keys = Self.keys(bundleID: bundleID, name: name)
        guard !keys.isEmpty else { return [] }
        return workspaces.filter { keys.contains($0.agent) }
            .sorted { ($0.isProject ? 1 : 0, $0.root) < ($1.isProject ? 1 : 0, $1.root) }
    }

    /// Directory names that belong to an agent: `.claude` for Claude Code, `.cursor` for Cursor, and so on.
    /// `.agents` holds skills any agent can load, so it counts for all of them.
    static func keys(bundleID: String, name: String) -> Set<String> {
        let known = AgentCatalog.knownAgent(bundleID: bundleID, appName: name)
        var keys = Set((known?.processNames ?? []).map { $0.lowercased() })
        keys.insert(bundleID.lowercased())
        keys.insert(name.lowercased())
        let directories = Set(AgentWorkspaceScanner.directories.values)
        var matched = keys.intersection(directories)
        if !matched.isEmpty { matched.insert("agents") }
        return matched
    }
}
