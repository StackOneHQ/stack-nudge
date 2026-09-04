import XCTest

@testable import StackNudgePanelCore

final class AttentionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func shouldRemind(firstSeen: TimeInterval,
                              lastNudged: TimeInterval,
                              sent: Int = 0,
                              every minutes: Int = 2) -> Bool {
        AttentionPolicy.shouldRemind(now: now,
                                     firstSeenAt: ago(firstSeen),
                                     lastNudgedAt: ago(lastNudged),
                                     remindersSent: sent,
                                     intervalMinutes: minutes)
    }

    // MARK: - shouldRemind

    func test_remindsOnceTheIntervalHasElapsed() {
        XCTAssertTrue(shouldRemind(firstSeen: 130, lastNudged: 130, every: 2))
    }

    func test_silentBeforeTheIntervalElapses() {
        XCTAssertFalse(shouldRemind(firstSeen: 90, lastNudged: 90, every: 2))
    }

    func test_exactlyOnTheIntervalReminds() {
        XCTAssertTrue(shouldRemind(firstSeen: 120, lastNudged: 120, every: 2))
    }

    // 0 is the "Off" entry in the Settings cycle, not a zero-second interval.
    func test_zeroIntervalDisablesReminders() {
        XCTAssertFalse(shouldRemind(firstSeen: 9999, lastNudged: 9999, every: 0))
    }

    func test_stopsAtTheReminderCap() {
        XCTAssertTrue(shouldRemind(firstSeen: 300, lastNudged: 300,
                                   sent: AttentionPolicy.maxReminders - 1))
        XCTAssertFalse(shouldRemind(firstSeen: 300, lastNudged: 300,
                                    sent: AttentionPolicy.maxReminders))
    }

    // Past notify.sh's 550s FIFO timeout the hook has given up and the agent
    // has fallen back to its own prompt, so the banner's Allow/Deny would be
    // dead buttons.
    func test_stopsOnceTheHookHasTimedOut() {
        XCTAssertFalse(shouldRemind(firstSeen: AttentionPolicy.promptLifetime + 1,
                                    lastNudged: 300))
        XCTAssertTrue(shouldRemind(firstSeen: AttentionPolicy.promptLifetime - 10,
                                   lastNudged: 300))
    }

    // The interval is measured from the last nudge, not from the prompt — two
    // reminders must not land back to back just because the prompt is old.
    func test_intervalIsMeasuredFromTheLastNudge() {
        XCTAssertFalse(shouldRemind(firstSeen: 400, lastNudged: 30, sent: 1))
        XCTAssertTrue(shouldRemind(firstSeen: 400, lastNudged: 200, sent: 1))
    }

    // MARK: - elapsedLabel

    func test_elapsedLabel_shapes() {
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(45), now: now), "45s")
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(240), now: now), "4m")
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(3600), now: now), "1h")
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(3720), now: now), "1h2m")
    }

    // A tick can land a hair before the wall-clock interval; "0m" would read as
    // a bug, so sub-minute stays in seconds.
    func test_elapsedLabel_subMinuteStaysInSeconds() {
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(59), now: now), "59s")
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: ago(0), now: now), "0s")
    }

    // Clock skew (NTP step, sleep/wake) must not produce a negative duration.
    func test_elapsedLabel_futureDateClampsToZero() {
        XCTAssertEqual(AttentionPolicy.elapsedLabel(since: now.addingTimeInterval(60), now: now), "0s")
    }

    func test_reminderBody_prefixesTheOriginalMessage() {
        let body = AttentionPolicy.reminderBody(original: "Bash(rm -rf build/)",
                                                waitedSince: ago(240), now: now)
        XCTAssertEqual(body, "Still waiting 4m · Bash(rm -rf build/)")
    }

    func test_reminderBody_withoutAnOriginalMessage() {
        XCTAssertEqual(AttentionPolicy.reminderBody(original: "", waitedSince: ago(60), now: now),
                       "Still waiting 1m")
    }

    // MARK: - isStalled

    private func isStalled(_ seconds: TimeInterval?, busy: Bool = true, after minutes: Int = 20) -> Bool {
        AttentionPolicy.isStalled(lastActivityAt: seconds.map(ago),
                                  busy: busy, now: now, thresholdMinutes: minutes)
    }

    func test_stalled_whenBusyAndSilentPastTheThreshold() {
        XCTAssertTrue(isStalled(21 * 60))
        XCTAssertFalse(isStalled(19 * 60))
    }

    // An idle session with no recent activity is just one you aren't using.
    func test_idleSessionIsNeverStalled() {
        XCTAssertFalse(isStalled(60 * 60, busy: false))
    }

    func test_zeroThresholdDisablesStallDetection() {
        XCTAssertFalse(isStalled(60 * 60, after: 0))
    }

    // No reported activity means no baseline to measure silence against.
    func test_noActivityTimestampIsNotStalled() {
        XCTAssertFalse(isStalled(nil))
    }

    func test_stalledLabel() {
        XCTAssertEqual(AttentionPolicy.stalledLabel(lastActivityAt: ago(24 * 60), now: now),
                       "no output 24m")
    }

    // MARK: - Watch lifetime

    // Regression guard for the bug this branch shipped and then fixed: prompt
    // watches used to be retired whenever their event left EventStore, but that
    // store prunes to `maxEventsPerSession` keyed on
    // `claudeSessionID ?? "agent:projectPath"`. Codex reports no claudeSessionID,
    // so two Codex sessions in one repo share a key and one could evict the
    // other's still-blocking prompt — silently ending reminders for an agent
    // that was still stuck. These assert the properties the fix relies on.
    func test_promptLifetimeMatchesTheHookTimeout() {
        // notify.sh's wait_for_permission_response gives the FIFO 550s. Past
        // that the agent has fallen back to its own prompt and the banner's
        // Allow/Deny are dead buttons, so reminders must stop.
        XCTAssertEqual(AttentionPolicy.promptLifetime, 550)
    }

    // The age cap is what retires a watch whose FIFO leaked because the hook was
    // killed before its cleanup trap ran. Without it a leaked FIFO would pin the
    // menu-bar count on forever.
    func test_remindingStopsAtTheLifetimeEvenIfNudgesRemain() {
        XCTAssertFalse(shouldRemind(firstSeen: AttentionPolicy.promptLifetime,
                                    lastNudged: 300, sent: 0))
        XCTAssertTrue(shouldRemind(firstSeen: AttentionPolicy.promptLifetime - 1,
                                   lastNudged: 300, sent: 0))
    }

    // MARK: - Settings labels

    func test_minuteLabel_coversBothOptionLists() {
        XCTAssertEqual(AttentionPolicy.minuteLabel(0), "Off")
        XCTAssertEqual(AttentionPolicy.minuteLabel(10), "10m")
        XCTAssertEqual(AttentionPolicy.minuteLabel(60), "1h")
        for minutes in AttentionPolicy.reminderMinuteOptions + AttentionPolicy.stalledMinuteOptions {
            XCTAssertFalse(AttentionPolicy.minuteLabel(minutes).isEmpty)
        }
    }

    // Both cycle rows index into these by value, so a duplicate or an unsorted
    // list would make ←/→ jump.
    func test_optionListsAreSortedAndUnique() {
        for list in [AttentionPolicy.reminderMinuteOptions, AttentionPolicy.stalledMinuteOptions] {
            XCTAssertEqual(list, list.sorted())
            XCTAssertEqual(list.count, Set(list).count)
            XCTAssertEqual(list.first, 0, "each list needs an Off entry at index 0")
        }
    }
}
