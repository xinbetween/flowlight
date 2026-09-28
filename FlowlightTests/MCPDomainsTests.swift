import XCTest
@testable import Flowlight

/// An MCP server reaches the network four different ways and each is learned somewhere different, so most of
/// these test that the four sources merge into one truthful row rather than four partial ones — and that the
/// one kind of domain a local rule cannot touch is never offered as though it could be.
final class MCPDomainsTests: XCTestCase {

    private func server(_ name: String, kind: MCPServerSummary.Kind, endpoint: String?) -> MCPServerSummary {
        MCPServerSummary(name: name, kind: kind, version: nil, endpoint: endpoint)
    }

    private func config(_ name: String, url: String?) -> MCPServerConfig {
        MCPServerConfig(name: name, client: "Claude", command: "node", args: [], url: url.flatMap(URL.init(string:)))
    }

    private func destination(_ label: String, via: [String], bytes: Int64 = 1000) -> AgentDestination {
        AgentDestination(label: label, ip: "1.2.3.4", provider: nil, protocols: ["https"], ports: "443",
                         counters: FlowCounters(bytesIn: bytes, bytesOut: 0, flows: 1), hasHostname: true, via: via)
    }

    // MARK: The four sources

    func testAConfiguredRemoteServerContributesItsHost() {
        let entries = MCPDomains.collect(seen: [], configured: [config("github", url: "https://mcp.github.com/v1")],
                                         destinations: [])
        XCTAssertEqual(entries.map(\.host), ["mcp.github.com"])
        XCTAssertEqual(entries.first?.sources, [.configured])
    }

    func testAnObservedEndpointContributesItsHostWithoutThePath() {
        let entries = MCPDomains.collect(seen: [server("linear", kind: .remote, endpoint: "mcp.linear.app/sse")],
                                         configured: [], destinations: [])
        XCTAssertEqual(entries.map(\.host), ["mcp.linear.app"],
                       "a rule names a host; the flow layer never sees a path")
        XCTAssertEqual(entries.first?.sources, [.observed])
    }

    /// The source this feature was asked for: the URL an agent declares to the model in its request body.
    func testAServerDeclaredToTheProviderContributesItsHost() {
        let entries = MCPDomains.collect(seen: [server("notion", kind: .provider, endpoint: "mcp.notion.com")],
                                         configured: [], destinations: [])
        XCTAssertEqual(entries.first?.sources, [.declared])
    }

    /// A local server has no URL of its own but still makes calls, and those are already attributed to it.
    func testALocalServersOwnTrafficIsAttributedToIt() {
        let entries = MCPDomains.collect(seen: [server("github", kind: .local, endpoint: nil)],
                                         configured: [],
                                         destinations: [destination("api.github.com", via: ["github"])])
        XCTAssertEqual(entries.map(\.host), ["api.github.com"])
        XCTAssertEqual(entries.first?.sources, [.contacted])
        XCTAssertEqual(entries.first?.counters?.total, 1000)
    }

    func testTrafficFromSomethingThatIsNotAnMCPServerIsIgnored() {
        let entries = MCPDomains.collect(seen: [server("github", kind: .local, endpoint: nil)], configured: [],
                                         destinations: [destination("registry.npmjs.org", via: ["curl"])])
        XCTAssertTrue(entries.isEmpty, "curl is a tool, not one of this agent's MCP servers")
    }

    // MARK: Merging

    /// "Declared in a config file" and "actually contacted" are different facts, and a domain carrying both is
    /// a stronger statement than either alone — so it must be one row, not two.
    func testTheSameHostFromSeveralSourcesIsOneRow() {
        let entries = MCPDomains.collect(
            seen: [server("linear", kind: .remote, endpoint: "https://mcp.linear.app/sse")],
            configured: [config("linear", url: "https://mcp.linear.app/sse")],
            destinations: [destination("mcp.linear.app", via: ["linear"])])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sources, [.configured, .observed, .contacted])
    }

    func testOneHostSharedByTwoServersNamesBoth() {
        let entries = MCPDomains.collect(
            seen: [server("a", kind: .remote, endpoint: "shared.example/one"),
                   server("b", kind: .remote, endpoint: "shared.example/two")],
            configured: [], destinations: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.servers, ["a", "b"])
    }

    func testBusiestHostComesFirst() {
        let entries = MCPDomains.collect(
            seen: [server("x", kind: .local, endpoint: nil)], configured: [],
            destinations: [destination("quiet.example", via: ["x"], bytes: 10),
                           destination("busy.example", via: ["x"], bytes: 9000)])
        XCTAssertEqual(entries.first?.host, "busy.example")
    }

    // MARK: What cannot be blocked

    /// The distinction the feature must not blur: the provider connects to its own connectors, so that traffic
    /// never touches this Mac and no local rule can reach it. A button there would do nothing.
    func testAProviderRunConnectorIsNotOfferedAsBlockable() {
        let entries = MCPDomains.collect(seen: [server("notion", kind: .provider, endpoint: "mcp.notion.com")],
                                         configured: [], destinations: [])
        XCTAssertFalse(entries.first!.blockable)
    }

    /// But once the same host has been reached from this Mac too, a rule does bite — so the row must offer it.
    func testAHostAlsoReachedLocallyIsBlockable() {
        let entries = MCPDomains.collect(
            seen: [server("notion", kind: .provider, endpoint: "mcp.notion.com")],
            configured: [config("notion", url: "https://mcp.notion.com/v1")], destinations: [])
        XCTAssertTrue(entries.first!.blockable)
        XCTAssertEqual(entries.first?.sources, [.declared, .configured])
    }

    // MARK: Hosts

    func testNormaliseReducesAnythingToABareHost() {
        XCTAssertEqual(MCPDomains.normalise("https://mcp.example.com/sse"), "mcp.example.com")
        XCTAssertEqual(MCPDomains.normalise("mcp.example.com/v1/messages"), "mcp.example.com")
        XCTAssertEqual(MCPDomains.normalise("MCP.Example.COM"), "mcp.example.com")
        XCTAssertEqual(MCPDomains.normalise("https://user:pw@mcp.example.com/x"), "mcp.example.com")
        XCTAssertEqual(MCPDomains.normalise("mcp.example.com:8443"), "mcp.example.com")
    }

    /// A port is stripped, but an IPv6 literal is colons all the way down and must survive intact.
    func testNormaliseDoesNotMangleIPv6() {
        XCTAssertEqual(MCPDomains.normalise("[2606:4700::1111]"), "[2606:4700::1111]")
    }

    func testNormaliseRejectsNothing() {
        XCTAssertNil(MCPDomains.normalise(nil))
        XCTAssertNil(MCPDomains.normalise(""))
        XCTAssertNil(MCPDomains.normalise("   "))
    }

    func testAServerWithNoHostAnywhereContributesNoRow() {
        let entries = MCPDomains.collect(seen: [server("local-only", kind: .local, endpoint: nil)],
                                         configured: [config("local-only", url: nil)], destinations: [])
        XCTAssertTrue(entries.isEmpty, "a stdio server that never reaches the network has no domain to show")
    }
}
