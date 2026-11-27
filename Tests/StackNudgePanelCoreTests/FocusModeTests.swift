import XCTest

@testable import StackNudgePanelCore

// Focus as a mute source and the per-tag "Notify me about" filter. The socket
// command that drives them is covered in CommandChannelTests.
@MainActor
final class FocusModeTests: XCTestCase {

    private func feed(_ tag: String?, source: EventSource = .github, title: String = "t") -> NudgeEvent {
        .feed(source: source, tag: tag, title: title, message: "")
    }

    private let agentEvent = NudgeEvent(agent: "claude-code", kind: .stop, title: "Done", message: "")

    // MARK: - Policy

    func test_policy_holdsEverythingWhileFocusedAndRespected() {
        let policy = FocusPolicy(focused: true, respect: true, meetingsPass: false)
        XCTAssertTrue(policy.holds(feed("review")))
        XCTAssertTrue(policy.holds(agentEvent))
        XCTAssertTrue(policy.holds(feed("calendar", source: .calendar)))
    }

    func test_policy_holdsNothingWhenNotFocusedOrNotRespected() {
        XCTAssertFalse(FocusPolicy(focused: false, respect: true, meetingsPass: false).holds(feed("ci")))
        XCTAssertFalse(FocusPolicy(focused: true, respect: false, meetingsPass: false).holds(feed("ci")))
    }

    func test_policy_meetingRemindersPassWhenAllowed() {
        let meeting = feed("calendar", source: .calendar)
        XCTAssertFalse(FocusPolicy(focused: true, respect: true, meetingsPass: true).holds(meeting))
        XCTAssertTrue(FocusPolicy(focused: true, respect: true, meetingsPass: true).holds(feed("review")))
    }

    // MARK: - Tracker

    func test_tracker_returnsWhatItHeldWhenFocusEnds() {
        var focus = FocusTracker()
        XCTAssertTrue(focus.set(true).isEmpty)
        focus.hold(feed("review", title: "a"))
        focus.hold(feed("ci", title: "b"))
        XCTAssertEqual(focus.held.count, 2)
        XCTAssertEqual(focus.set(false).map(\.title), ["a", "b"])
        XCTAssertTrue(focus.held.isEmpty)
        XCTAssertFalse(focus.active)
    }

    func test_tracker_repeatingTheCurrentStateIsANoOp() {
        var focus = FocusTracker()
        _ = focus.set(true)
        focus.hold(feed("review"))
        XCTAssertTrue(focus.set(true).isEmpty)
        XCTAssertEqual(focus.held.count, 1, "a repeated on must not drop what was held")
        XCTAssertTrue(focus.set(false).count == 1)
        XCTAssertTrue(focus.set(false).isEmpty)
    }

    func test_tracker_remembersWhenItLastChanged() {
        var focus = FocusTracker()
        XCTAssertNil(focus.lastChange)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        _ = focus.set(true, now: at)
        XCTAssertEqual(focus.lastChange, at)
    }

    // MARK: - Digest

    func test_digest_nothingHeldIsNoNotice() {
        XCTAssertNil(FocusDigest.text(for: []))
    }

    func test_digest_oneEventKeepsItsTitle() {
        XCTAssertEqual(FocusDigest.text(for: [feed("review", title: "PR #1 approved")]),
                       "While Focus was on: PR #1 approved")
    }

    func test_digest_countsByTagMostFirst() {
        let held = [feed("review"), feed("ci"), feed("review"), feed("review")]
        XCTAssertEqual(FocusDigest.text(for: held), "While Focus was on: 3 review, 1 CI")
    }

    func test_digest_untaggedEventsCountUnderTheirSource() {
        let held = [agentEvent, agentEvent, feed(nil, source: .script)]
        XCTAssertEqual(FocusDigest.text(for: held), "While Focus was on: 2 agent, 1 script")
    }

    // MARK: - Quiet tags

    func test_quietTags_roundTripThroughTheConfigValue() {
        let tags: Set<String> = ["ci", "review-request"]
        XCTAssertEqual(QuietTags.serialize(tags), "ci,review-request")
        XCTAssertEqual(QuietTags.parse("ci, review-request,,"), tags)
        XCTAssertEqual(QuietTags.parse(nil), [])
    }

    func test_quietTags_onlyAMatchingTagIsQuiet() {
        let quiet: Set<String> = ["ci"]
        XCTAssertTrue(QuietTags.isQuiet(feed("ci"), in: quiet))
        XCTAssertFalse(QuietTags.isQuiet(feed("review"), in: quiet))
        XCTAssertFalse(QuietTags.isQuiet(feed(nil), in: quiet))
        XCTAssertFalse(QuietTags.isQuiet(agentEvent, in: quiet))
    }

    func test_quietTags_knownListKeepsBuiltinsThenSeenThenOff() {
        let known = QuietTags.known(seen: ["zeta", "ci"], quiet: ["alpha", "ci"])
        XCTAssertEqual(Array(known.prefix(QuietTags.builtin.count)), QuietTags.builtin)
        XCTAssertEqual(Array(known.dropFirst(QuietTags.builtin.count)), ["zeta", "alpha"])
    }

    // MARK: - Nav

    func test_interrupts_isFalseForAQuietTagAndForAFocusHeldEvent() {
        let nav = PanelNav()
        XCTAssertTrue(nav.interrupts(feed("ci")))
        nav.quietTags = ["ci"]
        XCTAssertFalse(nav.interrupts(feed("ci")))
        XCTAssertTrue(nav.interrupts(feed("review")))
        _ = nav.focus.set(true)
        XCTAssertFalse(nav.interrupts(feed("review")))
        nav.respectFocus = false
        XCTAssertTrue(nav.interrupts(feed("review")))
    }

    func test_focusRowsAreInTheirOwnCategory() {
        let nav = PanelNav()
        XCTAssertEqual(nav.rows(in: .focus), [.respectFocus, .focusMeetings])
        XCTAssertTrue(nav.rows(in: .notifications).contains(.notifyTagsPage))
    }

    func test_notifyTagSelectionClampsToTheList() {
        let nav = PanelNav()
        nav.moveNotifyTagSelection(by: -1)
        XCTAssertEqual(nav.notifyTagSelection, 0)
        nav.moveNotifyTagSelection(by: 1000)
        XCTAssertEqual(nav.notifyTagSelection, nav.notifyTagList.count - 1)
    }
}
