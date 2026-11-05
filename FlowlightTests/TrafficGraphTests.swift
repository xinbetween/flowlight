import CoreGraphics
import Foundation
import XCTest
@testable import Flowlight

private final class TrafficGraphPlacementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isReleased = false
    private var placements = 0

    func observePlacement() {
        condition.lock()
        placements += 1
        if placements == 1 {
            condition.broadcast()
            while !isReleased {
                condition.wait()
            }
        }
        condition.unlock()
    }

    func waitForFirstPlacement(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while placements == 0 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    var placementCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return placements
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class TrafficGraphTests: XCTestCase {
    func testUnrelatedHoveredEdgeDoesNotOverrideNodeSelection() {
        let selectedNode = TrafficGraphNodeID(rawValue: "agent:magpie")
        let unrelatedEdge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "launcher:vscode→launched→agent:vscode"),
            source: TrafficGraphNodeID(rawValue: "launcher:vscode"),
            target: TrafficGraphNodeID(rawValue: "agent:vscode"),
            counters: FlowCounters(),
            filter: .none,
            relationship: .launched
        )

        XCTAssertFalse(
            TrafficGraphSelection.emphasizes(
                unrelatedEdge,
                selectedNode: selectedNode,
                selectedEdge: nil,
                hoveredEdge: unrelatedEdge.id
            ),
            "hover must not make an unrelated launcher edge look selected"
        )
    }

    func testRelatedHoveredEdgeCanBeEmphasizedWithinNodeSelection() {
        let selectedNode = TrafficGraphNodeID(rawValue: "agent:magpie")
        let relatedEdge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "agent:magpie→observed→destination:example"),
            source: selectedNode,
            target: TrafficGraphNodeID(rawValue: "destination:example"),
            counters: FlowCounters(bytesOut: 1),
            filter: .none
        )

        XCTAssertTrue(
            TrafficGraphSelection.emphasizes(
                relatedEdge,
                selectedNode: selectedNode,
                selectedEdge: nil,
                hoveredEdge: relatedEdge.id
            )
        )
    }

    private func row(
        app: String,
        name: String? = nil,
        path: String = "",
        domain: String,
        ip: String,
        owner: String = "",
        bytesIn: Int64 = 0,
        bytesOut: Int64 = 0,
        flows: Int64 = 0,
        parent: String = "",
        parentName: String = "",
        mcp: String = "",
        launcher: (id: String, name: String, path: String)? = nil,
        upstreamLauncher: (id: String, name: String, path: String)? = nil,
        relay: (id: String, name: String, path: String)? = nil,
        protocol appProtocol: String = "https",
        channel: NetworkChannel = .ip
    ) -> BreakdownRow {
        BreakdownRow(
            bundleID: app,
            appName: name ?? app,
            appPath: path,
            domain: domain,
            remoteIP: ip,
            ports: "",
            protocols: appProtocol,
            counters: FlowCounters(bytesIn: bytesIn, bytesOut: bytesOut, flows: flows),
            owner: owner,
            parentAgent: parent,
            parentAgentName: parentName,
            mcpServer: mcp,
            launcherBundleID: launcher?.id ?? "",
            launcherName: launcher?.name ?? "",
            launcherPath: launcher?.path ?? "",
            upstreamLauncherBundleID: upstreamLauncher?.id ?? "",
            upstreamLauncherName: upstreamLauncher?.name ?? "",
            upstreamLauncherPath: upstreamLauncher?.path ?? "",
            routeProxyBundleID: relay?.id ?? "",
            routeProxyName: relay?.name ?? "",
            routeProxyPath: relay?.path ?? "",
            channel: channel
        )
    }

    func testAIBuilderIncludesProvedAgentsButNotProviderBrowsing() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.anthropic.com", ip: "160.79.104.10", bytesOut: 100),
            row(app: "python3", name: "Python", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 80),
            row(app: "com.google.Chrome", name: "Chrome", domain: "chatgpt.com", ip: "104.18.2.2", bytesOut: 70),
            row(app: "com.google.Chrome.helper", name: "Chrome Helper", domain: "api.openai.com", ip: "104.18.2.3", bytesOut: 65),
            row(app: "com.apple.Music", name: "Music", domain: "apple.com", ip: "17.1.1.1", bytesOut: 60),
        ], limits: .unbounded)

        let agents = snapshot.nodes.filter { $0.kind == .agent }
        XCTAssertEqual(Set(agents.compactMap(\.filter.bundleID)), ["claude", "python3"])
        XCTAssertFalse(snapshot.nodes.contains { $0.filter.bundleID == "com.google.Chrome" })
        XCTAssertEqual(snapshot.total.bytesOut, 180)
    }

    func testAIBuilderFoldsAttributedToolsIntoAgentAndKeepsLineageHonest() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.anthropic.com", ip: "160.79.104.10", bytesOut: 100),
            row(app: "curl", name: "curl", domain: "paste.example", ip: "203.0.113.8", bytesOut: 50,
                parent: "claude", parentName: "Claude Code"),
            row(app: "node", name: "node", domain: "api.github.com", ip: "203.0.113.9", bytesOut: 30,
                parent: "claude", parentName: "Claude Code", mcp: "github"),
        ], limits: .unbounded)

        let agent = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        XCTAssertEqual(agent.counters.bytesOut, 180)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .mcp }.count, 1)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .runs }.count, 2)
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .invoked },
                       "stored process lineage is not inspected invocation evidence")
        XCTAssertEqual(snapshot.total.bytesOut, 180, "folding child traffic must not double count it")
    }

    func testAIBuilderKeepsProofFromRowsOutsideVisibleScope() {
        let allRows = [
            row(app: "python3", name: "Python", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 10),
            row(app: "python3", name: "Python", domain: "bucket.example", ip: "203.0.113.5", bytesOut: 90)
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: allRows, visibleRows: [allRows[1]], limits: .unbounded)

        XCTAssertEqual(snapshot.nodes.first { $0.kind == .agent }?.filter.bundleID, "python3")
        XCTAssertEqual(snapshot.total.bytesOut, 90)
        XCTAssertEqual(snapshot.edges.first { $0.relationship == .observed }?.filter.domain, "bucket.example")
    }

    func testAIBuilderRetainsDirectRemoteMCPWithoutInventingLineage() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "mcp.example", ip: "203.0.113.12", bytesOut: 25,
                mcp: "remote-docs")
        ], limits: .unbounded)

        let mcp = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .mcp })
        XCTAssertEqual(mcp.title, "remote-docs MCP")
        XCTAssertEqual(mcp.filter.bundleID, "claude")
        XCTAssertNil(mcp.filter.agentParent,
                     "direct remote MCP evidence has no stored process parent to filter by")
        XCTAssertEqual(mcp.filter.mcpServer, "remote-docs")
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .runs },
                       "remote MCP attribution is not stored process-lineage evidence")
        XCTAssertEqual(snapshot.edges.first { $0.relationship == .observed }?.source, mcp.id)
    }

    func testAIToolIdentityDoesNotSplitWhenDisplayNamesChange() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "Node", domain: "one.example", ip: "203.0.113.20", bytesOut: 10,
                parent: "claude", parentName: "Claude Code"),
            row(app: "node", name: "node", domain: "two.example", ip: "203.0.113.21", bytesOut: 20,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .tool }.count, 1,
                       "mutable display metadata must not create separate tool identities")
        XCTAssertEqual(snapshot.nodes.first { $0.kind == .tool }?.title, "Node",
                       "stable lexical metadata must not change when counters change")
        XCTAssertEqual(snapshot.nodes.first { $0.kind == .tool }?.counters.bytesOut, 30)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .runs }.count, 1)

        let reversed = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "node", domain: "two.example", ip: "203.0.113.21", bytesOut: 20,
                parent: "claude", parentName: "Claude Code"),
            row(app: "node", name: "Node", domain: "one.example", ip: "203.0.113.20", bytesOut: 10,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)
        XCTAssertEqual(reversed.nodes.map(\.id), snapshot.nodes.map(\.id))
        XCTAssertEqual(reversed.nodes.map(\.title), snapshot.nodes.map(\.title))
        XCTAssertEqual(reversed.nodes.map(\.counters), snapshot.nodes.map(\.counters))
        XCTAssertEqual(reversed.edges.map(\.id), snapshot.edges.map(\.id))
        XCTAssertEqual(reversed.edges.map(\.counters), snapshot.edges.map(\.counters))
        XCTAssertEqual(reversed.total, snapshot.total)
        XCTAssertEqual(reversed.hidden, snapshot.hidden, "row order must not change graph accounting")

        let counterRefresh = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "Node", domain: "one.example", ip: "203.0.113.20", bytesOut: 100,
                parent: "claude", parentName: "Claude Code"),
            row(app: "node", name: "node", domain: "two.example", ip: "203.0.113.21", bytesOut: 1,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)
        XCTAssertEqual(
            counterRefresh.nodes.first { $0.kind == .tool }?.title,
            snapshot.nodes.first { $0.kind == .tool }?.title,
            "counter-only refreshes must not rename a stable tool identity"
        )
    }

    func testAIBuilderProjectsAllowlistRefusalAsAgentToolAndBlockedPath() {
        let rows = [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.8",
                bytesOut: 25)
        ]
        let blocked = [
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "uploads.example", port: 443, count: 2,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: rows, blockedAttempts: blocked, limits: .unbounded)
        let agent = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        let tool = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .tool })
        let runs = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .runs })
        let refusal = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(runs.source, agent.id)
        XCTAssertEqual(runs.target, tool.id)
        XCTAssertEqual(refusal.source, tool.id)
        XCTAssertEqual(snapshot.nodes.first { $0.id == refusal.target }?.title, "uploads.example")
        XCTAssertEqual(refusal.enforcement?.count, 2)
        XCTAssertEqual(runs.counters, FlowCounters())
        XCTAssertEqual(refusal.counters, FlowCounters())
        XCTAssertEqual(snapshot.total.bytesOut, 25)
        XCTAssertEqual(snapshot.visibleTotal.bytesOut, 25)
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .invoked })
    }

    func testAIBuilderProjectsRefusalOnlyAgentWithoutInventingTraffic() {
        let blocked = [
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "uploads.example", port: 443, count: 2,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: [], blockedAttempts: blocked, limits: .unbounded)
        let agent = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        let tool = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .tool })
        let runs = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .runs })
        let refusal = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(agent.title, "Claude Code")
        XCTAssertEqual(runs.source, agent.id)
        XCTAssertEqual(runs.target, tool.id)
        XCTAssertEqual(refusal.source, tool.id)
        XCTAssertEqual(agent.counters, FlowCounters())
        XCTAssertEqual(tool.counters, FlowCounters())
        XCTAssertEqual(refusal.counters, FlowCounters())
        XCTAssertEqual(snapshot.total, FlowCounters(), "refusal evidence must never invent observed traffic")
        XCTAssertEqual(snapshot.visibleTotal, FlowCounters())
    }

    func testAIBuilderDoesNotTreatGenericRuleOrPackRefusalAsAgentProof() {
        for source in ["ordinary-rule", "managed-pack:advertising"] {
            let blocked = [
                BlockedAttemptRow(bundleID: "com.apple.Safari", appName: "Safari",
                                  agentKey: "com.apple.Safari", agentName: "Safari",
                                  destination: "tracker.example", port: 443, count: 1,
                                  category: "rule", source: source, detail: "")
            ]

            let snapshot = AITrafficGraphBuilder.build(rows: [], blockedAttempts: blocked, limits: .unbounded)

            XCTAssertTrue(snapshot.nodes.isEmpty, "\(source) is refusal evidence, not proof Safari is an AI agent")
            XCTAssertTrue(snapshot.edges.isEmpty)
            XCTAssertEqual(snapshot.total, FlowCounters())
            XCTAssertEqual(snapshot.visibleTotal, FlowCounters())
        }
    }

    func testAIBuilderKeepsBlockedOnlySearchMatchWithProofOutsideVisibleRows() {
        let allRows = [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.8",
                bytesOut: 25, launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app"))
        ]
        let blocked = [
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "uploads.example", port: 443, count: 2,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: allRows, visibleRows: [],
                                                   blockedAttempts: blocked, limits: .unbounded)

        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .agent && $0.filter.bundleID == "claude" })
        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .tool && $0.filter.bundleID == "curl" })
        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .launcher && $0.title == "Ghostty" })
        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .launched })
        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .blocked })
        XCTAssertEqual(snapshot.total, FlowCounters(), "hidden observed rows must not leak into searched totals")
    }

    func testAIBuilderPreservesGhosttyHerdrAgentLauncherChain() throws {
        let rows = [
            row(
                app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.8",
                bytesOut: 25,
                launcher: ("herdr", "Herdr", "/Users/x/.local/bin/herdr"),
                upstreamLauncher: (
                    "com.mitchellh.ghostty", "Ghostty",
                    "/Applications/Ghostty.app/Contents/MacOS/ghostty"
                )
            )
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let herdr = try XCTUnwrap(snapshot.nodes.first { $0.kind == .launcher && $0.title == "Herdr" })
        let ghostty = try XCTUnwrap(snapshot.nodes.first { $0.kind == .launcher && $0.title == "Ghostty" })
        let claude = try XCTUnwrap(snapshot.nodes.first { $0.kind == .agent && $0.filter.bundleID == "claude" })

        XCTAssertTrue(snapshot.edges.contains {
            $0.relationship == .launched && $0.source == ghostty.id && $0.target == herdr.id
        })
        XCTAssertTrue(snapshot.edges.contains {
            $0.relationship == .launched && $0.source == herdr.id && $0.target == claude.id
        })
        XCTAssertEqual(snapshot.hidden, .none)

        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 1_200, height: 760)
        )
        let ghosttyFrame = try XCTUnwrap(layout.nodeFrames[ghostty.id])
        let herdrFrame = try XCTUnwrap(layout.nodeFrames[herdr.id])
        let claudeFrame = try XCTUnwrap(layout.nodeFrames[claude.id])
        XCTAssertLessThan(ghosttyFrame.maxX, herdrFrame.minX)
        XCTAssertLessThan(herdrFrame.maxX, claudeFrame.minX)

        let capped = AITrafficGraphBuilder.build(
            rows: rows,
            limits: AITrafficGraphLimits(maxAgents: 1, maxTools: 0, maxDestinations: 1,
                                         maxObservedEdges: 1, maxLaunchers: 1, maxBlockedEdges: 0)
        )
        XCTAssertTrue(capped.nodes.contains { $0.kind == .launcher && $0.title == "Herdr" },
                      "the immediate restart target has priority when launcher capacity is scarce")
        XCTAssertFalse(capped.nodes.contains { $0.kind == .launcher && $0.title == "Ghostty" })
    }

    func testVisualizationSelectionClearsWhenSearchContextChanges() {
        XCTAssertTrue(VisualizeSelectionPolicy.shouldClear(previousQuery: "", newQuery: "uploads.example"))
        XCTAssertFalse(VisualizeSelectionPolicy.shouldClear(previousQuery: "uploads.example",
                                                             newQuery: "uploads.example"))
    }

    func testGroupExpansionMovesAccessibilityFocusToFirstRevealedExactItem() {
        let groupID = TrafficGraphNodeID(rawValue: "group")
        let firstNodeID = TrafficGraphNodeID(rawValue: "node:a")
        let secondNodeID = TrafficGraphNodeID(rawValue: "node:z")
        let edgeGroupID = TrafficGraphEdgeID(rawValue: "edge-group")
        let firstEdgeID = TrafficGraphEdgeID(rawValue: "edge:a")
        let secondEdgeID = TrafficGraphEdgeID(rawValue: "edge:z")
        let snapshot = TrafficGraphSnapshot(
            nodes: [TrafficGraphNode(
                id: groupID, kind: .app, title: "Group", detail: "", appPath: "",
                filter: .none, counters: FlowCounters(),
                collapsedNodeIDs: [secondNodeID, firstNodeID]
            )],
            edges: [TrafficGraphEdge(
                id: edgeGroupID, source: groupID, target: groupID,
                counters: FlowCounters(), filter: .none,
                collapsedEdgeIDs: [secondEdgeID, firstEdgeID]
            )],
            total: FlowCounters(), hidden: .none
        )

        XCTAssertEqual(
            VisualizeSelectionPolicy.revealedNodeFocus(afterExpanding: groupID, in: snapshot),
            firstNodeID
        )
        XCTAssertEqual(
            VisualizeSelectionPolicy.revealedEdgeFocus(afterExpanding: edgeGroupID, in: snapshot),
            firstEdgeID
        )
    }

    func testAIBuilderReservesToolAndDestinationCapacityForRefusalEvidence() {
        let rows = [
            row(app: "git", name: "git", domain: "github.com", ip: "203.0.113.10", bytesOut: 100,
                parent: "claude", parentName: "Claude Code"),
            row(app: "npm", name: "npm", domain: "npmjs.org", ip: "203.0.113.11", bytesOut: 90,
                parent: "claude", parentName: "Claude Code"),
        ]
        let blocked = [
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "uploads.example", port: 443, count: 10_000,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        ]
        let limits = AITrafficGraphLimits(maxAgents: 1, maxTools: 1, maxDestinations: 1,
                                          maxObservedEdges: 2, maxLaunchers: 0, maxBlockedEdges: 1)

        let snapshot = AITrafficGraphBuilder.build(rows: rows, blockedAttempts: blocked, limits: limits)

        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .tool && $0.filter.bundleID == "curl" })
        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .destination && $0.title == "uploads.example" })
        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .blocked && $0.enforcement?.count == 10_000 },
                      "refusal evidence must reserve scarce tool and destination capacity before observed traffic")
        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .tool }.count, limits.maxTools)
        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .destination || $0.kind == .service }.count,
                                 limits.maxDestinations)
    }

    func testAIBuilderReservesAgentCapacityForRefusalHeavyEvidence() {
        let agents = ["claude", "codex", "aider", "goose", "gemini", "opencode", "ollama"]
        let rows = (0..<7).map { index in
            row(app: agents[index], domain: "host\(index).example", ip: "203.0.113.\(index + 1)",
                bytesOut: Int64(100 - index))
        }
        let blocked = [
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "first.example", port: 443, count: 20_000,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code"),
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "claude", agentName: "Claude Code",
                              destination: "second.example", port: 443, count: 15_000,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code"),
            BlockedAttemptRow(bundleID: "curl", appName: "curl", agentKey: "ollama", agentName: "Ollama",
                              destination: "uploads.example", port: 443, count: 10_000,
                              category: "allowlist", source: "agent-allowlist", detail: "Ollama")
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: rows, blockedAttempts: blocked)

        XCTAssertTrue(snapshot.nodes.contains { $0.kind == .agent && $0.filter.bundleID == "ollama" })
        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .blocked && $0.enforcement?.count == 10_000 })
        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .agent }.count,
                                 AITrafficGraphLimits.standard.maxAgents)
    }

    func testAIBlockedAndObservedProviderShareOneDestinationNode() {
        let rows = [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.8",
                bytesOut: 25)
        ]
        let blocked = [
            BlockedAttemptRow(bundleID: "claude", appName: "Claude Code", agentKey: "claude",
                              agentName: "Claude Code", destination: "api.anthropic.com", port: 443, count: 2,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: rows, blockedAttempts: blocked, limits: .unbounded)
        let observed = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let refusal = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(observed.target, refusal.target)
        XCTAssertEqual(snapshot.nodes.first { $0.id == observed.target }?.kind, .service)
        XCTAssertEqual(snapshot.nodes.first { $0.id == observed.target }?.title, "Anthropic")
        XCTAssertEqual(snapshot.hidden.nodeCount, 0,
                       "metadata differences must not invent a second hidden destination node")
    }

    func testAIRunsRelationshipReadsAgentToTool() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "curl", name: "curl", domain: "example.com", ip: "203.0.113.10", bytesOut: 25,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)

        let lineage = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .runs })
        XCTAssertEqual(snapshot.nodes.first { $0.id == lineage.source }?.kind, .agent)
        XCTAssertEqual(snapshot.nodes.first { $0.id == lineage.target }?.kind, .tool)
    }

    func testAIBuilderRendersOneNodePerApplicationAcrossRoles() throws {
        let rows = [
            row(
                app: "claude", name: "Claude Code", path: "/opt/homebrew/bin/claude",
                domain: "api.anthropic.com", ip: "203.0.113.10", bytesOut: 25,
                launcher: ("claude", "Claude Code", "/opt/homebrew/bin/claude")
            ),
            row(
                app: "com.microsoft.VSCode", name: "Visual Studio Code",
                path: "/Applications/Visual Studio Code.app",
                domain: "api.openai.com", ip: "203.0.113.11", bytesOut: 20,
                launcher: (
                    "com.microsoft.VSCode",
                    "Visual Studio Code",
                    "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
                )
            ),
            row(
                app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                domain: "api.openai.com", ip: "203.0.113.12", bytesOut: 15,
                relay: ("com.yetone.magpie", "magpie", "/Applications/magpie.app")
            ),
            row(
                app: "com.flowlight.app", name: "Flowlight", path: "/Applications/Flowlight.app",
                domain: "api.anthropic.com", ip: "203.0.113.13", bytesOut: 10,
                relay: ("com.flowlight.app", "Flowlight", "/Applications/Flowlight.app")
            )
        ]
        let gateway = AgentGatewayConfig(
            agent: "com.yetone.magpie",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.magpie/settings.json",
            sourceKey: "gateway"
        )
        let identity = AgentGatewayIdentity(
            bundleID: "com.yetone.magpie",
            name: "magpie",
            path: "/Applications/magpie.app"
        )

        let snapshot = AITrafficGraphBuilder.build(
            rows: rows,
            gateways: [gateway],
            resolveGateway: { _ in identity },
            limits: .unbounded
        )

        for bundleID in ["claude", "com.microsoft.VSCode", "com.yetone.magpie", "com.flowlight.app"] {
            XCTAssertEqual(
                snapshot.nodes.filter {
                    $0.filter.bundleID == bundleID
                        && [.agent, .tool, .launcher, .proxy].contains($0.kind)
                }.count,
                1,
                "\(bundleID) should render once regardless of role"
            )
        }
        XCTAssertFalse(snapshot.edges.contains { $0.source == $0.target })
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)).count, snapshot.nodes.count)
        XCTAssertEqual(snapshot.hidden.nodeCount, 0)
        XCTAssertEqual(snapshot.hidden.edgeCount, 0)

        let magpie = try XCTUnwrap(snapshot.nodes.first { $0.filter.bundleID == "com.yetone.magpie" })
        XCTAssertTrue(magpie.roleEvidence.contains { evidence in
            evidence.relationship == .configuredGateway
                && evidence.configuration?.endpoint == "http://127.0.0.1:3425"
                && evidence.configuration?.sourceKey == "gateway"
        })
        XCTAssertTrue(magpie.roleEvidence.contains { $0.relationship == .routedThrough })

        let flowlight = try XCTUnwrap(snapshot.nodes.first { $0.filter.bundleID == "com.flowlight.app" })
        XCTAssertTrue(flowlight.roleEvidence.contains { $0.relationship == .routedThrough })
    }

    func testAIMergedAgentCardKeepsAttributedChildTraffic() throws {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                ip: "203.0.113.10", bytesOut: 10,
                launcher: ("claude", "Claude Code", "/usr/local/bin/claude")),
            row(app: "node", name: "node", domain: "api.github.com",
                ip: "203.0.113.11", bytesOut: 20,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)

        let claude = try XCTUnwrap(snapshot.nodes.first {
            $0.filter.bundleID == "claude"
                && [.agent, .tool, .launcher, .proxy].contains($0.kind)
        })
        XCTAssertEqual(claude.counters.bytesOut, 30,
                       "the semantic agent card must retain proved child traffic after role collapse")
        XCTAssertTrue(claude.filter.includeAttributedChildren)
        XCTAssertFalse(snapshot.edges.contains { $0.source == $0.target })
    }

    func testAIMergedToolAcrossAgentsUsesApplicationWideScope() throws {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "node", domain: "shared.example",
                ip: "203.0.113.10", bytesOut: 40,
                parent: "agent.one", parentName: "Agent One"),
            row(app: "node", name: "node", domain: "shared.example",
                ip: "203.0.113.11", bytesOut: 60,
                parent: "agent.two", parentName: "Agent Two")
        ], limits: .unbounded)

        let node = try XCTUnwrap(snapshot.nodes.first {
            $0.filter.bundleID == "node" && $0.kind == .tool
        })
        XCTAssertEqual(node.counters.bytesOut, 100)
        XCTAssertNil(node.filter.agentParent,
                     "a merged application card must not retain one role-specific parent scope")
        XCTAssertNil(node.filter.mcpServer)
        XCTAssertFalse(node.filter.includeAttributedChildren)
        XCTAssertTrue(node.filter.focusIncludesAttributedParents,
                      "global Focus must still match the merged executable through either proved parent")
        let edge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        XCTAssertEqual(edge.counters.bytesOut, 100)
        XCTAssertEqual(edge.filter.bundleID, "node")
        XCTAssertNil(edge.filter.agentParent,
                     "an aggregate edge must not retain one arbitrary member's parent scope")
        XCTAssertNil(edge.filter.domain)
        XCTAssertNil(edge.filter.remoteIP)
        XCTAssertNil(edge.filter.appProtocol)
    }

    func testAIMergedAliasesPreserveExactStoredBundleIDCasing() throws {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "CLAUDE", name: "claude", domain: "api.anthropic.com",
                ip: "203.0.113.10", bytesOut: 8),
            row(app: "claude-code", name: "claude", domain: "api.anthropic.com",
                ip: "203.0.113.11", bytesOut: 12)
        ], limits: .unbounded)

        let claude = try XCTUnwrap(snapshot.nodes.first {
            Set($0.filter.bundleIDs) == ["CLAUDE", "claude-code"]
        })
        XCTAssertEqual(claude.counters.bytesOut, 20)
        XCTAssertTrue(claude.filter.bundleIDs.contains("CLAUDE"),
                      "case-sensitive database identities must not be normalized in the query scope")
        let edge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        XCTAssertEqual(Set(edge.filter.bundleIDs), ["CLAUDE", "claude-code"])
    }

    func testAIMergedLauncherKeepsExternalLaunchEvidenceOnSurvivingCard() throws {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "com.microsoft.VSCode", name: "Visual Studio Code",
                domain: "api.openai.com", ip: "203.0.113.9", bytesOut: 15),
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                ip: "203.0.113.10", bytesOut: 25,
                launcher: ("com.microsoft.VSCode", "Visual Studio Code", "/Applications/Visual Studio Code.app"))
        ], limits: .unbounded)

        let vscode = try XCTUnwrap(snapshot.nodes.first {
            $0.filter.bundleID == "com.microsoft.VSCode"
                && [.agent, .tool, .launcher, .proxy].contains($0.kind)
        })
        XCTAssertTrue(
            vscode.roleEvidence.contains { $0.relationship == .launched },
            "role evidence: \(vscode.roleEvidence)"
        )
        let launched = try XCTUnwrap(snapshot.edges.first { $0.relationship == .launched })
        XCTAssertEqual(launched.source, vscode.id)
        XCTAssertNotEqual(launched.source, launched.target)
    }

    func testAIBuilderShowsPersistedLauncherEvidenceOnly() {
        let proved = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.10",
                bytesOut: 25, launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app"))
        ], limits: .unbounded)
        let launch = try! XCTUnwrap(proved.edges.first { $0.relationship == .launched })
        XCTAssertEqual(proved.nodes.first { $0.id == launch.source }?.kind, .launcher)
        XCTAssertEqual(proved.nodes.first { $0.id == launch.target }?.kind, .agent)

        let unknown = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.10",
                bytesOut: 25)
        ], limits: .unbounded)
        XCTAssertFalse(unknown.edges.contains { $0.relationship == .launched })
    }

    func testDependencyLayoutOrdersLauncherAgentToolAndDestinationWithoutOverlap() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "curl", name: "curl", domain: "uploads.example", ip: "203.0.113.10", bytesOut: 25,
                parent: "claude", parentName: "Claude Code",
                launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app"))
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_100, height: 760))
        let launcher = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .launcher })
        let agent = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        let tool = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .tool })
        let destination = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .destination })
        let launcherFrame = try! XCTUnwrap(layout.nodeFrames[launcher.id])
        let agentFrame = try! XCTUnwrap(layout.nodeFrames[agent.id])
        let toolFrame = try! XCTUnwrap(layout.nodeFrames[tool.id])
        let destinationFrame = try! XCTUnwrap(layout.nodeFrames[destination.id])

        XCTAssertLessThan(launcherFrame.maxX, agentFrame.minX)
        XCTAssertLessThan(agentFrame.maxX, toolFrame.minX)
        XCTAssertLessThan(toolFrame.maxX, destinationFrame.minX)
        let frames = Array(layout.nodeFrames.values)
        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]))
            }
        }
    }

    func testAIBuilderPreservesMultiplePersistedLaunchersDeterministically() {
        let rows = [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.10",
                bytesOut: 25, launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app")),
            row(app: "claude", name: "Claude Code", domain: "github.com", ip: "203.0.113.11",
                bytesOut: 10, launcher: ("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"))
        ]

        let snapshot = AITrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let reversed = AITrafficGraphBuilder.build(rows: rows.reversed(), limits: .unbounded)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .launcher }.count, 2)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .launched }.count, 2)
        XCTAssertEqual(reversed.nodes.map(\.id), snapshot.nodes.map(\.id))
        XCTAssertEqual(reversed.edges.map(\.id), snapshot.edges.map(\.id))
        XCTAssertEqual(snapshot.visibleTotal.total, 35)
    }

    func testAIBuilderCapsSharedLaunchersAndKeepsHiddenAccountingTruthful() {
        let rows = [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "203.0.113.10",
                bytesOut: 25, launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app")),
            row(app: "codex", name: "Codex", domain: "api.openai.com", ip: "203.0.113.11",
                bytesOut: 20, launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app")),
            row(app: "claude", name: "Claude Code", domain: "github.com", ip: "203.0.113.12",
                bytesOut: 10, launcher: ("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"))
        ]
        let limits = AITrafficGraphLimits(maxAgents: 2, maxTools: 2, maxDestinations: 2,
                                          maxObservedEdges: 2, maxLaunchers: 1)

        let snapshot = AITrafficGraphBuilder.build(rows: rows, limits: limits)
        let reversed = AITrafficGraphBuilder.build(rows: rows.reversed(), limits: limits)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .launcher }.count, 1)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .launched }.count, 2)
        XCTAssertGreaterThan(snapshot.hidden.nodeCount, 0)
        XCTAssertGreaterThan(snapshot.hidden.edgeCount, 0)
        XCTAssertEqual(reversed.nodes.map(\.id), snapshot.nodes.map(\.id))
        XCTAssertEqual(reversed.nodes.map(\.title), snapshot.nodes.map(\.title))
        XCTAssertEqual(reversed.hidden, snapshot.hidden)
    }

    func testAIBuilderRanksLaunchersByAggregateTrafficNotLexicalMetadataRow() throws {
        let rows = [
            row(app: "claude", domain: "one.example", ip: "203.0.113.1", bytesOut: 100,
                launcher: ("terminal.shared", "Zulu Terminal", "/Applications/Terminal.app")),
            row(app: "codex", domain: "two.example", ip: "203.0.113.2", bytesOut: 1,
                launcher: ("terminal.shared", "Alpha Alias", "/Applications/Terminal.app")),
            row(app: "tool.other", domain: "three.example", ip: "203.0.113.3", bytesOut: 50,
                parent: "agent.other", parentName: "Other Agent",
                launcher: ("launcher.other", "Other Launcher", "/Applications/Other.app")),
        ]
        let limits = AITrafficGraphLimits(maxAgents: 3, maxTools: 3, maxDestinations: 3,
                                          maxObservedEdges: 3, maxLaunchers: 1)

        let snapshot = AITrafficGraphBuilder.build(rows: rows, limits: limits)
        let launcher = try XCTUnwrap(snapshot.nodes.first { $0.kind == .launcher })

        XCTAssertEqual(launcher.filter.bundleID, "terminal.shared",
                       "the shared launcher's 101 bytes must outrank a 50-byte launcher even when its lexical metadata row has only 1 byte")
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .launched }.count, 2)
    }

    func testAIBuilderAcceptsStoredParentIdentityWithoutDisplayName() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "curl", name: "curl", domain: "example.com", ip: "203.0.113.10", bytesOut: 25,
                parent: "custom.agent")
        ], limits: .unbounded)

        let agent = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        XCTAssertEqual(agent.filter.bundleID, "custom.agent")
        XCTAssertEqual(agent.title, "custom.agent")
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .tool }.count, 1)
    }

    func testAIProviderGroupingRetainsExactHostAndAddressMembers() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.anthropic.com", ip: "160.79.104.10", bytesOut: 100),
            row(app: "claude", name: "claude", domain: "console.anthropic.com", ip: "160.79.104.11", bytesIn: 40),
        ], limits: .unbounded)

        let service = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .service })
        XCTAssertEqual(service.title, "Anthropic")
        let edge = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        XCTAssertEqual(edge.members.count, 2)
        XCTAssertEqual(Set(edge.members.compactMap(\.filter.domain)), ["api.anthropic.com", "console.anthropic.com"])
        XCTAssertEqual(Set(edge.members.compactMap(\.filter.remoteIP)), ["160.79.104.10", "160.79.104.11"])
        XCTAssertEqual(Set(edge.members.map(\.detail)), ["160.79.104.10", "160.79.104.11"])
        XCTAssertTrue(edge.members.allSatisfy { $0.filter.bundleID == "claude" })
    }

    func testAIOrdinaryDestinationsGroupByRegistrableDomainAndKeepExactMembers() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 40),
            row(app: "claude", name: "claude", domain: "deep.api.example.com", ip: "203.0.113.9", bytesOut: 60)
        ], limits: .unbounded)

        let destination = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .destination })
        XCTAssertEqual(destination.title, "example.com")
        XCTAssertEqual(destination.filter.domainSuffix, "example.com")
        XCTAssertEqual(Set(destination.members.compactMap(\.filter.domain)),
                       ["api.example.com", "deep.api.example.com"])
        XCTAssertEqual(snapshot.edges.first { $0.relationship == .observed }?.members.count, 2)
    }

    func testAISingleMemberProviderUsesItsExactFilter() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.anthropic.com", ip: "160.79.104.10", bytesOut: 100)
        ], limits: .unbounded)

        let service = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .service })
        XCTAssertEqual(service.filter.bundleID, "claude")
        XCTAssertEqual(service.filter.domain, "api.anthropic.com")
        XCTAssertEqual(service.filter.remoteIP, "160.79.104.10")
    }

    func testAIExactMembersKeepParentAndMCPAttribution() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "node", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 40,
                parent: "agent.one", mcp: "github"),
            row(app: "node", name: "node", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 60,
                parent: "agent.two", mcp: "filesystem")
        ], limits: .unbounded)

        let service = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .service })
        XCTAssertEqual(service.members.count, 2)
        XCTAssertEqual(Set(service.members.map(\.id)).count, 2)
        XCTAssertEqual(Set(service.members.compactMap(\.filter.agentParent)), ["agent.one", "agent.two"])
        XCTAssertEqual(Set(service.members.compactMap(\.filter.mcpServer)), ["github", "filesystem"])
    }

    func testAISharedOrdinaryDestinationKeepsExactDestinationScope() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "shared.example", ip: "203.0.113.42", bytesOut: 40),
            row(app: "codex", name: "codex", domain: "shared.example", ip: "203.0.113.42", bytesOut: 60)
        ], limits: .unbounded)

        let destination = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .destination })
        XCTAssertEqual(destination.members.count, 2)
        XCTAssertNil(destination.filter.bundleID,
                     "a shared destination node must cover every visible source")
        XCTAssertEqual(destination.filter.domainSuffix, "shared.example")
        XCTAssertNil(destination.filter.domain)
        XCTAssertNil(destination.filter.remoteIP)
        XCTAssertTrue(destination.members.allSatisfy {
            $0.filter.domain == "shared.example" && $0.filter.remoteIP == "203.0.113.42"
        })
    }

    func testAIBoundedNodeValuesMatchVisibleRelationships() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "claude", domain: "api.anthropic.com", ip: "160.79.104.10", bytesOut: 100),
            row(app: "codex", name: "codex", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 900)
        ], limits: AITrafficGraphLimits(maxAgents: 1, maxTools: 1, maxDestinations: 1, maxObservedEdges: 1))

        let observed = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let source = try! XCTUnwrap(snapshot.nodes.first { $0.id == observed.source })
        let destination = try! XCTUnwrap(snapshot.nodes.first { $0.id == observed.target })
        XCTAssertEqual(source.counters, observed.counters)
        XCTAssertEqual(destination.counters, observed.counters)
        XCTAssertEqual(destination.members, observed.members)
        XCTAssertEqual(snapshot.hidden.counters.bytesOut, 100)
    }

    func testAIToolFilterKeepsItsParentScope() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "node", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 40,
                parent: "agent.one", mcp: "github"),
            row(app: "node", name: "node", domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 60,
                parent: "agent.two", mcp: "github")
        ], limits: .unbounded)

        let tools = snapshot.nodes.filter { $0.kind == .mcp }
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(Set(tools.compactMap(\.filter.agentParent)), ["agent.one", "agent.two"])
        XCTAssertTrue(tools.allSatisfy { $0.filter.bundleID == "node" && $0.filter.mcpServer == "github" })
    }

    func testAICapsAreDeterministicAndPreserveHiddenAccounting() {
        let rows = (0..<24).flatMap { index -> [BreakdownRow] in
            let agent = index.isMultiple(of: 2) ? "claude" : "codex"
            return [
                row(app: agent, name: agent, domain: "host\(index).example", ip: "203.0.113.\(index)",
                    bytesIn: Int64(index + 1) * 100, flows: 1)
            ]
        }
        let limits = AITrafficGraphLimits(maxAgents: 1, maxTools: 1, maxDestinations: 4, maxObservedEdges: 4)

        let first = AITrafficGraphBuilder.build(rows: rows, limits: limits)
        let second = AITrafficGraphBuilder.build(rows: rows.reversed(), limits: limits)

        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), second.edges.map(\.id))
        XCTAssertEqual(first.hidden, second.hidden)
        XCTAssertEqual(first.visibleTotal.total + first.hidden.counters.total, first.total.total)
        XCTAssertEqual(first.visibleTotal.flows + first.hidden.counters.flows, first.total.flows)
    }

    func testAIStandardCapFitsTheMinimumCanvasWithoutOverlaps() {
        let rows = (0..<80).map { index in
            let agent = ["claude", "codex", "aider", "goose", "gemini", "opencode"][index % 6]
            return row(app: agent, name: agent, domain: "host\(index % 10).example",
                       ip: "203.0.113.\(index % 10)", bytesIn: Int64(index + 1) * 100, flows: 1)
        }
        let snapshot = AITrafficGraphBuilder.build(rows: rows)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 900, height: 760))
        let frames = Array(layout.nodeFrames.values)

        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                               "AI node frames \(frames[left]) and \(frames[right]) overlap")
            }
        }
    }

    func testAIBuilderKeepsConfiguredGatewayAndObservedProxyRouteAsSeparateEvidence() throws {
        var routed = row(app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                         domain: "api.anthropic.com", ip: "160.79.104.10",
                         bytesIn: 100, bytesOut: 50, flows: 2)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        routed.routeProxyPath = "/Applications/Flowlight.app"
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")

        let snapshot = AITrafficGraphBuilder.build(
            rows: [routed],
            gateways: [gateway],
            resolveGateway: { $0 == gateway.endpoint ? identity : nil },
            limits: .unbounded
        )
        let configured = try XCTUnwrap(snapshot.edges.first { $0.relationship == .configuredGateway })
        let route = try XCTUnwrap(snapshot.edges.first { $0.relationship == .routedThrough })
        let observed = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let agent = try XCTUnwrap(snapshot.nodes.first { $0.kind == .agent })
        let magpie = try XCTUnwrap(snapshot.nodes.first { $0.title == "magpie" })
        let flowlight = try XCTUnwrap(snapshot.nodes.first { $0.title == "Flowlight" })

        XCTAssertEqual(configured.source, agent.id)
        XCTAssertEqual(configured.target, magpie.id)
        XCTAssertEqual(configured.counters, FlowCounters())
        XCTAssertEqual(route.source, magpie.id)
        XCTAssertEqual(route.target, flowlight.id)
        XCTAssertEqual(route.counters, FlowCounters())
        XCTAssertEqual(route.trafficVolume, FlowCounters(bytesIn: 100, bytesOut: 50, flows: 2))
        XCTAssertEqual(observed.source, flowlight.id)
        XCTAssertEqual(observed.counters, FlowCounters(bytesIn: 100, bytesOut: 50, flows: 2))
        XCTAssertEqual(snapshot.total, observed.counters)
        XCTAssertEqual(snapshot.visibleTotal, observed.counters)

        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_100, height: 760))
        XCTAssertLessThan(try XCTUnwrap(layout.nodeFrames[agent.id]).midX,
                          try XCTUnwrap(layout.nodeFrames[magpie.id]).midX)
        XCTAssertLessThan(try XCTUnwrap(layout.nodeFrames[magpie.id]).midX,
                          try XCTUnwrap(layout.nodeFrames[flowlight.id]).midX)
        XCTAssertLessThan(try XCTUnwrap(layout.nodeFrames[flowlight.id]).midX,
                          try XCTUnwrap(layout.nodeFrames[observed.target]).midX)
        XCTAssertFalse(TrafficGraphFlowDash.animates(configured))
        XCTAssertFalse(TrafficGraphFlowDash.animates(route))
        XCTAssertTrue(TrafficGraphFlowDash.animates(observed))
    }

    func testAIConfiguredGatewayUsesExistingApplicationAgentIdentity() throws {
        let gateway = AgentGatewayConfig(
            agent: "cursor",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/Library/Application Support/Cursor/User/settings.json",
            sourceKey: "http.proxy"
        )
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")
        let snapshot = AITrafficGraphBuilder.build(
            rows: [row(app: "com.todesktop.230313mzl4w4u92", name: "Cursor", path: "/Applications/Cursor.app",
                       domain: "api.openai.com", ip: "104.18.1.1", bytesOut: 20)],
            gateways: [gateway], resolveGateway: { _ in identity }, limits: .unbounded
        )

        let agents = snapshot.nodes.filter { $0.kind == .agent }
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.filter.bundleID, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(snapshot.edges.first { $0.relationship == .configuredGateway }?.source, agents.first?.id)
    }

    func testAIConfiguredGatewayDoesNotClaimObservedAgentTraffic() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")
        let snapshot = AITrafficGraphBuilder.build(
            rows: [row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                       ip: "160.79.104.10", bytesOut: 20)],
            gateways: [gateway], resolveGateway: { _ in identity }, limits: .unbounded
        )

        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .configuredGateway }.count, 1)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertEqual(snapshot.visibleTotal.bytesOut, 20,
                       "configuration evidence must never duplicate or inherit observed counters")
    }

    func testAIConfiguredGatewaySurvivesWithoutLiveListener() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "https", host: "gateway.example", port: 443),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let snapshot = AITrafficGraphBuilder.build(
            rows: [], gateways: [gateway], resolveGateway: { _ in nil }, limits: .unbounded
        )

        let configured = try XCTUnwrap(snapshot.edges.first { $0.relationship == .configuredGateway })
        XCTAssertEqual(snapshot.nodes.first { $0.id == configured.target }?.title, "https://gateway.example:443")
        XCTAssertEqual(configured.configuration?.endpoint, "https://gateway.example:443")
        XCTAssertEqual(configured.counters, FlowCounters())
    }

    func testConfiguredGatewayScopeKeepsMatchingEvidenceOnly() {
        let claude = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "https", host: "gateway.example", port: 443),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let codex = AgentGatewayConfig(
            agent: "codex",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 4000),
            source: "~/.codex/config.toml",
            sourceKey: "model_providers.local.base_url"
        )

        XCTAssertTrue(VisualizeGatewayScope.includes(claude, query: "claude", focus: .none))
        XCTAssertFalse(VisualizeGatewayScope.includes(codex, query: "claude", focus: .none))
        XCTAssertTrue(VisualizeGatewayScope.includes(codex, query: "4000", focus: .none))
        XCTAssertTrue(VisualizeGatewayScope.includes(
            claude,
            query: "",
            focus: FocusScope(bundleIDs: ["claude"])
        ))
        XCTAssertFalse(VisualizeGatewayScope.includes(
            codex,
            query: "",
            focus: FocusScope(bundleIDs: ["claude"])
        ))
        XCTAssertTrue(VisualizeGatewayScope.includes(
            claude,
            query: "",
            focus: FocusScope(bundleIDs: ["claude-code"])
        ))
        let magpie = AgentGatewayIdentity(
            bundleID: "com.yetone.magpie",
            name: "magpie",
            path: "/Applications/magpie.app"
        )
        XCTAssertTrue(VisualizeGatewayScope.includes(
            claude,
            identity: magpie,
            query: "magpie",
            focus: .none
        ))
        XCTAssertTrue(VisualizeGatewayScope.includes(
            claude,
            identity: magpie,
            query: "",
            focus: FocusScope(bundleIDs: ["com.yetone.magpie"])
        ))
    }

    func testAIConfiguredOnlyGatewayRespectsNarrowedScope() {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "https", host: "gateway.example", port: 443),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )

        let unfiltered = AITrafficGraphBuilder.build(
            rows: [], gateways: [gateway], resolveGateway: { _ in nil }, limits: .unbounded
        )
        let narrowed = AITrafficGraphBuilder.build(
            rows: [], gateways: [gateway], resolveGateway: { _ in nil },
            includeConfiguredOnlyAgents: false, limits: .unbounded
        )

        XCTAssertTrue(unfiltered.edges.contains { $0.relationship == .configuredGateway })
        XCTAssertFalse(narrowed.edges.contains { $0.relationship == .configuredGateway })
        XCTAssertFalse(narrowed.nodes.contains { $0.kind == .agent })
    }

    func testAISemanticAliasesDoNotConsumeAnotherApplicationSlot() {
        let limits = AITrafficGraphLimits(
            maxAgents: 2,
            maxTools: 8,
            maxDestinations: 10,
            maxObservedEdges: 28
        )
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "Claude Code", domain: "one.example",
                ip: "203.0.113.1", bytesOut: 100),
            row(app: "claude-code", name: "Claude Code", domain: "two.example",
                ip: "203.0.113.2", bytesOut: 90),
            row(app: "codex", name: "Codex", domain: "three.example",
                ip: "203.0.113.3", bytesOut: 80)
        ], limits: limits)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .agent }.count, 2)
        XCTAssertTrue(snapshot.nodes.contains { $0.filter.bundleID == "codex" },
                      "historical aliases must not hide another semantic application")
        XCTAssertTrue(snapshot.nodes.contains { Set($0.filter.bundleIDs) == ["claude", "claude-code"] })
    }

    func testAICollapsedConfiguredGatewayKeepsEvidenceAndResolvedMetadata() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "localhost", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(
            bundleID: "claude",
            name: "Claude Code",
            path: "/Applications/Claude Code.app"
        )

        let snapshot = AITrafficGraphBuilder.build(
            rows: [],
            gateways: [gateway],
            resolveGateway: { _ in identity },
            limits: .unbounded
        )

        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertTrue(snapshot.edges.isEmpty,
                      "a role-collapse self-loop is not a real dependency edge")
        XCTAssertEqual(node.appPath, identity.path,
                       "the surviving configured agent inherits resolved application metadata")
        XCTAssertEqual(node.title, identity.name)
        XCTAssertTrue(node.roleEvidence.contains { $0.relationship == .configuredGateway })
    }

    func testAIGatewayAliasChoiceIsDeterministic() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "https", host: "gateway.example", port: 443),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let rows = [
            row(app: "claude-code", name: "claude", domain: "api.anthropic.com",
                ip: "203.0.113.1", bytesOut: 10),
            row(app: "claude", name: "claude", domain: "api.anthropic.com",
                ip: "203.0.113.2", bytesOut: 10)
        ]

        let snapshots = (0..<20).map { index in
            AITrafficGraphBuilder.build(
                rows: index.isMultiple(of: 2) ? rows : rows.reversed(),
                gateways: [gateway], resolveGateway: { _ in nil }, limits: .unbounded
            )
        }
        let sources = try snapshots.map { snapshot in
            try XCTUnwrap(snapshot.edges.first { $0.relationship == .configuredGateway }?.source)
        }

        XCTAssertEqual(Set(sources).count, 1)
        XCTAssertEqual(sources.first?.rawValue, "agent:6:claude")
        let claude = try XCTUnwrap(snapshots[0].nodes.first { $0.id.rawValue == "agent:6:claude" })
        XCTAssertEqual(claude.counters.bytesOut, 20,
                       "distinct historical aliases contribute their disjoint traffic to the surviving card")
        XCTAssertNil(claude.filter.bundleID)
        XCTAssertEqual(Set(claude.filter.bundleIDs), ["claude", "claude-code"])
        XCTAssertTrue(claude.filter.focus.isEmpty,
                      "historical aliases are intrinsic to the card, not stored in global Focus")
        let observed = snapshots[0].edges.filter { $0.relationship == .observed }
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0].counters.bytesOut, 20)
        XCTAssertEqual(observed[0].members.count, 2)
        XCTAssertNil(observed[0].filter.bundleID)
        XCTAssertEqual(Set(observed[0].filter.bundleIDs), ["claude", "claude-code"])
        XCTAssertTrue(observed[0].filter.focus.isEmpty)
    }

    func testAIGatewayProcessTrafficNeedsObservedRouteEvidence() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")
        let snapshot = AITrafficGraphBuilder.build(
            rows: [row(app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                       domain: "updates.example", ip: "203.0.113.20", bytesIn: 100)],
            gateways: [gateway], resolveGateway: { _ in identity }, limits: .unbounded
        )

        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .configuredGateway })
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .routedThrough })
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .observed })
        XCTAssertEqual(snapshot.visibleTotal, FlowCounters(),
                       "unrelated gateway-process traffic must not be attached to the configured agent")
    }

    func testAIGatewayRouteEvidenceDoesNotPromoteUnrelatedRowsFromSameProcess() throws {
        var routed = row(app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                         domain: "api.anthropic.com", ip: "160.79.104.10", bytesIn: 100)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        routed.routeProxyPath = "/Applications/Flowlight.app"
        let unrelated = row(app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                            domain: "updates.example", ip: "203.0.113.20", bytesIn: 900)
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")

        let snapshot = AITrafficGraphBuilder.build(
            rows: [routed, unrelated], gateways: [gateway],
            resolveGateway: { _ in identity }, limits: .unbounded
        )

        let route = try XCTUnwrap(snapshot.edges.first { $0.relationship == .routedThrough })
        XCTAssertEqual(route.displayedCounters.bytesIn, 100)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertFalse(snapshot.edges.contains { edge in
            edge.members.contains { $0.filter.domain == "updates.example" }
        })
        XCTAssertEqual(snapshot.visibleTotal.bytesIn, 100,
                       "capture-time route evidence applies only to the row that carries it")
        XCTAssertEqual(snapshot.total.bytesIn, 100)
    }

    func testAIGatewayEdgeIDsPreserveConfigurationTupleBoundaries() {
        let endpoint = AgentGatewayConfig.Endpoint(scheme: "https", host: "gateway.example", port: 443)
        let gateways = [
            AgentGatewayConfig(agent: "claude", endpoint: endpoint, source: "ab", sourceKey: "c"),
            AgentGatewayConfig(agent: "claude", endpoint: endpoint, source: "a", sourceKey: "bc")
        ]
        let snapshot = AITrafficGraphBuilder.build(
            rows: [row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                       ip: "203.0.113.10", bytesOut: 10)],
            gateways: gateways,
            resolveGateway: { _ in nil },
            limits: .unbounded
        )

        let configured = snapshot.edges.filter { $0.relationship == .configuredGateway }
        XCTAssertEqual(configured.count, 2)
        XCTAssertEqual(Set(configured.map(\.id)).count, 2,
                       "distinct configuration tuples must never concatenate into the same edge ID")
    }

    func testAIDistinctGatewayDeclarationsRemainVisibleAndHiddenCountsStayExact() throws {
        var routed = row(app: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app",
                         domain: "api.anthropic.com", ip: "160.79.104.10", bytesIn: 100)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        let identity = AgentGatewayIdentity(bundleID: "com.yetone.magpie", name: "magpie",
                                            path: "/Applications/magpie.app")
        let gateways = [
            AgentGatewayConfig(agent: "claude", endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
                               source: "~/.claude/settings.json", sourceKey: "env.HTTP_PROXY"),
            AgentGatewayConfig(agent: "claude", endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3426),
                               source: "~/.claude/settings.json", sourceKey: "env.HTTPS_PROXY"),
        ]
        let snapshot = AITrafficGraphBuilder.build(
            rows: [routed], gateways: gateways, resolveGateway: { _ in identity }, limits: .unbounded
        )

        let configured = snapshot.edges.filter { $0.relationship == .configuredGateway }
        XCTAssertEqual(configured.count, 2)
        XCTAssertEqual(Set(configured.map(\.id)).count, 2)
        XCTAssertEqual(snapshot.hidden.nodeCount, 0)
        XCTAssertEqual(snapshot.hidden.edgeCount, 0)
    }

    func testTrafficBuilderShowsExplicitProxyRouteWithoutDoubleCounting() {
        var routed = row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                         ip: "203.0.113.8", bytesIn: 100, bytesOut: 50, flows: 2)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        routed.routeProxyPath = "/Applications/Flowlight.app"

        let snapshot = TrafficGraphBuilder.build(rows: [routed], limits: .unbounded)
        let route = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .routedThrough })
        let observed = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })

        XCTAssertEqual(snapshot.nodes.first { $0.id == route.source }?.kind, .app)
        XCTAssertEqual(snapshot.nodes.first { $0.id == route.target }?.kind, .proxy)
        XCTAssertEqual(observed.source, route.target)
        XCTAssertEqual(route.counters, FlowCounters())
        XCTAssertEqual(route.trafficVolume, FlowCounters(bytesIn: 100, bytesOut: 50, flows: 2))
        XCTAssertEqual(observed.counters, FlowCounters(bytesIn: 100, bytesOut: 50, flows: 2))
        XCTAssertEqual(snapshot.total, observed.counters)
        XCTAssertEqual(snapshot.visibleTotal, observed.counters)
        XCTAssertEqual(snapshot.hidden.nodeCount, 0)
        XCTAssertEqual(snapshot.hidden.edgeCount, 0)
    }

    func testTrafficBuilderDeduplicatesOneRouteAcrossDestinationsAndKeepsStableProxyIdentity() {
        var first = row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                        ip: "203.0.113.8", bytesOut: 50)
        first.routeProxyBundleID = "com.flowlight.app"
        first.routeProxyName = "Flowlight"
        var second = row(app: "claude", name: "Claude Code", domain: "github.com",
                         ip: "203.0.113.9", bytesIn: 75)
        second.routeProxyBundleID = "com.flowlight.app"
        second.routeProxyName = "Flowlight renamed"

        let snapshot = TrafficGraphBuilder.build(rows: [first, second], limits: .unbounded)

        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .routedThrough }.count, 1)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .proxy }.count, 1)
        XCTAssertEqual(snapshot.nodes.first { $0.kind == .proxy }?.title, "Flowlight")
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 2)
        XCTAssertEqual(snapshot.total.total, 125)
        XCTAssertEqual(snapshot.visibleTotal.total, 125)
        XCTAssertEqual(snapshot.hidden.nodeCount, 0)
        XCTAssertEqual(snapshot.hidden.edgeCount, 0)

        let reversed = TrafficGraphBuilder.build(rows: [second, first], limits: .unbounded)
        XCTAssertEqual(reversed.nodes.map(\.id), snapshot.nodes.map(\.id))
        XCTAssertEqual(reversed.nodes.map(\.title), snapshot.nodes.map(\.title))
        XCTAssertEqual(reversed.edges.map(\.id), snapshot.edges.map(\.id))
        XCTAssertEqual(reversed.total, snapshot.total)
        XCTAssertEqual(reversed.hidden, snapshot.hidden)
    }

    func testRoutedObservedEdgesRemainDistinctPerOriginatingApp() {
        var first = row(app: "claude", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 50)
        first.routeProxyBundleID = "com.flowlight.app"
        first.routeProxyName = "Flowlight"
        var second = row(app: "codex", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 75)
        second.routeProxyBundleID = "com.flowlight.app"
        second.routeProxyName = "Flowlight"

        let snapshot = TrafficGraphBuilder.build(rows: [first, second], limits: .unbounded)
        let observed = snapshot.edges.filter { $0.relationship == .observed }

        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(Set(observed.map(\.id)).count, 2)
        XCTAssertEqual(Set(observed.compactMap(\.filter.bundleID)), ["claude", "codex"])
        XCTAssertEqual(snapshot.visibleTotal.total, 125)
    }

    func testBlockedAttemptsStaySeparateFromTrafficTotalsAndAllowBlockedOnlyDestinations() {
        let observed = row(app: "com.browser", name: "Browser", domain: "example.com",
                           ip: "203.0.113.8", bytesIn: 100, bytesOut: 25, flows: 2)
        let blocked = [
            BlockedAttemptRow(bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                              destination: "www.google-analytics.com", port: 443, count: 4,
                              category: "tracking", source: "Managed pack · official.privacy",
                              detail: "google-analytics.com"),
            BlockedAttemptRow(bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                              destination: "www.google-analytics.com", port: 443, count: 2,
                              category: "Rule", source: "Ordinary rule",
                              detail: "google-analytics.com")
        ]

        let snapshot = TrafficGraphBuilder.build(rows: [observed], blockedAttempts: blocked, limits: .unbounded)
        let edge = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .blocked }.count, 1)
        XCTAssertEqual(edge.enforcement?.count, 6)
        XCTAssertEqual(edge.enforcement?.category, "Rule, tracking")
        XCTAssertEqual(edge.enforcement?.source, "Managed pack · official.privacy, Ordinary rule")
        XCTAssertEqual(edge.counters, FlowCounters())
        XCTAssertEqual(edge.filter.domain, "www.google-analytics.com")
        XCTAssertEqual(snapshot.nodes.first { $0.id == edge.target }?.title, "google-analytics.com")
        XCTAssertEqual(snapshot.total, observed.counters)
        XCTAssertEqual(snapshot.visibleTotal, observed.counters)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 1)
    }

    func testBlockedIPDestinationsKeepExactAddressIdentityAndScope() throws {
        let addresses = ["203.0.113.8", "2001:db8::8"]
        let blocked = addresses.map { address in
            BlockedAttemptRow(
                bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                destination: address, port: 443, count: 1,
                category: "Rule", source: "Ordinary rule", detail: address
            )
        }

        let snapshot = TrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded
        )
        let destinations = snapshot.nodes.filter { $0.kind == .destination }
        let edges = snapshot.edges.filter { $0.relationship == .blocked }

        XCTAssertEqual(Set(destinations.map(\.title)), Set(addresses))
        XCTAssertEqual(Set(destinations.compactMap(\.filter.remoteIP)), Set(addresses))
        XCTAssertTrue(destinations.allSatisfy { $0.filter.domain == nil && $0.filter.domainSuffix == nil })
        XCTAssertEqual(Set(edges.compactMap(\.filter.remoteIP)), Set(addresses))
        XCTAssertTrue(edges.allSatisfy { $0.filter.domain == nil && $0.filter.domainSuffix == nil })
    }

    func testAIBlockedIPDestinationsKeepExactAddressIdentityAndScope() {
        let addresses = ["203.0.113.8", "2001:db8::8"]
        let blocked = addresses.map { address in
            BlockedAttemptRow(
                bundleID: "claude", appName: "Claude Code", agentKey: "claude", agentName: "Claude Code",
                destination: address, port: 443, count: 1,
                category: "Rule", source: "Ordinary rule", detail: address
            )
        }

        let snapshot = AITrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded
        )
        let destinations = snapshot.nodes.filter { $0.kind == .destination }
        let edges = snapshot.edges.filter { $0.relationship == .blocked }

        XCTAssertEqual(Set(destinations.map(\.title)), Set(addresses))
        XCTAssertEqual(Set(destinations.compactMap(\.filter.remoteIP)), Set(addresses))
        XCTAssertTrue(destinations.allSatisfy { $0.filter.domain == nil && $0.filter.domainSuffix == nil })
        XCTAssertEqual(Set(edges.compactMap(\.filter.remoteIP)), Set(addresses))
        XCTAssertTrue(edges.allSatisfy { $0.filter.domain == nil && $0.filter.domainSuffix == nil })
    }

    func testObservedAndBlockedBareIPShareOneTrafficDestination() throws {
        let observed = row(app: "com.browser", name: "Browser", domain: "", ip: "203.0.113.8",
                           bytesIn: 100)
        let blocked = BlockedAttemptRow(
            bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
            destination: "203.0.113.8", port: 443, count: 2,
            category: "Rule", source: "Ordinary rule", detail: "203.0.113.8"
        )

        let snapshot = TrafficGraphBuilder.build(
            rows: [observed], blockedAttempts: [blocked], limits: .unbounded
        )
        let observedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let blockedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })
        let destination = try XCTUnwrap(snapshot.nodes.first { $0.id == observedEdge.target })

        XCTAssertEqual(observedEdge.target, blockedEdge.target)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 1)
        XCTAssertEqual(destination.title, "203.0.113.8")
        XCTAssertEqual(destination.filter.remoteIP, "203.0.113.8")
        XCTAssertNil(destination.filter.domainSuffix)
        XCTAssertEqual(blockedEdge.filter.remoteIP, "203.0.113.8")
        XCTAssertNil(blockedEdge.filter.domain)
        XCTAssertEqual(snapshot.total.bytesIn, 100)
        XCTAssertEqual(blockedEdge.enforcement?.count, 2)
    }

    func testObservedAndBlockedBareIPWithOwnerMetadataShareOneTrafficDestination() throws {
        let observed = row(
            app: "com.browser", name: "Browser", domain: "", ip: "203.0.113.8",
            owner: "Example Network", bytesIn: 100
        )
        let blocked = BlockedAttemptRow(
            bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
            destination: "203.0.113.8", port: 443, count: 2,
            category: "Rule", source: "Ordinary rule", detail: "203.0.113.8"
        )

        let snapshot = TrafficGraphBuilder.build(
            rows: [observed], blockedAttempts: [blocked], limits: .unbounded
        )
        let observedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let blockedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })
        let destinations = snapshot.nodes.filter { $0.kind == .destination }

        XCTAssertEqual(observedEdge.target, blockedEdge.target)
        XCTAssertEqual(destinations.count, 1)
        XCTAssertEqual(destinations[0].title, "203.0.113.8")
        XCTAssertEqual(destinations[0].members.first?.title, "Example Network")
        XCTAssertNoThrow(
            TrafficGraphLayout.layout(
                snapshot: snapshot,
                in: CGRect(x: 0, y: 0, width: 900, height: 760)
            )
        )
    }

    func testObservedAndBlockedBareIPShareOneAIDestination() throws {
        let observed = row(app: "claude", name: "Claude Code", domain: "", ip: "203.0.113.8",
                           bytesIn: 100)
        let blocked = BlockedAttemptRow(
            bundleID: "claude", appName: "Claude Code", agentKey: "claude", agentName: "Claude Code",
            destination: "203.0.113.8", port: 443, count: 2,
            category: "Rule", source: "Ordinary rule", detail: "203.0.113.8"
        )

        let snapshot = AITrafficGraphBuilder.build(
            rows: [observed], blockedAttempts: [blocked], limits: .unbounded
        )
        let observedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        let blockedEdge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })
        let destination = try XCTUnwrap(snapshot.nodes.first { $0.id == observedEdge.target })

        XCTAssertEqual(observedEdge.target, blockedEdge.target)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 1)
        XCTAssertEqual(destination.title, "203.0.113.8")
        XCTAssertEqual(destination.filter.remoteIP, "203.0.113.8")
        XCTAssertNil(destination.filter.domainSuffix)
        XCTAssertEqual(blockedEdge.filter.remoteIP, "203.0.113.8")
        XCTAssertNil(blockedEdge.filter.domain)
        XCTAssertEqual(snapshot.total.bytesIn, 100)
        XCTAssertEqual(blockedEdge.enforcement?.count, 2)
    }

    func testTrafficBlockedAttemptsMergeCanonicalDestinationSpellings() throws {
        let blocked = [
            BlockedAttemptRow(
                bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                destination: "2001:0db8:0:0:0:0:0:1", port: 443, count: 2,
                category: "rule", source: "ordinary-rule", detail: "expanded"
            ),
            BlockedAttemptRow(
                bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                destination: "2001:db8::1", port: 443, count: 3,
                category: "rule", source: "ordinary-rule", detail: "compressed"
            ),
            BlockedAttemptRow(
                bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                destination: "Example.COM.", port: 443, count: 5,
                category: "rule", source: "ordinary-rule", detail: "trailing dot"
            ),
            BlockedAttemptRow(
                bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                destination: "example.com", port: 443, count: 7,
                category: "rule", source: "ordinary-rule", detail: "canonical"
            )
        ]

        let snapshot = TrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded
        )
        let edges = snapshot.edges.filter { $0.relationship == .blocked }

        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(Set(edges.compactMap { $0.enforcement?.count }), [5, 12])
        XCTAssertEqual(Set(edges.compactMap(\.filter.remoteIP)), ["2001:db8::1"])
        XCTAssertEqual(Set(edges.compactMap(\.filter.domain)), ["example.com"])
    }

    func testBlockedAttemptWithNoncanonicalHostnameRemainsVisible() throws {
        let attempt = BlockedAttemptRow(
            bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
            destination: "Legacy_Host.Example", port: 443, count: 4,
            category: "rule", source: "ordinary-rule", detail: "historical"
        )

        let traffic = TrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: [attempt], limits: .unbounded
        )
        let edge = try XCTUnwrap(traffic.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(edge.enforcement?.count, 4)
        XCTAssertEqual(edge.filter.domain, "legacy_host.example")
    }

    func testAIBlockedAttemptsMergeCanonicalDestinationSpellings() {
        let blocked = [
            BlockedAttemptRow(
                bundleID: "claude", appName: "Claude Code", agentKey: "claude", agentName: "Claude Code",
                destination: "2001:0db8:0:0:0:0:0:1", port: 443, count: 2,
                category: "rule", source: "ordinary-rule", detail: "expanded"
            ),
            BlockedAttemptRow(
                bundleID: "claude", appName: "Claude Code", agentKey: "claude", agentName: "Claude Code",
                destination: "2001:db8::1", port: 443, count: 3,
                category: "rule", source: "ordinary-rule", detail: "compressed"
            )
        ]

        let snapshot = AITrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded
        )
        let edges = snapshot.edges.filter { $0.relationship == .blocked }

        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.enforcement?.count, 5)
        XCTAssertEqual(edges.first?.filter.remoteIP, "2001:db8::1")
    }

    func testAIBlockedAttemptWithNoncanonicalHostnameRemainsVisible() throws {
        let attempt = BlockedAttemptRow(
            bundleID: "claude", appName: "Claude Code", agentKey: "claude", agentName: "Claude Code",
            destination: "Legacy_Host.Example", port: 443, count: 4,
            category: "rule", source: "ordinary-rule", detail: "historical"
        )

        let snapshot = AITrafficGraphBuilder.build(
            rows: [BreakdownRow](), blockedAttempts: [attempt], limits: .unbounded
        )
        let edge = try XCTUnwrap(snapshot.edges.first { $0.relationship == .blocked })

        XCTAssertEqual(edge.enforcement?.count, 4)
        XCTAssertEqual(edge.filter.domain, "legacy_host.example")
    }

    func testBlockedAttemptsKeepPortsDistinct() {
        let blocked = [
            BlockedAttemptRow(bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                              destination: "example.com", port: 22, count: 2,
                              category: "rule", source: "ordinary-rule", detail: "ssh"),
            BlockedAttemptRow(bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                              destination: "example.com", port: 443, count: 3,
                              category: "rule", source: "ordinary-rule", detail: "https")
        ]

        let snapshot = TrafficGraphBuilder.build(rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded)
        let edges = snapshot.edges.filter { $0.relationship == .blocked }

        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(Set(edges.compactMap { $0.enforcement?.count }), [2, 3])
        XCTAssertTrue(edges.contains { $0.enforcement?.detail.contains("Port 22") == true })
        XCTAssertTrue(edges.contains { $0.enforcement?.detail.contains("Port 443") == true })
    }

    func testBlockedEvidenceSharesTheGlobalNodeBudget() {
        let observed = (0..<10).map { index in
            row(app: "app.\(index)", domain: "observed-\(index).example", ip: "203.0.113.\(index + 1)",
                bytesIn: Int64(100 - index))
        }
        let blocked = (0..<5).map { index in
            BlockedAttemptRow(bundleID: "app.\(index)", appName: "App \(index)", agentKey: "", agentName: "",
                              destination: "blocked-\(index).example", port: 443, count: Int64(20 - index),
                              category: "tracking", source: "managed-pack:official.privacy", detail: "")
        }
        let limits = TrafficGraphLimits(maxApps: 8, maxDestinations: 10, maxEdges: 28, maxBlockedEdges: 12)

        let snapshot = TrafficGraphBuilder.build(rows: observed, blockedAttempts: blocked, limits: limits)

        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .app }.count, limits.maxApps)
        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .destination }.count, limits.maxDestinations)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .blocked }.count, 5)
        XCTAssertGreaterThan(snapshot.hidden.edgeCount, 0)
    }

    func testBlockedReserveStillLeavesOneRelationshipForEveryTopTrafficApp() {
        let observed = (0..<8).map { index in
            row(app: "app.\(index)", domain: "observed-\(index).example", ip: "203.0.113.\(index + 1)",
                bytesIn: Int64(1_000 - index))
        }
        let blocked = (0..<6).map { index in
            BlockedAttemptRow(bundleID: "app.\(index)", appName: "App \(index)", agentKey: "", agentName: "",
                              destination: "blocked-\(index).example", port: 443, count: Int64(20 - index),
                              category: "tracking", source: "managed-pack:official.privacy", detail: "")
        }

        let snapshot = TrafficGraphBuilder.build(rows: observed, blockedAttempts: blocked)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 8)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 8)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .blocked }.count, 5)
    }

    func testBlockedSelectionExpandsToAgentsAdmittedByObservedTraffic() {
        let agents = ["claude", "codex", "aider"]
        let observed = (0..<3).map { index in
            row(app: agents[index], name: agents[index], domain: "api-\(index).example",
                ip: "203.0.113.\(index + 1)", bytesIn: Int64(1_000 - index))
        }
        let blocked = (0..<3).map { index in
            BlockedAttemptRow(bundleID: agents[index], appName: agents[index], agentKey: agents[index],
                              agentName: agents[index], destination: "blocked-\(index).example", port: 443,
                              count: Int64(30 - index),
                              category: "tracking", source: "managed-pack:official.privacy", detail: "")
        }
        let limits = AITrafficGraphLimits(maxAgents: 6, maxTools: 8, maxDestinations: 10,
                                          maxObservedEdges: 28, maxBlockedEdges: 12)

        let snapshot = AITrafficGraphBuilder.build(rows: observed, blockedAttempts: blocked, limits: limits)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .agent }.count, 3)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .blocked }.count, 3,
                       "every visible agent's refusal should use the available blocked budget")
    }

    func testBlockedOnlyAppsCannotStarveBusyObservedTraffic() {
        let observed = row(app: "busy.app", name: "Busy", domain: "api.example.com",
                           ip: "203.0.113.8", bytesIn: 1_000_000)
        let blocked = (0..<8).map { index in
            BlockedAttemptRow(bundleID: "blocked.\(index)", appName: "Blocked \(index)", agentKey: "", agentName: "",
                              destination: "tracker-\(index).example", port: 443, count: Int64(100 - index),
                              category: "tracking", source: "managed-pack:test", detail: "")
        }
        let limits = TrafficGraphLimits(maxApps: 8, maxDestinations: 10, maxEdges: 28,
                                        maxBlockedEdges: 12, maxRelays: 6)

        let snapshot = TrafficGraphBuilder.build(rows: [observed], blockedAttempts: blocked, limits: limits)

        XCTAssertTrue(snapshot.edges.contains { $0.relationship == .observed && $0.filter.bundleID == "busy.app" })
        XCTAssertLessThanOrEqual(snapshot.nodes.filter { $0.kind == .app }.count, limits.maxApps)
    }

    func testProxyNodesRespectIntermediaryBudget() {
        let rows = (0..<8).map { index -> BreakdownRow in
            var result = row(app: "app.\(index)", domain: "api-\(index).example", ip: "203.0.113.\(index + 1)",
                             bytesIn: Int64(100 - index))
            result.routeProxyBundleID = "proxy.\(index)"
            result.routeProxyName = "Proxy \(index)"
            return result
        }
        let limits = TrafficGraphLimits(maxApps: 8, maxDestinations: 10, maxEdges: 28,
                                        maxBlockedEdges: 12, maxRelays: 3)

        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: limits)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .proxy }.count, 3)
        XCTAssertGreaterThan(snapshot.hidden.edgeCount, 0)
        XCTAssertGreaterThan(snapshot.hidden.counters.total, 0)
    }

    func testBuilderAggregatesDuplicateExactRelationships() {
        let rows = [
            row(app: "com.example.browser", name: "Browser", path: "/Applications/Browser.app/Contents/MacOS/Browser",
                domain: "api.example.com", ip: "203.0.113.8", bytesIn: 900, bytesOut: 100, flows: 2),
            row(app: "com.example.browser", name: "Browser", path: "/Applications/Browser.app/Contents/MacOS/Browser",
                domain: "api.example.com", ip: "203.0.113.8", bytesIn: 100, bytesOut: 40, flows: 1)
        ]

        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 1)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 1)
        XCTAssertEqual(snapshot.edges.count, 1)
        XCTAssertEqual(snapshot.edges[0].counters, FlowCounters(bytesIn: 1_000, bytesOut: 140, flows: 3))
        XCTAssertEqual(snapshot.total, FlowCounters(bytesIn: 1_000, bytesOut: 140, flows: 3))
    }

    func testDestinationGroupsSubdomainsAndPreservesExactMembers() {
        let rows = [
            row(app: "a", domain: "api.example.com", ip: "203.0.113.8", bytesIn: 10),
            row(app: "a", domain: "deep.api.example.com", ip: "203.0.113.9", bytesIn: 20),
            row(app: "a", domain: "cdn.example.com", ip: "203.0.113.10", bytesIn: 30),
            row(app: "a", domain: "api.example.co.uk", ip: "203.0.113.11", bytesIn: 40)
        ]

        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let destinations = snapshot.nodes.filter { $0.kind == .destination }

        XCTAssertEqual(destinations.count, 2)
        let example = try! XCTUnwrap(destinations.first { $0.title == "example.com" })
        XCTAssertEqual(example.filter.domainSuffix, "example.com")
        XCTAssertNil(example.filter.domain)
        XCTAssertEqual(example.counters.bytesIn, 60)
        XCTAssertEqual(Set(example.members.map(\.filter.domain)),
                       ["api.example.com", "deep.api.example.com", "cdn.example.com"])
        XCTAssertEqual(Set(example.members.compactMap(\.filter.remoteIP)),
                       ["203.0.113.8", "203.0.113.9", "203.0.113.10"])
        XCTAssertEqual(destinations.first { $0.title == "example.co.uk" }?.filter.domainSuffix, "example.co.uk")
        XCTAssertEqual(snapshot.edges.count, 2)
        XCTAssertEqual(snapshot.edges.first { $0.target == example.id }?.members.count, 3)
    }

    func testHostedTenantsRemainSeparateDomainFamilies() {
        for hosts in [
            ["alice.github.io", "bob.github.io"],
            ["alice.appspot.com", "bob.appspot.com"]
        ] {
            let snapshot = TrafficGraphBuilder.build(rows: [
                row(app: "a", domain: hosts[0], ip: "203.0.113.8", bytesIn: 10),
                row(app: "a", domain: hosts[1], ip: "203.0.113.9", bytesIn: 20)
            ], limits: .unbounded)
            let destinations = snapshot.nodes.filter { $0.kind == .destination }

            XCTAssertEqual(Set(destinations.map(\.title)), Set(hosts))
            XCTAssertEqual(Set(destinations.compactMap(\.filter.domainSuffix)), Set(hosts))
            XCTAssertEqual(snapshot.edges.count, 2)
        }
    }

    func testExactMembersPreserveProtocolAndChannelScope() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "api.example.com", ip: "203.0.113.8", bytesIn: 10,
                protocol: "https", channel: .ip),
            row(app: "a", domain: "api.example.com", ip: "203.0.113.8", bytesIn: 20,
                protocol: "quic", channel: .tunnel)
        ], limits: .unbounded)
        let members = try! XCTUnwrap(snapshot.edges.first).members

        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(Set(members.compactMap(\.filter.appProtocol)), ["https", "quic"])
        XCTAssertEqual(Set(members.compactMap(\.filter.channel)), [.ip, .tunnel])
    }

    func testHostnameLessDestinationsRemainExactByAddress() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "", ip: "203.0.113.8", owner: "Example Network", bytesIn: 10),
            row(app: "a", domain: "", ip: "203.0.113.9", owner: "Example Network", bytesIn: 20)
        ], limits: .unbounded)

        let destinations = snapshot.nodes.filter { $0.kind == .destination }
        XCTAssertEqual(destinations.count, 2)
        XCTAssertEqual(Set(destinations.compactMap(\.filter.remoteIP)), ["203.0.113.8", "203.0.113.9"])
    }

    func testAppIdentityUsesBundleIDRatherThanChangingDisplayMetadata() {
        let rows = [
            row(app: "a", name: "Old Name", path: "/tmp/tool", domain: "one.example", ip: "203.0.113.8", bytesIn: 10),
            row(app: "a", name: "Better Name", path: "/Applications/Better.app/Contents/MacOS/Better",
                domain: "two.example", ip: "203.0.113.9", bytesIn: 20)
        ]

        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let app = snapshot.nodes.filter { $0.kind == .app }

        XCTAssertEqual(app.count, 1)
        XCTAssertEqual(Set(snapshot.edges.map(\.source)).count, 1)
        XCTAssertEqual(app[0].filter.bundleID, "a")
        XCTAssertEqual(app[0].title, "Better Name")
    }

    func testAppMetadataUsesAvailableNameAndPathAcrossRows() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", name: "", path: "", domain: "busy.example", ip: "203.0.113.8", bytesIn: 1_000),
            row(app: "a", name: "Foo", path: "/Applications/Foo.app/Contents/MacOS/Foo",
                domain: "quiet.example", ip: "203.0.113.9", bytesIn: 10)
        ], limits: .unbounded)

        let app = try! XCTUnwrap(snapshot.nodes.first { $0.kind == .app })
        XCTAssertEqual(app.title, "Foo")
        XCTAssertEqual(app.appPath, "/Applications/Foo.app/Contents/MacOS/Foo")
    }

    func testStableIDsIgnoreTrafficCounterChanges() {
        let first = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "example.com", ip: "203.0.113.8", bytesIn: 10)
        ], limits: .unbounded)
        let second = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "example.com", ip: "203.0.113.8", bytesIn: 9_999, bytesOut: 4_000, flows: 20)
        ], limits: .unbounded)

        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), second.edges.map(\.id))
    }

    func testCapsChooseConnectedRelationshipsRatherThanDisjointRankings() {
        let rows = [
            row(app: "a", domain: "two.example", ip: "203.0.113.2", bytesIn: 50),
            row(app: "a", domain: "three.example", ip: "203.0.113.3", bytesIn: 50),
            row(app: "b", domain: "one.example", ip: "203.0.113.1", bytesIn: 45),
            row(app: "c", domain: "one.example", ip: "203.0.113.1", bytesIn: 45)
        ]

        let snapshot = TrafficGraphBuilder.build(
            rows: rows,
            limits: TrafficGraphLimits(maxApps: 1, maxDestinations: 1, maxEdges: 1)
        )

        XCTAssertEqual(snapshot.edges.count, 1)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 1)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 1)
        XCTAssertEqual(snapshot.edges[0].counters.bytesIn, 50)
    }

    func testTrafficAppCapRanksByWholeAppTotal() throws {
        let snapshot = TrafficGraphBuilder.build(
            rows: [
                row(app: "fragmented", domain: "one.example", ip: "203.0.113.1", bytesIn: 60),
                row(app: "fragmented", domain: "two.example", ip: "203.0.113.2", bytesIn: 60),
                row(app: "single", domain: "three.example", ip: "203.0.113.3", bytesIn: 100)
            ],
            limits: TrafficGraphLimits(maxApps: 1, maxDestinations: 2, maxEdges: 2)
        )

        let app = try XCTUnwrap(snapshot.nodes.first { $0.kind == .app })
        XCTAssertEqual(app.filter.bundleID, "fragmented")
        XCTAssertEqual(app.counters.bytesIn, 120)
    }

    func testTrafficAppNodeReportsWholePeriodTotalWhenRelationshipsAreHidden() throws {
        let snapshot = TrafficGraphBuilder.build(
            rows: [
                row(app: "app", domain: "one.example", ip: "203.0.113.1", bytesIn: 60),
                row(app: "app", domain: "two.example", ip: "203.0.113.2", bytesIn: 40)
            ],
            limits: TrafficGraphLimits(maxApps: 1, maxDestinations: 1, maxEdges: 1)
        )

        let app = try XCTUnwrap(snapshot.nodes.first { $0.kind == .app })
        let observed = try XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })
        XCTAssertEqual(app.counters.bytesIn, 100)
        XCTAssertEqual(observed.counters.bytesIn, 60)
        XCTAssertEqual(snapshot.hidden.counters.bytesIn, 40)
    }

    func testTopTrafficAppsReceiveRepresentativeRelationshipsBeforeSpareEdges() {
        let snapshot = TrafficGraphBuilder.build(
            rows: [
                row(app: "fragmented", domain: "one.example", ip: "203.0.113.1", bytesIn: 60),
                row(app: "fragmented", domain: "two.example", ip: "203.0.113.2", bytesIn: 60),
                row(app: "single", domain: "three.example", ip: "203.0.113.3", bytesIn: 100),
                row(app: "lower", domain: "four.example", ip: "203.0.113.4", bytesIn: 90)
            ],
            limits: TrafficGraphLimits(maxApps: 2, maxDestinations: 2, maxEdges: 2)
        )

        let apps = Set(snapshot.nodes.filter { $0.kind == .app }.compactMap(\.filter.bundleID))
        XCTAssertEqual(apps, ["fragmented", "single"])
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 2)
    }

    func testRepresentativeSelectionReconsidersBusyEdgeToShareDestinationCapacity() {
        let snapshot = TrafficGraphBuilder.build(
            rows: [
                row(app: "a", domain: "one.example", ip: "203.0.113.1", bytesIn: 100),
                row(app: "a", domain: "shared.example", ip: "203.0.113.2", bytesIn: 90),
                row(app: "b", domain: "shared.example", ip: "203.0.113.2", bytesIn: 95)
            ],
            limits: TrafficGraphLimits(
                maxApps: 2, maxDestinations: 1, maxEdges: 2,
                maxBlockedEdges: 0, maxRelays: 0
            )
        )

        let apps = Set(snapshot.nodes.filter { $0.kind == .app }.compactMap(\.filter.bundleID))
        let observed = snapshot.edges.filter { $0.relationship == .observed }
        XCTAssertEqual(apps, ["a", "b"])
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(Set(observed.map(\.target)).count, 1)
    }

    func testRepresentativeSelectionReconsidersBusyEdgeToShareRelayCapacity() {
        var first = row(app: "a", domain: "one.example", ip: "203.0.113.1", bytesIn: 100)
        first.routeProxyBundleID = "proxy.one"
        var sharedA = row(app: "a", domain: "two.example", ip: "203.0.113.2", bytesIn: 90)
        sharedA.routeProxyBundleID = "proxy.shared"
        var sharedB = row(app: "b", domain: "three.example", ip: "203.0.113.3", bytesIn: 95)
        sharedB.routeProxyBundleID = "proxy.shared"

        let snapshot = TrafficGraphBuilder.build(
            rows: [first, sharedA, sharedB],
            limits: TrafficGraphLimits(
                maxApps: 2, maxDestinations: 3, maxEdges: 2,
                maxBlockedEdges: 0, maxRelays: 1
            )
        )

        let apps = Set(snapshot.nodes.filter { $0.kind == .app }.compactMap(\.filter.bundleID))
        let relays = snapshot.nodes.filter { $0.kind == .proxy }
        XCTAssertEqual(apps, ["a", "b"])
        XCTAssertEqual(relays.count, 1)
        XCTAssertEqual(relays[0].id.rawValue, "proxy:12:proxy.shared")
    }

    func testStandardTrafficCapKeepsEveryTopAppBehindDistinctRelays() {
        let rows = (0..<8).map { index -> BreakdownRow in
            var result = row(
                app: "app.\(index)", domain: "host-\(index).example", ip: "203.0.113.\(index + 1)",
                bytesIn: Int64(1_000 - index)
            )
            result.routeProxyBundleID = "proxy.\(index)"
            result.routeProxyName = "Proxy \(index)"
            return result
        }

        let snapshot = TrafficGraphBuilder.build(rows: rows)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 8)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .proxy }.count, 8)
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .observed }.count, 8)
    }

    func testFlowlightApplicationAndObservedRouteCoalesceWithoutLosingEvidence() throws {
        let own = row(app: "com.flowlight.app", name: "Flowlight", domain: "updates.example",
                      ip: "203.0.113.10", bytesIn: 25)
        var routed = row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                         ip: "203.0.113.11", bytesOut: 75)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        let direct = row(app: "claude", name: "Claude Code", domain: "direct.example",
                         ip: "203.0.113.12", bytesOut: 1_000)

        let snapshot = TrafficGraphBuilder.build(rows: [own, routed, direct], limits: .unbounded)
        let flowlightNodes = snapshot.nodes.filter {
            [.app, .proxy].contains($0.kind)
                && ($0.filter.bundleID == "com.flowlight.app"
                    || $0.filter.bundleIDs.contains("com.flowlight.app"))
        }
        let flowlight = try XCTUnwrap(flowlightNodes.first)
        let route = try XCTUnwrap(snapshot.edges.first {
            $0.relationship == .routedThrough && $0.target == flowlight.id
        })
        let observed = snapshot.edges.filter {
            $0.relationship == .observed && $0.source == flowlight.id
        }
        let page = TrafficGraphListPager.page(in: snapshot, visibleCount: 25)

        XCTAssertEqual(flowlightNodes.count, 1)
        XCTAssertEqual(flowlight.kind, .app)
        XCTAssertEqual(flowlight.counters.bytesIn, 25)
        XCTAssertEqual(flowlight.counters.bytesOut, 75)
        XCTAssertEqual(flowlight.filter.bundleID, "com.flowlight.app")
        XCTAssertFalse(flowlight.isFilterExact)
        XCTAssertTrue(flowlight.roleEvidence.contains { $0.relationship == .routedThrough })
        XCTAssertFalse(page.roleItems.contains { $0.evidence.relationship == .routedThrough })
        XCTAssertEqual(page.edges.filter { $0.relationship == .routedThrough }.count, 1)
        XCTAssertEqual(route.counters.total, 0)
        XCTAssertEqual(route.displayedCounters.bytesOut, 75)
        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(Set(observed.flatMap(\.members).compactMap(\.filter.bundleID)),
                       ["com.flowlight.app", "claude"])
        XCTAssertFalse(snapshot.edges.contains { $0.source == $0.target })
        XCTAssertEqual(Set(snapshot.nodes.map(\.id)).count, snapshot.nodes.count)
        XCTAssertEqual(snapshot.total.total, 1_100)
        XCTAssertEqual(snapshot.visibleTotal.total, 1_100)
    }

    func testAIMapBoundsTheDefaultWithoutDiscardingCompleteListEvidence() {
        let rows = (0..<35).map { index in
            row(
                app: "claude",
                name: "Claude Code",
                domain: "quiet\(index).example",
                ip: "192.0.2.\(index)",
                bytesIn: Int64(index + 1),
                bytesOut: Int64(35 - index),
                flows: 1
            )
        }

        let build = AITrafficGraphBuilder.buildForPresentation(rows: rows)
        let reportTotal = rows.reduce(into: FlowCounters()) { $0 += $1.counters }

        XCTAssertEqual(build.complete.edges.filter { $0.relationship == .observed }.count, 35)
        XCTAssertEqual(build.complete.visibleTotal, reportTotal)
        XCTAssertTrue(build.map.representedNodeIDs.isSubset(of: Set(build.complete.nodes.map(\.id))))
        XCTAssertTrue(build.map.representedEdgeIDs.isSubset(of: Set(build.complete.edges.map(\.id))))
        XCTAssertEqual(build.map.visibleTotal.total + build.map.hidden.counters.total, reportTotal.total)
        XCTAssertGreaterThan(build.map.hidden.edgeCount, 0)
    }

    func testAIPresentationBuildRepresentsEveryDomainInCollapsedMapGroups() {
        let rows = (0..<35).map { index in
            row(
                app: "claude",
                name: "Claude Code",
                domain: "quiet\(index).example",
                ip: "192.0.2.\(index)",
                bytesOut: Int64(35 - index),
                flows: 1
            )
        }

        let build = AITrafficGraphBuilder.buildForPresentation(rows: rows)
        let completeNodeIDs = Set(build.complete.nodes.map(\.id))
        let completeEdgeIDs = Set(build.complete.edges.map(\.id))

        XCTAssertEqual(build.complete.edges.filter { $0.relationship == .observed }.count, 35)
        XCTAssertEqual(build.complete.nodes.filter { $0.kind == .destination }.count, 35)
        XCTAssertEqual(build.complete.hidden, .none)
        XCTAssertLessThan(build.map.nodes.filter { $0.kind == .destination }.count, 35)
        XCTAssertEqual(build.map.nodes.first { $0.kind == .agent }?.counters.total,
                       build.map.visibleTotal.total)
        XCTAssertTrue(build.map.representedNodeIDs.isSubset(of: completeNodeIDs))
        XCTAssertTrue(build.map.representedEdgeIDs.isSubset(of: completeEdgeIDs))
        XCTAssertEqual(build.map.hidden.edgeCount, 17)
        XCTAssertEqual(build.map.visibleTotal.total + build.map.hidden.counters.total,
                       build.complete.visibleTotal.total)
    }

    func testAISearchRevealsExactQuietDomainOnMap() {
        let rows = (0..<11).map { index in
            row(
                app: "claude",
                name: "Claude Code",
                domain: "quiet\(index).example",
                ip: "192.0.2.\(index)",
                bytesOut: Int64(11 - index),
                flows: 1
            )
        }
        let full = AITrafficGraphBuilder.buildForPresentation(rows: rows)
        let quietRows = VisualizeEvidenceScope.rows(
            rows,
            query: "quiet10.example",
            focus: .none
        )
        let searched = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            visibleRows: quietRows
        )

        XCTAssertEqual(full.complete.edges.filter { $0.relationship == .observed }.count, 11)
        XCTAssertEqual(full.map.representedEdgeIDs, Set(full.complete.edges.map(\.id)))
        XCTAssertEqual(quietRows.count, 1)
        XCTAssertEqual(searched.complete.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertTrue(searched.complete.nodes.contains { $0.title == "quiet10.example" })
        XCTAssertTrue(searched.map.nodes.contains {
            $0.title == "quiet10.example" && !$0.isCollapsedGroup
        })
        XCTAssertEqual(searched.map.representedNodeIDs, Set(searched.complete.nodes.map(\.id)))
        XCTAssertEqual(searched.map.representedEdgeIDs, Set(searched.complete.edges.map(\.id)))
    }

    func testAIListRetainsTwentyNinthRelationshipAndFocusCanIsolateIt() {
        let rows = (0..<29).map { index in
            row(
                app: "claude",
                name: "Claude Code",
                domain: "focus\(index).example",
                ip: "198.51.100.\(index)",
                bytesIn: Int64(29 - index),
                flows: 1
            )
        }
        let limits = AITrafficGraphLimits(
            maxAgents: 1,
            maxTools: 0,
            maxDestinations: 29,
            maxObservedEdges: 28,
            maxLaunchers: 0,
            maxBlockedEdges: 0
        )
        let full = AITrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: limits)
        let page = TrafficGraphListPager.page(in: full.complete, visibleCount: 50)
        let focusedRows = VisualizeEvidenceScope.rows(
            rows,
            query: "",
            focus: FocusScope(hosts: ["focus28.example"])
        )
        let focused = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            visibleRows: focusedRows,
            mapLimits: limits
        )

        XCTAssertEqual(full.complete.edges.filter { $0.relationship == .observed }.count, 29)
        XCTAssertEqual(page.edges.filter { $0.relationship == .observed }.count, 29)
        XCTAssertEqual(full.map.edges.filter { $0.relationship == .observed }.count, 28)
        XCTAssertEqual(full.map.hidden.edgeCount, 1)
        XCTAssertEqual(full.map.hidden.counters.bytesIn, 1)
        XCTAssertEqual(focusedRows.count, 1)
        XCTAssertEqual(focused.complete.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertTrue(focused.complete.nodes.contains { $0.title == "focus28.example" })
    }

    func testRouteProxyFocusRetainsTrafficOwnedByAnotherApplication() {
        let routed = row(
            app: "claude",
            name: "Claude Code",
            domain: "api.anthropic.com",
            ip: "192.0.2.1",
            bytesOut: 10,
            flows: 1,
            relay: ("com.flowlight.app", "Flowlight", "/Applications/Flowlight.app")
        )

        let focused = VisualizeEvidenceScope.rows(
            [routed],
            query: "",
            focus: FocusScope(bundleIDs: ["com.flowlight.app"])
        )

        XCTAssertEqual(focused.count, 1)
        XCTAssertEqual(focused.first?.bundleID, "claude")
        XCTAssertEqual(focused.first?.routeProxyBundleID, "com.flowlight.app")
    }

    func testConfiguredOnlyCoalescedGatewayRemainsInMapAndList() throws {
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "localhost", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(
            bundleID: "claude",
            name: "Claude Code",
            path: "/Applications/Claude Code.app"
        )

        let build = AITrafficGraphBuilder.buildForPresentation(
            rows: [],
            gateways: [gateway],
            resolveGateway: { _ in identity }
        )
        let node = try XCTUnwrap(build.complete.nodes.first)
        let page = TrafficGraphListPager.page(in: build.complete, visibleCount: 25)

        XCTAssertTrue(build.complete.edges.isEmpty)
        XCTAssertTrue(node.roleEvidence.contains { $0.relationship == .configuredGateway })
        XCTAssertEqual(build.map.nodes.map(\.id), [node.id])
        XCTAssertEqual(page.roleItems.count, 1)
        XCTAssertEqual(page.roleItems.first?.evidence.relationship, .configuredGateway)
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertEqual(TrafficGraphListPager.totalCount(in: build.complete), 1)
        XCTAssertEqual(
            TrafficGraphListPager.clampedVisibleCount(current: 25, in: build.complete),
            1,
            "role-only relationships must be visible on the initial List page"
        )
    }

    func testCoalescedRouteRespectsApplicationAndRelayCaps() {
        let own = row(
            app: "com.flowlight.app",
            name: "Flowlight",
            domain: "updates.example",
            ip: "192.0.2.10",
            bytesIn: 25,
            flows: 1
        )
        let routed = row(
            app: "claude",
            name: "Claude Code",
            domain: "api.anthropic.com",
            ip: "192.0.2.11",
            bytesOut: 75,
            flows: 1,
            relay: ("com.flowlight.app", "Flowlight", "/Applications/Flowlight.app")
        )
        let limits = TrafficGraphLimits(
            maxApps: 1,
            maxDestinations: 2,
            maxEdges: 2,
            maxBlockedEdges: 0,
            maxRelays: 0
        )

        let build = TrafficGraphBuilder.buildForPresentation(rows: [own, routed], mapLimits: limits)

        XCTAssertEqual(build.map.nodes.filter { $0.kind == .app }.count, 1)
        XCTAssertEqual(build.map.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertFalse(build.map.edges.contains { edge in
            edge.members.contains { $0.filter.bundleID == "claude" }
        })
    }

    func testConfiguredOnlyNodesRemainExactWithoutMapOmissions() {
        let gateways = (0..<7).map { index in
            AgentGatewayConfig(
                agent: "configured.\(index)",
                endpoint: .init(scheme: "http", host: "localhost", port: UInt16(3_400 + index)),
                source: "settings.\(index)",
                sourceKey: "gateway"
            )
        }
        let build = AITrafficGraphBuilder.buildForPresentation(
            rows: [],
            gateways: gateways,
            resolveGateway: { endpoint in
                guard let index = gateways.firstIndex(where: { $0.endpoint == endpoint }) else { return nil }
                return AgentGatewayIdentity(
                    bundleID: "configured.\(index)",
                    name: "Configured \(index)",
                    path: ""
                )
            }
        )

        XCTAssertEqual(build.complete.nodes.count, 7)
        XCTAssertEqual(build.map.nodes.count, 7)
        XCTAssertEqual(build.map.representedNodeIDs, Set(build.complete.nodes.map(\.id)))
        XCTAssertEqual(build.map.hidden, .none)
    }

    func testMapDestinationCountersAndMembersExcludeOmittedRelationships() throws {
        let rows = (0..<20).map { index in
            row(
                app: "app.\(index)",
                domain: "shared.example",
                ip: "203.0.113.10",
                bytesIn: 1,
                flows: 1
            )
        }
        let limits = TrafficGraphLimits(
            maxApps: 8,
            maxDestinations: 1,
            maxEdges: 20,
            maxBlockedEdges: 0,
            maxRelays: 0
        )
        let build = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: limits)
        let destination = try XCTUnwrap(build.map.nodes.first { $0.kind == .destination })

        XCTAssertEqual(build.map.visibleTotal.bytesIn, 8)
        XCTAssertEqual(destination.counters.bytesIn, build.map.visibleTotal.bytesIn)
        XCTAssertEqual(destination.members.count, 8)
        XCTAssertEqual(build.map.hidden.counters.bytesIn, 12)
    }

    func testSharedToolTrafficSurvivesMoreParentsThanAgentCap() {
        let toolID = TrafficGraphNodeID(rawValue: "tool:shared")
        let destinationID = TrafficGraphNodeID(rawValue: "destination:shared")
        let agentIDs = (0..<7).map { TrafficGraphNodeID(rawValue: "agent:\($0)") }
        let agents = agentIDs.enumerated().map { index, id in
            TrafficGraphNode(
                id: id,
                kind: .agent,
                title: "Agent \(index)",
                detail: "agent.\(index)",
                appPath: "",
                filter: TrafficFilter(bundleID: "agent.\(index)"),
                counters: FlowCounters(bytesOut: 1, flows: 1)
            )
        }
        let tool = TrafficGraphNode(
            id: toolID,
            kind: .tool,
            title: "Shared tool",
            detail: "",
            appPath: "",
            filter: TrafficFilter(bundleID: "tool.shared"),
            counters: FlowCounters(bytesOut: 7, flows: 7)
        )
        let destination = TrafficGraphNode(
            id: destinationID,
            kind: .destination,
            title: "shared.example",
            detail: "",
            appPath: "",
            filter: TrafficFilter(domain: "shared.example"),
            counters: FlowCounters(bytesOut: 7, flows: 7)
        )
        let members = agentIDs.enumerated().map { index, _ in
            TrafficGraphMember(
                id: "member.\(index)",
                title: "shared.example",
                detail: "",
                filter: TrafficFilter(bundleID: "tool.shared", agentParent: "agent.\(index)"),
                counters: FlowCounters(bytesOut: 1, flows: 1),
                protocols: "https",
                channel: .ip
            )
        }
        let observed = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "tool→observed→destination"),
            source: toolID,
            target: destinationID,
            counters: FlowCounters(bytesOut: 7, flows: 7),
            filter: .none,
            members: members
        )
        let runs = agentIDs.map { agentID in
            TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: agentID.rawValue + "→runs→tool"),
                source: agentID,
                target: toolID,
                counters: FlowCounters(),
                filter: .none,
                relationship: .runs
            )
        }
        let complete = TrafficGraphSnapshot(
            nodes: agents + [tool, destination],
            edges: [observed] + runs,
            total: observed.counters,
            hidden: .none
        )
        let limits = AITrafficGraphLimits(
            maxAgents: 6,
            maxTools: 1,
            maxDestinations: 1,
            maxObservedEdges: 1,
            maxLaunchers: 0,
            maxBlockedEdges: 0
        )

        let map = TrafficGraphMapProjector.project(complete, limits: limits)

        XCTAssertTrue(map.edges.contains { $0.id == observed.id })
        XCTAssertEqual(map.edges.filter { $0.relationship == .runs }.count, 6)
        XCTAssertEqual(map.nodes.filter { $0.kind == .agent }.count, 6)
    }

    func testMapPresentationClearsListOnlySelection() {
        let visibleEdge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "visible"),
            source: TrafficGraphNodeID(rawValue: "source"),
            target: TrafficGraphNodeID(rawValue: "target"),
            counters: FlowCounters(),
            filter: .none
        )
        let map = TrafficGraphSnapshot(nodes: [], edges: [visibleEdge], total: FlowCounters(), hidden: .none)

        XCTAssertTrue(VisualizeSelectionPolicy.mapOmitsSelection(
            selectedNode: nil,
            selectedEdge: TrafficGraphEdgeID(rawValue: "list-only"),
            map: map
        ))
        XCTAssertFalse(VisualizeSelectionPolicy.mapOmitsSelection(
            selectedNode: nil,
            selectedEdge: visibleEdge.id,
            map: map
        ))
    }

    func testMapSelectionResolvesProjectedNodeInsteadOfCompleteNode() throws {
        let rows = (0..<20).map { index in
            row(
                app: "app.\(index)",
                domain: "shared.example",
                ip: "203.0.113.10",
                bytesIn: 1,
                flows: 1
            )
        }
        let limits = TrafficGraphLimits(
            maxApps: 8,
            maxDestinations: 1,
            maxEdges: 20,
            maxBlockedEdges: 0,
            maxRelays: 0
        )
        let build = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: limits)
        let selectedID = try XCTUnwrap(build.map.nodes.first { $0.kind == .destination }?.id)

        let mapNode = try XCTUnwrap(VisualizeSelectionPolicy.selectedNode(selectedID, in: build.map))
        let listNode = try XCTUnwrap(VisualizeSelectionPolicy.selectedNode(selectedID, in: build.complete))

        XCTAssertEqual(mapNode.counters.bytesIn, 8)
        XCTAssertEqual(mapNode.members.count, 8)
        XCTAssertEqual(listNode.counters.bytesIn, 20)
        XCTAssertEqual(listNode.members.count, 20)
    }

    func testListPresentationClearsOrdinaryNodeSelectionButKeepsVisibleRows() {
        let ordinary = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "destination:ordinary"),
            kind: .destination,
            title: "ordinary.example",
            detail: "",
            appPath: "",
            filter: TrafficFilter(domain: "ordinary.example"),
            counters: FlowCounters()
        )
        let evidenced = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "agent:evidenced"),
            kind: .agent,
            title: "Evidenced",
            detail: "agent.evidenced",
            appPath: "",
            filter: TrafficFilter(bundleID: "agent.evidenced"),
            counters: FlowCounters(),
            roleEvidence: [TrafficGraphRoleEvidence(relationship: .runs, detail: "Observed agent")]
        )
        let visibleEdge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "visible"),
            source: ordinary.id,
            target: evidenced.id,
            counters: FlowCounters(),
            filter: .none
        )
        let complete = TrafficGraphSnapshot(
            nodes: [ordinary, evidenced],
            edges: [visibleEdge],
            total: FlowCounters(),
            hidden: .none
        )

        XCTAssertTrue(VisualizeSelectionPolicy.listOmitsSelection(
            selectedNode: ordinary.id,
            selectedEdge: nil,
            complete: complete
        ))
        XCTAssertFalse(VisualizeSelectionPolicy.listOmitsSelection(
            selectedNode: evidenced.id,
            selectedEdge: nil,
            complete: complete
        ))
        XCTAssertFalse(VisualizeSelectionPolicy.listOmitsSelection(
            selectedNode: nil,
            selectedEdge: visibleEdge.id,
            complete: complete
        ))
    }

    func testEndpointProjectionDefaultsToTenTrafficSourcesRankedByAggregateTraffic() throws {
        let rows = (0..<12).flatMap { app in
            (0..<2).map { destination in
                row(
                    app: "app.\(app)",
                    name: "App \(app)",
                    domain: "host\(destination).example",
                    ip: "203.0.113.\(destination)",
                    bytesOut: Int64(app + 1),
                    flows: 1
                )
            }
        }
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete

        let map = TrafficGraphEndpointProjector.defaultMap(complete, sourceLimit: 10)
        let visibleSources = Set(map.nodes.compactMap { node in
            node.kind == .app ? node.filter.bundleID : nil
        })

        XCTAssertEqual(visibleSources.count, 10)
        XCTAssertFalse(visibleSources.contains("app.0"))
        XCTAssertFalse(visibleSources.contains("app.1"))
        XCTAssertTrue(visibleSources.contains("app.11"))
        XCTAssertEqual(complete.edges.filter { $0.relationship == .observed }.count, 24,
                       "the exact snapshot used by List and Reports must remain exhaustive")
    }

    func testEndpointProjectionRanksTrafficTiesByStableIdentity() {
        let rows = (0..<11).map { index in
            row(app: "app.\(String(format: "%02d", index))",
                domain: "host\(index).example", ip: "192.0.2.\(index)", bytesOut: 10)
        }
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete

        let first = TrafficGraphEndpointProjector.defaultMap(complete, sourceLimit: 10)
        let reversed = TrafficGraphEndpointProjector.defaultMap(
            TrafficGraphBuilder.buildForPresentation(rows: rows.reversed(), mapLimits: .unbounded).complete,
            sourceLimit: 10
        )
        let firstIDs = first.nodes.filter { $0.kind == .app }.map(\.id)

        XCTAssertEqual(firstIDs, reversed.nodes.filter { $0.kind == .app }.map(\.id))
        XCTAssertFalse(first.nodes.contains { $0.filter.bundleID == "app.10" },
                       "the stable ID tie-break must omit the same eleventh source on every rebuild")
    }

    func testEndpointProjectionRanksAIRootsByAttributedAggregateTraffic() throws {
        var rows = (0..<11).map { index in
            row(app: "tool.\(index)", domain: "host\(index).example",
                ip: "198.51.100.\(index)", bytesOut: Int64(100 - index),
                parent: "agent.\(index)", parentName: "Agent \(index)")
        }
        rows.append(row(app: "node", domain: "child.example", ip: "198.51.100.200",
                        bytesOut: 1_000, parent: "agent.10", parentName: "Agent 10"))
        let complete = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded
        ).complete

        let options = TrafficGraphEndpointProjector.sourceOptions(in: complete)
        let quietRoot = try XCTUnwrap(options.first { option in
            complete.nodes.first { $0.id == option.id }?.filter.bundleID == "agent.10"
        })
        let map = TrafficGraphEndpointProjector.defaultMap(complete, sourceLimit: 10)

        XCTAssertEqual(quietRoot.counters.bytesOut, 1_090)
        XCTAssertTrue(map.nodes.contains { $0.filter.bundleID == "agent.10" },
                      "attributed child traffic must rank under its proved AI root")
        XCTAssertEqual(map.nodes.filter { $0.kind == .agent }.count, 10)
    }

    func testEndpointProjectionSupportsAllFourSourceDestinationScopes() throws {
        let rows = [
            row(app: "app.one", domain: "one.example", ip: "203.0.113.1", bytesOut: 10),
            row(app: "app.one", domain: "two.example", ip: "203.0.113.2", bytesOut: 20),
            row(app: "app.two", domain: "one.example", ip: "203.0.113.1", bytesOut: 30),
            row(app: "app.two", domain: "two.example", ip: "203.0.113.2", bytesOut: 40),
        ]
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete
        let source = try XCTUnwrap(complete.nodes.first { $0.filter.bundleID == "app.one" }?.id)
        let destination = try XCTUnwrap(complete.nodes.first { $0.title == "one.example" }?.id)

        let anyToAny = TrafficGraphEndpointProjector.scope(complete, query: .init())
        let sourceToAny = TrafficGraphEndpointProjector.scope(complete, query: .init(source: source))
        let anyToDestination = TrafficGraphEndpointProjector.scope(
            complete, query: .init(destination: destination)
        )
        let exact = TrafficGraphEndpointProjector.scope(
            complete, query: .init(source: source, destination: destination)
        )

        XCTAssertEqual(anyToAny.edges.filter { $0.relationship == .observed }.count, 4)
        XCTAssertEqual(sourceToAny.edges.filter { $0.relationship == .observed }.count, 2)
        XCTAssertEqual(anyToDestination.edges.filter { $0.relationship == .observed }.count, 2)
        XCTAssertEqual(exact.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertEqual(exact.visibleTotal.bytesOut, 10)
        XCTAssertEqual(TrafficGraphListPager.page(in: exact, visibleCount: 25).edges.count,
                       exact.edges.count, "List must retain every exact relationship in the selected scope")
    }

    func testEndpointOptionsMutuallyFilterByTheOppositeSelection() throws {
        let rows = [
            row(app: "app.one", domain: "one.example", ip: "203.0.113.1", bytesOut: 10),
            row(app: "app.one", domain: "shared.example", ip: "203.0.113.2", bytesOut: 20),
            row(app: "app.two", domain: "shared.example", ip: "203.0.113.2", bytesOut: 30),
            row(app: "app.two", domain: "two.example", ip: "203.0.113.3", bytesOut: 40)
        ]
        let evidence = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete
        let appOne = try XCTUnwrap(evidence.nodes.first { $0.filter.bundleID == "app.one" }?.id)
        let oneDestination = try XCTUnwrap(evidence.nodes.first { $0.title == "one.example" }?.id)

        let compatibleSources = TrafficGraphEndpointProjector.sourceOptions(
            in: evidence,
            matchingDestination: oneDestination
        )
        let compatibleDestinations = TrafficGraphEndpointProjector.destinationOptions(
            in: evidence,
            matchingSource: appOne
        )
        let destinationFocused = TrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded,
            endpointQuery: .init(destination: oneDestination)
        )
        let sourceFocused = TrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded,
            endpointQuery: .init(source: appOne)
        )

        XCTAssertEqual(compatibleSources.map(\.id), [appOne])
        XCTAssertEqual(Set(compatibleDestinations.map(\.title)), ["one.example", "shared.example"])
        XCTAssertEqual(destinationFocused.sourceOptions.map(\.id), [appOne])
        XCTAssertEqual(Set(sourceFocused.destinationOptions.map(\.title)), ["one.example", "shared.example"])
    }

    func testEndpointProjectionSupportsMultipleSourcesAndDestinations() throws {
        let rows = [
            row(app: "app.one", domain: "one.example", ip: "203.0.113.1", bytesOut: 10),
            row(app: "app.one", domain: "shared.example", ip: "203.0.113.2", bytesOut: 20),
            row(app: "app.two", domain: "one.example", ip: "203.0.113.1", bytesOut: 30),
            row(app: "app.two", domain: "shared.example", ip: "203.0.113.2", bytesOut: 40),
            row(app: "app.three", domain: "shared.example", ip: "203.0.113.2", bytesOut: 50)
        ]
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete
        let appOne = try XCTUnwrap(complete.nodes.first { $0.filter.bundleID == "app.one" }?.id)
        let appTwo = try XCTUnwrap(complete.nodes.first { $0.filter.bundleID == "app.two" }?.id)
        let appThree = try XCTUnwrap(complete.nodes.first { $0.filter.bundleID == "app.three" }?.id)
        let one = try XCTUnwrap(complete.nodes.first { $0.title == "one.example" }?.id)
        let shared = try XCTUnwrap(complete.nodes.first { $0.title == "shared.example" }?.id)

        let query = TrafficGraphEndpointQuery(
            sources: [appOne, appTwo],
            destinations: [one, shared]
        )
        let scoped = TrafficGraphEndpointProjector.scope(complete, query: query)
        let compatibleSources = TrafficGraphEndpointProjector.sourceOptions(
            in: complete,
            matchingDestinations: [one, shared]
        )
        let compatibleDestinations = TrafficGraphEndpointProjector.destinationOptions(
            in: complete,
            matchingSources: [appOne, appTwo]
        )

        XCTAssertEqual(scoped.edges.filter { $0.relationship == .observed }.count, 4)
        XCTAssertEqual(scoped.visibleTotal.bytesOut, 100)
        XCTAssertEqual(Set(compatibleSources.map(\.id)), [appOne, appTwo])
        XCTAssertFalse(compatibleSources.contains { $0.id == appThree })
        XCTAssertEqual(Set(compatibleDestinations.map(\.id)), [one, shared])
    }

    func testEndpointMultiSelectionKeepsBlockedOnlyPairsCompatible() throws {
        let blocked = [
            BlockedAttemptRow(bundleID: "app.one", appName: "One", agentKey: "", agentName: "",
                              destination: "blocked.example", port: 443, count: 2,
                              category: "tracking", source: "managed-pack:test", detail: ""),
            BlockedAttemptRow(bundleID: "app.two", appName: "Two", agentKey: "", agentName: "",
                              destination: "blocked.example", port: 443, count: 3,
                              category: "tracking", source: "managed-pack:test", detail: "")
        ]
        let complete = TrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](), blockedAttempts: blocked, mapLimits: .unbounded
        ).complete
        let sources = Set(complete.nodes.filter { $0.kind == .app }.map(\.id))
        let destination = try XCTUnwrap(complete.nodes.first { $0.title == "blocked.example" }?.id)

        let options = TrafficGraphEndpointProjector.destinationOptions(
            in: complete,
            matchingSources: sources
        )
        let scoped = TrafficGraphEndpointProjector.scope(
            complete,
            query: TrafficGraphEndpointQuery(sources: sources, destinations: [destination])
        )

        XCTAssertEqual(options.map(\.id), [destination])
        XCTAssertEqual(options.first?.enforcementCount, 5)
        XCTAssertEqual(scoped.edges.filter { $0.relationship == .blocked }.count, 2)
    }

    func testEndpointProjectionKeepsASelectedQuietSourceAndDestinationExact() throws {
        let rows = (0..<12).map { index in
            row(app: "app.\(index)", domain: "host\(index).example",
                ip: "203.0.113.\(index)", bytesOut: Int64(100 - index))
        }
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete
        let quietSource = try XCTUnwrap(complete.nodes.first { $0.filter.bundleID == "app.11" }?.id)
        let quietDestination = try XCTUnwrap(complete.nodes.first { $0.title == "host11.example" }?.id)
        let defaultMap = TrafficGraphEndpointProjector.defaultMap(complete, sourceLimit: 10)
        let focused = TrafficGraphEndpointProjector.scope(
            complete,
            query: .init(source: quietSource, destination: quietDestination)
        )

        XCTAssertFalse(defaultMap.representedNodeIDs.contains(quietSource))
        XCTAssertTrue(focused.nodes.contains { $0.id == quietSource })
        XCTAssertTrue(focused.nodes.contains { $0.id == quietDestination })
        XCTAssertEqual(focused.edges.filter { $0.relationship == .observed }.count, 1)
        XCTAssertEqual(focused.hidden, .none)
    }

    func testDefaultEndpointMapBoundsDenseEdgesEvenWhenNodeKindsAreBelowGroupingThreshold() {
        let rows = (0..<12).flatMap { app in
            (0..<12).map { destination in
                row(app: "app.\(app)", domain: "host\(destination).example",
                    ip: "203.0.113.\(destination)", bytesOut: 1)
            }
        }

        let build = TrafficGraphBuilder.buildForPresentation(rows: rows)

        XCTAssertEqual(build.complete.edges.filter { $0.relationship == .observed }.count, 144)
        XCTAssertLessThanOrEqual(build.map.edges.filter { $0.relationship == .observed }.count, 40,
                                 "a dense 10×12 default must not bypass the effective edge cap")
        XCTAssertEqual(build.map.visibleTotal.total + build.map.hidden.counters.total,
                       build.complete.visibleTotal.total)
    }

    func testFocusedEndpointMapGroupsLargeNeighborhoodWithoutDroppingExactMembership() throws {
        let rows = (0..<35).map { index in
            row(app: "app.focused", domain: "host\(index).example",
                ip: "198.51.100.\(index)", bytesOut: Int64(index + 1))
        }
        let evidence = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: .unbounded).complete
        let source = try XCTUnwrap(evidence.nodes.first { $0.filter.bundleID == "app.focused" }?.id)

        let build = TrafficGraphBuilder.buildForPresentation(
            rows: rows,
            endpointQuery: .init(source: source)
        )

        XCTAssertLessThan(build.map.nodes.count, build.complete.nodes.count)
        XCTAssertEqual(build.map.representedNodeIDs, Set(build.complete.nodes.map(\.id)))
        XCTAssertEqual(build.map.representedEdgeIDs, Set(build.complete.edges.map(\.id)))
        XCTAssertEqual(build.map.visibleTotal, build.complete.visibleTotal)
        XCTAssertEqual(build.map.hidden, .none)
    }

    func testEndpointSelectorOptionsComeFromExactEvidenceNotTheDefaultMap() {
        let rows = (0..<12).map { index in
            row(app: "app.\(index)", domain: "host\(index).example",
                ip: "192.0.2.\(index)", bytesOut: Int64(index + 1))
        }

        let build = TrafficGraphBuilder.buildForPresentation(rows: rows)

        XCTAssertEqual(build.sourceOptions.count, 12)
        XCTAssertEqual(build.destinationOptions.count, 12)
        XCTAssertEqual(build.map.nodes.filter { $0.kind == .app }.count, 10)
    }

    func testAIFocusedEndpointSeparatesSharedToolTrafficByParent() throws {
        let rows = [
            row(app: "node", name: "node", domain: "shared.example",
                ip: "203.0.113.10", bytesOut: 40,
                parent: "agent.one", parentName: "Agent One"),
            row(app: "node", name: "node", domain: "shared.example",
                ip: "203.0.113.11", bytesOut: 60,
                parent: "agent.two", parentName: "Agent Two")
        ]
        let evidence = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded
        )
        let agentOneOption = try XCTUnwrap(evidence.sourceOptions.first { option in
            evidence.complete.nodes.first { $0.id == option.id }?.filter.bundleID == "agent.one"
        })
        let agentTwoOption = try XCTUnwrap(evidence.sourceOptions.first { option in
            evidence.complete.nodes.first { $0.id == option.id }?.filter.bundleID == "agent.two"
        })
        XCTAssertEqual(agentOneOption.counters.bytesOut, 40)
        XCTAssertEqual(agentTwoOption.counters.bytesOut, 60)

        let focusedBuild = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded,
            endpointQuery: .init(source: agentOneOption.id)
        )
        let focused = focusedBuild.complete
        let observed = try XCTUnwrap(focused.edges.first { $0.relationship == .observed })

        XCTAssertEqual(focusedBuild.destinationOptions.count, 1)
        XCTAssertEqual(focusedBuild.destinationOptions.first?.counters.bytesOut, 40)
        XCTAssertEqual(focused.visibleTotal.bytesOut, 40)
        XCTAssertEqual(observed.counters.bytesOut, 40)
        XCTAssertEqual(Set(observed.members.compactMap(\.filter.agentParent)), ["agent.one"])
    }

    func testAIFocusedEndpointSeparatesSharedToolBlocksByParent() throws {
        let blocked = [
            BlockedAttemptRow(
                bundleID: "node", appName: "node", agentKey: "agent.one", agentName: "Agent One",
                destination: "shared.example", port: 443, count: 2,
                category: "tracking", source: "managed-pack:test", detail: "shared"
            ),
            BlockedAttemptRow(
                bundleID: "node", appName: "node", agentKey: "agent.two", agentName: "Agent Two",
                destination: "shared.example", port: 443, count: 3,
                category: "tracking", source: "managed-pack:test", detail: "shared"
            )
        ]
        let evidence = AITrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](),
            blockedAttempts: blocked,
            mapLimits: .unbounded
        )
        let agentOne = try XCTUnwrap(evidence.sourceOptions.first { option in
            evidence.complete.nodes.first { $0.id == option.id }?.filter.bundleID == "agent.one"
        })
        let agentTwo = try XCTUnwrap(evidence.sourceOptions.first { option in
            evidence.complete.nodes.first { $0.id == option.id }?.filter.bundleID == "agent.two"
        })

        let agentOneBuild = AITrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](), blockedAttempts: blocked, mapLimits: .unbounded,
            endpointQuery: .init(source: agentOne.id)
        )
        let agentTwoBuild = AITrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](), blockedAttempts: blocked, mapLimits: .unbounded,
            endpointQuery: .init(source: agentTwo.id)
        )

        XCTAssertEqual(agentOne.enforcementCount, 2)
        XCTAssertEqual(agentTwo.enforcementCount, 3)
        XCTAssertEqual(agentOneBuild.destinationOptions.first?.enforcementCount, 2)
        XCTAssertEqual(agentTwoBuild.destinationOptions.first?.enforcementCount, 3)
        XCTAssertEqual(agentOneBuild.complete.edges.first { $0.relationship == .blocked }?.enforcement?.count, 2)
        XCTAssertEqual(agentTwoBuild.complete.edges.first { $0.relationship == .blocked }?.enforcement?.count, 3)
    }

    func testBlockedOnlyTrafficPresentationRemainsSelectableAndBounded() {
        let blocked = (0..<30).map { index in
            BlockedAttemptRow(
                bundleID: "blocked.\(index)", appName: "Blocked \(index)",
                agentKey: "", agentName: "", destination: "tracker-\(index).example",
                port: 443, count: Int64(100 - index), category: "tracking",
                source: "managed-pack:test", detail: ""
            )
        }

        let build = TrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](),
            blockedAttempts: blocked
        )

        XCTAssertEqual(build.sourceOptions.count, 30)
        XCTAssertEqual(build.destinationOptions.count, 30)
        XCTAssertLessThanOrEqual(build.map.nodes.filter { $0.kind == .app }.count, 10)
        XCTAssertLessThanOrEqual(build.map.nodes.filter { $0.kind == .destination }.count, 18)
        XCTAssertLessThanOrEqual(build.map.edges.filter { $0.relationship == .blocked }.count, 12)
        XCTAssertGreaterThan(build.map.hidden.edgeCount, 0)
    }

    func testBlockedOnlyAIPresentationRemainsSelectableAndBounded() {
        let blocked = (0..<30).map { index in
            BlockedAttemptRow(
                bundleID: "claude", appName: "Claude Code", agentKey: "claude",
                agentName: "Claude Code", destination: "tracker-\(index).example",
                port: 443, count: Int64(100 - index), category: "tracking",
                source: "managed-pack:test", detail: ""
            )
        }

        let build = AITrafficGraphBuilder.buildForPresentation(
            rows: [BreakdownRow](),
            blockedAttempts: blocked
        )

        XCTAssertEqual(build.sourceOptions.count, 1)
        XCTAssertEqual(build.destinationOptions.count, 30)
        XCTAssertLessThanOrEqual(build.map.edges.filter { $0.relationship == .blocked }.count, 12)
        XCTAssertGreaterThan(build.map.hidden.edgeCount, 0)
    }

    func testEndpointSelectionPrunesOnlyOptionsThatDisappear() {
        let retained = TrafficGraphEndpointOption(
            id: TrafficGraphNodeID(rawValue: "app:retained"),
            title: "Retained", detail: "", counters: FlowCounters()
        )
        let missing = TrafficGraphNodeID(rawValue: "app:missing")

        XCTAssertEqual(
            VisualizeSelectionPolicy.validEndpointSelection([retained.id, missing], options: [retained]),
            [retained.id]
        )
        XCTAssertEqual(VisualizeSelectionPolicy.validEndpointSelection([missing], options: [retained]), [])
        XCTAssertEqual(VisualizeSelectionPolicy.validEndpointSelection([], options: [retained]), [])
    }

    func testAllApplicationsMapReconcilesWithCompleteReportTotals() {
        let rows = (0..<35).map { index in
            row(
                app: "app.complete",
                name: "Complete",
                domain: "host\(index).example",
                ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1),
                bytesOut: Int64(35 - index),
                flows: 1
            )
        }

        let build = TrafficGraphBuilder.buildForPresentation(rows: rows)
        let reportTotal = rows.reduce(into: FlowCounters()) { $0 += $1.counters }

        XCTAssertEqual(build.complete.visibleTotal, reportTotal)
        XCTAssertEqual(build.complete.edges.filter { $0.relationship == .observed }.count, 35)
        XCTAssertTrue(build.map.representedNodeIDs.isSubset(of: Set(build.complete.nodes.map(\.id))))
        XCTAssertTrue(build.map.representedEdgeIDs.isSubset(of: Set(build.complete.edges.map(\.id))))
        XCTAssertEqual(build.map.visibleTotal.total + build.map.hidden.counters.total, reportTotal.total)
        XCTAssertGreaterThan(build.map.hidden.edgeCount, 0)
    }

    func testMapGroupingPartitionsEveryExactItemAndExpansionPreservesTotals() throws {
        let rows = (0..<35).map { index in
            row(
                app: "app.complete",
                name: "Complete",
                domain: "host\(index).example",
                ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1),
                bytesOut: Int64(35 - index),
                flows: 1
            )
        }
        let complete = TrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded
        ).complete
        let collapsed = TrafficGraphMapGrouping.project(complete)
        let group = try XCTUnwrap(collapsed.nodes.first {
            $0.kind == .destination && $0.isCollapsedGroup
        })
        let expanded = TrafficGraphMapGrouping.project(
            complete,
            expandedGroupIDs: [group.id]
        )

        XCTAssertEqual(collapsed.representedNodeIDs, Set(complete.nodes.map(\.id)))
        XCTAssertEqual(collapsed.representedEdgeIDs, Set(complete.edges.map(\.id)))
        XCTAssertEqual(expanded.representedNodeIDs, Set(complete.nodes.map(\.id)))
        XCTAssertEqual(expanded.representedEdgeIDs, Set(complete.edges.map(\.id)))
        XCTAssertEqual(collapsed.visibleTotal, complete.visibleTotal)
        XCTAssertEqual(expanded.visibleTotal, complete.visibleTotal)
        XCTAssertTrue(group.collapsedNodeIDs.allSatisfy { id in
            expanded.nodes.contains { $0.id == id && !$0.isCollapsedGroup }
        })
        XCTAssertFalse(expanded.nodes.contains { $0.id == group.id })
    }

    func testMapGroupingPreservesTheExactFilterForOneCollapsedRelationship() throws {
        let apps = (0..<13).map { index in
            TrafficGraphNode(
                id: TrafficGraphNodeID(rawValue: "app:\(index)"),
                kind: .app,
                title: "Alpha \(index)",
                detail: "app.\(index)",
                appPath: "",
                filter: TrafficFilter(bundleID: "app.\(index)"),
                counters: FlowCounters(bytesIn: 1, flows: 1)
            )
        }
        let destination = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "destination:one.example"),
            kind: .destination,
            title: "one.example",
            detail: "",
            appPath: "",
            filter: TrafficFilter(domain: "one.example"),
            counters: FlowCounters(bytesIn: 1, flows: 1)
        )
        let exactFilter = TrafficFilter(bundleID: "app.0", domain: "one.example")
        let exactEdge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "app.0→one.example"),
            source: apps[0].id,
            target: destination.id,
            counters: FlowCounters(bytesIn: 1, flows: 1),
            filter: exactFilter
        )
        let projected = TrafficGraphMapGrouping.project(TrafficGraphSnapshot(
            nodes: apps + [destination],
            edges: [exactEdge],
            total: exactEdge.counters,
            hidden: .none
        ))
        let collapsed = try XCTUnwrap(projected.edges.first)

        XCTAssertTrue(collapsed.isCollapsedGroup)
        XCTAssertEqual(collapsed.collapsedEdgeIDs, [exactEdge.id])
        XCTAssertEqual(collapsed.filter, exactFilter)
    }

    func testMapGroupingBoundsEdgeDenseMapsWithStableExactMembership() throws {
        let source = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "app:browser"),
            kind: .app,
            title: "Browser",
            detail: "com.browser",
            appPath: "",
            filter: TrafficFilter(bundleID: "com.browser"),
            counters: FlowCounters()
        )
        let target = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "destination:example.com"),
            kind: .destination,
            title: "example.com",
            detail: "",
            appPath: "",
            filter: TrafficFilter(domain: "example.com"),
            counters: FlowCounters()
        )
        func snapshot(detailSuffix: String) -> TrafficGraphSnapshot {
            let edges = (0..<128).map { index in
                TrafficGraphEdge(
                    id: TrafficGraphEdgeID(rawValue: "blocked:\(index)"),
                    source: source.id,
                    target: target.id,
                    counters: FlowCounters(),
                    filter: TrafficFilter(bundleID: "com.browser", domain: "example.com"),
                    relationship: .blocked,
                    enforcement: TrafficGraphEnforcement(
                        count: 1,
                        category: "rule-\(detailSuffix)",
                        source: "ordinary-rule",
                        detail: "Port \(8_000 + index), \(detailSuffix)"
                    )
                )
            }
            return TrafficGraphSnapshot(nodes: [source, target], edges: edges,
                                        total: FlowCounters(), hidden: .none)
        }
        let first = TrafficGraphMapGrouping.project(snapshot(detailSuffix: "first"))
        let refreshed = TrafficGraphMapGrouping.project(snapshot(detailSuffix: "updated"))
        let grouped = try XCTUnwrap(first.edges.first)

        XCTAssertEqual(first.edges.count, 1)
        XCTAssertEqual(grouped.collapsedEdgeIDs.count, 128)
        XCTAssertEqual(grouped.representedEdgeIDs, Set((0..<128).map {
            TrafficGraphEdgeID(rawValue: "blocked:\($0)")
        }))
        XCTAssertEqual(refreshed.edges.map(\.id), first.edges.map(\.id),
                       "mutable enforcement descriptions must not change aggregate identity")

        let expanded = TrafficGraphMapGrouping.project(
            snapshot(detailSuffix: "first"),
            expandedEdgeGroupIDs: [grouped.id]
        )
        XCTAssertEqual(expanded.edges.count, 128)
        XCTAssertEqual(Set(expanded.edges.map(\.id)), grouped.representedEdgeIDs)
        XCTAssertTrue(expanded.edges.allSatisfy { !$0.isCollapsedGroup })
        XCTAssertEqual(expanded.representedEdgeIDs, grouped.representedEdgeIDs)
    }

    func testMapGroupingFoldsAccentedLatinTitlesIntoAlphabetBuckets() {
        let nodes = (0..<13).map { index in
            TrafficGraphNode(
                id: TrafficGraphNodeID(rawValue: "app:\(index)"),
                kind: .app,
                title: index.isMultiple(of: 2) ? "Éditeur \(index)" : "Ångström \(index)",
                detail: "",
                appPath: "",
                filter: .none,
                counters: FlowCounters()
            )
        }
        let projected = TrafficGraphMapGrouping.project(TrafficGraphSnapshot(
            nodes: nodes,
            edges: [],
            total: FlowCounters(),
            hidden: .none
        ))
        let titles = Set(projected.nodes.map(\.title))

        XCTAssertTrue(titles.contains("Applications A–D"))
        XCTAssertTrue(titles.contains("Applications E–H"))
        XCTAssertFalse(titles.contains("Applications #"))
    }

    func testMapGroupingIDsStayStableAcrossInputOrderCountersAndUnrelatedExpansion() throws {
        let rows: [BreakdownRow] = (0..<28).map { index -> BreakdownRow in
            let prefix = index < 14 ? "alpha" : "zulu"
            return row(
                app: "app.complete",
                name: "Complete",
                domain: "\(prefix)\(index).example",
                ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1),
                bytesOut: Int64(28 - index),
                flows: 1
            )
        }
        let louderRows = rows.map { value -> BreakdownRow in
            var value = value
            value.counters.bytesIn *= 10
            value.counters.bytesOut *= 10
            value.counters.flows *= 10
            return value
        }
        let complete = TrafficGraphBuilder.buildForPresentation(
            rows: rows,
            mapLimits: .unbounded
        ).complete
        let reversed = TrafficGraphBuilder.buildForPresentation(
            rows: rows.reversed(),
            mapLimits: .unbounded
        ).complete
        let louder = TrafficGraphBuilder.buildForPresentation(
            rows: louderRows,
            mapLimits: .unbounded
        ).complete
        let first = TrafficGraphMapGrouping.project(complete)
        let reordered = TrafficGraphMapGrouping.project(reversed)
        let refreshed = TrafficGraphMapGrouping.project(louder)
        let groups = first.nodes.filter { $0.kind == .destination && $0.isCollapsedGroup }
            .sorted { $0.id < $1.id }
        let expandedID = try XCTUnwrap(groups.first?.id)
        let unchanged = try XCTUnwrap(groups.last)
        let expanded = TrafficGraphMapGrouping.project(
            complete,
            expandedGroupIDs: [expandedID]
        )

        XCTAssertEqual(first.nodes.map(\.id), reordered.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), reordered.edges.map(\.id))
        XCTAssertEqual(first.nodes.map(\.id), refreshed.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), refreshed.edges.map(\.id))
        XCTAssertEqual(first.representedNodeIDs, Set(complete.nodes.map(\.id)))
        XCTAssertEqual(first.representedEdgeIDs, Set(complete.edges.map(\.id)))
        XCTAssertTrue(expanded.nodes.contains {
            $0.id == unchanged.id && $0.collapsedNodeIDs == unchanged.collapsedNodeIDs
        })
        XCTAssertEqual(expanded.representedNodeIDs, first.representedNodeIDs)
        XCTAssertEqual(expanded.representedEdgeIDs, first.representedEdgeIDs)
        XCTAssertEqual(refreshed.visibleTotal, louder.visibleTotal)
    }

    func testPresentationBuildKeepsEveryRelationshipBesideBoundedMap() {
        let rows = (0..<35).map { index in
            row(
                app: "app.complete",
                name: "Complete",
                domain: "host\(index).example",
                ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1),
                flows: 1
            )
        }
        let limits = TrafficGraphLimits(
            maxApps: 1,
            maxDestinations: 10,
            maxEdges: 28,
            maxBlockedEdges: 0,
            maxRelays: 0
        )

        let build = TrafficGraphBuilder.buildForPresentation(rows: rows, mapLimits: limits)
        let completeNodeIDs = Set(build.complete.nodes.map(\.id))
        let completeEdgeIDs = Set(build.complete.edges.map(\.id))

        XCTAssertEqual(build.complete.edges.filter { $0.relationship == .observed }.count, 35)
        XCTAssertEqual(build.complete.hidden, .none)
        XCTAssertEqual(build.map.edges.filter { $0.relationship == .observed }.count, 10)
        XCTAssertTrue(Set(build.map.nodes.map(\.id)).isSubset(of: completeNodeIDs))
        XCTAssertTrue(Set(build.map.edges.map(\.id)).isSubset(of: completeEdgeIDs))
        XCTAssertEqual(build.map.hidden.nodeCount, build.complete.nodes.count - build.map.nodes.count)
        XCTAssertEqual(build.map.hidden.edgeCount, build.complete.edges.count - build.map.edges.count)
        XCTAssertEqual(build.map.visibleTotal.total + build.map.hidden.counters.total, build.complete.total.total)
    }

    func testListPagerRevealsCompleteRelationshipsTwentyFiveAtATime() {
        let rows = (0..<61).map { index in
            row(
                app: "app.complete",
                domain: "host\(index).example",
                ip: "198.51.100.\(index)",
                bytesOut: Int64(index + 1),
                flows: 1
            )
        }
        let complete = TrafficGraphBuilder.buildForPresentation(rows: rows).complete

        let first = TrafficGraphListPager.page(in: complete, visibleCount: 25)
        let second = TrafficGraphListPager.page(
            in: complete,
            visibleCount: TrafficGraphListPager.nextVisibleCount(
                current: first.shownCount,
                total: first.totalCount
            )
        )
        let final = TrafficGraphListPager.page(
            in: complete,
            visibleCount: TrafficGraphListPager.nextVisibleCount(
                current: second.shownCount,
                total: second.totalCount
            )
        )

        XCTAssertEqual(first.shownCount, 25)
        XCTAssertEqual(first.remainingCount, 36)
        XCTAssertEqual(second.shownCount, 50)
        XCTAssertEqual(second.remainingCount, 11)
        XCTAssertEqual(final.shownCount, 61)
        XCTAssertEqual(final.remainingCount, 0)
        XCTAssertEqual(Set(final.edges.map(\.id)).count, 61)
        XCTAssertEqual(final.edges.map(\.id), complete.edges.map(\.id))
    }

    func testListExpansionDoesNotChangeMapIdentityOrGeometry() {
        let rows = (0..<61).map { index in
            row(
                app: "app.complete",
                domain: "stable\(index).example",
                ip: "203.0.113.\(index)",
                bytesOut: Int64(index + 1),
                flows: 1
            )
        }
        let build = TrafficGraphBuilder.buildForPresentation(rows: rows)
        // TrafficGraphCanvas applies these minimums before requesting geometry. An undersized synthetic canvas can
        // make padded cards form an unbroken wall, forcing the router to exhaust candidates no real view requests.
        let size = CGSize(
            width: max(1_200, TrafficGraphLayout.minimumCanvasWidth(for: build.map)),
            height: max(900, TrafficGraphLayout.minimumCanvasHeight(for: build.map))
        )
        let firstPage = TrafficGraphListPager.page(in: build.complete, visibleCount: 25)
        let beforeKey = TrafficGraphLayoutKey(snapshot: build.map, size: size)
        let beforeLayout = TrafficGraphLayout.layout(
            snapshot: build.map,
            in: CGRect(origin: .zero, size: size)
        )
        let secondPage = TrafficGraphListPager.page(
            in: build.complete,
            visibleCount: TrafficGraphListPager.nextVisibleCount(
                current: firstPage.shownCount,
                total: firstPage.totalCount
            )
        )
        let afterKey = TrafficGraphLayoutKey(snapshot: build.map, size: size)
        let afterLayout = TrafficGraphLayout.layout(
            snapshot: build.map,
            in: CGRect(origin: .zero, size: size)
        )

        XCTAssertEqual(firstPage.shownCount, 25)
        XCTAssertEqual(secondPage.shownCount, 50)
        XCTAssertEqual(beforeKey, afterKey)
        XCTAssertEqual(build.map.nodes.map(\.id), beforeKey.nodeIDs)
        XCTAssertEqual(build.map.edges.map(\.id), beforeKey.edgeIDs)
        XCTAssertEqual(beforeLayout.nodeFrames, afterLayout.nodeFrames)
        XCTAssertEqual(beforeLayout.edgeCurves, afterLayout.edgeCurves)
    }

    func testCapsAreDeterministicAndAccountForEverythingHidden() {
        let rows = (0..<12).map { index in
            row(app: "app.\(index)", domain: "host\(index).example", ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1) * 100, bytesOut: Int64(index + 1), flows: 1)
        }
        let limits = TrafficGraphLimits(maxApps: 4, maxDestinations: 5, maxEdges: 6)

        let first = TrafficGraphBuilder.build(rows: rows, limits: limits)
        let second = TrafficGraphBuilder.build(rows: rows.reversed(), limits: limits)

        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), second.edges.map(\.id))
        XCTAssertEqual(first.hidden, second.hidden)
        XCTAssertGreaterThan(first.hidden.nodeCount, 0)
        XCTAssertGreaterThan(first.hidden.edgeCount, 0)
        XCTAssertEqual(first.visibleTotal.total + first.hidden.counters.total, first.total.total)
        XCTAssertEqual(first.visibleTotal.flows + first.hidden.counters.flows, first.total.flows)
    }

    func testLayoutIsDeterministicAndCounterIndependent() {
        let rows = (0..<8).map { index in
            row(app: "app.\(index % 3)", domain: "host\(index).example", ip: "203.0.113.\(index)",
                bytesIn: Int64(index + 1) * 100)
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let louder = TrafficGraphSnapshot(
            nodes: snapshot.nodes.map { node in
                var node = node
                node.counters.bytesIn *= 100
                return node
            },
            edges: snapshot.edges.map { edge in
                var edge = edge
                edge.counters.bytesIn *= 100
                return edge
            },
            total: snapshot.total,
            hidden: snapshot.hidden
        )
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 680)

        let first = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)
        let second = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)
        let updated = TrafficGraphLayout.layout(snapshot: louder, in: bounds)

        XCTAssertEqual(first.nodeFrames, second.nodeFrames)
        XCTAssertEqual(first.nodeFrames, updated.nodeFrames)
        XCTAssertEqual(first.edgeCurves, second.edgeCurves)
    }

    func testLayoutAvoidsNodeFrameOverlapsWhenSpaceIsAvailable() {
        let rows = (0..<10).map { index in
            row(app: "app.\(index % 4)", domain: "host\(index).example", ip: "203.0.113.\(index)", bytesIn: 100)
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 1_200, height: 760))
        let frames = Array(layout.nodeFrames.values)

        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                               "node frames \(frames[left]) and \(frames[right]) overlap")
            }
        }
    }

    func testStandardCapFitsTheMinimumScrollableCanvasWithoutOverlaps() {
        let rows = (0..<104).map { index in
            row(app: "app.\(index % 8)", domain: "host\(index % 13).example", ip: "203.0.113.\(index % 13)",
                bytesIn: Int64(index + 1) * 100, flows: 1)
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows)
        let canvasHeight = TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 900, height: canvasHeight)
        )
        let frames = Array(layout.nodeFrames.values)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 8)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 13)
        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                               "node frames \(frames[left]) and \(frames[right]) overlap")
            }
        }
    }

    func testCachedLayoutIsRecomputedWhenTopologyExpands() {
        let initial = TrafficGraphBuilder.build(
            rows: (0..<8).map { index in
                row(
                    app: "app.\(index % 2)", domain: "host\(index).example",
                    ip: "203.0.113.\(index)", bytesIn: 100
                )
            },
            limits: .unbounded
        )
        let expanded = TrafficGraphBuilder.build(
            rows: (0..<13).map { index in
                row(
                    app: "app.\(index % 2)", domain: "host\(index).example",
                    ip: "203.0.113.\(index)", bytesIn: 100
                )
            },
            limits: .unbounded
        )
        let initialLayout = TrafficGraphLayout.layout(
            snapshot: initial,
            in: CGRect(x: 0, y: 0, width: 900, height: 760)
        )
        let expandedHeight = TrafficGraphLayout.minimumCanvasHeight(for: expanded)
        let layout = TrafficGraphLayout.layout(
            snapshot: expanded,
            in: CGRect(x: 0, y: 0, width: 900, height: expandedHeight),
            preserving: initialLayout
        )
        let frames = Array(layout.nodeFrames.values)

        XCTAssertEqual(layout.nodeFrames.count, expanded.nodes.count)
        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(
                    frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                    "node frames \(frames[left]) and \(frames[right]) overlap"
                )
            }
        }
    }

    func testEdgeWidthIsBoundedAndMonotonic() {
        let totals: [Int64] = [0, 1_000, 1_000_000, 1_000_000_000]
        let widths = totals.map { TrafficGraphLayout.edgeWidth(bytes: $0, maximum: totals.last!) }
        let trafficWidths = totals.map { TrafficGraphLayout.trafficWidth(bytes: $0, maximum: totals.last!) }

        XCTAssertEqual(widths, widths.sorted())
        XCTAssertGreaterThanOrEqual(widths.first!, 1.5)
        XCTAssertLessThanOrEqual(widths.last!, 9)
        XCTAssertEqual(trafficWidths, trafficWidths.sorted())
        XCTAssertEqual(trafficWidths.first!, 0)
        XCTAssertLessThanOrEqual(trafficWidths.last!, 3.25)
        XCTAssertGreaterThan(trafficWidths[2], trafficWidths[1])
    }

    func testParallelBlockedPortsHaveDistinctAndIndependentlyHittableCurves() {
        let blocked = (0..<12).map { index in
            let port = UInt16(8_000 + index)
            return BlockedAttemptRow(bundleID: "com.browser", appName: "Browser", agentKey: "", agentName: "",
                                     destination: "example.com", port: port, count: Int64(index + 1),
                                     category: "rule", source: "ordinary-rule", detail: "port \(port)")
        }
        let snapshot = TrafficGraphBuilder.build(rows: [BreakdownRow](), blockedAttempts: blocked, limits: .unbounded)
        let edges = snapshot.edges.filter { $0.relationship == .blocked }.sorted { $0.id < $1.id }
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let curves = edges.map { edge in
            try! XCTUnwrap(layout.edgeCurves[edge.id], "missing curve for \(edge.id.rawValue)")
        }

        XCTAssertEqual(curves.count, blocked.count)
        for (edge, curve) in zip(edges, curves) {
            let source = try! XCTUnwrap(layout.nodeFrames[edge.source])
            let target = try! XCTUnwrap(layout.nodeFrames[edge.target])
            XCTAssertEqual(curve.start.x, source.maxX, accuracy: 0.001)
            XCTAssertTrue((source.minY...source.maxY).contains(curve.start.y),
                          "blocked edge must remain attached to its source card")
            XCTAssertEqual(curve.end.x, target.minX, accuracy: 0.001)
            XCTAssertTrue((target.minY...target.maxY).contains(curve.end.y),
                          "blocked edge must remain attached to its destination card")
            XCTAssertEqual(layout.edge(at: curve.point(at: 0.5), tolerance: 5), edge.id)
        }
        let midpointYs = curves.map { $0.point(at: 0.5).y }.sorted()
        for pair in zip(midpointYs, midpointYs.dropFirst()) {
            XCTAssertGreaterThan(pair.1 - pair.0, 12)
        }
    }

    func testEdgeHitTestingCoversLongCurvesAtMaximumZoom() {
        let edgeID = TrafficGraphEdgeID(rawValue: "long")
        let curve = TrafficGraphCurve(
            start: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: 1_600, y: 0),
            control2: CGPoint(x: 2_400, y: 1_200),
            end: CGPoint(x: 4_000, y: 1_200)
        )
        let layout = TrafficGraphLayoutSnapshot(nodeFrames: [:], edgeCurves: [edgeID: curve],
                                                edgeWidths: [edgeID: 3])

        for step in 0...200 {
            let point = curve.point(at: CGFloat(step) / 200)
            XCTAssertEqual(layout.edge(at: point, tolerance: 12 / TrafficGraphViewport.maximumScale), edgeID)
        }
    }

    func testEdgeHitTestingUsesTheStableCurveGeometry() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "example.com", ip: "203.0.113.8", bytesIn: 1_000)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let edge = snapshot.edges[0]
        let curve = layout.edgeCurves[edge.id]!

        XCTAssertEqual(layout.edge(at: curve.point(at: 0.5), tolerance: 10), edge.id)
        XCTAssertNil(layout.edge(at: CGPoint(x: 20, y: 20), tolerance: 5))
    }

    func testFlowDashPhaseIsSparseDeterministicAndDirectional() {
        XCTAssertEqual(TrafficGraphFlowDash.pattern, [8, 26])
        XCTAssertEqual(TrafficGraphFlowDash.strokeWidth, 1.8)
        XCTAssertEqual(TrafficGraphFlowDash.frameInterval, 1 / 30)
        let first = TrafficGraphEdgeID(rawValue: "observed|app.a|one.example")
        let second = TrafficGraphEdgeID(rawValue: "observed|app.b|two.example")
        let firstSpeed = TrafficGraphFlowDash.speed(for: first)
        let secondSpeed = TrafficGraphFlowDash.speed(for: second)
        XCTAssertTrue((22.4...41.6).contains(firstSpeed))
        XCTAssertTrue((22.4...41.6).contains(secondSpeed))
        XCTAssertNotEqual(firstSpeed, secondSpeed)
        let sampleIDs = (0..<64).map { TrafficGraphEdgeID(rawValue: "edge-\($0)") }
        let sampleSpeeds = TrafficGraphFlowDash.speeds(for: sampleIDs)
        XCTAssertEqual(sampleSpeeds.count, sampleIDs.count)
        XCTAssertEqual(Set(sampleSpeeds.values).count, sampleIDs.count)
        XCTAssertGreaterThan(
            (sampleSpeeds.values.max() ?? 0) - (sampleSpeeds.values.min() ?? 0),
            15
        )
        XCTAssertEqual(sampleSpeeds, TrafficGraphFlowDash.speeds(for: Array(sampleIDs.reversed())))
        let expandedSpeeds = TrafficGraphFlowDash.speeds(for: sampleIDs + [
            TrafficGraphEdgeID(rawValue: "unrelated-new-edge")
        ])
        for edgeID in sampleIDs {
            XCTAssertEqual(expandedSpeeds[edgeID], sampleSpeeds[edgeID],
                           "an unchanged edge must keep its speed when topology changes")
        }
        XCTAssertEqual(firstSpeed, TrafficGraphFlowDash.speed(for: first))
        XCTAssertEqual(
            TrafficGraphFlowDash.phase(at: 0.25, edgeID: first, direction: .sent),
            -TrafficGraphFlowDash.phase(at: 0.25, edgeID: first, direction: .received)
        )
        XCTAssertEqual(
            TrafficGraphFlowDash.phase(at: 0.25, edgeID: first, direction: .sent),
            TrafficGraphFlowDash.phase(at: 0.25, edgeID: first, direction: .invocation)
        )

        let lanes = TrafficGraphFlowDash.lanes(
            counters: FlowCounters(bytesIn: 75, bytesOut: 25),
            totalWidth: 20
        )
        XCTAssertEqual(lanes.received.width, 15)
        XCTAssertEqual(lanes.received.offset, -2.5)
        XCTAssertEqual(lanes.sent.width, 5)
        XCTAssertEqual(lanes.sent.offset, 7.5)
        XCTAssertEqual(
            TrafficGraphFlowDash.borderOffset(totalWidth: 20, direction: .received),
            -9.1
        )
        XCTAssertEqual(
            TrafficGraphFlowDash.borderOffset(totalWidth: 20, direction: .sent),
            9.1
        )
    }

    func testLayoutPreservesSurvivingNodeFramesWhenTopologyChanges() {
        let initial = TrafficGraphBuilder.build(rows: [
            row(app: "app.a", domain: "one.example", ip: "203.0.113.1", bytesIn: 100),
            row(app: "app.b", domain: "two.example", ip: "203.0.113.2", bytesIn: 100)
        ], limits: .unbounded)
        let expanded = TrafficGraphBuilder.build(rows: [
            row(app: "app.a", domain: "one.example", ip: "203.0.113.1", bytesIn: 100),
            row(app: "app.b", domain: "two.example", ip: "203.0.113.2", bytesIn: 100),
            row(app: "app.c", domain: "three.example", ip: "203.0.113.3", bytesIn: 100)
        ], limits: .unbounded)
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 760)
        let first = TrafficGraphLayout.layout(snapshot: initial, in: bounds)
        let second = TrafficGraphLayout.layout(snapshot: expanded, in: bounds, preserving: first)

        for node in initial.nodes {
            XCTAssertEqual(second.nodeFrames[node.id], first.nodeFrames[node.id],
                           "adding unrelated topology must not shuffle surviving cards")
        }
    }

    func testAddingLauncherToPreservedNarrowLayoutDoesNotOverlapSurvivingStages() {
        let rows = [
            row(app: "curl", name: "curl", domain: "uploads.example", ip: "203.0.113.10", bytesOut: 25,
                parent: "claude", parentName: "Claude Code")
        ]
        let expandedRows = [
            row(app: "curl", name: "curl", domain: "uploads.example", ip: "203.0.113.10", bytesOut: 25,
                parent: "claude", parentName: "Claude Code",
                launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app"))
        ]
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 760)
        let initial = TrafficGraphLayout.layout(
            snapshot: AITrafficGraphBuilder.build(rows: rows, limits: .unbounded), in: bounds
        )
        let expanded = TrafficGraphLayout.layout(
            snapshot: AITrafficGraphBuilder.build(rows: expandedRows, limits: .unbounded),
            in: bounds,
            preserving: initial
        )
        let frames = Array(expanded.nodeFrames.values)

        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                               "preserved frames must move apart when a dependency stage is added")
            }
        }
    }

    func testResizeMovesSurvivingNodesToNewSemanticColumns() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "Node", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 10,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)
        let wide = TrafficGraphLayout.layout(snapshot: snapshot,
                                             in: CGRect(x: 0, y: 0, width: 1_400, height: 760))
        let narrow = TrafficGraphLayout.layout(snapshot: snapshot,
                                               in: CGRect(x: 0, y: 0, width: 900, height: 760), preserving: wide)

        for node in snapshot.nodes {
            let wideFrame = try! XCTUnwrap(wide.nodeFrames[node.id])
            let narrowFrame = try! XCTUnwrap(narrow.nodeFrames[node.id])
            XCTAssertEqual(narrowFrame.midY, wideFrame.midY, accuracy: 0.001)
            let sourceX = 24 + TrafficGraphLayout.appSize.width / 2
            let destinationX = 900 - 24 - TrafficGraphLayout.destinationSize.width / 2
            switch node.kind {
            case .app, .agent:
                XCTAssertEqual(narrowFrame.midX, sourceX, accuracy: 0.001)
            case .launcher:
                XCTFail("this topology has no launcher evidence")
            case .tool, .mcp, .proxy:
                XCTAssertGreaterThan(narrowFrame.minX, sourceX + TrafficGraphLayout.appSize.width / 2 + 15)
                XCTAssertLessThan(narrowFrame.maxX,
                                  destinationX - TrafficGraphLayout.destinationSize.width / 2 - 15)
                XCTAssertNotEqual(narrowFrame.midX, wideFrame.midX)
            case .destination, .service:
                XCTAssertEqual(narrowFrame.midX, destinationX, accuracy: 0.001)
                XCTAssertNotEqual(narrowFrame.midX, wideFrame.midX)
            }
        }
        let orderedX = snapshot.nodes.compactMap { narrow.nodeFrames[$0.id]?.midX }.sorted()
        XCTAssertEqual(Set(orderedX).count, 3)
    }

    func testRoutesDoNotCrossUnrelatedNodeFrames() {
        let rows = (0..<6).flatMap { app in
            (0..<6).map { destination in
                row(app: "app.\(app)", domain: "host\(destination).example",
                    ip: "203.0.113.\(destination)", bytesIn: 100)
            }
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_200, height: 760))

        XCTAssertLessThan(layout.contentBounds.height, 2_000,
                          "obstacle routing must not push a dense graph into an unreadable auto-fit thumbnail")
        for edge in snapshot.edges {
            let curve = try! XCTUnwrap(layout.edgeCurves[edge.id])
            let obstacles = layout.nodeFrames.filter { id, _ in id != edge.source && id != edge.target }
            for step in 1..<100 {
                let point = curve.point(at: CGFloat(step) / 100)
                XCTAssertFalse(obstacles.values.contains { $0.insetBy(dx: -18, dy: -18).contains(point) },
                               "route \(edge.id.rawValue) brings its ribbon or animated dash over an unrelated card near \(point)")
            }
        }
    }

    func testDemoAIMapKeepsObstacleRoutesWithinReadableFitBounds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-graph-\(UUID().uuidString).sqlite")
        let database = try TrafficDatabase(url: url)
        try DemoData.seed(database, now: now)
        let from = now.addingTimeInterval(-Granularity.week.defaultWindow)
        let rows = try database.aiVisualizationRows(.week, from: from, to: now)
        let attempts = try database.blockedAttempts(from: from, to: now)
        let build = AITrafficGraphBuilder.buildForPresentation(
            rows: rows,
            blockedAttempts: attempts,
            gateways: DemoData.agentGateways,
            resolveGateway: { DemoData.gatewayIdentity($0) }
        )
        let size = CGSize(width: max(1_280, TrafficGraphLayout.minimumCanvasWidth(for: build.map)),
                          height: max(800, TrafficGraphLayout.minimumCanvasHeight(for: build.map)))
        let layout = TrafficGraphLayout.layout(snapshot: build.map, in: CGRect(origin: .zero, size: size))

        XCTAssertGreaterThan(build.map.nodes.count, 10)
        XCTAssertLessThan(layout.contentBounds.height, size.height * 2,
                          "demo AI map must remain readable after automatic Fit")
        XCTAssertTrue(
            CGRect(origin: .zero, size: size).contains(layout.contentBounds),
            "every routed ribbon must stay inside the canvas so Fit cannot reveal pre-transform clipping: \(layout.contentBounds) in \(size)"
        )
        for edge in build.map.edges {
            let curve = try XCTUnwrap(layout.edgeCurves[edge.id])
            let obstacles = layout.nodeFrames.filter { id, _ in
                id != edge.source && id != edge.target
            }
            for step in 1..<100 {
                let point = curve.point(at: CGFloat(step) / 100)
                if let obstacle = obstacles.first(where: {
                    $0.value.insetBy(dx: -10, dy: -10).contains(point)
                }) {
                    XCTFail(
                        "demo route \(edge.id.rawValue) crosses \(obstacle.key.rawValue) "
                            + "at \(obstacle.value) near \(point); curve \(curve)"
                    )
                }
            }
        }
        for leftIndex in build.map.edges.indices {
            for rightIndex in build.map.edges.indices where rightIndex > leftIndex {
                let left = build.map.edges[leftIndex]
                let right = build.map.edges[rightIndex]
                guard let leftCurve = layout.edgeCurves[left.id],
                      let rightCurve = layout.edgeCurves[right.id] else { continue }
                let sharedEndpoint = left.source == right.source || left.source == right.target
                    || left.target == right.source || left.target == right.target
                let closeSamples = (15..<85).filter { step in
                    let t = CGFloat(step) / 100
                    let leftPoint = leftCurve.point(at: t)
                    let rightPoint = rightCurve.point(at: t)
                    return hypot(leftPoint.x - rightPoint.x, leftPoint.y - rightPoint.y) < 4
                }.count
                XCTAssertLessThan(
                    closeSamples,
                    sharedEndpoint ? 18 : 8,
                    "routes \(left.id.rawValue) and \(right.id.rawValue) share one corridor"
                )
            }
        }
    }

    func testRelationshipEdgesRouteAroundUnrelatedLaneCards() {
        let launcher = TrafficGraphNodeID(rawValue: "launcher:terminal")
        let agent = TrafficGraphNodeID(rawValue: "agent:claude")
        let tool = TrafficGraphNodeID(rawValue: "tool:node")
        let snapshot = TrafficGraphSnapshot(
            nodes: [
                TrafficGraphNode(id: launcher, kind: .launcher, title: "Terminal", detail: "", appPath: "",
                                 filter: .none, counters: FlowCounters()),
                TrafficGraphNode(id: agent, kind: .agent, title: "Claude Code", detail: "", appPath: "",
                                 filter: .none, counters: FlowCounters()),
                TrafficGraphNode(id: tool, kind: .tool, title: "Node", detail: "", appPath: "",
                                 filter: .none, counters: FlowCounters())
            ],
            edges: [TrafficGraphEdge(id: TrafficGraphEdgeID(rawValue: "terminal-runs-node"),
                                     source: launcher, target: tool, counters: FlowCounters(),
                                     filter: .none, relationship: .runs)],
            total: FlowCounters(),
            hidden: .none
        )
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 900, height: 500))
        let curve = try! XCTUnwrap(layout.edgeCurves[snapshot.edges[0].id])
        let obstacle = try! XCTUnwrap(layout.nodeFrames[agent]).insetBy(dx: -8, dy: -8)

        for step in 1..<100 {
            XCTAssertFalse(obstacle.contains(curve.point(at: CGFloat(step) / 100)),
                           "relationship edge crosses an unrelated agent card")
        }
    }

    func testDirectAIRibbonAvoidsIntermediaryCards() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "claude", name: "Claude Code", domain: "api.anthropic.com", ip: "160.79.104.10",
                bytesOut: 100),
            row(app: "node", name: "Node", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 50,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let direct = try! XCTUnwrap(snapshot.edges.first { edge in
            edge.relationship == .observed
                && snapshot.nodes.first { $0.id == edge.source }?.kind == .agent
        })
        let curve = try! XCTUnwrap(layout.edgeCurves[direct.id])
        let intermediaries = snapshot.nodes.filter { $0.kind == .tool || $0.kind == .mcp }
            .compactMap { layout.nodeFrames[$0.id] }

        for step in 1..<100 {
            let point = curve.point(at: CGFloat(step) / 100)
            XCTAssertFalse(intermediaries.contains { $0.insetBy(dx: -5, dy: -5).contains(point) })
        }
    }

    func testDirectBlockedAIEdgeAvoidsIntermediaryCards() {
        let blocked = (0..<12).map { index in
            BlockedAttemptRow(bundleID: "claude", appName: "Claude Code", agentKey: "claude",
                              agentName: "Claude Code", destination: "uploads.example",
                              port: UInt16(8_000 + index), count: 1,
                              category: "allowlist", source: "agent-allowlist", detail: "Claude Code")
        }
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "Node", domain: "api.example.com", ip: "203.0.113.8", bytesOut: 50,
                parent: "claude", parentName: "Claude Code")
        ], blockedAttempts: blocked, limits: .unbounded)
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let direct = snapshot.edges.filter { edge in
            edge.relationship == .blocked
                && snapshot.nodes.first { $0.id == edge.source }?.kind == .agent
        }
        var previous = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)
        let sourceIDs = Set(direct.map(\.source))
        let targetIDs = Set(direct.map(\.target))
        for node in snapshot.nodes {
            guard var frame = previous.nodeFrames[node.id] else { continue }
            switch node.kind {
            case .agent where sourceIDs.contains(node.id): frame.origin.y = 154
            case .tool, .mcp: frame.origin.y = 274
            case .destination where targetIDs.contains(node.id): frame.origin.y = 394
            default: continue
            }
            previous.nodeFrames[node.id] = frame
        }
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds, preserving: previous)
        let intermediaries = snapshot.nodes.filter { $0.kind == .tool || $0.kind == .mcp }
            .compactMap { layout.nodeFrames[$0.id] }

        XCTAssertEqual(direct.count, blocked.count)
        XCTAssertFalse(intermediaries.isEmpty)
        for edge in direct {
            let curve = try! XCTUnwrap(layout.edgeCurves[edge.id])
            let source = try! XCTUnwrap(layout.nodeFrames[edge.source])
            let target = try! XCTUnwrap(layout.nodeFrames[edge.target])
            XCTAssertTrue((source.minY...source.maxY).contains(curve.start.y))
            XCTAssertTrue((target.minY...target.maxY).contains(curve.end.y))
            XCTAssertEqual(layout.edge(at: curve.point(at: 0.5), tolerance: 5), edge.id)
            for step in 1..<100 {
                let point = curve.point(at: CGFloat(step) / 100)
                XCTAssertFalse(intermediaries.contains { $0.insetBy(dx: -5, dy: -5).contains(point) },
                               "parallel blocked edge \(edge.id.rawValue) crosses an intermediary card")
            }
        }
    }

    func testObservedRouteSegmentUsesTheSamePeriodTrafficWidthWithoutDoubleCounting() {
        var routed = row(app: "claude", name: "Claude Code", domain: "api.anthropic.com",
                         ip: "203.0.113.8", bytesIn: 4_000_000_000, bytesOut: 300_000_000, flows: 2)
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        let snapshot = TrafficGraphBuilder.build(rows: [routed], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let route = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .routedThrough })
        let observed = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .observed })

        XCTAssertEqual(route.displayedCounters.total, 4_300_000_000)
        XCTAssertEqual(route.counters.total, 0, "route width metadata must not duplicate graph accounting")
        XCTAssertEqual(layout.edgeWidths[route.id], layout.edgeWidths[observed.id])
        XCTAssertEqual(snapshot.visibleTotal.total, 4_300_000_000)
    }

    func testSankeyRibbonsStayInsideNodePortsAndScaleWithTraffic() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "app.a", domain: "api.example.com", ip: "203.0.113.1", bytesIn: 100),
            row(app: "app.a", domain: "other.test", ip: "203.0.113.2", bytesIn: 10_000),
            row(app: "app.b", domain: "cdn.example.com", ip: "203.0.113.3", bytesIn: 1_000_000)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let observed = snapshot.edges.sorted { $0.counters.total < $1.counters.total }
        let widths = observed.compactMap { layout.edgeWidths[$0.id] }

        XCTAssertEqual(widths, widths.sorted())
        XCTAssertGreaterThan(widths.first ?? 0, 0)
        XCTAssertLessThanOrEqual(widths.last ?? 0, 24)
        for edge in observed {
            let curve = try! XCTUnwrap(layout.edgeCurves[edge.id])
            let width = try! XCTUnwrap(layout.edgeWidths[edge.id])
            let source = try! XCTUnwrap(layout.nodeFrames[edge.source])
            let target = try! XCTUnwrap(layout.nodeFrames[edge.target])
            XCTAssertTrue(source.insetBy(dx: 0, dy: -width / 2).contains(curve.start))
            XCTAssertTrue(target.insetBy(dx: 0, dy: -width / 2).contains(curve.end))
        }
    }

    func testSankeyOrdersPortsByOppositeLaneAndKeepsLineageSeparate() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "node", name: "Node", domain: "z.test", ip: "203.0.113.1", bytesOut: 1_000,
                parent: "claude", parentName: "Claude Code"),
            row(app: "node", name: "Node", domain: "a.test", ip: "203.0.113.2", bytesOut: 2_000,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_000, height: 600))
        let observed = snapshot.edges.filter { $0.relationship == .observed }
            .sorted { left, right in
                let leftTarget = layout.nodeFrames[left.target]?.midY ?? 0
                let rightTarget = layout.nodeFrames[right.target]?.midY ?? 0
                return leftTarget < rightTarget
            }
        let sourcePorts = observed.compactMap { layout.edgeCurves[$0.id]?.start.y }

        XCTAssertEqual(sourcePorts, sourcePorts.sorted())
        XCTAssertTrue(observed.allSatisfy { (layout.edgeWidths[$0.id] ?? 0) > 1.5 })
        for edge in snapshot.edges where edge.relationship == .runs {
            XCTAssertEqual(layout.edgeWidths[edge.id], 1.5)
        }
    }

    func testMixedRelationshipPortsStayInsideTheirCards() throws {
        let source = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "app:source"),
            kind: .app,
            title: "Source",
            detail: "",
            appPath: "",
            filter: .none,
            counters: FlowCounters(bytesIn: 3_000, flows: 3)
        )
        let targets = (0..<9).map { index in
            TrafficGraphNode(
                id: TrafficGraphNodeID(rawValue: "destination:\(index)"),
                kind: .destination,
                title: "target\(index).example",
                detail: "",
                appPath: "",
                filter: .none,
                counters: FlowCounters(bytesIn: 1_000, flows: 1)
            )
        }
        let edges = targets.enumerated().map { index, target in
            TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: "edge:\(index)"),
                source: source.id,
                target: target.id,
                counters: index < 3 ? FlowCounters(bytesIn: 1_000, flows: 1) : FlowCounters(),
                filter: .none,
                relationship: index < 3 ? .observed : .blocked
            )
        }
        let snapshot = TrafficGraphSnapshot(
            nodes: [source] + targets,
            edges: edges,
            total: FlowCounters(bytesIn: 3_000, flows: 3),
            hidden: .none
        )
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let sourceFrame = try XCTUnwrap(layout.nodeFrames[source.id])

        for edge in edges {
            let curve = try XCTUnwrap(layout.edgeCurves[edge.id])
            let width = try XCTUnwrap(layout.edgeWidthCaps[edge.id])
            XCTAssertGreaterThanOrEqual(curve.start.y - width / 2, sourceFrame.minY)
            XCTAssertLessThanOrEqual(curve.start.y + width / 2, sourceFrame.maxY)
        }
    }

    func testDenseSemanticPortsCompressTheirGapsInsideTheCard() throws {
        let source = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "app:source"), kind: .app, title: "Source", detail: "",
            appPath: "", filter: .none, counters: FlowCounters()
        )
        let targets = (0..<24).map { index in
            TrafficGraphNode(
                id: TrafficGraphNodeID(rawValue: "destination:\(index)"), kind: .destination,
                title: "target\(index).example", detail: "", appPath: "", filter: .none,
                counters: FlowCounters()
            )
        }
        let edges = targets.enumerated().map { index, target in
            TrafficGraphEdge(
                id: TrafficGraphEdgeID(rawValue: "blocked:\(index)"),
                source: source.id,
                target: target.id,
                counters: FlowCounters(),
                filter: .none,
                relationship: .blocked
            )
        }
        let snapshot = TrafficGraphSnapshot(
            nodes: [source] + targets,
            edges: edges,
            total: FlowCounters(),
            hidden: .none
        )
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 1_600)
        )
        let sourceFrame = try XCTUnwrap(layout.nodeFrames[source.id])

        for edge in edges {
            let curve = try XCTUnwrap(layout.edgeCurves[edge.id])
            let width = try XCTUnwrap(layout.edgeWidths[edge.id])
            XCTAssertGreaterThanOrEqual(curve.start.y - width / 2, sourceFrame.minY)
            XCTAssertLessThanOrEqual(curve.start.y + width / 2, sourceFrame.maxY)
        }
    }

    func testSameLaneRelationshipCurvesAroundInterveningCard() throws {
        func node(_ id: String, title: String) -> TrafficGraphNode {
            TrafficGraphNode(
                id: TrafficGraphNodeID(rawValue: id),
                kind: .app,
                title: title,
                detail: "",
                appPath: "",
                filter: .none,
                counters: FlowCounters()
            )
        }
        let source = node("app:a", title: "A")
        let middle = node("app:b", title: "B")
        let target = node("app:c", title: "C")
        let edge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "a-launches-c"),
            source: source.id,
            target: target.id,
            counters: FlowCounters(),
            filter: .none,
            relationship: .launched
        )
        let snapshot = TrafficGraphSnapshot(
            nodes: [source, middle, target],
            edges: [edge],
            total: FlowCounters(),
            hidden: .none
        )
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let curve = try XCTUnwrap(layout.edgeCurves[edge.id])
        let obstacle = try XCTUnwrap(layout.nodeFrames[middle.id]).insetBy(dx: -10.75, dy: -10.75)

        XCTAssertGreaterThan(abs(curve.point(at: 0.5).x - curve.start.x), 20)
        for step in 1..<200 {
            XCTAssertFalse(obstacle.contains(curve.point(at: CGFloat(step) / 200)))
        }
    }

    func testSameLaneRelationshipTriesTheClearOppositeSide() {
        let obstacle = CGRect(x: 170, y: 0, width: 360, height: 400)
        let curve = TrafficGraphLayout.sameLaneCurve(
            start: CGPoint(x: 150, y: 50),
            end: CGPoint(x: 150, y: 350),
            side: .right,
            avoiding: [obstacle],
            width: 1.5,
            within: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let padded = obstacle.insetBy(dx: -10.75, dy: -10.75)

        XCTAssertLessThan(curve.point(at: 0.5).x, 150)
        for step in 1..<200 {
            XCTAssertFalse(padded.contains(curve.point(at: CGFloat(step) / 200)))
        }
    }

    func testWideRibbonClearanceIncludesHalfItsRenderedWidth() throws {
        let source = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "app:source"), kind: .app, title: "Source", detail: "",
            appPath: "", filter: .none, counters: FlowCounters(bytesIn: 1_000_000, flows: 1)
        )
        let obstacle = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "tool:middle"), kind: .tool, title: "Middle", detail: "",
            appPath: "", filter: .none, counters: FlowCounters()
        )
        let target = TrafficGraphNode(
            id: TrafficGraphNodeID(rawValue: "destination:target"), kind: .destination,
            title: "target.example", detail: "", appPath: "", filter: .none,
            counters: FlowCounters(bytesIn: 1_000_000, flows: 1)
        )
        let edge = TrafficGraphEdge(
            id: TrafficGraphEdgeID(rawValue: "source→target"),
            source: source.id,
            target: target.id,
            counters: FlowCounters(bytesIn: 1_000_000, flows: 1),
            filter: .none
        )
        let snapshot = TrafficGraphSnapshot(
            nodes: [source, obstacle, target],
            edges: [edge],
            total: edge.counters,
            hidden: .none
        )
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let curve = try XCTUnwrap(layout.edgeCurves[edge.id])
        let width = try XCTUnwrap(layout.edgeWidths[edge.id])
        let clearance = try XCTUnwrap(layout.nodeFrames[obstacle.id])
            .insetBy(dx: -(10 + width / 2), dy: -(10 + width / 2))

        for step in 1..<200 {
            XCTAssertFalse(clearance.contains(curve.point(at: CGFloat(step) / 200)))
        }
    }

    func testViewportClampsScaleAndRoundTripsCoordinates() {
        var viewport = TrafficGraphViewport()
        viewport.zoom(by: 20, around: CGPoint(x: 420, y: 260))
        XCTAssertEqual(viewport.scale, TrafficGraphViewport.maximumScale)
        viewport.pan(by: CGSize(width: 73, height: -41))

        let graphPoint = CGPoint(x: 310, y: 155)
        let screenPoint = viewport.screenPoint(for: graphPoint)
        let restored = viewport.graphPoint(for: screenPoint)
        XCTAssertEqual(restored.x, graphPoint.x, accuracy: 0.001)
        XCTAssertEqual(restored.y, graphPoint.y, accuracy: 0.001)

        viewport.zoom(by: 0.001, around: CGPoint(x: 300, y: 200))
        XCTAssertEqual(viewport.scale, TrafficGraphViewport.minimumScale)
    }

    func testViewportFitCanScaleBelowInteractiveZoomFloor() {
        let content = CGRect(x: 24, y: 22, width: 852, height: 716)
        let bounds = CGRect(x: 0, y: 0, width: 560, height: 350)
        var viewport = TrafficGraphViewport()

        viewport.fit(content: content, in: bounds)

        XCTAssertLessThan(viewport.scale, TrafficGraphViewport.minimumScale)
        let fitScale = viewport.scale
        viewport.zoom(by: 1 / 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertEqual(viewport.scale, fitScale, accuracy: 0.001)
        viewport.zoom(by: 1.2, around: CGPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertGreaterThan(viewport.scale, fitScale)
        viewport.fit(content: content, in: bounds)
        let topLeft = viewport.screenPoint(for: content.origin)
        let bottomRight = viewport.screenPoint(for: CGPoint(x: content.maxX, y: content.maxY))
        XCTAssertGreaterThanOrEqual(topLeft.x, bounds.minX + 31.9)
        XCTAssertGreaterThanOrEqual(topLeft.y, bounds.minY + 31.9)
        XCTAssertLessThanOrEqual(bottomRight.x, bounds.maxX - 31.9)
        XCTAssertLessThanOrEqual(bottomRight.y, bounds.maxY - 31.9)
    }

    func testViewportFitCentersTheWholeGraphByDefault() {
        let content = CGRect(x: 80, y: 60, width: 900, height: 700)
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 520)
        var viewport = TrafficGraphViewport(scale: 1.8, offset: CGSize(width: 90, height: -30))

        viewport.fit(content: content, in: bounds)

        let topLeft = viewport.screenPoint(for: content.origin)
        let bottomRight = viewport.screenPoint(for: CGPoint(x: content.maxX, y: content.maxY))
        XCTAssertGreaterThanOrEqual(topLeft.x, bounds.minX + 31.9)
        XCTAssertGreaterThanOrEqual(topLeft.y, bounds.minY + 31.9)
        XCTAssertLessThanOrEqual(bottomRight.x, bounds.maxX - 31.9)
        XCTAssertLessThanOrEqual(bottomRight.y, bounds.maxY - 31.9)
        XCTAssertEqual((topLeft.x + bottomRight.x) / 2, bounds.midX, accuracy: 0.001)
        XCTAssertEqual((topLeft.y + bottomRight.y) / 2, bounds.midY, accuracy: 0.001)
    }

    func testBarycentricSweepsRemoveAvoidableLaneCrossings() {
        let snapshot = TrafficGraphBuilder.build(rows: (0..<8).map { index in
            row(
                app: "app.\(index)",
                domain: "host\(7 - index).example",
                ip: "203.0.113.\(8 - index)",
                bytesIn: 100
            )
        }, limits: .unbounded)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
            height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        )
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)

        XCTAssertEqual(TrafficGraphLayout.crossingCount(snapshot: snapshot, layout: layout), 0)
    }

    func testDensityAwareCanvasKeepsEverySemanticColumnInsideBounds() {
        var routed = row(
            app: "node", name: "Node", domain: "api.example.com", ip: "203.0.113.8",
            bytesOut: 100, parent: "claude", parentName: "Claude Code",
            launcher: ("com.mitchellh.ghostty", "Ghostty", "/Applications/Ghostty.app")
        )
        routed.routeProxyBundleID = "com.flowlight.app"
        routed.routeProxyName = "Flowlight"
        routed.routeProxyPath = "/Applications/Flowlight.app"
        let gateway = AgentGatewayConfig(
            agent: "claude",
            endpoint: .init(scheme: "http", host: "127.0.0.1", port: 3425),
            source: "~/.claude/settings.json",
            sourceKey: "env.ANTHROPIC_BASE_URL"
        )
        let identity = AgentGatewayIdentity(
            bundleID: "com.yetone.magpie", name: "magpie", path: "/Applications/magpie.app"
        )
        let snapshot = AITrafficGraphBuilder.build(
            rows: [routed], gateways: [gateway], resolveGateway: { _ in identity }, limits: .unbounded
        )
        let width = TrafficGraphLayout.minimumCanvasWidth(for: snapshot)
        let height = TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)

        XCTAssertGreaterThan(width, 900, "dense six-stage topology needs more than the legacy fixed width")
        for frame in layout.nodeFrames.values {
            XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX + 23.9)
            XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX - 23.9)
        }
    }

    func testCounterRefreshUpdatesWidthsWithoutRecomputingGeometry() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "app", domain: "quiet.example", ip: "203.0.113.1", bytesIn: 100),
            row(app: "app", domain: "busy.example", ip: "203.0.113.2", bytesIn: 1_000_000)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 760)
        )
        var inverted = snapshot
        inverted.edges = snapshot.edges.map { edge in
            var edge = edge
            edge.counters.bytesIn = edge.counters.bytesIn == 100 ? 1_000_000 : 100
            return edge
        }

        let refreshed = layout.updatingTrafficWidths(for: inverted)

        XCTAssertEqual(refreshed.nodeFrames, layout.nodeFrames)
        XCTAssertEqual(refreshed.edgeCurves, layout.edgeCurves)
        XCTAssertNotEqual(refreshed.edgeWidths, layout.edgeWidths)
    }

    func testRibbonWidthsStayGloballyMonotonicAcrossDifferentFanout() {
        let crowded = (0..<20).map { index in
            row(
                app: "crowded",
                domain: "host\(index).example",
                ip: "203.0.113.\(index + 1)",
                bytesIn: index == 0 ? 1_000_000 : 1
            )
        }
        let snapshot = TrafficGraphBuilder.build(rows: crowded + [
            row(app: "isolated", domain: "single.example", ip: "198.51.100.1", bytesIn: 1)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(
                x: 0,
                y: 0,
                width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
                height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
            )
        )
        let ordered = snapshot.edges.compactMap { edge -> (Int64, CGFloat)? in
            guard let width = layout.edgeWidths[edge.id] else { return nil }
            return (edge.displayedCounters.total, width)
        }.sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 < right.0
        }

        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.1, pair.1.1 + 0.0001,
                                     "less traffic must never render wider because another node has more fanout")
        }
    }

    func testViewportVisibilityCullsOffscreenGeometryButFitIncludesEverything() {
        let snapshot = TrafficGraphBuilder.build(rows: (0..<80).map { index in
            row(
                app: "app.\(index % 8)", domain: "host\(index % 40).example",
                ip: "203.0.113.\(index % 40)", bytesIn: Int64(index + 1)
            )
        }, limits: .unbounded)
        let graphBounds = CGRect(
            x: 0,
            y: 0,
            width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
            height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        )
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: graphBounds)
        let screenBounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let top = layout.visibleRegion(
            in: TrafficGraphViewport().visibleGraphRect(in: screenBounds),
            margin: 0
        )
        var fitted = TrafficGraphViewport()
        fitted.fit(content: layout.contentBounds, in: screenBounds)
        let all = layout.visibleRegion(in: fitted.visibleGraphRect(in: screenBounds), margin: 1)

        XCTAssertLessThan(top.nodeIDs.count, snapshot.nodes.count)
        XCTAssertLessThan(top.edgeIDs.count, snapshot.edges.count)
        XCTAssertEqual(all.nodeIDs, Set(snapshot.nodes.map(\.id)))
        XCTAssertEqual(all.edgeIDs, Set(snapshot.edges.map(\.id)))
    }

    func testViewportInteractionPreventsLaterTopologyFromAutomaticallyFitting() {
        XCTAssertTrue(TrafficGraphViewportPolicy.shouldAutoFit(isUserControlled: false))
        XCTAssertFalse(TrafficGraphViewportPolicy.shouldAutoFit(isUserControlled: true))
    }

    func testFocusedTopologyDoesNotPreserveStrandedLayoutPositions() throws {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "app.one", domain: "one.example", ip: "203.0.113.1", bytesOut: 10),
            row(app: "app.two", domain: "two.example", ip: "203.0.113.2", bytesOut: 20)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(
            snapshot: snapshot,
            in: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let source = try XCTUnwrap(snapshot.nodes.first { $0.filter.bundleID == "app.one" }?.id)
        let focused = TrafficGraphEndpointProjector.scope(
            snapshot,
            query: TrafficGraphEndpointQuery(source: source)
        )

        XCTAssertTrue(TrafficGraphViewportPolicy.shouldPreserveLayout(snapshot: snapshot, previous: layout))
        XCTAssertFalse(TrafficGraphViewportPolicy.shouldPreserveLayout(snapshot: focused, previous: layout))
    }

    func testCancelledLargeLayoutDoesNotPublishPartialGeometry() async {
        let snapshot = TrafficGraphBuilder.build(rows: (0..<600).map { index in
            row(
                app: "app.\(index % 60)", domain: "host\(index).example",
                ip: "203.0.\(index / 256).\(index % 256)", bytesIn: Int64(index + 1)
            )
        }, limits: .unbounded)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
            height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        )
        let gate = TrafficGraphPlacementGate()
        let task = Task.detached(priority: .userInitiated) {
            TrafficGraphLayout.layout(
                snapshot: snapshot,
                in: bounds,
                placementObserver: { gate.observePlacement() }
            )
        }

        XCTAssertTrue(gate.waitForFirstPlacement(timeout: 2))
        task.cancel()
        let releaseTask = Task.detached(priority: .userInitiated) {
            gate.release()
        }
        await releaseTask.value
        let layout = await task.value

        XCTAssertEqual(gate.placementCount, 1)
        XCTAssertTrue(layout.nodeFrames.isEmpty)
        XCTAssertTrue(layout.edgeCurves.isEmpty)
    }

    func testLargeTopologyLayoutBenchmark() {
        let snapshot = TrafficGraphBuilder.build(rows: (0..<600).map { index in
            row(
                app: "app.\(index % 60)", domain: "host\(index).example",
                ip: "203.0.\(index / 256).\(index % 256)", bytesIn: Int64(index + 1)
            )
        }, limits: .unbounded)
        XCTAssertEqual(snapshot.edges.count, 600)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: TrafficGraphLayout.minimumCanvasWidth(for: snapshot),
            height: TrafficGraphLayout.minimumCanvasHeight(for: snapshot)
        )

        measure(metrics: [XCTClockMetric()]) {
            let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: bounds)
            XCTAssertEqual(layout.nodeFrames.count, snapshot.nodes.count)
            XCTAssertEqual(layout.edgeCurves.count, snapshot.edges.count)
        }
    }
}
