import XCTest

@testable import StackNudgePanelCore

// OutcomesView.groups rolls the handoff ledger up for the Tickets tab. These
// pin the grouping key (ticket, falling back to branch), the token/session
// aggregation, the tickets-before-branches ordering, and the recency sort
// within a band.
final class OutcomesViewTests: XCTestCase {

    private func record(id: String,
                        agent: String = "claude",
                        repoRoot: String? = "/work/stack-nudge",
                        branch: String? = nil,
                        ticket: String? = nil,
                        tokens: Int? = nil,
                        files: Int? = nil,
                        insertions: Int? = nil,
                        deletions: Int? = nil,
                        updated: TimeInterval = 0) -> HandoffRecord {
        let date = Date(timeIntervalSince1970: updated)
        return HandoffRecord(
            id: id, agent: agent, repoRoot: repoRoot, branch: branch, ticket: ticket,
            model: nil, contextTokens: tokens, headCommit: nil, filesChanged: files,
            insertions: insertions, deletions: deletions, createdAt: date, updatedAt: date)
    }

    func test_groupsByTicket_sumsTokensAndCountsSessions() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", ticket: "ENG-1", tokens: 100, updated: 1),
            record(id: "b", ticket: "ENG-1", tokens: 200, updated: 2),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "ENG-1")
        XCTAssertEqual(groups.first?.isTicket, true)
        XCTAssertEqual(groups.first?.sessionCount, 2)
        XCTAssertEqual(groups.first?.totalTokens, 300)
    }

    func test_branchUsedAsKeyWhenNoTicket() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "feat/x", ticket: nil, tokens: 50),
        ])
        XCTAssertEqual(groups.first?.id, "feat/x")
        XCTAssertEqual(groups.first?.isTicket, false)
        XCTAssertEqual(groups.first?.totalTokens, 50)
    }

    func test_ticketsSortBeforeBranches_evenWhenBranchIsNewer() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "feat/x", updated: 100),  // newest, but a branch
            record(id: "b", ticket: "ENG-1", updated: 1),     // older, but a ticket
        ])
        XCTAssertEqual(groups.map(\.id), ["ENG-1", "feat/x"])
    }

    func test_withinTickets_sortedByMostRecentActivity() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", ticket: "ENG-1", updated: 1),
            record(id: "b", ticket: "ENG-2", updated: 5),
        ])
        XCTAssertEqual(groups.map(\.id), ["ENG-2", "ENG-1"])
    }

    func test_distinctAgentsPreservedInFirstSeenOrder() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", agent: "claude", ticket: "ENG-1", updated: 1),
            record(id: "b", agent: "codex",  ticket: "ENG-1", updated: 2),
            record(id: "c", agent: "claude", ticket: "ENG-1", updated: 3),
        ])
        XCTAssertEqual(groups.first?.agents, ["Claude", "Codex"])
    }

    func test_noTicketNoBranch_fallsBackToPlaceholder() {
        let groups = OutcomesView.groups(from: [record(id: "a", branch: nil)])
        XCTAssertEqual(groups.first?.id, "—")
        XCTAssertEqual(groups.first?.isTicket, false)
    }

    func test_lowercaseBranch_regroupsUnderTicket_evenWhenStoredTicketIsNil() {
        // A record captured before the parser fix: ticket=nil, lowercase branch.
        // The rollup re-derives ENG-75 from the branch so it groups as a ticket.
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "eng-75/sync", ticket: nil, tokens: 100),
        ])
        XCTAssertEqual(groups.first?.id, "ENG-75")
        XCTAssertEqual(groups.first?.isTicket, true)
    }

    func test_repos_distinctNamesFromRepoRoot() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", ticket: "ENG-1"),
            record(id: "b", repoRoot: "/work/unified-cloud-api", ticket: "ENG-1"),
            record(id: "c", repoRoot: "/work/stack-nudge", ticket: "ENG-1"),
        ])
        XCTAssertEqual(groups.first?.repos, ["stack-nudge", "unified-cloud-api"])
    }

    func test_ticketBranchBreakdown_perBranchHeaviestFirst() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "ENG-1/backend",  ticket: "ENG-1", tokens: 100),
            record(id: "b", branch: "ENG-1/frontend", ticket: "ENG-1", tokens: 900),
            record(id: "c", branch: "ENG-1/backend",  ticket: "ENG-1", tokens: 100),
        ])
        let branches = groups.first?.branches ?? []
        XCTAssertEqual(branches.map(\.branch), ["ENG-1/frontend", "ENG-1/backend"])
        XCTAssertEqual(branches.first?.totalTokens, 900)
        XCTAssertEqual(branches.last?.sessionCount, 2)
    }

    func test_branchOnlyGroup_exposesItsOwnBranchSlice() {
        // Branch-only groups carry their single slice (for the outcome rollup);
        // the view just doesn't render it as a redundant sub-row.
        let groups = OutcomesView.groups(from: [record(id: "a", branch: "feat/x")])
        XCTAssertEqual(groups.first?.isTicket, false)
        XCTAssertEqual(groups.first?.branches.map(\.branch), ["feat/x"])
    }

    func test_branchDiff_usesLatestSnapshotNotSum() {
        // Two sessions on one branch: the diff is the latest snapshot (current
        // pending state), not the sum — uncommitted state is point-in-time.
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "ENG-1/x", ticket: "ENG-1", files: 5, insertions: 50, deletions: 5, updated: 1),
            record(id: "b", branch: "ENG-1/x", ticket: "ENG-1", files: 8, insertions: 80, deletions: 9, updated: 2),
        ])
        XCTAssertEqual(groups.first?.branches.first?.diff,
                       DiffStat(filesChanged: 8, insertions: 80, deletions: 9))
    }

    func test_groupDiff_sumsLatestAcrossBranches() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "ENG-1/be", ticket: "ENG-1", files: 3, insertions: 30, deletions: 1, updated: 1),
            record(id: "b", branch: "ENG-1/fe", ticket: "ENG-1", files: 7, insertions: 70, deletions: 2, updated: 2),
        ])
        XCTAssertEqual(groups.first?.diff, DiffStat(filesChanged: 10, insertions: 100, deletions: 3))
    }

    func test_diff_emptyWhenNoSnapshotCaptured() {
        let groups = OutcomesView.groups(from: [record(id: "a", ticket: "ENG-1")])
        XCTAssertEqual(groups.first?.diff.isEmpty, true)
    }
}
