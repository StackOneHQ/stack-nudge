import XCTest

@testable import StackNudgePanelCore

// availableUsageClients decides which clients get a row in the Usage tab. The
// rule used to be "has a non-empty snapshot"; a client that failed simply
// vanished, and the only error the tab could show was Claude's global one. Now a
// client with an error but no snapshot lists itself so the error renders on its
// own detail pane — these pin that, and pin that a Claude error never drops
// Claude just because another client happens to have data.
@MainActor
final class UsageAvailabilityTests: XCTestCase {

    private func claudeSnapshot(five: Double? = 10) -> QuotaSnapshot {
        QuotaSnapshot(fiveHour: five.map { QuotaTier(utilization: $0, resetsAt: nil) },
                      sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil, planType: nil)
    }

    private func codexSnapshot() -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(primary: QuotaTier(utilization: 20, resetsAt: nil),
                           secondary: nil, planType: nil)
    }

    func test_claudeWithTiers_isListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot()
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }

    // The new behaviour: an error with no snapshot to fall back on still lists
    // the client, so the note has a pane to render on instead of falling through
    // to the tab's cold-load empty state.
    func test_claudeWithErrorButNoSnapshot_isListed() {
        let nav = PanelNav()
        nav.quotaErrors[.claude] = "Rate-limited — retrying shortly."
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }

    func test_claudeWithNeitherSnapshotNorError_isNotListed() {
        let nav = PanelNav()
        XCTAssertTrue(nav.availableUsageClients.isEmpty)
    }

    // An all-nil snapshot isn't a usable client, and without an error it stays
    // out of the list — matching the pre-existing "empty snapshot isn't a
    // client" rule.
    func test_emptyClaudeSnapshotWithoutError_isNotListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot(five: nil)
        XCTAssertTrue(nav.availableUsageClients.isEmpty)
    }

    // Regression guard: a Claude error must not drop Claude out of the list just
    // because Codex has data. Both are listed; the failing client keeps its row.
    func test_claudeErrorWithCodexPresent_listsBoth() {
        let nav = PanelNav()
        nav.quotaErrors[.claude] = "Couldn't refresh — run `claude /usage` to check your session."
        nav.codexQuota = codexSnapshot()
        XCTAssertEqual(nav.availableUsageClients, [.claude, .codex])
    }

    // A held-stale Claude snapshot (error present, but the last-good bars are
    // still there) keeps its row too — the error marks it stale rather than
    // removing it.
    func test_claudeHeldStaleSnapshot_staysListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot()
        nav.quotaErrors[.claude] = "Couldn't refresh — run `claude /usage` to check your session."
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }
}
