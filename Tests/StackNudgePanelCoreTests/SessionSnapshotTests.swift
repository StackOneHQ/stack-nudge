import XCTest

@testable import StackNudgePanelCore

// The session shape `event:session` and the MCP server both read, and the
// changes a listener is sent.
final class SessionSnapshotTests: XCTestCase {

    private func session(_ pid: Int, agent: String = "claude", live: String? = "idle",
                         claudeID: String? = nil, name: String? = nil,
                         status: SessionStatus = .active) -> Session {
        Session(id: pid, pid: pid, agent: agent,
                projectPath: "/Users/x/api", projectName: "api",
                terminalPID: 1, terminalApp: "iTerm2", elapsed: "01:00",
                customName: name, status: status,
                tabId: "w0t0p0", tabName: "a tab", tty: "ttys001",
                claudeSessionID: claudeID, liveStatus: live)
    }

    private func prompt(pid: Int? = nil, claudeID: String? = nil) -> NudgeEvent {
        NudgeEvent(agent: "claude", kind: .permission, title: "Bash", message: "rm -rf build",
                   hasActionButton: true, agentPID: pid, claudeSessionID: claudeID)
    }

    func testStateComesFromLiveStatusAndWaitingPrompts() {
        let sessions = [session(1, live: "busy"), session(2, live: "idle"), session(3, agent: "codex", live: nil),
                        session(4, live: "busy", claudeID: "c-4"), session(5, status: .finished(at: Date()))]
        let list = SessionSnapshot.list(sessions: sessions, events: [prompt(claudeID: "c-4")],
                                        isBlocking: { _ in true })
        XCTAssertEqual(list.map(\.state), [.busy, .idle, .active, .waiting, .ended])
    }

    // A prompt the hook gave up on, or a feed event, isn't something waiting.
    func testOnlyAPromptStillBlockingCountsAsWaiting() {
        let feed = NudgeEvent.feed(source: .script, tag: nil, title: "x", message: "y")
        XCTAssertEqual(SessionSnapshot.list(sessions: [session(1)], events: [prompt(pid: 1)],
                                            isBlocking: { _ in false }).first?.state, .idle)
        XCTAssertEqual(SessionSnapshot.list(sessions: [session(1)], events: [feed],
                                            isBlocking: { _ in true }).first?.state, .idle)
        XCTAssertEqual(SessionSnapshot.list(sessions: [session(1)], events: [prompt(pid: 1)],
                                            isBlocking: { _ in true }).first?.state, .waiting)
    }

    // No path, tab or prompt text leaves the app; only a chosen name does.
    func testFieldsCarryNoPathsOrTabsOrPromptText() {
        let snapshot = SessionSnapshot.list(sessions: [session(7, claudeID: "c-7", name: "api work")],
                                            events: [], isBlocking: { _ in true })[0]
        XCTAssertEqual(snapshot.fields, ["session": .string("claude-7"), "pid": .int(7), "agent": .string("claude"),
                                         "state": .string("idle"), "repo": .string("api"),
                                         "title": .string("api work"), "claude_session": .string("c-7")])
        XCTAssertNil(SessionSnapshot.list(sessions: [session(8)], events: [],
                                          isBlocking: { _ in true })[0].fields["title"])
    }

    func testChangesAreNewChangedAndGoneSessionsOnly() {
        let before = SessionSnapshot.list(sessions: [session(1), session(2), session(3)], events: [],
                                          isBlocking: { _ in true })
        let after = SessionSnapshot.list(sessions: [session(1), session(2, live: "busy"), session(4)], events: [],
                                         isBlocking: { _ in true })
        let changes = SessionSnapshot.changes(from: before, to: after)
        XCTAssertEqual(changes.map(\.handle), ["claude-2", "claude-4", "claude-3"])
        XCTAssertEqual(changes.map(\.state), [.busy, .idle, .ended])
        XCTAssertEqual(SessionSnapshot.changes(from: after, to: after), [])
    }

    // A session that has already said it ended isn't ended again when it
    // drops off the list.
    func testAnEndedSessionIsntEndedTwice() {
        let ended = SessionSnapshot.list(sessions: [session(1, status: .finished(at: Date()))], events: [],
                                         isBlocking: { _ in true })
        XCTAssertEqual(SessionSnapshot.changes(from: ended, to: []), [])
    }
}
