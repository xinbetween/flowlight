import SwiftUI
import XCTest
@testable import Flowlight

final class BodySearchTests: XCTestCase {
    /// Characters carrying the highlight. Runs would undercount: two adjacent matches share identical
    /// attributes, so AttributedString coalesces them into one run.
    private func highlightedCharacters(_ line: String, term: String) -> Int {
        let attributed = BodyView.attributed(line, term: term)
        return attributed.runs.filter { $0.backgroundColor != nil }
            .reduce(0) { $0 + attributed.characters[$1.range].count }
    }

    func testEveryOccurrenceIsMarked() {
        XCTAssertEqual(highlightedCharacters("token=abc token=def", term: "token"), 10)   // both "token"s
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(highlightedCharacters("Authorization: Bearer", term: "authorization"), 13)
    }

    func testTermAtTheEndDoesNotLoopForever() {
        // The loop advances past each hit; a match touching the end used to be the awkward case.
        XCTAssertEqual(highlightedCharacters("ends with key", term: "key"), 3)
    }

    func testRepeatedAdjacentMatches() {
        XCTAssertEqual(highlightedCharacters("aaaa", term: "aa"), 4)
    }

    func testNothingIsMarkedWithoutATerm() {
        XCTAssertEqual(highlightedCharacters("anything at all", term: ""), 0)
    }

    func testTextIsUnchangedByHighlighting() {
        let line = "GET /v1/messages HTTP/1.1"
        XCTAssertEqual(String(BodyView.attributed(line, term: "messages").characters), line)
    }
}
