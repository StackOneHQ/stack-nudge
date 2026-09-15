import XCTest

@testable import StackNudgePanelCore

// Pins the Usage tab's pace marker: where it sits, and when it refuses to draw.
// A marker is a claim about data, so the absent cases matter as much as the
// arithmetic — a stale snapshot pinned to the far right would read as "window
// nearly over" when the truth is "we don't know".
final class QuotaPaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func ahead(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    // MARK: - elapsedFraction

    func testHalfwayThroughWindow() {
        let f = QuotaReset.elapsedFraction(until: ahead(2.5 * 3600),
                                           windowLength: QuotaWindow.fiveHours, now: now)
        XCTAssertEqual(f ?? -1, 0.5, accuracy: 0.0001)
    }

    func testJustStartedIsNearZero() {
        let f = QuotaReset.elapsedFraction(until: ahead(QuotaWindow.sevenDays),
                                           windowLength: QuotaWindow.sevenDays, now: now)
        XCTAssertEqual(f ?? -1, 0, accuracy: 0.0001)
    }

    func testAlmostOverIsNearOne() {
        let f = QuotaReset.elapsedFraction(until: ahead(60),
                                           windowLength: QuotaWindow.fiveHours, now: now)
        XCTAssertEqual(f ?? -1, 1 - 60 / (5 * 3600), accuracy: 0.0001)
    }

    // A reset in the past means the snapshot is stale, not that the window is
    // 100% elapsed. Same rule QuotaReset.remaining already applies.
    func testPastResetDrawsNoMarker() {
        XCTAssertNil(QuotaReset.elapsedFraction(until: ahead(-1),
                                                windowLength: QuotaWindow.fiveHours, now: now))
    }

    func testExactResetInstantDrawsNoMarker() {
        XCTAssertNil(QuotaReset.elapsedFraction(until: now,
                                                windowLength: QuotaWindow.fiveHours, now: now))
    }

    func testNonPositiveWindowDrawsNoMarker() {
        XCTAssertNil(QuotaReset.elapsedFraction(until: ahead(3600), windowLength: 0, now: now))
        XCTAssertNil(QuotaReset.elapsedFraction(until: ahead(3600), windowLength: -60, now: now))
    }

    // Claude's 5h window is documented as rolling, so a reset further out than
    // the assumed length is plausible. Pin to the start rather than going
    // negative and drawing the marker off the left edge of the bar.
    func testRemainingLongerThanWindowClampsToZero() {
        let f = QuotaReset.elapsedFraction(until: ahead(9 * 3600),
                                           windowLength: QuotaWindow.fiveHours, now: now)
        XCTAssertEqual(f ?? -1, 0, accuracy: 0.0001)
    }

    // MARK: - QuotaWindow.title

    func testTitleNamesTheFiveHourWindow() {
        XCTAssertEqual(QuotaWindow.title(windowLength: 300 * 60), "Current session (5h)")
    }

    func testTitleNamesTheWeeklyWindow() {
        XCTAssertEqual(QuotaWindow.title(windowLength: 10080 * 60), "Current week")
    }

    func testTitleFallsBackToWholeUnitsForUnknownWindows() {
        XCTAssertEqual(QuotaWindow.title(windowLength: 24 * 3600), "Current window (1d)")
        XCTAssertEqual(QuotaWindow.title(windowLength: 3 * 3600), "Current window (3h)")
        XCTAssertEqual(QuotaWindow.title(windowLength: 90 * 60), "Current window (90m)")
    }

    // MARK: - UsageView seams

    func testTierWithoutWindowLengthDrawsNoMarker() {
        let tier = QuotaTier(utilization: 40, resetsAt: ahead(3600))
        XCTAssertNil(UsageView.elapsedFraction(tier, now: now))
    }

    func testTierWithoutResetDrawsNoMarker() {
        let tier = QuotaTier(utilization: 0, resetsAt: nil, windowLength: QuotaWindow.fiveHours)
        XCTAssertNil(UsageView.elapsedFraction(tier, now: now))
    }

    // Under pace deliberately, so this pins the two numbers and nothing else —
    // the warning suffix has its own test.
    func testAccessibilityLabelCarriesBothNumbers() {
        let tier = QuotaTier(utilization: 30,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceDescription(tier, now: now),
                       "30% used, 40% of the window elapsed")
    }

    func testAccessibilityLabelOmitsPaceWhenUnknown() {
        let tier = QuotaTier(utilization: 62, resetsAt: nil)
        XCTAssertEqual(UsageView.paceDescription(tier, now: now), "62% used")
    }

    // VoiceOver must not read "62% used" while the row prints "38% left".
    func testAccessibilityLabelFollowsTheShowRemainingToggle() {
        let tier = QuotaTier(utilization: 30,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceDescription(tier, showRemaining: true, now: now),
                       "70% left, 40% of the window elapsed")
        XCTAssertEqual(UsageView.paceDescription(tier, showRemaining: false, now: now),
                       "30% used, 40% of the window elapsed")
    }

    // Distinct fallback string, so this can't pass by echoing the expected value.
    func testCodexTitleFallsBackWhenNoWindowReported() {
        let tier = QuotaTier(utilization: 10, resetsAt: ahead(3600))
        XCTAssertEqual(UsageView.codexTitle(tier, fallback: "slot default"), "slot default")
    }

    func testCodexTitlePrefersTheReportedWindowOverTheFallback() {
        let tier = QuotaTier(utilization: 10,
                             resetsAt: ahead(3600),
                             windowLength: QuotaWindow.sevenDays)
        XCTAssertEqual(UsageView.codexTitle(tier, fallback: "Current session (5h)"),
                       "Current week")
    }

    // MARK: - Pace warning

    // The row shows the warning only when usage is meaningfully ahead of the
    // clock; a tier that is merely on pace must stay quiet, or the orange
    // becomes something to learn to ignore.
    func testWarnsWhenUsageIsAheadOfTheClock() {
        // 62% used, 40% of a 5h window gone.
        let tier = QuotaTier(utilization: 62,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceWarning(tier, now: now), "22% ahead of pace")
    }

    func testStaysQuietWhenOnPace() {
        // 46% used, 45% elapsed — 1 point apart.
        let tier = QuotaTier(utilization: 46,
                             resetsAt: ahead(0.55 * QuotaWindow.sevenDays),
                             windowLength: QuotaWindow.sevenDays)
        XCTAssertNil(UsageView.paceWarning(tier, now: now))
    }

    func testStaysQuietWhenUnderPace() {
        let tier = QuotaTier(utilization: 11,
                             resetsAt: ahead(0.64 * QuotaWindow.sevenDays),
                             windowLength: QuotaWindow.sevenDays)
        XCTAssertNil(UsageView.paceWarning(tier, now: now))
    }

    func testThresholdBoundary() {
        XCTAssertNil(QuotaReset.paceOvershoot(utilization: 44.9, elapsedFraction: 0.40))
        XCTAssertEqual(QuotaReset.paceOvershoot(utilization: 45, elapsedFraction: 0.40) ?? 0,
                       5, accuracy: 0.0001)
    }

    // No window or no reset time means no elapsed fraction, so nothing to
    // compare against — silence, not a warning derived from a missing number.
    func testNoWarningWithoutAWindow() {
        XCTAssertNil(UsageView.paceWarning(QuotaTier(utilization: 99, resetsAt: ahead(3600)),
                                           now: now))
        XCTAssertNil(UsageView.paceWarning(QuotaTier(utilization: 99, resetsAt: nil,
                                                     windowLength: QuotaWindow.fiveHours),
                                           now: now))
    }

    func testOvershootClampsNegativeInputs() {
        XCTAssertNil(QuotaReset.paceOvershoot(utilization: -20, elapsedFraction: 0.5))
        XCTAssertEqual(QuotaReset.paceOvershoot(utilization: 40, elapsedFraction: -1) ?? 0,
                       40, accuracy: 0.0001)
    }

    // The row prints utilization unclamped, so the overshoot has to agree with
    // it: "113% used" beside "50% ahead of pace" is arithmetic that fails.
    func testOvershootAgreesWithAnOver100Reading() {
        XCTAssertEqual(QuotaReset.paceOvershoot(utilization: 113, elapsedFraction: 0.50) ?? 0,
                       63, accuracy: 0.0001)
    }

    // The warning is visible text with its own a11y element, so repeating it in
    // the bar's accessibilityValue made VoiceOver announce it twice.
    func testAccessibilityValueDoesNotRepeatTheWarning() {
        let tier = QuotaTier(utilization: 62,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceWarning(tier, now: now), "22% ahead of pace")
        XCTAssertEqual(UsageView.paceDescription(tier, now: now),
                       "62% used, 40% of the window elapsed")
    }

    // MARK: - Widget ring labels

    // The pill named Codex's rings by slot too, so a weekly window in `primary`
    // read "5h" on the pill while the Usage tab read "Current week".
    func testWidgetRingLabelFollowsTheReportedWindow() {
        let weekly = QuotaTier(utilization: 13,
                               resetsAt: ahead(3600),
                               windowLength: QuotaWindow.sevenDays)
        XCTAssertEqual(WidgetQuota.ringLabel(weekly, fallback: "5h"), "7d")

        let session = QuotaTier(utilization: 13,
                                resetsAt: ahead(3600),
                                windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(WidgetQuota.ringLabel(session, fallback: "7d"), "5h")
    }

    func testWidgetRingLabelFallsBackWithNoWindow() {
        XCTAssertEqual(WidgetQuota.ringLabel(nil, fallback: "5h"), "5h")
        XCTAssertEqual(
            WidgetQuota.ringLabel(QuotaTier(utilization: 1, resetsAt: nil), fallback: "7d"), "7d")
    }
}
