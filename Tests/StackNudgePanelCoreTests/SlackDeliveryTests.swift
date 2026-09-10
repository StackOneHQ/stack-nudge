import XCTest

@testable import StackNudgePanelCore

final class SlackDeliveryTests: XCTestCase {

    // MARK: - shouldSend

    private func shouldSend(kind: NudgeKind = .permission,
                            isReminder: Bool = false,
                            sessionMuted: Bool = false,
                            enabled: Bool = true,
                            notifyOnStop: Bool = false,
                            idleSeconds: TimeInterval = 600,
                            threshold: Int = 5) -> Bool {
        SlackDelivery.shouldSend(kind: kind, isReminder: isReminder,
                                 sessionMuted: sessionMuted, enabled: enabled,
                                 notifyOnStop: notifyOnStop, idleSeconds: idleSeconds,
                                 idleThresholdMinutes: threshold)
    }

    func test_sendsPermissionPromptWhenIdlePastTheThreshold() {
        XCTAssertTrue(shouldSend(idleSeconds: 5 * 60))
        XCTAssertFalse(shouldSend(idleSeconds: 5 * 60 - 1))
    }

    func test_disabledSendsNothing() {
        XCTAssertFalse(shouldSend(enabled: false))
    }

    // A per-session mute silences Slack too, matching the first-banner gate.
    func test_perSessionMuteSuppresses() {
        XCTAssertFalse(shouldSend(sessionMuted: true))
    }

    func test_zeroThresholdMeansAlways() {
        XCTAssertTrue(shouldSend(idleSeconds: 0, threshold: 0))
    }

    func test_stopEventsAreOffByDefault() {
        XCTAssertFalse(shouldSend(kind: .stop))
        XCTAssertTrue(shouldSend(kind: .stop, notifyOnStop: true))
    }

    func test_otherEventsNeverSend() {
        XCTAssertFalse(shouldSend(kind: .other, notifyOnStop: true, threshold: 0))
    }

    // A reminder already proved the prompt went unanswered — the user may be back
    // at the desk and still not have seen the banner, which is the case reminders
    // exist for. So reminders skip the idle gate but not the other gates.
    func test_remindersSkipTheIdleGateButNotTheOthers() {
        XCTAssertTrue(shouldSend(isReminder: true, idleSeconds: 0, threshold: 60))
        XCTAssertFalse(shouldSend(isReminder: true, sessionMuted: true, idleSeconds: 0))
        XCTAssertFalse(shouldSend(isReminder: true, enabled: false, idleSeconds: 0))
    }

    // MARK: - Message text

    private func event(kind: NudgeKind = .permission,
                       agent: String = "claude-code",
                       message: String = "Bash(rm -rf build/)",
                       project: String? = "/Users/x/Workspace/attack-lib") -> NudgeEvent {
        NudgeEvent(agent: agent, kind: kind, title: "t", message: message,
                   projectPath: project)
    }

    func test_text_titlesOnlyByDefault() {
        let text = SlackDelivery.text(for: event(), label: nil,
                                      includeDetail: false, isReminder: false)
        XCTAssertEqual(text, "Claude Code in attack-lib needs permission")
        // The privacy promise: the tool call must not leave the machine unless
        // the user opted in.
        XCTAssertFalse(text.contains("rm -rf"))
    }

    func test_text_detailAppendsTheMessage() {
        let text = SlackDelivery.text(for: event(), label: nil,
                                      includeDetail: true, isReminder: false)
        XCTAssertEqual(text, "Claude Code in attack-lib needs permission\nBash(rm -rf build/)")
    }

    func test_text_prefersTheSessionLabelOverTheRepo() {
        XCTAssertEqual(
            SlackDelivery.text(for: event(), label: "attack-lib refactor",
                               includeDetail: false, isReminder: false),
            "Claude Code in attack-lib refactor needs permission")
    }

    func test_text_reminderWording() {
        XCTAssertEqual(
            SlackDelivery.text(for: event(), label: nil,
                               includeDetail: false, isReminder: true),
            "Claude Code in attack-lib is still waiting for permission")
    }

    func test_text_withoutAProjectFallsBackToTheAgentAlone() {
        XCTAssertEqual(
            SlackDelivery.text(for: event(project: nil), label: nil,
                               includeDetail: false, isReminder: false),
            "Claude Code needs permission")
    }

    func test_text_detailWithAnEmptyMessageAddsNoBlankLine() {
        XCTAssertEqual(
            SlackDelivery.text(for: event(message: ""), label: nil,
                               includeDetail: true, isReminder: false),
            "Claude Code in attack-lib needs permission")
    }

    func test_agentNamesReadLikeTheBanner() {
        XCTAssertEqual(SlackDelivery.agentName("claude-code"), "Claude Code")
        XCTAssertEqual(SlackDelivery.agentName("codex"), "Codex")
        XCTAssertEqual(SlackDelivery.agentName("agy"), "Antigravity")
        XCTAssertEqual(SlackDelivery.agentName("something-else"), "something-else")
    }

    // MARK: - Settings options

    func test_idleOptionsMatchTheRequestedShape() {
        XCTAssertEqual(SlackDelivery.idleMinuteOptions.first, 0)
        XCTAssertEqual(SlackDelivery.idleMinuteOptions.last, 60)
        XCTAssertEqual(SlackDelivery.idleMinuteOptions,
                       SlackDelivery.idleMinuteOptions.sorted())
        // Every step past the "Always" entry is 5 minutes.
        for (a, b) in zip(SlackDelivery.idleMinuteOptions, SlackDelivery.idleMinuteOptions.dropFirst()) {
            XCTAssertEqual(b - a, 5)
        }
    }

    func test_idleLabel() {
        XCTAssertEqual(SlackDelivery.idleLabel(0), "Always")
        XCTAssertEqual(SlackDelivery.idleLabel(5), "5m")
        XCTAssertEqual(SlackDelivery.idleLabel(60), "60m")
    }

    // MARK: - Finished-turn rate limiting

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // The bug: the idle threshold is a floor, not a rate limit. Once you cross
    // it the condition stays true for the whole absence, so every event passes
    // independently. Diagnosed from a real log — 1284 events, 96% of them stop,
    // busy hours running 50+ — which meant an hour away was ~50 DMs.
    func test_burstOfFinishedTurnsCollapsesToOneMessage() {
        let turns = 50
        let spacing = 72.0            // ~every 72s, i.e. just under an hour total
        var lastSent: Date?
        var suppressed = 0
        var sent = 0
        var reported = 0              // events accounted for in a sent message

        for i in 0..<turns {
            let now = t0.addingTimeInterval(Double(i) * spacing)
            switch SlackDelivery.throttleStop(now: now, lastSentAt: lastSent,
                                              suppressed: suppressed) {
            case .suppress:
                suppressed += 1
            case .send(let folded):
                sent += 1
                reported += folded + 1   // the folded ones, plus this one
                lastSent = now
                suppressed = 0
            }
        }

        // The property that matters: a handful of messages, not one per event.
        let span = Double(turns - 1) * spacing
        XCTAssertEqual(sent, Int(span / SlackDelivery.stopCooldown) + 1,
                       "one immediately, then one per cooldown window")
        XCTAssertLessThan(sent, turns / 10, "50 turns must not be 50 DMs")

        // And nothing vanishes: every turn is either reported or still pending
        // in the suppressed count waiting for the next window.
        XCTAssertEqual(reported + suppressed, turns,
                       "every finished turn must be accounted for somewhere")
    }

    // The first stop of an absence is the one worth having promptly.
    func test_firstStopSendsImmediately() {
        XCTAssertEqual(SlackDelivery.throttleStop(now: t0, lastSentAt: nil, suppressed: 0),
                       .send(coalesced: 0))
    }

    func test_secondStopInsideTheWindowIsSuppressed() {
        let outcome = SlackDelivery.throttleStop(
            now: t0.addingTimeInterval(60), lastSentAt: t0, suppressed: 0)
        XCTAssertEqual(outcome, .suppress)
    }

    func test_stopSendsAgainOnceTheWindowPasses() {
        let outcome = SlackDelivery.throttleStop(
            now: t0.addingTimeInterval(SlackDelivery.stopCooldown), lastSentAt: t0, suppressed: 4)
        XCTAssertEqual(outcome, .send(coalesced: 4))
    }

    // Nothing is dropped silently — what was swallowed is reported.
    func test_coalescedCountReachesTheMessage() {
        let event = NudgeEvent(agent: "claude-code", kind: .stop, title: "Claude Code",
                               message: "", projectPath: "/Users/x/stack-nudge")
        let text = SlackDelivery.text(for: event, label: "stack-nudge",
                                      includeDetail: false, isReminder: false, coalesced: 7)
        XCTAssertTrue(text.contains("7 more"), "got: \(text)")
    }

    func test_singleTurnReadsNormally() {
        let event = NudgeEvent(agent: "claude-code", kind: .stop, title: "Claude Code",
                               message: "", projectPath: "/Users/x/stack-nudge")
        let text = SlackDelivery.text(for: event, label: "stack-nudge",
                                      includeDetail: false, isReminder: false, coalesced: 0)
        XCTAssertEqual(text, "Claude Code in stack-nudge finished a turn")
    }

    // Permission prompts must NOT be throttled: each blocks an agent until it is
    // answered, they are rare, and repeats of one are already capped by
    // AttentionPolicy.maxReminders. Throttling them would withhold exactly the
    // notifications that are actionable.
    func test_permissionPromptsAreNotRateLimited() {
        for _ in 0..<20 {
            XCTAssertTrue(SlackDelivery.shouldSend(
                kind: .permission, isReminder: false, sessionMuted: false,
                enabled: true, notifyOnStop: true,
                idleSeconds: 3600, idleThresholdMinutes: 10),
                "a blocking prompt must always get through")
        }
    }

}
