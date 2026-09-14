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

    func testAccessibilityLabelCarriesBothNumbers() {
        let tier = QuotaTier(utilization: 62,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceDescription(tier, now: now),
                       "62% used, 40% of the window elapsed")
    }

    func testAccessibilityLabelOmitsPaceWhenUnknown() {
        let tier = QuotaTier(utilization: 62, resetsAt: nil)
        XCTAssertEqual(UsageView.paceDescription(tier, now: now), "62% used")
    }

    // VoiceOver must not read "62% used" while the row prints "38% left".
    func testAccessibilityLabelFollowsTheShowRemainingToggle() {
        let tier = QuotaTier(utilization: 62,
                             resetsAt: ahead(3 * 3600),
                             windowLength: QuotaWindow.fiveHours)
        XCTAssertEqual(UsageView.paceDescription(tier, showRemaining: true, now: now),
                       "38% left, 40% of the window elapsed")
        XCTAssertEqual(UsageView.paceDescription(tier, showRemaining: false, now: now),
                       "62% used, 40% of the window elapsed")
    }

    func testCodexTitleFallsBackWhenNoWindowReported() {
        let tier = QuotaTier(utilization: 10, resetsAt: ahead(3600))
        XCTAssertEqual(UsageView.codexTitle(tier, fallback: "Current week"), "Current week")
    }
}
