import CoreGraphics
import XCTest
@testable import Flowlight

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
        XCTAssertEqual(snapshot.nodes.first { $0.kind == .tool }?.title, "node",
                       "the heaviest row supplies display metadata deterministically")
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

    func testVisualizationSelectionClearsWhenSearchContextChanges() {
        XCTAssertTrue(VisualizeSelectionPolicy.shouldClear(previousQuery: "", newQuery: "uploads.example"))
        XCTAssertFalse(VisualizeSelectionPolicy.shouldClear(previousQuery: "uploads.example",
                                                             newQuery: "uploads.example"))
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
        XCTAssertTrue(layout.particles(for: configured, at: 1, reduceMotion: false).isEmpty)
        XCTAssertTrue(layout.particles(for: route, at: 1, reduceMotion: false).isEmpty)
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
        XCTAssertEqual(snapshot.nodes.first { $0.kind == .proxy }?.title, "Flowlight renamed")
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
        let rows = (0..<80).map { index in
            row(app: "app.\(index % 8)", domain: "host\(index % 10).example", ip: "203.0.113.\(index % 10)",
                bytesIn: Int64(index + 1) * 100, flows: 1)
        }
        let snapshot = TrafficGraphBuilder.build(rows: rows)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 900, height: 760))
        let frames = Array(layout.nodeFrames.values)

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .app }.count, 8)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .destination }.count, 10)
        for left in frames.indices {
            for right in frames.indices where right > left {
                XCTAssertFalse(frames[left].insetBy(dx: -8, dy: -8).intersects(frames[right]),
                               "node frames \(frames[left]) and \(frames[right]) overlap")
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

    func testParticlesAreDeterministicAndReducedMotionRemovesThem() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "example.com", ip: "203.0.113.8", bytesIn: 1_000_000, bytesOut: 500_000)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let edge = snapshot.edges[0]
        let first = layout.particles(for: edge, at: 123.45, reduceMotion: false)
        let second = layout.particles(for: edge, at: 123.45, reduceMotion: false)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(layout.particles(for: edge, at: 123.45, reduceMotion: true).isEmpty)
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

        for edge in snapshot.edges {
            let curve = try! XCTUnwrap(layout.edgeCurves[edge.id])
            let obstacles = layout.nodeFrames.filter { id, _ in id != edge.source && id != edge.target }
            for step in 1..<100 {
                let point = curve.point(at: CGFloat(step) / 100)
                XCTAssertFalse(obstacles.values.contains { $0.insetBy(dx: -5, dy: -5).contains(point) },
                               "route \(edge.id.rawValue) enters an unrelated card near \(point)")
            }
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

    func testRepresentativeParticleMovesCalmly() {
        let snapshot = TrafficGraphBuilder.build(rows: [
            row(app: "a", domain: "example.com", ip: "203.0.113.8", bytesOut: 1_000_000)
        ], limits: .unbounded)
        let layout = TrafficGraphLayout.layout(snapshot: snapshot,
                                                in: CGRect(x: 0, y: 0, width: 1_000, height: 500))
        let edge = snapshot.edges[0]
        let first = try! XCTUnwrap(layout.particles(for: edge, at: 120, reduceMotion: false).first)
        let second = try! XCTUnwrap(layout.particles(for: edge, at: 121, reduceMotion: false).first)

        XCTAssertLessThan(hypot(first.position.x - second.position.x, first.position.y - second.position.y), 55,
                          "one second should communicate activity without racing across the map")
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
}
