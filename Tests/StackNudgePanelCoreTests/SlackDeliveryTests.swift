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
}
