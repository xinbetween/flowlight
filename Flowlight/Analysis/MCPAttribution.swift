import Darwin
import Foundation

/// An MCP server as an agent's configuration declares it.
struct MCPServerConfig: Equatable, Sendable, Codable {
    var name: String
    var client: String          // "Claude Code", "Cursor", …
    var command: String?
    var args: [String]
    var url: URL?

    /// The part of the launch command that identifies this server ("@modelcontextprotocol/server-github", "mcp-server-fetch",
    /// "/path/server.py"). Launcher names and flags are skipped.
    var signature: String? {
        let launchers: Set<String> = ["npx", "node", "bunx", "bun", "deno", "uvx", "uv", "python", "python3", "pipx", "docker", "sh", "bash", "zsh", "env"]
        let verbs: Set<String> = ["run", "exec", "x", "--from", "mcp", "tool", "-m", "--"]
        for arg in args where !arg.hasPrefix("-") && !verbs.contains(arg) && !arg.contains("=") { return arg }
        if let command, !launchers.contains((command as NSString).lastPathComponent) { return command }
        return nil
    }
}

enum MCPConfigReader {
    enum Format { case json(keys: [String]), claudeCode, codexTOML }

    /// Where the common agents keep their MCP configuration.
    static func knownFiles(home: URL) -> [(client: String, url: URL, format: Format)] {
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            ("Claude Code", home.appendingPathComponent(".claude.json"), .claudeCode),
            ("Claude Code", home.appendingPathComponent(".claude/settings.json"), .json(keys: ["mcpServers"])),
            ("Claude", support.appendingPathComponent("Claude/claude_desktop_config.json"), .json(keys: ["mcpServers"])),
            ("Cursor", home.appendingPathComponent(".cursor/mcp.json"), .json(keys: ["mcpServers"])),
            ("Windsurf", home.appendingPathComponent(".codeium/windsurf/mcp_config.json"), .json(keys: ["mcpServers"])),
            ("Visual Studio Code", support.appendingPathComponent("Code/User/mcp.json"), .json(keys: ["servers", "mcpServers"])),
            ("Codex", home.appendingPathComponent(".codex/config.toml"), .codexTOML),
            ("Zed", home.appendingPathComponent(".config/zed/settings.json"), .json(keys: ["context_servers"])),
            ("Gemini CLI", home.appendingPathComponent(".gemini/settings.json"), .json(keys: ["mcpServers"])),
        ]
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [MCPServerConfig] {
        knownFiles(home: home).flatMap { file -> [MCPServerConfig] in
            guard let data = try? Data(contentsOf: file.url) else { return [] }
            switch file.format {
            case .json(let keys): return parseJSON(data, client: file.client, keys: keys)
            case .claudeCode:
                // Top-level servers plus every project's servers.
                var servers = parseJSON(data, client: file.client, keys: ["mcpServers"])
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let projects = root["projects"] as? [String: Any] {
                    for case let project as [String: Any] in projects.values {
                        if let block = project["mcpServers"] as? [String: Any] { servers += entries(block, client: file.client) }
                    }
                }
                return servers
            case .codexTOML: return parseCodexTOML(String(decoding: data, as: UTF8.self))
            }
        }
    }

    static func parseJSON(_ data: Data, client: String, keys: [String]) -> [MCPServerConfig] {
        guard let root = (try? JSONSerialization.jsonObject(with: stripJSONComments(data))) as? [String: Any] else { return [] }
        return keys.flatMap { key in (root[key] as? [String: Any]).map { entries($0, client: client) } ?? [] }
    }

    static func entries(_ block: [String: Any], client: String) -> [MCPServerConfig] {
        block.compactMap { name, value in
            guard let spec = value as? [String: Any] else { return nil }
            var command = spec["command"] as? String
            var args = spec["args"] as? [String] ?? []
            if let nested = spec["command"] as? [String: Any] { // Zed: {"command": {"path": …, "args": […]}}
                command = nested["path"] as? String
                args = nested["args"] as? [String] ?? args
            }
            let url = (spec["url"] as? String ?? spec["serverUrl"] as? String ?? spec["httpUrl"] as? String).flatMap(URL.init(string:))
            guard command != nil || url != nil else { return nil }
            return MCPServerConfig(name: name, client: client, command: command, args: args, url: url)
        }
        .sorted { $0.name < $1.name }
    }

    /// Codex: `[mcp_servers.name]` tables with `command`, `args` and `url` keys.
    static func parseCodexTOML(_ text: String) -> [MCPServerConfig] {
        var servers: [MCPServerConfig] = []
        var current: MCPServerConfig?
        func flush() { if let c = current, c.command != nil || c.url != nil { servers.append(c) }; current = nil }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if line.hasPrefix("[mcp_servers."), line.hasSuffix("]"), !line.contains(".env") {
                    let name = String(line.dropFirst("[mcp_servers.".count).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    current = MCPServerConfig(name: name, client: "Codex", command: nil, args: [], url: nil)
                }
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let strings = value.split(separator: "\"", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            switch key {
            case "command": current?.command = strings.first
            case "args": current?.args = strings
            case "url": current?.url = strings.first.flatMap(URL.init(string:))
            default: break
            }
        }
        flush()
        return servers
    }

    private static func stripJSONComments(_ data: Data) -> Data {
        // VS Code and Zed settings allow // comments; drop whole-line comments (good enough for config files).
        let text = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        return Data(text.utf8)
    }
}

enum MCPMatcher {
    /// The configured server whose signature appears in this command line.
    static func match(argv: [String], servers: [MCPServerConfig]) -> MCPServerConfig? {
        let line = argv.joined(separator: " ")
        return servers.first { server in
            guard let signature = server.signature, signature.count >= 3 else { return false }
            return line.contains(signature)
        }
    }

    /// Unconfigured but recognizably an MCP server: a path or argument naming an MCP package
    /// ("@modelcontextprotocol/server-slack", "mcp-server-git", "playwright-mcp"). Returns the package name.
    static func heuristicName(argv: [String]) -> String? {
        for arg in argv {
            if let range = arg.range(of: "@modelcontextprotocol/") {
                let name = arg[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
                if !name.isEmpty { return name }
            }
            for component in arg.split(separator: "/").map({ String($0).lowercased() }) {
                let name = component.replacingOccurrences(of: ".js", with: "").replacingOccurrences(of: ".py", with: "")
                if name.hasPrefix("mcp-server-") || name.hasPrefix("mcp_server") || name.hasSuffix("-mcp")
                    || name.hasSuffix("-mcp-server") || name.contains("-mcp-") || name.hasSuffix("_mcp") {
                    return name
                }
            }
        }
        return nil
    }
}

/// One process, as far as attribution needs it.
struct ProcessSnapshot: Sendable {
    var pid: Int32
    var ppid: Int32
    var bundleID: String
    var name: String
    var argv: [String]
}

/// Who a process works for: the agent it descends from, and the MCP server it is (if any).
struct AgentContext: Equatable, Sendable {
    var agentBundleID: String
    var agentName: String
    var mcpServer: String?
}

enum AgentLineage {
    /// Walks up from `pid` to the nearest ancestor that is an agent. The process itself being an agent means it
    /// works for itself (no context). `agentName` returns a display name for agents, nil otherwise.
    static func context(for pid: Int32, lookup: (Int32) -> ProcessSnapshot?, agentName: (String, String) -> String?,
                        servers: [MCPServerConfig], maxDepth: Int = 16) -> AgentContext? {
        guard let start = lookup(pid), agentName(start.bundleID, start.name) == nil else { return nil }
        var visited = [start]
        var current = start
        for _ in 0..<maxDepth {
            guard current.ppid > 1, let parent = lookup(current.ppid), parent.pid != current.pid else { return nil }
            if let name = agentName(parent.bundleID, parent.name) {
                let server = visited.lazy.compactMap { MCPMatcher.match(argv: $0.argv, servers: servers)?.name }.first
                    ?? visited.lazy.compactMap { MCPMatcher.heuristicName(argv: $0.argv) }.first
                return AgentContext(agentBundleID: parent.bundleID, agentName: name, mcpServer: server)
            }
            visited.append(parent)
            current = parent
        }
        return nil
    }

    /// Remote (HTTP) MCP servers, by hostname.
    static func remoteServer(forHost host: String, servers: [MCPServerConfig]) -> MCPServerConfig? {
        guard !host.isEmpty else { return nil }
        return servers.first { $0.url?.host?.lowercased() == host.lowercased() }
    }
}
