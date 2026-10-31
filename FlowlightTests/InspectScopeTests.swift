import XCTest
@testable import Flowlight

/// "Inspect Claude Code's Traffic" opened Inspect and showed Google Chrome.
///
/// The menu item put the app's name into the search field, and Inspect searches response bodies as well as
/// hosts and app names — so the term matched every page whose HTML happens to contain the words "Claude Code",
/// which on a machine browsing its own GitHub repository is most of them. The filter was working perfectly and
/// answering a different question from the one the menu item asks.
final class InspectScopeTests: XCTestCase {

    private func database() throws -> TrafficDatabase {
        try TrafficDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID()).sqlite"))
    }

    private func exchange(app: (String, String), host: String, body: String = "",
                          agent: String? = nil, mcpServer: String? = nil) -> HTTPExchange {
        HTTPExchange(
            id: nil, started: Date(), duration: 0.1, scheme: "https", host: host, port: 443, method: "GET",
            path: "/", status: 200, requestHeaders: [], requestBody: Data(), requestSize: 0, requestTruncated: false,
            responseHeaders: [], responseBody: Data(body.utf8), responseSize: body.count, responseTruncated: false,
            contentType: "text/html", pid: 1, bundleID: app.0, appName: app.1, agent: agent, agentName: agent,
            mcpServer: mcpServer, toolCalls: [], toolResults: [], mcp: [], llm: nil, note: nil, mockRule: nil, guardrail: nil)
    }

    /// The exact shape of the bug: a page that merely mentions the app's name.
    func testScopingToAnAppExcludesAPageThatOnlyMentionsIt() throws {
        let db = try database()
        _ = try db.insertExchange(exchange(app: ("claude", "Claude Code"), host: "api.anthropic.com"))
        _ = try db.insertExchange(exchange(app: ("com.google.Chrome", "Google Chrome"), host: "github.com",
                                       body: "<p>Generated with Claude Code</p>"))

        let scoped = try db.exchanges(since: Date().addingTimeInterval(-60), app: "claude")
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.appName, "Claude Code")

        let searched = try db.exchanges(since: Date().addingTimeInterval(-60), search: "Claude Code")
        XCTAssertEqual(searched.count, 2, "precondition: searching the text matches the page that mentions it")
    }

    func testScopingToAHostKeepsItsSubdomains() throws {
        let db = try database()
        _ = try db.insertExchange(exchange(app: ("a", "A"), host: "api.github.com"))
        _ = try db.insertExchange(exchange(app: ("b", "B"), host: "github.com"))
        _ = try db.insertExchange(exchange(app: ("c", "C"), host: "example.com"))

        let scoped = try db.exchanges(since: Date().addingTimeInterval(-60), host: "github.com")
        XCTAssertEqual(Set(scoped.map(\.host)), ["github.com", "api.github.com"])
    }

    /// A scope and a search have to compose, or narrowing a scoped list would silently widen it.
    func testAScopeAndASearchBothApply() throws {
        let db = try database()
        _ = try db.insertExchange(exchange(app: ("claude", "Claude Code"), host: "api.anthropic.com"))
        _ = try db.insertExchange(exchange(app: ("claude", "Claude Code"), host: "registry.npmjs.org"))

        let both = try db.exchanges(since: Date().addingTimeInterval(-60), search: "npmjs", app: "claude")
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(both.first?.host, "registry.npmjs.org")
    }

    func testInspectLinkQueryKeepsAttributionScopeWhileDroppingSearch() throws {
        let db = try database()
        _ = try db.insertExchange(exchange(app: ("node", "Node"), host: "api.github.com",
                                           agent: "claude", mcpServer: "github"))
        _ = try db.insertExchange(exchange(app: ("node", "Node"), host: "api.github.com",
                                           agent: "cursor", mcpServer: "github"))
        _ = try db.insertExchange(exchange(app: ("node", "Node"), host: "api.github.com",
                                           agent: "claude", mcpServer: "filesystem"))

        let linked = try InspectLinkQuery.load(
            from: db,
            since: Date().addingTimeInterval(-60),
            focus: .none,
            app: "node",
            host: "api.github.com",
            includeAttributedChildren: false,
            agentParent: "claude",
            mcpServer: "github"
        )

        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.agent, "claude")
        XCTAssertEqual(linked.first?.mcpServer, "github")
    }

    func testNoScopeStillReturnsEverything() throws {
        let db = try database()
        _ = try db.insertExchange(exchange(app: ("a", "A"), host: "one.example"))
        _ = try db.insertExchange(exchange(app: ("b", "B"), host: "two.example"))
        XCTAssertEqual(try db.exchanges(since: Date().addingTimeInterval(-60)).count, 2)
    }
}
