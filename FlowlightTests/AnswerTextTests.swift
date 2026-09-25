import XCTest
@testable import Flowlight

/// What reaches the person when the model answers with its own plumbing.
final class AnswerTextTests: XCTestCase {

    /// The exact shape seen in the panel: the model printed the call it meant to make.
    func testATurnThatIsOnlyAToolCallLeavesNothingToShow() {
        let raw = """
        system tools: {"name": "runQuery", "arguments": {"query": "trafficTotals", "from": \
        "2026-09-25T13:31:00-07:00", "to": "2026-09-25T13:31:00-07:00", "app": "default", "limit": "1", \
        "granularity": "hour"}}]```<executable_end>
        """
        XCTAssertTrue(AnswerText.cleaned(raw).isEmpty)
    }

    func testAnAnswerWithACallStuckToItKeepsTheAnswer() {
        let raw = """
        Chrome sent the most yesterday, 1.7 GB.
        {"name": "runQuery", "arguments": {"query": "topApps"}}
        <executable_end>
        """
        XCTAssertEqual(AnswerText.cleaned(raw), "Chrome sent the most yesterday, 1.7 GB.")
    }

    func testOrdinaryProseIsUntouched() {
        let answer = "Chrome sent 1.7 GB yesterday, mostly to www.youtube.com.\n\nNothing else came close."
        XCTAssertEqual(AnswerText.cleaned(answer), answer)
    }

    func testAnAnswerThatTalksAboutToolsIsNotMistakenForOne() {
        let answer = "Claude Code called the Bash tool six times, and one of those calls failed."
        XCTAssertEqual(AnswerText.cleaned(answer), answer)
    }
}
