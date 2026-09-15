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

    // Regression: the pill counts down whichever window is shorter, and Codex
    // frequently publishes only a weekly one — which rendered as "111h41m"
    // because the format was written for a 5-hour window.
    func testShortLabelRollsIntoDays() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(4 * 86400 + 15 * 3600), now: now), "4d15h")
    }

    func testShortLabelDropsZeroHoursOnAWholeDay() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(3 * 86400), now: now), "3d")
    }

    // Just under a day stays in hours rather than rounding up to "1d".
    func testShortLabelBelowADayStaysInHours() {
        XCTAssertEqual(QuotaReset.shortLabel(until: ahead(23 * 3600 + 59 * 60), now: now), "23h59m")
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

    // MARK: - absoluteLabel

    // Pinned to a fixed instant and an explicit timezone: the whole point of
    // this label is that a Codex unix timestamp and an Antigravity ISO 8601
    // string come out in the same shape Claude's CLI prints, so the exact
    // characters are the contract.
    private let london = TimeZone(identifier: "Europe/London")!
    private let noon = Date(timeIntervalSince1970: 1_719_748_800)  // 30 Jun 2024, 13:00 BST

    func testAbsoluteLabelWithMinutes() {
        let resets = Date(timeIntervalSince1970: 1_719_769_800)
        XCTAssertEqual(QuotaReset.absoluteLabel(until: resets, now: noon, timeZone: london),
                       "Jun 30 at 6:50pm")
    }

    // Claude drops ":00" on the hour; so do we.
    func testAbsoluteLabelOnTheHour() {
        let resets = Date(timeIntervalSince1970: 1_720_058_400)
        XCTAssertEqual(QuotaReset.absoluteLabel(until: resets, now: noon, timeZone: london),
                       "Jul 4 at 3am")
    }

    func testAbsoluteLabelAtMidnight() {
        let resets = Date(timeIntervalSince1970: 1_722_466_800)
        XCTAssertEqual(QuotaReset.absoluteLabel(until: resets, now: noon, timeZone: london),
                       "Aug 1 at 12am")
    }

    // Same instant, two timezones. Claude's CLI reports the reset in the
    // timezone on the account; we render every client's in the machine's.
    func testAbsoluteLabelRendersInTheGivenTimezone() {
        let resets = Date(timeIntervalSince1970: 1_719_769_800)
        XCTAssertEqual(QuotaReset.absoluteLabel(until: resets, now: noon,
                                                timeZone: TimeZone(identifier: "UTC")!),
                       "Jun 30 at 5:50pm")
    }

    func testAbsoluteLabelIsNilOnceElapsed() {
        XCTAssertNil(QuotaReset.absoluteLabel(until: now, now: now, timeZone: london))
        XCTAssertNil(QuotaReset.absoluteLabel(until: ahead(-60), now: now, timeZone: london))
    }

    // What we render, ClaudeCliQuotaProbe reads back. Rendered in the host's
    // timezone because that's what parseResetsAt assumes when the line carries
    // no "(Europe/London)" suffix of its own.
    func testAbsoluteLabelRoundTripsThroughTheClaudeParser() {
        let resets = Date(timeIntervalSince1970: 1_719_769_800)
        let label = QuotaReset.absoluteLabel(until: resets, now: noon)
        XCTAssertEqual(ClaudeCliQuotaProbe.parseResetsAt(label ?? "", now: noon), resets)
    }

    // MARK: - fullLabel

    func testFullLabelPairsCountdownWithClockTime() {
        let resets = Date(timeIntervalSince1970: 1_719_769_800)
        let label = QuotaReset.fullLabel(until: resets, now: noon, timeZone: london)
        // The countdown half is RelativeDateTimeFormatter's, so its wording is
        // the host's locale; only the pairing and the clock half are ours.
        XCTAssertEqual(label?.hasSuffix(" \u{00B7} Jun 30 at 6:50pm"), true)
        let countdown = QuotaReset.relativeLabel(until: resets, now: noon)
        XCTAssertEqual(label?.hasPrefix(countdown ?? "#"), true)
    }

    func testFullLabelIsNilOnceElapsed() {
        XCTAssertNil(QuotaReset.fullLabel(until: ahead(-60), now: now, timeZone: london))
    }

    // MARK: - remaining

    func testRemainingIsNilAtAndAfterTheDeadline() {
        XCTAssertEqual(QuotaReset.remaining(until: ahead(60), now: now), 60)
        XCTAssertNil(QuotaReset.remaining(until: now, now: now))
        XCTAssertNil(QuotaReset.remaining(until: ahead(-60), now: now))
    }
}
