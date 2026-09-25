import XCTest
@testable import Flowlight

/// Help links land on the section about the screen you asked from.
///
/// The docs page and the sidebar are two files that have to agree, and nothing at runtime notices when they
/// stop agreeing — a renamed heading just quietly opens the top of a long page instead. So the agreement is
/// checked here, against the page as it is actually published.
final class HelpTests: XCTestCase {

    func testEveryScreenPointsAtASectionTheDocsActuallyHave() throws {
        let page = try publishedDocs()
        for item in SidebarItem.allCases {
            XCTAssertTrue(page.contains("id=\"\(item.helpAnchor)\""),
                          "\(item.rawValue) asks for #\(item.helpAnchor), which the docs page doesn't have")
        }
    }

    func testTheFixedHelpLinksStillResolve() throws {
        let page = try publishedDocs()
        for anchor in ["agent-configuration", "faq"] {
            XCTAssertTrue(page.contains("id=\"\(anchor)\""), "the Help menu links to #\(anchor), which is gone")
        }
    }

    func testTheHelpURLIsBuiltFromTheAnchorRatherThanGuessed() {
        XCTAssertEqual(Help.forScreen(.rules).absoluteString, "https://flowlight.xinbetween.com/docs/#rules")
        XCTAssertEqual(Help.forScreen(.inspect).absoluteString, "https://flowlight.xinbetween.com/docs/#inspection")
    }

    /// The built page, which is what a help link actually opens.
    private func publishedDocs() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/docs/index.html"), encoding: .utf8)
    }
}
