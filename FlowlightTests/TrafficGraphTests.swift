import CoreGraphics
import XCTest
@testable import Flowlight

final class TrafficGraphTests: XCTestCase {
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
        channel: NetworkChannel = .ip
    ) -> BreakdownRow {
        BreakdownRow(
            bundleID: app,
            appName: name ?? app,
            appPath: path,
            domain: domain,
            remoteIP: ip,
            ports: "",
            protocols: "https",
            counters: FlowCounters(bytesIn: bytesIn, bytesOut: bytesOut, flows: flows),
            owner: owner,
            parentAgent: parent,
            parentAgentName: parentName,
            mcpServer: mcp,
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
        XCTAssertEqual(snapshot.edges.filter { $0.relationship == .worksFor }.count, 2)
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

        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .mcp }.map(\.title), ["remote-docs MCP"])
        XCTAssertFalse(snapshot.edges.contains { $0.relationship == .worksFor },
                       "remote MCP attribution is not stored process-lineage evidence")
        XCTAssertEqual(snapshot.edges.first { $0.relationship == .observed }?.source,
                       snapshot.nodes.first { $0.kind == .mcp }?.id)
    }

    func testAIWorksForRelationshipReadsToolToAgent() {
        let snapshot = AITrafficGraphBuilder.build(rows: [
            row(app: "curl", name: "curl", domain: "example.com", ip: "203.0.113.10", bytesOut: 25,
                parent: "claude", parentName: "Claude Code")
        ], limits: .unbounded)

        let lineage = try! XCTUnwrap(snapshot.edges.first { $0.relationship == .worksFor })
        XCTAssertEqual(snapshot.nodes.first { $0.id == lineage.source }?.kind, .tool)
        XCTAssertEqual(snapshot.nodes.first { $0.id == lineage.target }?.kind, .agent)
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
        XCTAssertTrue(edge.members.allSatisfy { $0.filter.bundleID == "claude" })
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

    func testDestinationIdentityPreservesExactHostAndAddress() {
        let rows = [
            row(app: "a", domain: "api.example.com", ip: "203.0.113.8", bytesIn: 10),
            row(app: "a", domain: "api.example.com", ip: "203.0.113.9", bytesIn: 20),
            row(app: "a", domain: "cdn.example.com", ip: "203.0.113.8", bytesIn: 30)
        ]

        let snapshot = TrafficGraphBuilder.build(rows: rows, limits: .unbounded)
        let destinations = snapshot.nodes.filter { $0.kind == .destination }

        XCTAssertEqual(destinations.count, 3)
        XCTAssertEqual(Set(destinations.map(\.filter.domain)), ["api.example.com", "cdn.example.com"])
        XCTAssertEqual(Set(destinations.map(\.filter.remoteIP)), ["203.0.113.8", "203.0.113.9"])
        XCTAssertEqual(Set(snapshot.edges.map(\.id.rawValue)).count, 3)
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

        XCTAssertEqual(widths, widths.sorted())
        XCTAssertGreaterThanOrEqual(widths.first!, 1.5)
        XCTAssertLessThanOrEqual(widths.last!, 9)
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
}
