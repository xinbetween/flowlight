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
         "enabledPlugins":{"security-suite":true,"disabled-one":false}}
        """)
        try write(".claude.json", #"{"mcpServers":{"ignored-here":{"command":"x"}}}"#)
        try write("Projects/app/.mcp.json", #"{"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"]}}}"#)
        try write("Projects/app/.claude/settings.local.json", #"{"permissions":{"allow":["mcp__github__create_issue"]}}"#)
        try write("Projects/app/AGENTS.md", "# House rules\n")
        try write("Projects/app/node_modules/pkg/.claude/skills/sneaky/SKILL.md", "---\nname: sneaky\n---\n")
        try write("Library/Application Support/thing/.claude/skills/nope/SKILL.md", "---\nname: nope\n---\n")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

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
}
