import XCTest

@testable import StackNudgePanelCore

final class FakeJoinDetector: JoinDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: JoinState
    private var _calls: [String] = []
    init(_ state: JoinState) { _state = state }

    var state: JoinState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    func check(url: String) -> JoinState {
        lock.withLock { _calls.append(url) }
        return state
    }
}

final class JoinTargetTests: XCTestCase {

    func testMeetCodesInVariousUrlShapes() {
        let code = JoinTarget.meetCode(in:)
        XCTAssertEqual(code("https://meet.google.com/abc-defg-hij"), "abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/abc-defg-hij?authuser=1"), "abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/abc-defg-hij?authuser=1&hs=122&pli=1"), "abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/u/2/abc-defg-hij"), "abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/ABC-defg-hij#x"), "abc-defg-hij")
        // the shape newer Meet tabs show while you are in the call
        XCTAssertEqual(code("https://meet.google.com/meet/emh-pjrs-fxk"), "emh-pjrs-fxk")
        XCTAssertEqual(code("https://meet.google.com/u/1/meet/emh-pjrs-fxk?authuser=1"), "emh-pjrs-fxk")
        XCTAssertTrue(JoinTarget.of("https://meet.google.com/emh-pjrs-fxk").matches(tab: "https://meet.google.com/meet/emh-pjrs-fxk"))
        XCTAssertNil(code("https://meet.google.com/home"))
        XCTAssertNil(code("https://meet.google.com/landing"))
        XCTAssertNil(code("https://meet.google.com/"))
        XCTAssertNil(code("https://example.com/abc-defg-hij"))
    }

    func testZoomIdsFromJoinLinks() {
        XCTAssertEqual(JoinTarget.zoomId(in: "https://us02web.zoom.us/j/81234567890?pwd=abc"), "81234567890")
        XCTAssertEqual(JoinTarget.zoomId(in: "https://zoom.us/j/81234567890"), "81234567890")
        XCTAssertEqual(JoinTarget.zoomId(in: "https://app.zoom.us/wc/81234567890/join"), "81234567890")
        XCTAssertNil(JoinTarget.zoomId(in: "https://zoom.us/my/ana"))
    }

    func testTargetsByProvider() {
        XCTAssertEqual(JoinTarget.of("https://meet.google.com/abc-defg-hij?authuser=1"), .meet(code: "abc-defg-hij"))
        XCTAssertEqual(JoinTarget.of("https://us02web.zoom.us/j/81234567890"), .zoom(id: "81234567890"))
        XCTAssertEqual(JoinTarget.of("https://zoom.us/my/ana"), .zoom(id: nil))
        XCTAssertEqual(JoinTarget.of("https://teams.microsoft.com/l/meetup-join/19%3a"), .teams)
        XCTAssertEqual(JoinTarget.of("https://acme.webex.com/meet/x"), .unsupported)
    }

    func testTabMatchesOnlyTheSameMeeting() {
        let t = JoinTarget.meet(code: "abc-defg-hij")
        XCTAssertTrue(t.matches(tab: "https://meet.google.com/abc-defg-hij?authuser=3"))
        XCTAssertFalse(t.matches(tab: "https://meet.google.com/zzz-yyyy-xxx"))
        XCTAssertFalse(t.matches(tab: "https://calendar.google.com/abc-defg-hij"))
    }

    func testDecisionNeedsAReadableBrowserToSayNotJoined() {
        let t = JoinTarget.meet(code: "abc-defg-hij")
        let open = TabRead.urls(["https://meet.google.com/abc-defg-hij?authuser=1"])
        func decide(_ reads: [TabRead]) -> JoinState { JoinDecision.decide(t, reads: reads, zoomInMeeting: false, teamsWindow: false) }
        XCTAssertEqual(decide([.urls(["https://example.com"]), open]), .joined)
        XCTAssertEqual(decide([.urls(["https://example.com"])]), .notJoined)
        XCTAssertEqual(decide([.denied]), .unknown)
        XCTAssertEqual(decide([.denied, .urls([])]), .notJoined)
        XCTAssertEqual(decide([]), .unknown)
    }

    func testZoomJoinedFromTheHelperProcess() {
        let t = JoinTarget.zoom(id: "81234567890")
        XCTAssertEqual(JoinDecision.decide(t, reads: [], zoomInMeeting: true, teamsWindow: false), .joined)
        XCTAssertEqual(JoinDecision.decide(t, reads: [], zoomInMeeting: false, teamsWindow: false), .notJoined)
        XCTAssertEqual(JoinDecision.decide(t, reads: [.denied], zoomInMeeting: false, teamsWindow: false), .unknown)
        XCTAssertEqual(JoinDecision.decide(t, reads: [.urls(["https://app.zoom.us/wc/81234567890/start"])], zoomInMeeting: false, teamsWindow: false), .joined)
        XCTAssertEqual(JoinDecision.decide(.unsupported, reads: [], zoomInMeeting: false, teamsWindow: false), .unknown)
    }

    func testTeamsJoinedFromItsWindowTitle() {
        XCTAssertEqual(JoinDecision.decide(.teams, reads: [], zoomInMeeting: false, teamsWindow: true), .joined)
        XCTAssertEqual(JoinDecision.decide(.teams, reads: [.urls([])], zoomInMeeting: false, teamsWindow: false), .notJoined)
        XCTAssertEqual(JoinDecision.decide(.teams, reads: [], zoomInMeeting: false, teamsWindow: false), .unknown)
    }
}

@MainActor
final class JoinWatcherTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let meet = "https://meet.google.com/abc-defg-hij"

    private func reminder(_ id: String = "m", url: String? = nil) -> JoinCandidate {
        JoinCandidate(id: id, url: url ?? meet, start: start)
    }

    private final class Harness {
        var now: Date
        var joined: [String] = []
        var notJoined: [String] = []
        let detector: FakeJoinDetector
        var watcher: JoinWatcher!
        init(now: Date, state: JoinState) {
            self.now = now
            detector = FakeJoinDetector(state)
        }
    }

    private func harness(at offset: TimeInterval, _ state: JoinState, enabled: Bool = true) -> Harness {
        let h = Harness(now: start.addingTimeInterval(offset), state: state)
        h.watcher = JoinWatcher(
            detector: h.detector, clock: { [unowned h] in h.now }, enabled: { enabled },
            background: { $0() }, deliver: { $0() }, autoSchedule: false,
            onJoined: { [unowned h] in h.joined.append($0.id) }, onNotJoined: { [unowned h] in h.notJoined.append($0.id) })
        return h
    }

    func testJoinInsideTheWindowResolvesTheReminder() {
        let h = harness(at: -120, .joined)
        h.watcher.sync([reminder()])
        XCTAssertEqual(h.joined, ["m"])
        h.now = start.addingTimeInterval(-60)
        h.watcher.sync([reminder()])
        XCTAssertEqual(h.detector.calls.count, 1)
    }

    func testNotJoinedAtTheStartReportsOnceAndKeepsPolling() {
        let h = harness(at: -60, .notJoined)
        h.watcher.sync([reminder()])
        XCTAssertTrue(h.notJoined.isEmpty)
        h.now = start.addingTimeInterval(1)
        h.watcher.poll()
        h.now = start.addingTimeInterval(20)
        h.watcher.poll()
        XCTAssertEqual(h.notJoined, ["m"])
        XCTAssertTrue(h.joined.isEmpty)
        XCTAssertEqual(h.detector.calls.count, 3)

        h.detector.state = .joined
        h.now = start.addingTimeInterval(40)
        h.watcher.poll()
        XCTAssertEqual(h.joined, ["m"])
    }

    func testUnknownChangesNothing() {
        let h = harness(at: 10, .unknown)
        h.watcher.sync([reminder()])
        XCTAssertTrue(h.joined.isEmpty && h.notJoined.isEmpty)
    }

    func testPollsAtMostEveryFifteenSeconds() {
        let h = harness(at: -200, .notJoined)
        h.watcher.sync([reminder()])
        for s in stride(from: -198.0, through: -186, by: 2) {
            h.now = start.addingTimeInterval(s)
            h.watcher.poll()
        }
        XCTAssertEqual(h.detector.calls.count, 1)
        h.now = start.addingTimeInterval(-185)
        h.watcher.poll()
        XCTAssertEqual(h.detector.calls.count, 2)
    }

    func testOnlyPollsInsideTheWindow() {
        let early = harness(at: -301, .notJoined)
        early.watcher.sync([reminder()])
        XCTAssertTrue(early.detector.calls.isEmpty)
        early.now = start.addingTimeInterval(-300)
        early.watcher.poll()
        early.watcher.sync([reminder()])
        XCTAssertEqual(early.detector.calls.count, 1)

        let late = harness(at: 299, .notJoined)
        late.watcher.sync([reminder()])
        XCTAssertEqual(late.detector.calls.count, 1)
        late.now = start.addingTimeInterval(300)
        late.watcher.poll()
        late.watcher.sync([reminder()])
        XCTAssertEqual(late.detector.calls.count, 1)
    }

    func testIgnoresLinklessRemindersAndTheDisabledSetting() {
        let h = harness(at: 0, .joined)
        h.watcher.sync([reminder("b", url: "ical://ekevent/x?method=show"), reminder("c", url: "")])
        XCTAssertTrue(h.detector.calls.isEmpty)

        let off = harness(at: 0, .joined, enabled: false)
        off.watcher.sync([reminder()])
        XCTAssertTrue(off.detector.calls.isEmpty)
    }

    func testAJoinedMeetingIsNeverCheckedAgain() {
        let h = harness(at: 0, .joined)
        h.watcher.sync([reminder()])
        h.now = start.addingTimeInterval(60)
        h.watcher.sync([reminder()])
        h.watcher.poll()
        XCTAssertEqual(h.detector.calls.count, 1)
        XCTAssertEqual(h.joined, ["m"])
    }
}
