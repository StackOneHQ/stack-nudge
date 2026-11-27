import XCTest

@testable import StackNudgePanelCore

final class AgentQuestionTests: XCTestCase {

    func testAClosingQuestionIsTheQuestion() {
        XCTAssertEqual(AgentQuestion.question(in: "Should I raise it?"), "Should I raise it?")
        XCTAssertEqual(AgentQuestion.question(in: "Tests pass. Want me to open the PR?\n\n"),
                       "Want me to open the PR?")
    }

    func testOnlyTheLastLineCounts() {
        XCTAssertNil(AgentQuestion.question(in: "Which one did you mean?\n\nI went with the first. Done."))
        XCTAssertNil(AgentQuestion.question(in: "Raised #291."))
        XCTAssertNil(AgentQuestion.question(in: ""))
        XCTAssertNil(AgentQuestion.question(in: nil))
        XCTAssertNil(AgentQuestion.question(in: "?"))
    }

    func testMarkupAroundTheQuestionIsIgnored() {
        XCTAssertEqual(AgentQuestion.question(in: "**Want me to go ahead?**"), "Want me to go ahead?")
        XCTAssertEqual(AgentQuestion.question(in: "Options:\n- Rebase now\n- Or wait for CI?"), "Or wait for CI?")
        XCTAssertEqual(AgentQuestion.question(in: "1. Merge it?"), "Merge it?")
        XCTAssertEqual(AgentQuestion.question(in: "> Ship it?"), "Ship it?")
        XCTAssertEqual(AgentQuestion.question(in: "(Or should I leave it?)"), "Or should I leave it?")
    }

    // "Shall I run this?" above the command is still the turn's question.
    func testATrailingCodeBlockIsSkipped() {
        let reply = "Shall I run this?\n\n```bash\nmake release\n```\n"
        XCTAssertEqual(AgentQuestion.question(in: reply), "Shall I run this?")
        XCTAssertNil(AgentQuestion.question(in: "```\nonly code?\n```"))
        XCTAssertNil(AgentQuestion.question(in: "cut off mid-block\nis this?\n```"))
    }

    func testALongQuestionIsCut() {
        let long = String(repeating: "word ", count: 60) + "ok?"
        let question = AgentQuestion.question(in: long)
        XCTAssertEqual(question?.count, AgentQuestion.maxLength)
        XCTAssertEqual(question?.last, "…")
    }
}
