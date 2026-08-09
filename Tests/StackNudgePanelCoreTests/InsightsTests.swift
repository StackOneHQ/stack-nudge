import XCTest

@testable import StackNudgePanelCore

// Insights.summarize is the pure spend-to-outcome rollup behind the Insights
// tab. These pin the bucket partition (shipped / abandoned / in-flight), the
// shipped-share math, the staleness cutoff that defines abandoned, PR state
// superseding the local git heuristic, the agent/model mixes, and the trailing
// window boundary.
final class InsightsTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func key(_ repoRoot: String?, _ branch: String?) -> String {
        PanelNav.outcomeKey(repoRoot, branch)
    }

    private func record(id: String,
                        agent: String = "claude",
                        repoRoot: String? = "/work/repo",
                        branch: String? = "feat/x",
                        ticket: String? = nil,
                        model: String? = nil,
                        tokens: Int? = 100,
                        updated: Date) -> HandoffRecord {
        HandoffRecord(
            id: id, agent: agent, repoRoot: repoRoot, branch: branch, ticket: ticket,
            model: model, contextTokens: tokens, headCommit: nil, filesChanged: nil,
            insertions: nil, deletions: nil, createdAt: updated, updatedAt: updated)
    }

    private func pr(_ state: PRState) -> PullRequestInfo {
        PullRequestInfo(number: 1, url: "https://example/pr/1", state: state, isDraft: false, ci: nil)
    }

    func test_partitionsTokensByBucket_shippedIsMergedPlusPushed() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", tokens: 100, updated: yesterday),
                record(id: "b", branch: "b2", tokens: 200, updated: yesterday),
                record(id: "c", branch: "b3", tokens: 50,  updated: yesterday),
            ],
            outcomeByBranch: [
                key("/work/repo", "b1"): .merged,
                key("/work/repo", "b2"): .pushed,
                key("/work/repo", "b3"): .needsReview,
            ],
            pullRequestByBranch: [:],
            now: now, window: 7 * day)

        XCTAssertEqual(actual.totalTokens, 350)
        XCTAssertEqual(actual.tokensByBucket[.shipped], 300)
        XCTAssertEqual(actual.tokensByBucket[.inFlight], 50)   // recent needs-review, not abandoned
        XCTAssertNil(actual.tokensByBucket[.abandoned])
        XCTAssertEqual(actual.shippedShare, 300.0 / 350.0, accuracy: 0.0001)
        XCTAssertEqual(actual.tokensByStatus[.merged], 100)
        XCTAssertEqual(actual.tokensByStatus[.pushed], 200)
        XCTAssertEqual(actual.tokensByStatus[.needsReview], 50)
    }

    func test_shippedShare_zeroWhenNothingShipped_oneWhenAllShipped() {
        let yesterday = now.addingTimeInterval(-day)

        let nothing = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: 100, updated: yesterday)],
            outcomeByBranch: [key("/work/repo", "b1"): .needsReview],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(nothing.shippedShare, 0)

        let everything = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: 100, updated: yesterday)],
            outcomeByBranch: [key("/work/repo", "b1"): .merged],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(everything.shippedShare, 1)
    }

    func test_abandoned_onlyWhenUnshippedBranchGoneQuietPastCutoff() {
        let quiet30d = now.addingTimeInterval(-30 * day)
        let abandoned = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: 100, updated: quiet30d)],
            outcomeByBranch: [key("/work/repo", "b1"): .committed],
            pullRequestByBranch: [:], now: now, window: 90 * day)   // window wider than the 14d cutoff
        XCTAssertEqual(abandoned.tokensByBucket[.abandoned], 100)
        XCTAssertNil(abandoned.tokensByBucket[.inFlight])

        let recent2d = now.addingTimeInterval(-2 * day)
        let inFlight = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: 100, updated: recent2d)],
            outcomeByBranch: [key("/work/repo", "b1"): .committed],
            pullRequestByBranch: [:], now: now, window: 90 * day)
        XCTAssertEqual(inFlight.tokensByBucket[.inFlight], 100)
        XCTAssertNil(inFlight.tokensByBucket[.abandoned])
    }

    func test_prStateSupersedesLocal_squashMergeReadsAsShipped() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: 100, updated: yesterday)],
            outcomeByBranch: [key("/work/repo", "b1"): .committed],       // local: commits not on base
            pullRequestByBranch: [key("/work/repo", "b1"): pr(.merged)],  // but the PR squash-merged
            now: now, window: 7 * day)
        XCTAssertEqual(actual.tokensByBucket[.shipped], 100)
        XCTAssertEqual(actual.tokensByStatus[.merged], 100)
        XCTAssertNil(actual.tokensByStatus[.committed])
    }

    func test_agentMix_canonicalized() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", agent: "cursor", branch: "b1", tokens: 100, updated: yesterday),
                record(id: "b", agent: "codex",  branch: "b2", tokens: 40,  updated: yesterday),
            ],
            outcomeByBranch: [:], pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.tokensByAgent["claude"], 100)   // cursor canonicalizes to claude
        XCTAssertEqual(actual.tokensByAgent["codex"], 40)
    }

    func test_modelMix_keyedByRawId() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", model: "claude-opus-4-8", tokens: 100, updated: yesterday),
                record(id: "b", branch: "b2", model: "claude-opus-4-8", tokens: 30,  updated: yesterday),
                record(id: "c", branch: "b3", model: "gpt-5-codex",     tokens: 20,  updated: yesterday),
            ],
            outcomeByBranch: [:], pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.tokensByModel["claude-opus-4-8"], 130)
        XCTAssertEqual(actual.tokensByModel["gpt-5-codex"], 20)
    }

    func test_window_excludesOlderThanWindow_includesEdge() {
        let insideWindow = now.addingTimeInterval(-3 * day)
        let onEdge       = now.addingTimeInterval(-7 * day)   // exactly at windowStart, inclusive
        let outsideWindow = now.addingTimeInterval(-10 * day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", tokens: 100, updated: insideWindow),
                record(id: "b", branch: "b2", tokens: 10,  updated: onEdge),
                record(id: "c", branch: "b3", tokens: 999, updated: outsideWindow),
            ],
            outcomeByBranch: [:], pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.totalTokens, 110)
        XCTAssertEqual(actual.sessionCount, 2)
    }

    func test_emptyRecords_yieldsEmptySummary() {
        let actual = Insights.summarize(
            records: [], outcomeByBranch: [:], pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.totalTokens, 0)
        XCTAssertEqual(actual.sessionCount, 0)
        XCTAssertEqual(actual.ticketCount, 0)
        XCTAssertEqual(actual.shippedShare, 0)
        XCTAssertTrue(actual.tokensByBucket.isEmpty)
    }

    func test_nilTokens_countsSessionButZeroTokens() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [record(id: "a", branch: "b1", tokens: nil, updated: yesterday)],
            outcomeByBranch: [key("/work/repo", "b1"): .merged],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.sessionCount, 1)
        XCTAssertEqual(actual.totalTokens, 0)
    }

    func test_topTickets_rankedByTokensWithDominantStatus() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", ticket: "ENG-1", tokens: 500, updated: yesterday),
                record(id: "b", branch: "b2", ticket: "ENG-2", tokens: 100, updated: yesterday),
            ],
            outcomeByBranch: [
                key("/work/repo", "b1"): .merged,
                key("/work/repo", "b2"): .needsReview,
            ],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.topTickets.map(\.label), ["ENG-1", "ENG-2"])
        XCTAssertEqual(actual.topTickets.first?.status, .merged)
        XCTAssertEqual(actual.topTickets.first?.bucket, .shipped)
    }

    func test_topTickets_dominantStatusPrefersMostShipped() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", ticket: "ENG-1", tokens: 100, updated: yesterday),
                record(id: "b", branch: "b2", ticket: "ENG-1", tokens: 100, updated: yesterday),
            ],
            outcomeByBranch: [
                key("/work/repo", "b1"): .needsReview,
                key("/work/repo", "b2"): .merged,
            ],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.topTickets.count, 1)
        XCTAssertEqual(actual.topTickets.first?.tokens, 200)
        XCTAssertEqual(actual.topTickets.first?.status, .merged)   // merged outranks needs-review
    }

    func test_topTickets_prSupersedesLocalAndCarriesURL() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [record(id: "a", branch: "b1", ticket: "ENG-1", tokens: 100, updated: yesterday)],
            outcomeByBranch: [key("/work/repo", "b1"): .committed],
            pullRequestByBranch: [key("/work/repo", "b1"): pr(.merged)],
            now: now, window: 7 * day)
        XCTAssertEqual(actual.topTickets.first?.status, .merged)
        XCTAssertEqual(actual.topTickets.first?.bucket, .shipped)
        XCTAssertEqual(actual.topTickets.first?.prURL, "https://example/pr/1")
    }

    func test_shippedTokensByAgent_countsOnlyShippedBuckets() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", agent: "claude", branch: "b1", tokens: 100, updated: yesterday),
                record(id: "b", agent: "claude", branch: "b2", tokens: 100, updated: yesterday),
                record(id: "c", agent: "codex",  branch: "b3", tokens: 50,  updated: yesterday),
            ],
            outcomeByBranch: [
                key("/work/repo", "b1"): .merged,
                key("/work/repo", "b2"): .needsReview,
                key("/work/repo", "b3"): .pushed,
            ],
            pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.tokensByAgent["claude"], 200)
        XCTAssertEqual(actual.shippedTokensByAgent["claude"], 100)   // only the merged branch
        XCTAssertEqual(actual.tokensByAgent["codex"], 50)
        XCTAssertEqual(actual.shippedTokensByAgent["codex"], 50)     // pushed counts as shipped
    }

    func test_ticketCount_distinctTicketsTouched() {
        let yesterday = now.addingTimeInterval(-day)
        let actual = Insights.summarize(
            records: [
                record(id: "a", branch: "b1", ticket: "ENG-1", tokens: 10, updated: yesterday),
                record(id: "b", branch: "b2", ticket: "ENG-1", tokens: 10, updated: yesterday),
                record(id: "c", branch: "b3", ticket: "ENG-2", tokens: 10, updated: yesterday),
                record(id: "d", branch: "feat/x", ticket: nil, tokens: 10, updated: yesterday),
            ],
            outcomeByBranch: [:], pullRequestByBranch: [:], now: now, window: 7 * day)
        XCTAssertEqual(actual.ticketCount, 2)
    }
}
