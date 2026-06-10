import XCTest

@testable import StackNudgePanelCore

// TicketAttribution turns the git context a handoff captures into a Linear/Jira
// key, per the monorepo branch/commit conventions. These pin the precedence
// (branch > commit > PR), the anchored-branch trust, and the allow-list guard
// against false positives like "UTF-8".
final class TicketAttributionTests: XCTestCase {

    func test_ticket_fromConventionalBranch() {
        XCTAssertEqual(TicketAttribution.ticket(branch: "ENG-12142/fix-idp-logout"), "ENG-12142")
    }

    func test_ticket_jiraStyleBranch() {
        XCTAssertEqual(TicketAttribution.ticket(branch: "PROJ-87/add-export"), "PROJ-87")
    }

    func test_ticket_branchWithoutKey_returnsNil() {
        XCTAssertNil(TicketAttribution.ticket(branch: "main"))
        XCTAssertNil(TicketAttribution.ticket(branch: "spike/quick-thing"))
    }

    func test_ticket_fromCommitScope_whenBranchHasNone() {
        XCTAssertEqual(
            TicketAttribution.ticket(branch: "spike", commitSubject: "fix(ENG-9): a bug"),
            "ENG-9")
    }

    func test_ticket_fromPR_whenBranchAndCommitHaveNone() {
        XCTAssertEqual(
            TicketAttribution.ticket(branch: "spike", commitSubject: "wip", pr: "ENG-5 add thing"),
            "ENG-5")
    }

    func test_ticket_branchTakesPrecedenceOverCommit() {
        XCTAssertEqual(
            TicketAttribution.ticket(branch: "ENG-1/x", commitSubject: "fix(ENG-2): y"),
            "ENG-1")
    }

    func test_anchoredBranchKey_trustedRegardlessOfAllowlist() {
        // An anchored branch key is trusted even when not in the allow-list.
        XCTAssertEqual(
            TicketAttribution.ticket(branch: "ENG-12142/x", allowedPrefixes: ["JIRA"]),
            "ENG-12142")
    }

    func test_allowedPrefixes_filtersCommitFalsePositive() {
        // "UTF-8" matches the key shape but isn't a real ticket.
        XCTAssertNil(
            TicketAttribution.ticket(branch: "spike", commitSubject: "chore: bump to UTF-8",
                                     allowedPrefixes: ["ENG"]))
        XCTAssertEqual(
            TicketAttribution.ticket(branch: "spike", commitSubject: "fix(ENG-9): x",
                                     allowedPrefixes: ["ENG"]),
            "ENG-9")
    }

    func test_nonAnchoredBranchKey_foundViaFallback() {
        XCTAssertEqual(TicketAttribution.ticket(branch: "feature/ENG-77-thing"), "ENG-77")
    }
}
