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

    // The skip case production actually hits: key present (so it clears the
    // `contains("rate_limits")` pre-filter) but null — 4,240 lines locally.
    func testIgnoresALineWhoseRateLimitsAreNull() {
        XCTAssertNil(CodexQuotaProbe.snapshot(
            fromLine: #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#))
    }

    func testIgnoresALineWithoutRateLimits() {
        XCTAssertNil(CodexQuotaProbe.snapshot(
            fromLine: #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#))
    }

    // MARK: - Alerts

    private func tier(_ used: Double, minutes: Double?) -> QuotaTier {
        QuotaTier(utilization: used, resetsAt: nil, windowLength: minutes.map { $0 * 60 })
    }

    // Keyed by the window, not the slot it came in: under `limit_id=codex` the
    // weekly window arrives as primary, and the same key for both would read a
    // drop from weekly to session numbers as a rollover.
    func testAlertsNameEachWindowByItsLength() {
        let weeklyOnly = CodexQuotaSnapshot(primary: tier(40, minutes: 10080), secondary: nil, planType: "pro")
        XCTAssertEqual(weeklyOnly.alertTiers.map(\.key), ["seven_day"])
        XCTAssertEqual(weeklyOnly.alertTiers.map(\.label), ["Weekly"])

        let both = CodexQuotaSnapshot(primary: tier(10, minutes: 300), secondary: tier(40, minutes: 10080),
                                      planType: "plus")
        XCTAssertEqual(both.alertTiers.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(both.alertTiers.map(\.label), ["Session", "Weekly"])
    }

    func testAnUnusualWindowIsNamedByItsLengthAndAnUnknownOneByItsSlot() {
        let snapshot = CodexQuotaSnapshot(primary: tier(5, minutes: 1440), secondary: tier(7, minutes: nil),
                                          planType: nil)
        XCTAssertEqual(snapshot.alertTiers.map(\.key), ["window_1d", "secondary"])
        XCTAssertEqual(snapshot.alertTiers.map(\.label), ["1d", "Limit"])
    }

    // Every Codex login climbs through the buckets on its own, apart from any
    // Claude login's, and keeps its state through a switch of the default
    // Claude login, which clears every key without a "|".
    @MainActor
    func testEachCodexLoginKeepsItsOwnAlertState() {
        let work = CodexLogin(codexHome: "/h/.codex-work", label: "work")
        let prefixes = [PanelController.codexAlertKeyPrefix(nil), PanelController.codexAlertKeyPrefix(work),
                        PanelController.quotaAlertKeyPrefix(ClaudeLogin(configDir: "/h/.codex-work", label: "x"))]
        XCTAssertEqual(Set(prefixes).count, 3)
        for prefix in prefixes { XCTAssertTrue(prefix.hasSuffix("|")) }
        XCTAssertFalse(PanelController.codexAlertKeyPrefix(work).hasPrefix(PanelController.codexAlertKeyPrefix(nil)))
    }
}
