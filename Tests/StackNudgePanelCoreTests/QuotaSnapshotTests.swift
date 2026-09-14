import XCTest

@testable import StackNudgePanelCore

// hasTier is the one question two callers have to answer identically: which
// clients get a row in the Usage tab, and whether an error replaces a client's
// bars or sits above them. They used to disagree — the view asked "is the
// snapshot non-nil", which is a weaker question than "did anything parse into a
// tier" — and a snapshot that landed with no recognised tier drew a stale
// warning above an empty pane, swallowing the message saying what had failed.
final class QuotaSnapshotTests: XCTestCase {

    private func tier(_ used: Double) -> QuotaTier {
        QuotaTier(utilization: used, resetsAt: nil)
    }

    // MARK: - Claude

    private func claude(five: QuotaTier? = nil, week: QuotaTier? = nil,
                        opus: QuotaTier? = nil, sonnet: QuotaTier? = nil) -> QuotaSnapshot {
        QuotaSnapshot(fiveHour: five, sevenDay: week,
                      sevenDayOpus: opus, sevenDaySonnet: sonnet, planType: "max")
    }

    func test_claude_anySingleTierCounts() {
        XCTAssertTrue(claude(five: tier(2)).hasTier)
        XCTAssertTrue(claude(week: tier(23)).hasTier)
        XCTAssertTrue(claude(opus: tier(12)).hasTier)
        XCTAssertTrue(claude(sonnet: tier(0)).hasTier)
    }

    // The shape parseResultText produces from a plan whose only bucket line is
    // one we don't map yet ("Current month (experimental)"): .ok, a plan type,
    // and not a single tier behind it.
    func test_claude_snapshotWithNoRecognisedTier() {
        XCTAssertFalse(claude().hasTier)
    }

    // MARK: - Codex

    func test_codex_eitherWindowCounts() {
        XCTAssertTrue(CodexQuotaSnapshot(primary: tier(20), secondary: nil, planType: "plus").hasTier)
        XCTAssertTrue(CodexQuotaSnapshot(primary: nil, secondary: tier(4), planType: "plus").hasTier)
    }

    // A rollout older than its own rate-limit window: both windows are dropped
    // as rolled-over, and what's left parses to a snapshot with nothing in it.
    func test_codex_expiredWindowsLeaveNothing() {
        XCTAssertFalse(CodexQuotaSnapshot(primary: nil, secondary: nil, planType: "plus").hasTier)
    }

    // MARK: - Antigravity

    func test_antigravity_countsItsModels() {
        let model = AntigravityQuotaSnapshot.ModelQuota(label: "Claude Opus 4.6", tier: tier(40))
        XCTAssertTrue(AntigravityQuotaSnapshot(planType: "pro", models: [model],
                                               promptCredits: nil, flowCredits: nil).hasTier)
        XCTAssertFalse(AntigravityQuotaSnapshot(planType: "pro", models: [],
                                                promptCredits: nil, flowCredits: nil).hasTier)
    }
}
