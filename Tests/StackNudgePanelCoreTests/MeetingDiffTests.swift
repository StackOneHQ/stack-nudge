import XCTest

@testable import StackNudgePanelCore

// The meeting rules ported from Hounder: what counts as added, changed or
// cancelled, when a heads-up is due, and when the morning summary goes out.
final class MeetingDiffTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lead: TimeInterval = 600

    private func meeting(_ id: String, title: String = "Standup", in minutes: Double = 120, length: Double = 30,
                         location: String = "", organizer: String = "Ana") -> Meeting {
        let start = now.addingTimeInterval(minutes * 60)
        return Meeting(id: id, itemId: id, title: title, start: start, end: start.addingTimeInterval(length * 60),
                       location: location, organizer: organizer, joinUrl: "", calendar: "Work")
    }

    func testDuplicateCalendarCopiesCollapse() {
        var a = meeting("a", title: "Engineering Standup")
        var b = meeting("b", title: "Engineering Standup")
        b.calendar = "Product Engineering"
        b.joinUrl = "https://meet.google.com/abc-defg-hij"
        a.joinUrl = ""
        let out = [a, b, meeting("c", title: "Retro", in: 300)].dedupedByOccurrence()
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first?.joinUrl, "https://meet.google.com/abc-defg-hij")
    }

    func testLateSyncedOldMeetingIsNotAnnounced() {
        var m = meeting("old")
        m.created = now.addingTimeInterval(-86_400 * 3)
        XCTAssertTrue(MeetingDiff.diff(old: [], new: [m], now: now, since: now.addingTimeInterval(-60)).isEmpty)
        m.created = now.addingTimeInterval(-30)
        XCTAssertEqual(MeetingDiff.diff(old: [], new: [m], now: now, since: now.addingTimeInterval(-60)).count, 1)
    }

    func testBriefDropDuringSyncIsNotACancellation() {
        let m = meeting("a")
        // First refresh without it: held, nothing announced.
        XCTAssertTrue(MeetingDiff.diff(old: [m], new: [], now: now, missingSince: [:]).isEmpty)
        let held = MeetingDiff.held(old: [m], new: [], now: now, missingSince: [:])
        XCTAssertEqual(held["a"], now)
        // Still missing a minute later: still held.
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(MeetingDiff.diff(old: [m], new: [], now: later, missingSince: held).isEmpty)
        // Missing past the grace period: cancelled, and no longer held.
        let past = now.addingTimeInterval(MeetingDiff.cancelGrace + 1)
        XCTAssertEqual(MeetingDiff.diff(old: [m], new: [], now: past, missingSince: held).map(\.kind), ["meeting-cancelled"])
        XCTAssertTrue(MeetingDiff.held(old: [m], new: [], now: past, missingSince: held).isEmpty)
    }

    func testNewIdForTheSameMeetingIsNeitherCancelledNorAdded() {
        var moved = meeting("new-id")
        moved.created = now
        XCTAssertTrue(MeetingDiff.diff(old: [meeting("old-id")], new: [moved], now: now, since: now.addingTimeInterval(-60)).isEmpty)
        XCTAssertTrue(MeetingDiff.missing(old: [meeting("old-id")], new: [moved], now: now).isEmpty)
    }

    func testAdded() {
        let out = MeetingDiff.diff(old: [], new: [meeting("a")], now: now)
        XCTAssertEqual(out.map(\.kind), ["meeting-added"])
        XCTAssertEqual(out[0].title, "New meeting: Standup")
        XCTAssertEqual(out[0].severity, .info)
        XCTAssertTrue(out[0].body.hasSuffix(", Ana"))
    }

    func testMovedWithinDayIsActionWhenSoon() {
        let old = meeting("a")
        var new = old
        new.start = old.start.addingTimeInterval(90 * 60)
        new.end = old.end.addingTimeInterval(90 * 60)
        let out = MeetingDiff.diff(old: [old], new: [new], now: now)
        XCTAssertEqual(out.map(\.kind), ["meeting-changed"])
        XCTAssertEqual(out[0].severity, .action)
        let c = MeetingDiff.clock
        XCTAssertEqual(out[0].body, "\(c(old.start))\u{2013}\(c(old.end)) \u{2192} \(c(new.start))\u{2013}\(c(new.end))")
    }

    func testRenamedAndLocationFarAwayIsInfo() {
        let old = meeting("a", in: 60 * 48)
        var new = old
        new.title = "Sync"
        new.location = "Room 2"
        let out = MeetingDiff.diff(old: [old], new: [new], now: now)
        XCTAssertEqual(out[0].severity, .info)
        XCTAssertEqual(out[0].body, "Was \u{201C}\(old.title)\u{201D}\nLocation: \(old.location.isEmpty ? "none" : old.location) \u{2192} Room 2")
    }

    func testJoinLinkChangeAloneIsQuiet() {
        let old = meeting("a")
        var new = old
        new.joinUrl = "https://meet.google.com/abc-defg-hij"
        XCTAssertTrue(MeetingDiff.diff(old: [old], new: [new], now: now).isEmpty)
    }

    func testCancelledOnlyWhileUpcoming() {
        let upcoming = meeting("a")
        let finished = meeting("b", in: -120)
        let out = MeetingDiff.diff(old: [upcoming, finished], new: [], now: now)
        XCTAssertEqual(out.map(\.kind), ["meeting-cancelled"])
        XCTAssertEqual(out[0].title, "Meeting cancelled: Standup")
    }

    func testUnchangedIsQuiet() {
        let m = meeting("a")
        XCTAssertTrue(MeetingDiff.diff(old: [m], new: [m], now: now).isEmpty)
    }

    func testNoticeBecomesACalendarFeedEvent() {
        let out = MeetingDiff.diff(old: [], new: [meeting("a")], now: now)
        let event = out[0].event(now: now)
        XCTAssertEqual(event.source, .calendar)
        XCTAssertEqual(event.tag, "calendar")
        XCTAssertEqual(event.severity, .info)
        XCTAssertTrue(event.url?.absoluteString.hasPrefix("ical://ekevent/a") == true)
    }

    // MARK: Heads-up

    func testSoonFiresOnceAndSchedulesNext() {
        let m = meeting("a", in: 9)
        let later = meeting("b", in: 60)
        XCTAssertEqual(MeetingDiff.due([m, later], fired: [], lead: lead, now: now).map(\.id), ["a"])
        XCTAssertTrue(MeetingDiff.due([m], fired: [MeetingDiff.dueKey(m)], lead: lead, now: now).isEmpty)
        XCTAssertEqual(MeetingDiff.nextDue([m, later], fired: [MeetingDiff.dueKey(m)], lead: lead, now: now),
                       later.start.addingTimeInterval(-600))
        let n = MeetingDiff.soonNotice(meeting("a", in: 10), now: now)
        XCTAssertEqual(n.title, "Standup starts in 10 min")
        XCTAssertEqual(n.severity, .action)
    }

    func testLeadTimeWidensTheHeadsUpWindow() {
        let m = meeting("a", in: 14)
        XCTAssertTrue(MeetingDiff.due([m], fired: [], lead: 600, now: now).isEmpty)
        XCTAssertEqual(MeetingDiff.due([m], fired: [], lead: 900, now: now).map(\.id), ["a"])
        XCTAssertEqual(MeetingDiff.nextDue([m], fired: [], lead: 900, now: now.addingTimeInterval(-3600)),
                       m.start.addingTimeInterval(-900))
    }

    func testReminderKeyNamesTheMeetingAndItsStart() {
        let m = meeting("a")
        XCTAssertEqual(MeetingDiff.dueKey(m), "meeting:a:\(Int(m.start.timeIntervalSince1970))")
        XCTAssertEqual(MeetingDiff.soonNotice(m, now: now).key, MeetingDiff.dueKey(m))
    }

    func testStartAlertReplacesTheHeadsUpAtAlertSeverity() {
        let m = meeting("a", in: 10)
        let soon = MeetingDiff.soonNotice(m, now: now)
        let started = MeetingDiff.startNotice(m)
        XCTAssertEqual(started.key, soon.key)
        XCTAssertEqual(started.severity, .alert)
        XCTAssertEqual(started.title, "Standup is starting now")
    }

    func testStartAlertNeedsAHeadsUpAndFiresOnce() {
        let m = meeting("a", in: 0)
        let key = MeetingDiff.dueKey(m)
        XCTAssertTrue(MeetingDiff.startDue([m], fired: [], started: [], now: now).isEmpty, "never warned, so no alert")
        XCTAssertEqual(MeetingDiff.startDue([m], fired: [key], started: [], now: now).map(\.id), ["a"])
        XCTAssertTrue(MeetingDiff.startDue([m], fired: [key], started: [key], now: now).isEmpty)
        XCTAssertTrue(MeetingDiff.startDue([m], fired: [key], started: [], now: now.addingTimeInterval(-1)).isEmpty)
        XCTAssertTrue(MeetingDiff.startDue([m], fired: [key], started: [], now: now.addingTimeInterval(MeetingDiff.reminderTail)).isEmpty)
    }

    func testReminderExpiresFiveMinutesAfterTheStart() {
        let m = meeting("a", in: 0)
        let key = MeetingDiff.dueKey(m)
        XCTAssertTrue(MeetingDiff.expired([m], fired: [key], now: now.addingTimeInterval(299)).isEmpty)
        XCTAssertEqual(MeetingDiff.expired([m], fired: [key], now: now.addingTimeInterval(300)).map(\.id), ["a"])
        XCTAssertTrue(MeetingDiff.expired([m], fired: [], now: now.addingTimeInterval(300)).isEmpty)
    }

    func testNextReminderStepWalksStartThenExpiry() {
        let m = meeting("a", in: 5)
        let key = MeetingDiff.dueKey(m)
        XCTAssertNil(MeetingDiff.nextReminderStep([m], fired: [], started: [], now: now))
        XCTAssertEqual(MeetingDiff.nextReminderStep([m], fired: [key], started: [], now: now), m.start)
        XCTAssertEqual(MeetingDiff.nextReminderStep([m], fired: [key], started: [key], now: now), m.start.addingTimeInterval(300))
        XCTAssertNil(MeetingDiff.nextReminderStep([m], fired: [key], started: [key], now: m.start.addingTimeInterval(300)))
    }

    func testLinkFallsBackToCalendarDeepLink() {
        XCTAssertTrue(meeting("a").link.hasPrefix("ical://ekevent/a"))
        var m = meeting("a")
        m.joinUrl = "https://zoom.us/j/1"
        XCTAssertEqual(m.link, "https://zoom.us/j/1")
    }

    func testJoinUrlExtraction() {
        XCTAssertEqual(MeetingDiff.joinUrl(in: [nil, "", "Join: https://meet.google.com/abc-defg-hij?authuser=0."]),
                       "https://meet.google.com/abc-defg-hij?authuser=0")
        XCTAssertEqual(MeetingDiff.joinUrl(in: ["see https://acme.zoom.us/j/123456?pwd=x, ok"]), "https://acme.zoom.us/j/123456?pwd=x")
        XCTAssertTrue(MeetingDiff.joinUrl(in: ["https://teams.microsoft.com/l/meetup-join/19%3a"]).contains("meetup-join"))
        XCTAssertTrue(MeetingDiff.joinUrl(in: ["https://acme.webex.com/meet/ana"]).contains("webex.com"))
        XCTAssertEqual(MeetingDiff.joinUrl(in: ["https://example.com/x"]), "")
    }

    func testNotesSnippetIsOnePlainTruncatedLine() {
        var m = meeting("a")
        XCTAssertEqual(m.notesSnippet(), "")
        m.notes = "<p>Agenda&nbsp;&amp; goals</p><ul><li>One</li><li>Two</li></ul>"
        XCTAssertEqual(m.notesSnippet(), "Agenda & goals - One - Two")
        m.notes = String(repeating: "word ", count: 100)
        XCTAssertEqual(m.notesSnippet(limit: 20).count, 20)
        XCTAssertTrue(m.notesSnippet(limit: 20).hasSuffix("\u{2026}"))
    }

    // MARK: Morning summary

    private var cal: Calendar { Calendar.current }

    // Local time, matching `clock`. 2026-10-21 is a Wednesday; 2026-10-24 a Saturday.
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int, title: String) -> Meeting {
        let start = date(day, hour, minute)
        return Meeting(id: "\(title)\(day)\(hour)\(minute)", itemId: "x", title: title, start: start,
                       end: start.addingTimeInterval(1800), location: "", organizer: "", joinUrl: "", calendar: "Work")
    }

    private func due(_ now: Date, _ s: SummarySettings = SummarySettings(), last: String? = nil) -> Bool {
        MeetingDiff.summaryDue(now: now, settings: s, lastDate: last, calendar: cal)
    }

    func testAgendaListsThreeThenCount() {
        let three = [at(21, 10, 0, title: "Standup"), at(21, 11, 30, title: "Design review"), at(21, 14, 0, title: "1:1 with Sam")]
        XCTAssertEqual(MeetingDiff.agenda(three), "10:00 Standup, 11:30 Design review, 14:00 1:1 with Sam")
        let five = three + [at(21, 15, 0, title: "A"), at(21, 16, 0, title: "B")]
        XCTAssertEqual(MeetingDiff.agenda(five), "10:00 Standup, 11:30 Design review, 14:00 1:1 with Sam, +2 more")
    }

    func testSummaryNoticeCountsOnlyToday() throws {
        let meetings = [at(21, 14, 0, title: "Late"), at(21, 10, 0, title: "Early"), at(22, 9, 0, title: "Tomorrow")]
        let n = try XCTUnwrap(MeetingDiff.summaryNotice(meetings, now: date(21, 9), announceEmpty: false, calendar: cal))
        XCTAssertEqual(n.title, "Today: 2 meetings")
        XCTAssertEqual(n.body, "10:00 Early, 14:00 Late")
        XCTAssertEqual(n.kind, "meeting-summary")
        XCTAssertEqual(n.severity, .info)
        XCTAssertEqual(n.url, "ical://")
        XCTAssertEqual(n.key, "meeting-summary:2026-10-21")
        let one = try XCTUnwrap(MeetingDiff.summaryNotice([at(21, 10, 0, title: "Solo")], now: date(21, 9), announceEmpty: false, calendar: cal))
        XCTAssertEqual(one.title, "Today: 1 meeting")
    }

    func testEmptyDaySkippedUnlessWanted() throws {
        let tomorrow = [at(22, 9, 0, title: "Tomorrow")]
        XCTAssertNil(MeetingDiff.summaryNotice(tomorrow, now: date(21, 9), announceEmpty: false, calendar: cal))
        let n = try XCTUnwrap(MeetingDiff.summaryNotice(tomorrow, now: date(21, 9), announceEmpty: true, calendar: cal))
        XCTAssertEqual(n.title, "No meetings today")
    }

    func testSummaryDueWindow() {
        XCTAssertFalse(due(date(21, 8, 59)))
        XCTAssertTrue(due(date(21, 9, 0)))
        XCTAssertTrue(due(date(21, 11, 59)))
        XCTAssertFalse(due(date(21, 12, 0)))
        XCTAssertFalse(due(date(21, 9, 0), SummarySettings(enabled: false)))
        XCTAssertFalse(due(date(21, 9, 0), SummarySettings(minutes: 10 * 60)))
        XCTAssertTrue(due(date(21, 10, 0), SummarySettings(minutes: 10 * 60)))
    }

    func testSummaryOncePerDay() {
        XCTAssertFalse(due(date(21, 9, 5), last: MeetingDiff.dayKey(date(21, 9), calendar: cal)))
        XCTAssertTrue(due(date(21, 9, 5), last: "2026-10-20"))
    }

    func testSummarySkipsWeekendsByDefault() {
        XCTAssertFalse(due(date(24, 9, 5)))
        XCTAssertTrue(due(date(24, 9, 5), SummarySettings(weekdaysOnly: false)))
    }

    func testNextSummaryDueSchedulesAcrossDays() {
        let s = SummarySettings()
        func next(_ now: Date, _ s: SummarySettings = s, last: String? = nil) -> Date? {
            MeetingDiff.nextSummaryDue(now: now, settings: s, lastDate: last, calendar: cal)
        }
        XCTAssertEqual(next(date(21, 7)), date(21, 9))
        XCTAssertEqual(next(date(21, 9, 30), last: "2026-10-21"), date(22, 9))
        XCTAssertEqual(next(date(21, 9, 30)), date(22, 9))
        XCTAssertEqual(next(date(23, 12)), date(26, 9))
        XCTAssertEqual(next(date(24, 8), SummarySettings(weekdaysOnly: false)), date(24, 9))
        XCTAssertNil(next(date(21, 7), SummarySettings(enabled: false)))
    }
}
