import XCTest

@testable import StackNudgePanelCore

// OutcomesView.groups rolls the handoff ledger up for the Tickets tab. These
// pin the grouping key (ticket, else the repo the unticketed work ran in), the
// token/session aggregation, the tickets-before-repos ordering, and the recency
// sort within a band.
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
        XCTAssertEqual(groups.first?.label, "ENG-1")
        XCTAssertEqual(groups.first?.isTicket, true)
        XCTAssertEqual(groups.first?.sessionCount, 2)
        XCTAssertEqual(groups.first?.totalTokens, 300)
    }

    func test_unticketedWork_groupsUnderItsRepo() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", branch: "feat/x", ticket: nil, tokens: 50),
        ])
        XCTAssertEqual(groups.first?.label, "stack-nudge")
        XCTAssertEqual(groups.first?.kind, .repo)
        XCTAssertEqual(groups.first?.isTicket, false)
        XCTAssertEqual(groups.first?.branches.map(\.branch), ["feat/x"])
        XCTAssertEqual(groups.first?.totalTokens, 50)
    }

    func test_ticketsSortBeforeRepos_evenWhenRepoIsNewer() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", branch: "feat/x", updated: 100),  // newest, but unticketed
            record(id: "b", ticket: "ENG-1", updated: 1),                                    // older, but a ticket
        ])
        XCTAssertEqual(groups.map(\.label), ["ENG-1", "stack-nudge"])
    }

    func test_withinTickets_sortedByMostRecentActivity() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", ticket: "ENG-1", updated: 1),
            record(id: "b", ticket: "ENG-2", updated: 5),
        ])
        XCTAssertEqual(groups.map(\.label), ["ENG-2", "ENG-1"])
    }

    func test_distinctAgentsPreservedInFirstSeenOrder() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", agent: "claude", ticket: "ENG-1", updated: 1),
            record(id: "b", agent: "codex",  ticket: "ENG-1", updated: 2),
            record(id: "c", agent: "claude", ticket: "ENG-1", updated: 3),
        ])
        XCTAssertEqual(groups.first?.agents, ["Claude", "Codex"])
    }

    func test_noTicketNoRepo_fallsBackToPlaceholder() {
        let groups = OutcomesView.groups(from: [record(id: "a", repoRoot: nil, branch: nil)])
        XCTAssertEqual(groups.first?.label, "—")
        XCTAssertEqual(groups.first?.kind, .repo)
    }

    func test_lowercaseBranch_regroupsUnderTicket_evenWhenStoredTicketIsNil() {
        // A record captured before the parser fix: ticket=nil, lowercase branch.
        // The rollup re-derives ENG-75 from the branch so it groups as a ticket.
        let groups = OutcomesView.groups(from: [
            record(id: "a", branch: "eng-75/sync", ticket: nil, tokens: 100),
        ])
        XCTAssertEqual(groups.first?.label, "ENG-75")
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

    func test_repoGroup_gathersUnticketedBranches_heaviestFirst() {
        // Several unticketed branches in one repo collapse into a single repo
        // group, each branch a sub-row ordered by tokens.
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", branch: "feat/light", tokens: 100),
            record(id: "b", repoRoot: "/work/stack-nudge", branch: "feat/heavy", tokens: 900),
            record(id: "c", repoRoot: "/work/stack-nudge", branch: "feat/light", tokens: 100),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.label, "stack-nudge")
        XCTAssertEqual(groups.first?.kind, .repo)
        XCTAssertEqual(groups.first?.branches.map(\.branch), ["feat/heavy", "feat/light"])
        XCTAssertEqual(groups.first?.sessionCount, 3)
        XCTAssertEqual(groups.first?.totalTokens, 1100)
    }

    func test_unticketedWork_splitsByRepo() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", branch: "feat/x", updated: 1),
            record(id: "b", repoRoot: "/work/hub",         branch: "feat/y", updated: 2),
        ])
        XCTAssertEqual(groups.map(\.label), ["hub", "stack-nudge"])  // distinct repo groups, recency-sorted
        XCTAssertTrue(groups.allSatisfy { $0.kind == .repo })
    }

    func test_ticketAndRepoCoexist_ticketFirst() {
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/stack-nudge", branch: "feat/x", updated: 5),  // unticketed → repo
            record(id: "b", repoRoot: "/work/stack-nudge", branch: "eng-9/api", updated: 1),  // ticket
        ])
        XCTAssertEqual(groups.map(\.label), ["ENG-9", "stack-nudge"])
        XCTAssertEqual(groups.map(\.kind), [.ticket, .repo])
    }

    func test_groupID_uniqueWhenTicketAndRepoShareName() {
        // A repo literally named "ENG-9" and a ticket ENG-9 produce the same
        // display label but must stay distinct groups with distinct ids — else
        // SwiftUI's ForEach / row selection collides on the shared id.
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/ENG-9", branch: "feat/x", ticket: nil),  // repo basename "ENG-9"
            record(id: "b", repoRoot: "/work/svc",   branch: "eng-9/api", ticket: nil), // derives ticket ENG-9
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.label)), ["ENG-9"])               // same display text
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)                    // distinct ids
        XCTAssertEqual(Set(groups.map(\.kind)), [.ticket, .repo])
    }

    func test_distinctReposSameBasename_notMerged() {
        // …/acme/api and …/example/api share a basename but are different repos.
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/clients/acme/api",    branch: "feat/x", tokens: 100),
            record(id: "b", repoRoot: "/clients/example/api", branch: "feat/y", tokens: 200),
        ])
        XCTAssertEqual(groups.count, 2)                                   // not merged
        XCTAssertEqual(Set(groups.map(\.label)), ["api"])                 // same display label
        XCTAssertEqual(Set(groups.map(\.id)), ["r:/clients/acme/api", "r:/clients/example/api"])
    }

    func test_branchBreakdown_sameBranchNameAcrossRepos_staysDistinct() {
        // One ticket worked in two repos, each with a branch named ENG-9/main.
        // Keying by (repoRoot, branch) keeps them as two slices with their own
        // repoRoot, rather than collapsing into one and losing a repo.
        let groups = OutcomesView.groups(from: [
            record(id: "a", repoRoot: "/work/api-a", branch: "ENG-9/main", ticket: "ENG-9", tokens: 100),
            record(id: "b", repoRoot: "/work/api-b", branch: "ENG-9/main", ticket: "ENG-9", tokens: 200),
        ])
        let branches = groups.first?.branches ?? []
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(Set(branches.map(\.repoRoot)), ["/work/api-a", "/work/api-b"])
        XCTAssertEqual(Set(branches.map(\.id)).count, 2)
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
