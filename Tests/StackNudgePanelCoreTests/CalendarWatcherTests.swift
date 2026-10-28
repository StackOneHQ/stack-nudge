import XCTest

@testable import StackNudgePanelCore

// The watcher's decisions, driven through `apply` so no test touches EventKit,
// the real calendar or ~/.stack-nudge.
@MainActor
final class CalendarWatcherTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir = ""
    private var store = EventStore()
    private var settings = CalendarSettings()

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "calendar-watcher-" + UUID().uuidString
        store = EventStore()
        settings = CalendarSettings()
        settings.summary.enabled = false
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(atPath: dir) }
    }

    private func watcher(detector: JoinDetector = FakeJoinDetector(.unknown), at now: @escaping () -> Date) -> CalendarWatcher {
        CalendarWatcher(events: store, settings: { [unowned self] in settings }, clock: now, stateDir: dir,
                        detector: detector, background: { $0() }, deliver: { $0() }, autoSchedule: false)
    }

    private func meeting(_ id: String = "a", in minutes: Double, join: String = "") -> Meeting {
        let start = t0.addingTimeInterval(minutes * 60)
        return Meeting(id: id, itemId: id, title: "Standup", start: start, end: start.addingTimeInterval(1800),
                       location: "", organizer: "Ana", joinUrl: join, calendar: "Work")
    }

    private func reminders() -> [NudgeEvent] {
        store.events.filter { $0.key?.hasPrefix("meeting:") == true }
    }

    func testTheFirstRefreshSeedsWithoutAnnouncing() {
        let w = watcher { self.t0 }
        w.apply(current: [meeting(in: 120)], signature: "x", now: t0)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testAMeetingAddedLaterIsAnnounced() {
        let w = watcher { self.t0 }
        w.apply(current: [], signature: "x", now: t0)
        w.apply(current: [meeting(in: 120)], signature: "x", now: t0.addingTimeInterval(60))
        XCTAssertEqual(store.events.map(\.title), ["New meeting: Standup"])
        XCTAssertEqual(store.events.first?.source, .calendar)
    }

    func testTheHeadsUpIsAnActionRowThatTheStartAlertReplaces() {
        let m = meeting(in: 10)
        var now = t0
        let w = watcher { now }
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertEqual(reminders().map(\.severity), [.action])
        XCTAssertEqual(reminders().first?.title, "Standup starts in 10 min")
        XCTAssertEqual(reminders().first?.key, MeetingDiff.dueKey(m))

        now = m.start
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertEqual(reminders().map(\.severity), [.alert], "same key, so one row")
        XCTAssertEqual(reminders().first?.title, "Standup is starting now")

        w.apply(current: [m], signature: "x", now: now.addingTimeInterval(60))
        XCTAssertEqual(store.events.count, 1, "the alert fires once")
    }

    func testTheReminderOpensTheMeetingLink() {
        let m = meeting(in: 10, join: "https://meet.google.com/abc-defg-hij")
        let w = watcher { self.t0 }
        w.apply(current: [m], signature: "x", now: t0)
        XCTAssertEqual(reminders().first?.url?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testTheReminderGoesFiveMinutesAfterTheStart() {
        let m = meeting(in: 10)
        let w = watcher { self.t0 }
        w.apply(current: [m], signature: "x", now: t0)
        w.apply(current: [m], signature: "x", now: m.start)
        w.apply(current: [m], signature: "x", now: m.start.addingTimeInterval(299))
        XCTAssertEqual(reminders().count, 1)
        w.apply(current: [m], signature: "x", now: m.start.addingTimeInterval(300))
        XCTAssertTrue(reminders().isEmpty)
        w.apply(current: [m], signature: "x", now: m.start.addingTimeInterval(360))
        XCTAssertTrue(reminders().isEmpty, "an expired reminder does not come back")
    }

    func testJoiningClearsTheReminderAndSuppressesTheStartAlert() {
        let m = meeting(in: 4, join: "https://meet.google.com/abc-defg-hij")
        var now = t0
        let detector = FakeJoinDetector(.joined)
        let w = watcher(detector: detector) { now }
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertTrue(reminders().isEmpty, "joined inside the first check")
        XCTAssertEqual(detector.calls, ["https://meet.google.com/abc-defg-hij"])

        now = m.start
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertTrue(reminders().isEmpty, "no start alert for a meeting already joined")
    }

    func testNotJoiningLeavesTheAlertUpUntilItExpires() {
        let m = meeting(in: 4, join: "https://meet.google.com/abc-defg-hij")
        var now = t0
        let w = watcher(detector: FakeJoinDetector(.notJoined)) { now }
        w.apply(current: [m], signature: "x", now: now)
        now = m.start
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertEqual(reminders().map(\.severity), [.alert])
        now = m.start.addingTimeInterval(120)
        w.apply(current: [m], signature: "x", now: now)
        XCTAssertEqual(reminders().map(\.severity), [.alert])
    }

    func testDetectionOffNeverLooksAtTheBrowser() {
        settings.detectJoin = false
        let m = meeting(in: 4, join: "https://meet.google.com/abc-defg-hij")
        let detector = FakeJoinDetector(.joined)
        let w = watcher(detector: detector) { self.t0 }
        w.apply(current: [m], signature: "x", now: t0)
        XCTAssertTrue(detector.calls.isEmpty)
        XCTAssertEqual(reminders().count, 1)
    }

    func testAMovedMeetingLosesItsOldReminder() {
        let m = meeting(in: 10)
        let w = watcher { self.t0 }
        w.apply(current: [m], signature: "x", now: t0)
        XCTAssertEqual(reminders().count, 1)
        var moved = m
        moved.start = m.start.addingTimeInterval(3600)
        moved.end = m.end.addingTimeInterval(3600)
        w.apply(current: [moved], signature: "x", now: t0.addingTimeInterval(60))
        XCTAssertTrue(reminders().isEmpty)
        XCTAssertEqual(store.events.map(\.title), ["Meeting changed: Standup"])
    }

    func testTheLeadTimeSettingMovesTheHeadsUp() {
        settings.leadMinutes = 5
        let m = meeting(in: 8)
        let w = watcher { self.t0 }
        w.apply(current: [m], signature: "x", now: t0)
        XCTAssertTrue(reminders().isEmpty)
        w.apply(current: [m], signature: "x", now: t0.addingTimeInterval(3 * 60))
        XCTAssertEqual(reminders().first?.title, "Standup starts in 5 min")
    }

    func testTheSummaryIsOneInfoRowOncePerDay() {
        let cal = Calendar.current
        let nine = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 5))!
        var s = CalendarSettings()
        s.summary.weekdaysOnly = false
        settings = s
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14))!
        let m = Meeting(id: "a", itemId: "a", title: "Retro", start: start, end: start.addingTimeInterval(1800),
                        location: "", organizer: "", joinUrl: "", calendar: "Work")
        let w = watcher { nine }
        w.apply(current: [m], signature: "x", now: nine)
        w.apply(current: [m], signature: "x", now: nine.addingTimeInterval(60))
        XCTAssertEqual(store.events.map(\.title), ["Today: 1 meeting"])
        XCTAssertEqual(store.events.first?.severity, .info)
        XCTAssertEqual(store.events.first?.message, "14:00 Retro")
    }

    func testTodaysMeetingsAreReportedForAView() {
        let cal = Calendar.current
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        func at(_ day: Int, _ hour: Int, _ id: String) -> Meeting {
            let s = cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
            return Meeting(id: id, itemId: id, title: id, start: s, end: s.addingTimeInterval(1800),
                           location: "", organizer: "", joinUrl: "", calendar: "Work")
        }
        var reported: [Meeting] = []
        let w = CalendarWatcher(events: store, settings: { [unowned self] in settings }, clock: { noon }, stateDir: dir,
                                detector: FakeJoinDetector(.unknown), background: { $0() }, deliver: { $0() },
                                autoSchedule: false, onToday: { reported = $0 })
        w.apply(current: [at(21, 15, "late"), at(21, 9, "early"), at(22, 9, "tomorrow")], signature: "x", now: noon)
        XCTAssertEqual(reported.map(\.id), ["early", "late"])
    }
}
