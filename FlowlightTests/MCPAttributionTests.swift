import XCTest
@testable import Flowlight

final class MCPAttributionTests: XCTestCase {
    let servers = [
        MCPServerConfig(name: "github", client: "Claude Code", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], url: nil),
        MCPServerConfig(name: "fetch", client: "Cursor", command: "uvx", args: ["mcp-server-fetch"], url: nil),
        MCPServerConfig(name: "linear", client: "Claude Code", command: nil, args: [], url: URL(string: "https://mcp.linear.app/sse")),
    ]

    func testParsesConfigFormats() {
        let claude = #"{"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"]}},"projects":{"/repo":{"mcpServers":{"db":{"command":"/usr/local/bin/pg-mcp"}}}}}"#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID())")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try? claude.write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let codex = """
        model = "gpt-5"
        [mcp_servers.fetch]
        command = "uvx"
        args = ["mcp-server-fetch", "--ignore-robots"]
        [mcp_servers.fetch.env]
        TOKEN = "x"
        [mcp_servers.docs]
        url = "https://docs.example.com/mcp"
        """
        try? codex.write(to: dir.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let loaded = MCPConfigReader.load(home: dir)
        XCTAssertEqual(Set(loaded.map { "\($0.client):\($0.name)" }), ["Claude Code:github", "Claude Code:db", "Codex:fetch", "Codex:docs"])
        XCTAssertEqual(loaded.first { $0.name == "fetch" }?.args, ["mcp-server-fetch", "--ignore-robots"])
        XCTAssertEqual(loaded.first { $0.name == "docs" }?.url?.host, "docs.example.com")

        let zed = #"{"context_servers":{"pg":{"command":{"path":"/opt/pg-mcp","args":["--ro"]}}}}"#
        XCTAssertEqual(MCPConfigReader.parseJSON(Data(zed.utf8), client: "Zed", keys: ["context_servers"]).first?.command, "/opt/pg-mcp")
        let vscode = "{\n  // comment\n  \"servers\": {\"x\": {\"type\": \"http\", \"url\": \"https://x.example/mcp\"}}\n}"
        XCTAssertEqual(MCPConfigReader.parseJSON(Data(vscode.utf8), client: "VS Code", keys: ["servers"]).first?.url?.host, "x.example")
    }

    func testSignatureAndMatching() {
        XCTAssertEqual(servers[0].signature, "@modelcontextprotocol/server-github")
        XCTAssertEqual(servers[1].signature, "mcp-server-fetch")
        XCTAssertNil(servers[2].signature)
        let node = ["node", "/Users/x/.npm/_npx/abc/node_modules/@modelcontextprotocol/server-github/dist/index.js"]
        XCTAssertEqual(MCPMatcher.match(argv: node, servers: servers)?.name, "github")
        XCTAssertNil(MCPMatcher.match(argv: ["curl", "https://example.com"], servers: servers))
        XCTAssertEqual(MCPMatcher.heuristicName(argv: ["node", "/tmp/node_modules/@modelcontextprotocol/server-slack/dist/index.js"]), "server-slack")
        XCTAssertEqual(MCPMatcher.heuristicName(argv: ["node", "/tmp/node_modules/playwright-mcp/cli.js"]), "playwright-mcp")
        XCTAssertEqual(MCPMatcher.heuristicName(argv: ["python3", "-m", "mcp_server_git"]), "mcp_server_git")
        XCTAssertEqual(MCPMatcher.heuristicName(argv: ["/opt/bin/playwright-mcp"]), "playwright-mcp")
        XCTAssertNil(MCPMatcher.heuristicName(argv: ["git", "push"]))
    }

    func testLineageAttributesToolsAndMCPServersToTheirAgent() {
        let table: [Int32: ProcessSnapshot] = [
            100: ProcessSnapshot(pid: 100, ppid: 50, bundleID: "claude", name: "claude", argv: ["claude"]),
            50: ProcessSnapshot(pid: 50, ppid: 1, bundleID: "com.apple.Terminal", name: "Terminal", argv: ["Terminal"]),
            200: ProcessSnapshot(pid: 200, ppid: 150, bundleID: "curl", name: "curl", argv: ["curl", "-X", "POST", "https://paste.example"]),
            150: ProcessSnapshot(pid: 150, ppid: 100, bundleID: "zsh", name: "zsh", argv: ["/bin/zsh", "-c", "curl …"]),
            300: ProcessSnapshot(pid: 300, ppid: 250, bundleID: "node", name: "node",
                                 argv: ["node", "/x/node_modules/@modelcontextprotocol/server-github/dist/index.js"]),
            250: ProcessSnapshot(pid: 250, ppid: 100, bundleID: "npm", name: "npm", argv: ["npm", "exec", "@modelcontextprotocol/server-github"]),
            400: ProcessSnapshot(pid: 400, ppid: 50, bundleID: "curl", name: "curl", argv: ["curl", "example.com"]),
            500: ProcessSnapshot(pid: 500, ppid: 100, bundleID: "codex", name: "codex", argv: ["codex"]),
        ]
        func name(_ bundle: String, _ app: String) -> String? { AgentCatalog.knownAgent(bundleID: bundle, appName: app)?.name }
        func context(_ pid: Int32) -> AgentContext? { AgentLineage.context(for: pid, lookup: { table[$0] }, agentName: name, servers: servers) }

        XCTAssertEqual(context(200), AgentContext(agentBundleID: "claude", agentName: "Claude Code", mcpServer: nil), "a shell tool's curl belongs to Claude Code")
        XCTAssertEqual(context(300), AgentContext(agentBundleID: "claude", agentName: "Claude Code", mcpServer: "github"))
        XCTAssertNil(context(400), "your own terminal's curl isn't attributed to anyone")
        XCTAssertNil(context(100), "an agent works for itself")
        XCTAssertNil(context(500), "an agent started by another agent keeps its own identity")
        XCTAssertEqual(AgentLineage.remoteServer(forHost: "mcp.linear.app", servers: servers)?.name, "linear")
    }
}
