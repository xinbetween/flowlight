import XCTest
@testable import Flowlight

final class AgentWorkspaceScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        func write(_ path: String, _ contents: String) throws {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try write(".claude/skills/pdf/SKILL.md", "---\nname: pdf-tools\ndescription: Fill and sign PDFs\n---\n# PDF\n")
        try write(".claude/skills/broken/README.md", "no front matter")
        try write(".claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Reviews diffs\ntools: Read, Grep\n---\n")
        try write(".claude/commands/deploy.md", "Deploy the app\n")
        try write(".claude/settings.json", """
        {"permissions":{"allow":["Bash(git status)","WebFetch","Bash(curl:*)"],"deny":["Read(./.env)"],"ask":["Write"]},
         "hooks":{"Notification":[{"matcher":"","hooks":[{"type":"command","command":"curl -s -d hi https://ntfy.sh/mine"}]}],
                  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/.claude/hooks/audit.sh"}]}]},
         "enabledPlugins":{"security-suite":true,"disabled-one":false},
         "env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:3425/anthropic"}}
        """)
        try write(".claude.json", #"{"mcpServers":{"ignored-here":{"command":"x"}}}"#)
        try write("Projects/app/.mcp.json", #"{"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"]}}}"#)
        try write("Projects/app/.claude/settings.local.json", #"{"permissions":{"allow":["mcp__github__create_issue"]}}"#)
        try write("Projects/app/AGENTS.md", "# House rules\n")
        try write("Projects/app/node_modules/pkg/.claude/skills/sneaky/SKILL.md", "---\nname: sneaky\n---\n")
        try write("Library/Application Support/thing/.claude/skills/nope/SKILL.md", "---\nname: nope\n---\n")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testReadsDocumentedGatewaySettingsWithoutKeepingSecretsOrPaths() throws {
        let claude = try XCTUnwrap(AgentGatewayConfigReader.parseJSON(
            Data(#"{"env":{"ANTHROPIC_BASE_URL":"http://user:secret@127.0.0.1:3425/anthropic?token=hidden"}}"#.utf8),
            agent: "claude",
            source: "~/.claude/settings.json",
            keys: [.nested(["env", "ANTHROPIC_BASE_URL"])]
        ).first)
        XCTAssertEqual(claude.endpoint.scheme, "http")
        XCTAssertEqual(claude.endpoint.host, "127.0.0.1")
        XCTAssertEqual(claude.endpoint.port, 3425)
        XCTAssertEqual(claude.sourceKey, "env.ANTHROPIC_BASE_URL")
        XCTAssertFalse(claude.endpoint.description.contains("secret"))
        XCTAssertFalse(claude.endpoint.description.contains("anthropic"))
        XCTAssertFalse(claude.endpoint.description.contains("token"))

        let editor = try XCTUnwrap(AgentGatewayConfigReader.parseJSON(
            Data(#"{"http.proxy":"http://proxy.example:8080"}"#.utf8),
            agent: "cursor",
            source: "~/Library/Application Support/Cursor/User/settings.json",
            keys: [.literal("http.proxy")]
        ).first)
        XCTAssertEqual(editor.endpoint.host, "proxy.example")
        XCTAssertEqual(editor.endpoint.port, 8080)
    }

    func testReadsJSONWithCommentsAndFormatsIPv6Endpoint() throws {
        let cursor = try XCTUnwrap(AgentGatewayConfigReader.parseJSON(
            Data("""
            {
              // VS Code settings files permit comments and trailing commas.
              "http.proxy": "http://[::1]:3425/private?token=hidden",
            }
            """.utf8),
            agent: "cursor",
            source: "~/Library/Application Support/Cursor/User/settings.json",
            keys: [.literal("http.proxy")]
        ).first)

        XCTAssertEqual(cursor.endpoint.description, "http://[::1]:3425")
    }

    func testReadsOnlySelectedCodexProviderAndGeminiGateway() throws {
        let gateways = AgentGatewayConfigReader.parseCodexTOML(
            """
            model_provider = "openai"
            [model_providers.local]
            base_url = "http://127.0.0.1:3425/v1"
            [model_providers.openai]
            base_url = "https://api.openai.com/v1"
            """,
            source: "~/.codex/config.toml"
        )
        let codex = try XCTUnwrap(gateways.first)
        XCTAssertEqual(gateways.count, 1)
        XCTAssertEqual(codex.agent, "codex")
        XCTAssertEqual(codex.sourceKey, "model_providers.openai.base_url")
        XCTAssertEqual(codex.endpoint.host, "api.openai.com")

        let gemini = try XCTUnwrap(AgentGatewayConfigReader.parseJSON(
            Data(#"{"general":{"proxy":"http://127.0.0.1:3425"}}"#.utf8),
            agent: "gemini",
            source: "~/.gemini/settings.json",
            keys: [.nested(["general", "proxy"])]
        ).first)
        XCTAssertEqual(gemini.sourceKey, "general.proxy")
        XCTAssertEqual(gemini.endpoint.host, "127.0.0.1")
    }

    func testWorkspaceScanRetainsConfiguredGatewayAsRelationshipEvidence() throws {
        let workspaces = AgentWorkspaceScanner.scan(home: home)
        let claude = try XCTUnwrap(workspaces.first { $0.agent == "claude" })
        let gateway = try XCTUnwrap(claude.gateways.first)
        XCTAssertEqual(gateway.agent, "claude")
        XCTAssertEqual(gateway.endpoint.port, 3425)
        XCTAssertEqual(gateway.source, "~/.claude/settings.json")
    }

    func testDecodesWorkspaceStoredBeforeGatewayDiscovery() throws {
        let data = Data(#"{"agent":"claude","root":"~/.claude","isProject":false,"capabilities":[],"mcpServers":[]}"#.utf8)
        let workspace = try JSONDecoder().decode(AgentWorkspace.self, from: data)

        XCTAssertEqual(workspace.agent, "claude")
        XCTAssertTrue(workspace.gateways.isEmpty)
    }

    func testScanReadsOnlyDocumentedGlobalGatewayFilesOutsideAgentFolders() throws {
        let file = home.appendingPathComponent("Library/Application Support/Cursor/User/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"http.proxy":"http://127.0.0.1:3425/private?token=hidden"}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let cursor = try XCTUnwrap(AgentWorkspaceScanner.scan(home: home).first { $0.agent == "cursor" })
        let gateway = try XCTUnwrap(cursor.gateways.first)
        XCTAssertEqual(gateway.endpoint.description, "http://127.0.0.1:3425")
        XCTAssertEqual(gateway.source, "~/Library/Application Support/Cursor/User/settings.json")
        XCTAssertFalse(gateway.endpoint.description.contains("token"))
    }

    func testScansHomeAgentFoldersOnly() {
        let workspaces = AgentWorkspaceScanner.scan(home: home)
        XCTAssertEqual(workspaces.map(\.root), ["~/.claude"], "project folders are not scanned until the person adds one")
        let user = workspaces[0]
        XCTAssertFalse(user.isProject)
        XCTAssertEqual(user.of(.skill).map(\.name), ["pdf-tools"], "a folder without SKILL.md front matter is not a skill")
        XCTAssertEqual(user.of(.skill).first?.detail, "Fill and sign PDFs")
        XCTAssertEqual(user.of(.subagent).map(\.name), ["reviewer"])
        XCTAssertEqual(user.of(.subagent).first?.detail, "Reviews diffs")
        XCTAssertEqual(user.of(.command).map(\.name), ["deploy"])
        XCTAssertEqual(user.of(.plugin).map(\.name), ["security-suite"], "only enabled plugins")
        XCTAssertEqual(user.of(.skill).first?.source, "~/.claude/skills/pdf/SKILL.md")
    }

    func testAddedProjectFolderIsScanned() {
        let project = home.appendingPathComponent("Projects/app")
        let workspaces = AgentWorkspaceScanner.scan(home: home, extraRoots: [project])
        let found = try! XCTUnwrap(workspaces.first { $0.isProject })
        XCTAssertEqual(found.mcpServers.map(\.name), ["github"], "a project's .mcp.json sits next to .claude")
        XCTAssertEqual(found.of(.instructions).map(\.name), ["AGENTS.md"])
        let names = workspaces.flatMap(\.capabilities).map(\.name)
        XCTAssertFalse(names.contains("sneaky"), "node_modules is skipped")
    }

    func testProjectLocalGatewayOverridesSharedSettings() throws {
        let root = home.appendingPathComponent("Projects/app/.claude")
        let shared = root.appendingPathComponent("settings.json")
        let local = root.appendingPathComponent("settings.local.json")
        try #"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:3000"}}"#
            .write(to: shared, atomically: true, encoding: .utf8)
        try #"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:3425"}}"#
            .write(to: local, atomically: true, encoding: .utf8)

        let gateways = AgentWorkspaceScanner.gatewaySettings(
            in: root, agent: "claude", home: home, fm: .default
        )

        XCTAssertEqual(gateways.count, 1)
        XCTAssertEqual(gateways.first?.endpoint.port, 3425)
        XCTAssertEqual(gateways.first?.source, "~/Projects/app/.claude/settings.local.json")
    }

    func testNeverWalksIntoProtectedFolders() throws {
        // macOS gates Desktop, Documents and Downloads behind a privacy prompt; Flowlight must not trip it.
        let hidden = home.appendingPathComponent("Documents/work/.claude/skills/secret")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "---\nname: secret\n---\n".write(to: hidden.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let names = AgentWorkspaceScanner.scan(home: home).flatMap(\.capabilities).map(\.name)
        XCTAssertFalse(names.contains("secret"))
        // Unless the person picks that folder themselves.
        let picked = AgentWorkspaceScanner.scan(home: home, extraRoots: [home.appendingPathComponent("Documents/work")])
        XCTAssertTrue(picked.flatMap(\.capabilities).map(\.name).contains("secret"))
    }

    func testHooksAndSensitivePermissions() {
        let user = AgentWorkspaceScanner.scan(home: home).first { !$0.isProject }!
        let hooks = user.of(.hook)
        XCTAssertEqual(hooks.map(\.name), ["Notification", "PreToolUse · Bash"])
        XCTAssertEqual(hooks.first?.detail, "curl -s -d hi https://ntfy.sh/mine")
        XCTAssertTrue(hooks.allSatisfy(\.isSensitive), "hooks run commands, so they always stand out")

        let allowed = user.of(.permission).filter { $0.detail == "allow" }
        XCTAssertEqual(allowed.filter(\.isSensitive).map(\.name).sorted(), ["Bash(curl:*)", "WebFetch"])
        XCTAssertFalse(allowed.first { $0.name == "Bash(git status)" }!.isSensitive)
        XCTAssertEqual(user.of(.permission).first { $0.name == "Read(./.env)" }?.detail, "deny")
    }

    func testStaleResolvedBookmarkRenewsOnlyAfterSecurityScopeStarts() {
        let old = Data("old".utf8)
        let fresh = Data("fresh".utf8)
        let root = home.appendingPathComponent("Documents/work")
        var calls: [String] = []

        let restored = WorkspaceBookmarkRestoration.restore(
            [old],
            resolve: { _ in (root, true) },
            startAccessing: { _ in calls.append("access"); return true },
            renew: { _ in calls.append("renew"); return fresh }
        )

        XCTAssertEqual(restored.roots, [root.standardizedFileURL])
        XCTAssertEqual(restored.scopedRoots, restored.roots)
        XCTAssertEqual(restored.bookmarks, [fresh])
        XCTAssertTrue(restored.deferred.isEmpty)
        XCTAssertEqual(calls, ["access", "renew"])
    }

    func testRemovedWorkspaceBookmarkCannotReappearAfterItResolvesLater() {
        let old = Data("old".utf8)
        let root = home.appendingPathComponent("Documents/work").standardizedFileURL

        let restored = WorkspaceBookmarkRestoration.restore(
            [old], excluding: [root.path],
            resolve: { _ in (root, false) },
            startAccessing: { _ in XCTFail("a removed root must not regain security scope"); return true },
            renew: { _ in XCTFail("a removed root must not be renewed"); return nil }
        )

        XCTAssertTrue(restored.roots.isEmpty)
        XCTAssertTrue(restored.bookmarks.isEmpty)
        XCTAssertTrue(restored.deferred.isEmpty)
    }

    func testUnresolvedOrInaccessibleBookmarksRemainRetryableButNotVisible() {
        let unresolved = Data("unresolved".utf8)
        let inaccessible = Data("inaccessible".utf8)
        let root = home.appendingPathComponent("Documents/work")

        let restored = WorkspaceBookmarkRestoration.restore(
            [unresolved, inaccessible],
            resolve: { bookmark in bookmark == unresolved ? nil : (root, true) },
            startAccessing: { _ in false },
            renew: { _ in XCTFail("an inaccessible URL must not be renewed"); return nil }
        )

        XCTAssertTrue(restored.roots.isEmpty)
        XCTAssertTrue(restored.scopedRoots.isEmpty)
        XCTAssertEqual(restored.bookmarks, [unresolved, inaccessible])
        XCTAssertEqual(restored.deferred, restored.bookmarks)
    }
}
