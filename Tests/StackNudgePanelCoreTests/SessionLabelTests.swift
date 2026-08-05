import XCTest

@testable import StackNudgePanelCore

// One cascade, used by the Sessions row, the nudge row, the banner title and
// the spoken phrase. Before this existed each of those resolved names
// differently: the nudge row never saw a name set inside the agent, and the
// banner only ever matched Claude sessions, so a renamed Codex session was
// announced by its folder name.
final class SessionLabelTests: XCTestCase {

    private func session(pid: Int = 1,
                         agent: String = "claude",
                         projectPath: String? = "/Users/x/stackone",
                         projectName: String? = "stackone",
                         customName: String? = nil,
                         liveTitle: String? = nil,
                         liveTitleSource: String? = nil,
                         tabId: String? = nil) -> Session {
        Session(
            id: pid, pid: pid, agent: agent,
            projectPath: projectPath, projectName: projectName,
            terminalPID: 2, terminalApp: "iTerm2", elapsed: nil,
            customName: customName, status: .active,
            tabId: tabId, tabName: nil,
            liveTitle: liveTitle, liveTitleSource: liveTitleSource
        )
    }

    private func event(agent: String = "claude-code",
                       projectPath: String? = "/Users/x/stackone",
                       agentPID: Int? = 1,
                       sessionID: String? = nil,
                       claudeSessionID: String? = nil) -> NudgeEvent {
        NudgeEvent(
            agent: agent, kind: .stop, title: "Claude Code", message: "Done",
            projectPath: projectPath,
            agentPID: agentPID, sessionID: sessionID,
            claudeSessionID: claudeSessionID
        )
    }

    // MARK: - Sessions

    func test_chosenName_paneRenameWins() {
        let actual = SessionLabel.chosenName(for: session(customName: "logs traceability",
                                                          liveTitle: "renamed in agent",
                                                          liveTitleSource: "user"))
        XCTAssertEqual(actual, "logs traceability")
    }

    func test_chosenName_agentRenameIsUsed() {
        let actual = SessionLabel.chosenName(for: session(liveTitle: "ENG-1185 logs",
                                                          liveTitleSource: "user"))
        XCTAssertEqual(actual, "ENG-1185 logs")
    }

    // Claude Code 2.1+ hands every session a derived name like "stackone-89".
    // Treating those as user intent made every banner read
    // "Claude Code — stackone-89", which is exactly what a rename that didn't
    // come through looks like.
    func test_chosenName_derivedAgentNameIsIgnored() {
        let actual = SessionLabel.chosenName(for: session(liveTitle: "stackone-89",
                                                          liveTitleSource: "derived"))
        XCTAssertNil(actual)
    }

    // Older Claude Code reports no source at all; keep trusting the name there
    // so this doesn't silently regress those installs.
    func test_chosenName_noSourceReportedIsTrusted() {
        let actual = SessionLabel.chosenName(for: session(liveTitle: "my session",
                                                          liveTitleSource: nil))
        XCTAssertEqual(actual, "my session")
    }

    func test_chosenName_legacyPlaceholderIsIgnored() {
        let actual = SessionLabel.chosenName(for: session(liveTitle: "main-agent",
                                                          liveTitleSource: nil))
        XCTAssertNil(actual)
    }

    func test_chosenName_blankNamesAreIgnored() {
        XCTAssertNil(SessionLabel.chosenName(for: session(customName: "   ", liveTitle: "  ")))
    }

    func test_displayName_fallsBackToProjectThenFallback() {
        XCTAssertEqual(SessionLabel.displayName(for: session(), fallback: "a session"),
                       "stackone")
        XCTAssertEqual(
            SessionLabel.displayName(for: session(projectPath: nil, projectName: nil),
                                     fallback: "a session"),
            "a session"
        )
    }

    // MARK: - Events

    func test_chosenName_forEvent_matchesByAgentPID() {
        let persistence = SessionPersistence(path: Self.scratchFile())
        let actual = SessionLabel.chosenName(
            for: event(agentPID: 42),
            in: [session(pid: 42, customName: "the renamed one")],
            persistence: persistence
        )
        XCTAssertEqual(actual, "the renamed one")
    }

    // A Codex/Gemini/Antigravity event carries no Claude session UUID. The old
    // banner join keyed on that field alone, so those agents could never pick
    // up a rename.
    func test_chosenName_forEvent_worksForNonClaudeAgents() {
        let persistence = SessionPersistence(path: Self.scratchFile())
        let actual = SessionLabel.chosenName(
            for: event(agent: "codex", agentPID: 7, claudeSessionID: nil),
            in: [session(pid: 7, agent: "codex", customName: "sandbox spike")],
            persistence: persistence
        )
        XCTAssertEqual(actual, "sandbox spike")
    }

    // Once the process is gone the process list can't answer, so the on-disk
    // store is the only source left.
    func test_chosenName_forEvent_fallsBackToPersistence() {
        let persistence = SessionPersistence(path: Self.scratchFile())
        persistence.setCustomName(agent: "claude", projectPath: "/Users/x/stackone", "from disk")

        let actual = SessionLabel.chosenName(for: event(agentPID: 999),
                                             in: [],
                                             persistence: persistence)
        XCTAssertEqual(actual, "from disk")
    }

    func test_chosenName_forEvent_nilWhenNobodyNamedIt() {
        let persistence = SessionPersistence(path: Self.scratchFile())
        let actual = SessionLabel.chosenName(for: event(agentPID: 1),
                                             in: [session(pid: 1)],
                                             persistence: persistence)
        XCTAssertNil(actual, "a project folder is not a name anyone chose")
    }

    func test_displayName_forEvent_fallsBackToProjectFolder() {
        let persistence = SessionPersistence(path: Self.scratchFile())
        let actual = SessionLabel.displayName(for: event(agentPID: 1),
                                               in: [session(pid: 1)],
                                               persistence: persistence)
        XCTAssertEqual(actual, "stackone")
    }

    func test_tabIdentifier_prefersTerminalSessionIDOverIPCHook() {
        let withBoth = NudgeEvent(agent: "claude-code", kind: .stop, title: "t", message: "m",
                                  ipcHook: "/sock/window.sock", sessionID: "ABC-123")
        XCTAssertEqual(SessionLabel.tabIdentifier(for: withBoth), "ABC-123")

        let hookOnly = NudgeEvent(agent: "claude-code", kind: .stop, title: "t", message: "m",
                                  ipcHook: "/sock/window.sock", sessionID: "")
        XCTAssertEqual(SessionLabel.tabIdentifier(for: hookOnly), "/sock/window.sock")

        let neither = NudgeEvent(agent: "claude-code", kind: .stop, title: "t", message: "m")
        XCTAssertNil(SessionLabel.tabIdentifier(for: neither))
    }

    private static func scratchFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-label-tests-\(UUID().uuidString).json")
    }
}

// The hook picks the phrase but can't resolve session names, so it now sends
// the template unsubstituted and the app fills in the label.
final class VoicePhraseTests: XCTestCase {

    func test_spoken_substitutesTheLabel() {
        XCTAssertEqual(VoicePhrase.spoken(template: "%s is ready for you", label: "auth"),
                       "auth is ready for you")
    }

    func test_spoken_expandsSlugsIntoWords() {
        XCTAssertEqual(VoicePhrase.spoken(template: "task complete in %s", label: "stackone-cli"),
                       "task complete in stack one C L I")
    }

    // No label to say, no template (older installed hook), or a phrase with no
    // placeholder: the caller falls back to what the hook already substituted.
    func test_spoken_nilWhenNothingToSubstitute() {
        XCTAssertNil(VoicePhrase.spoken(template: "%s is ready", label: nil))
        XCTAssertNil(VoicePhrase.spoken(template: "%s is ready", label: ""))
        XCTAssertNil(VoicePhrase.spoken(template: nil, label: "auth"))
        XCTAssertNil(VoicePhrase.spoken(template: "all done", label: "auth"))
    }

    // Substitution is a literal replace, not printf: a user-supplied phrase
    // from phrases.user.json with a stray % must not corrupt the output.
    func test_spoken_leavesOtherPercentTokensAlone() {
        XCTAssertEqual(VoicePhrase.spoken(template: "%s is 100%% done", label: "auth"),
                       "auth is 100%% done")
    }
}
