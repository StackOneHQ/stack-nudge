import XCTest

@testable import StackNudgePanelCore

// The boundary is what matters: a deadline that has passed must read as unknown
// on every surface. The widget's old formatter floored at "1m", so a held-over
// snapshot showed a live one-minute countdown indefinitely.
final class QuotaResetTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func ahead(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    // MARK: - shortLabel

    func testShortLabelHoursAndMinutes() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(2 * 3600 + 24 * 60), now: now), "2h24m")
    }

    func testShortLabelDropsZeroMinutes() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(2 * 3600), now: now), "2h")
    }

    func testShortLabelUnderAnHour() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(14 * 60), now: now), "14m")
    }

    // Sub-minute rounds up to "1m" — it really is about to reset.
    func testShortLabelSubMinuteRoundsUp() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(20), now: now), "1m")
    }

    func testShortLabelIsNilOnceElapsed() {
        XCTAssertNil(QuotaReset.shortLabel(until: now, now: now))
        XCTAssertNil(QuotaReset.shortLabel(until: ahead(-1), now: now))
        // The shape the year-splice bug produced: a deadline ~12 months back.
        XCTAssertNil(QuotaReset.shortLabel(until: ahead(-365 * 24 * 3600), now: now))
    }

    // MARK: - relativeLabel

    func testRelativeLabelPresentWhileFuture() {
        XCTAssertNotNil(QuotaReset.relativeLabel(until: ahead(2 * 3600), now: now))
    }

    func testRelativeLabelIsNilOnceElapsed() {
        XCTAssertNil(QuotaReset.relativeLabel(until: ahead(-2 * 3600), now: now))
    }

    // MARK: - remaining

    func testRemainingIsNilAtAndAfterTheDeadline() {
        XCTAssertEqual(QuotaReset.remaining(until: ahead(60), now: now), 60)
        XCTAssertNil(QuotaReset.remaining(until: now, now: now))
        XCTAssertNil(QuotaReset.remaining(until: ahead(-60), now: now))
    }
}
