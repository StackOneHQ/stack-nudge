import XCTest

@testable import StackNudgePanelCore

// Pins Codex's rollout payload shape to the parser that reads it, using lines
// in the form Codex actually writes rather than a hand-built dictionary.
//
// The regression this exists for: the Usage tab titled tiers by slot position,
// assuming primary = 5h and secondary = weekly. Under `limit_id=codex` there is
// no 5-hour window at all and the weekly one arrives as `primary`, so a weekly
// quota was displayed as "Current session (5h)". `window_minutes` is the only
// field that distinguishes them.
final class CodexUsageTests: XCTestCase {

    // resets_at values are absolute, so `now` is pinned relative to them.
    private let resetsAt: TimeInterval = 1_789_805_437

    private func line(_ rateLimits: String) -> String {
        """
        {"timestamp":"2026-09-04T14:02:10.000Z","ordinal":1,"type":"event_msg",\
        "payload":{"type":"token_count","info":null,"rate_limits":\(rateLimits)}}
        """
    }

    // limit_id=codex: one weekly window, in the primary slot, secondary null.
    private var weeklyOnly: String {
        line("""
        {"limit_id":"codex","limit_name":null,\
        "primary":{"used_percent":13.0,"window_minutes":10080,"resets_at":\(Int(resetsAt))},\
        "secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},\
        "individual_limit":null,"spend_control_reached":null,"plan_type":"pro",\
        "rate_limit_reached_type":null}
        """)
    }

    // limit_id=codex_bengalfox: the 5h + weekly pair.
    private var fiveHourAndWeekly: String {
        line("""
        {"limit_id":"codex_bengalfox","limit_name":null,\
        "primary":{"used_percent":42.0,"window_minutes":300,"resets_at":\(Int(resetsAt))},\
        "secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":\(Int(resetsAt))},\
        "credits":null,"individual_limit":null,"spend_control_reached":null,\
        "plan_type":"plus","rate_limit_reached_type":null}
        """)
    }

    func testReadsWindowLengthFromPayload() {
        let now = Date(timeIntervalSince1970: resetsAt - 3600)
        let snap = CodexQuotaProbe.snapshot(fromLine: fiveHourAndWeekly, now: now)
        XCTAssertEqual(snap?.primary?.windowLength, 300 * 60)
        XCTAssertEqual(snap?.secondary?.windowLength, 10080 * 60)
        XCTAssertEqual(snap?.planType, "plus")
    }

    // The mislabel, pinned: a primary slot carrying a weekly window must not be
    // titled "Current session (5h)".
    func testWeeklyWindowInPrimarySlotIsTitledAsWeekly() {
        let now = Date(timeIntervalSince1970: resetsAt - 3600)
        guard let primary = CodexQuotaProbe.snapshot(fromLine: weeklyOnly, now: now)?.primary else {
            return XCTFail("expected a primary tier")
        }
        XCTAssertEqual(primary.windowLength, 10080 * 60)
        XCTAssertEqual(UsageView.codexTitle(primary, fallback: "Current session (5h)"),
                       "Current week")
    }

    func testPaceMarkerPositionForAWeeklyWindow() {
        // Three days left of seven → four sevenths elapsed.
        let now = Date(timeIntervalSince1970: resetsAt - 3 * 24 * 3600)
        let snap = CodexQuotaProbe.snapshot(fromLine: weeklyOnly, now: now)
        let fraction = UsageView.elapsedFraction(snap!.primary!, now: now)
        XCTAssertEqual(fraction ?? -1, 4.0 / 7.0, accuracy: 0.0001)
    }

    // Unchanged behaviour: a window that already reset is dropped, not shown stale.
    func testDropsATierWhoseResetHasPassed() {
        let now = Date(timeIntervalSince1970: resetsAt + 1)
        let snap = CodexQuotaProbe.snapshot(fromLine: weeklyOnly, now: now)
        XCTAssertNil(snap?.primary)
    }

    // The skip case production actually hits: the key is present (so it passes
    // parseLatestRateLimits' `contains("rate_limits")` pre-filter) but null.
    // 4,240 such lines across 279 local rollouts.
    func testIgnoresALineWhoseRateLimitsAreNull() {
        XCTAssertNil(CodexQuotaProbe.snapshot(
            fromLine: #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#))
    }

    func testIgnoresALineWithoutRateLimits() {
        XCTAssertNil(CodexQuotaProbe.snapshot(
            fromLine: #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#))
    }
}
