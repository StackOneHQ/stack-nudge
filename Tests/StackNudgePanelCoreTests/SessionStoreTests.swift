import XCTest

@testable import StackNudgePanelCore

// Agent detection runs on `ps` args, and Claude Code 2.1 turned that into a
// minefield: the daemon, the background pty hosts and the spare process are
// all executables called `claude`. Every one of them was landing in the
// Sessions pane as a row, and because none of them exits when a session does,
// the finished-session prune could never reach them. The daemon in particular
// is parented to launchd and lives for weeks.
//
// Arg strings here are copied verbatim from `ps -axo args=` on a machine
// running Claude Code 2.1.220, so they pin the real shapes rather than a
// guess at them.
final class DetectAgentTests: XCTestCase {

    func test_detectAgent_interactiveClaude() {
        XCTAssertEqual(SessionStore.detectAgent(args: "claude"), "claude")
    }

    func test_detectAgent_resumedSession_isNotMistakenForASubcommand() {
        // The resumed-session UUID is a positional argument, so the
        // subcommand scan has to stop at the flag it belongs to.
        XCTAssertEqual(
            SessionStore.detectAgent(args: "claude --resume a80e8b9d-0868-4541-92de-3e5eae6b4e4b"),
            "claude"
        )
        XCTAssertEqual(
            SessionStore.detectAgent(args: "claude --resume=86ae070c-bdaf-49fa-a68e-8f8474146aa5 --fork-session"),
            "claude"
        )
    }

    func test_detectAgent_absolutePathClaude() {
        XCTAssertEqual(SessionStore.detectAgent(args: "/opt/homebrew/bin/claude --permission-mode auto"),
                       "claude")
    }

    func test_detectAgent_daemon_isNotASession() {
        let args = "/Users/x/.local/bin/claude daemon run --json-path /Users/x/.claude/daemon.json"
            + " --log-file /Users/x/.claude/daemon.log --origin transient"
        XCTAssertNil(SessionStore.detectAgent(args: args))
    }

    func test_detectAgent_backgroundPtyHost_isNotASession() {
        let args = "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-502/d6d4ed8d/spare/9ea21c85.pty.sock"
            + " 200 50 -- /Users/x/.local/share/claude/versions/2.1.220"
        XCTAssertNil(SessionStore.detectAgent(args: args))
    }

    func test_detectAgent_backgroundSpare_isNotASession() {
        let args = "claude bg-spare --bg-spare /tmp/cc-daemon-502/d6d4ed8d/spare/9ea21c85.claim.sock"
        XCTAssertNil(SessionStore.detectAgent(args: args))
    }

    // The app-bundle helper leads with a flag rather than a subcommand, and it
    // inherits the project cwd — which is what made it the worst of the four.
    // It read as a genuine session in that project, one that had usually
    // already ended.
    func test_detectAgent_appBundlePtyHost_isNotASession() {
        let args = "/Users/x/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"
            + " --bg-pty-host /tmp/cc-daemon-502/d6d4ed8d/pty/a4085187.sock 118 77"
            + " -- /Users/x/.local/share/claude/versions/2.1.220 --session-id a4085187"
        XCTAssertNil(SessionStore.detectAgent(args: args))
    }

    func test_detectAgent_nodeHostedAgents() {
        XCTAssertEqual(SessionStore.detectAgent(args: "node /opt/homebrew/lib/node_modules/gemini-cli/index.js"),
                       "gemini")
        XCTAssertEqual(SessionStore.detectAgent(args: "node /Users/x/.npm/codex/bin/codex.js"),
                       "codex")
        XCTAssertEqual(SessionStore.detectAgent(args: "codex"), "codex")
        XCTAssertEqual(SessionStore.detectAgent(args: "agy"), "agy")
    }

    func test_detectAgent_pi() {
        // pi ships as a node-run bundle; the package path is the signature.
        XCTAssertEqual(
            SessionStore.detectAgent(
                args: "node /Users/x/.nvm/versions/node/v22.20.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"),
            "pi")
        // A future compiled binary invoked directly.
        XCTAssertEqual(SessionStore.detectAgent(args: "pi"), "pi")
        XCTAssertEqual(SessionStore.detectAgent(args: "/opt/homebrew/bin/pi --resume"), "pi")
    }

    // Similarly-named neighbours that share a prefix with an agent binary.
    func test_detectAgent_nonAgentProcesses() {
        XCTAssertNil(SessionStore.detectAgent(args: "/Users/x/.local/bin/codex-code-mode-host"))
        XCTAssertNil(SessionStore.detectAgent(args: "/bin/zsh -c source /Users/x/.claude/shell-snapshots/s.sh"))
        XCTAssertNil(SessionStore.detectAgent(args: "/Users/x/.local/share/claude/versions/2.1.220 --session-id a4085187"))
        XCTAssertNil(SessionStore.detectAgent(args: ""))
    }
}

// The visible-state ladder: a session that's running stays, one that just
// exited lingers briefly so the user sees it end, and one that ended a while
// ago goes away.
final class SessionReconcileTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_688_512)

    private func session(pid: Int,
                         status: SessionStatus = .active,
                         customName: String? = nil,
                         liveStatus: String? = nil,
                         lastActivityAt: Date? = nil) -> Session {
        Session(
            id: pid, pid: pid, agent: "claude",
            projectPath: "/Users/x/proj", projectName: "proj",
            terminalPID: 1, terminalApp: "iTerm2", elapsed: "01:00",
            customName: customName, status: status,
            tabId: nil, tabName: nil,
            liveStatus: liveStatus, lastActivityAt: lastActivityAt
        )
    }

    func test_reconcile_stillRunningStaysActive() {
        let actual = SessionStore.reconcile(previous: [session(pid: 1)],
                                            found: [session(pid: 1)],
                                            now: now)
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual.first?.status, .active)
    }

    func test_reconcile_disappearedIsMarkedFinished() {
        let actual = SessionStore.reconcile(previous: [session(pid: 1)],
                                            found: [],
                                            now: now)
        XCTAssertEqual(actual.first?.status, .finished(at: now))
    }

    func test_reconcile_recentlyFinishedIsKept() {
        let justEnded = session(pid: 1, status: .finished(at: now.addingTimeInterval(-5)))
        let actual = SessionStore.reconcile(previous: [justEnded], found: [], now: now)
        XCTAssertEqual(actual.count, 1, "a session that ended 5s ago should still be on screen")
    }

    func test_reconcile_longFinishedIsPruned() {
        let stale = session(pid: 1, status: .finished(at: now.addingTimeInterval(-31)))
        let actual = SessionStore.reconcile(previous: [stale], found: [], now: now)
        XCTAssertTrue(actual.isEmpty, "a session that ended over 30s ago should be pruned")
    }

    func test_reconcile_finishedSessionIsNotResurrected() {
        // Two polls with nothing running: mark finished, then drop.
        let first = SessionStore.reconcile(previous: [session(pid: 1)], found: [], now: now)
        let second = SessionStore.reconcile(previous: first, found: [],
                                            now: now.addingTimeInterval(31))
        XCTAssertTrue(second.isEmpty)
    }

    func test_reconcile_inMemoryNameSurvivesAPoll() {
        let renamed = session(pid: 1, customName: "logs traceability")
        let actual = SessionStore.reconcile(previous: [renamed],
                                            found: [session(pid: 1)],
                                            now: now)
        XCTAssertEqual(actual.first?.customName, "logs traceability")
    }

    func test_reconcile_seededNameAppliesWhenNoneInMemory() {
        let actual = SessionStore.reconcile(previous: [session(pid: 1)],
                                            found: [session(pid: 1, customName: "from disk")],
                                            now: now)
        XCTAssertEqual(actual.first?.customName, "from disk")
    }

    func test_reconcile_newSessionsAreAdded() {
        let actual = SessionStore.reconcile(previous: [session(pid: 1)],
                                            found: [session(pid: 1), session(pid: 2)],
                                            now: now)
        XCTAssertEqual(Set(actual.map(\.pid)), [1, 2])
    }

    // Live above dormant above finished. A tab left open for a week is still a
    // session, but it shouldn't sit above the one that's working right now.
    func test_reconcile_sortsLiveThenDormantThenFinished() {
        let dormant = session(pid: 1, lastActivityAt: now.addingTimeInterval(-8 * 24 * 3600))
        let finished = session(pid: 2, status: .finished(at: now.addingTimeInterval(-5)))
        let live = session(pid: 3, lastActivityAt: now.addingTimeInterval(-10))

        let actual = SessionStore.reconcile(previous: [dormant, finished, live],
                                            found: [dormant, live],
                                            now: now)
        XCTAssertEqual(actual.map(\.pid), [3, 1, 2])
    }

    func test_reconcile_busySortsAboveIdleWithinLiveTier() {
        let idle = session(pid: 1, liveStatus: "idle", lastActivityAt: now)
        let busy = session(pid: 2, liveStatus: "busy", lastActivityAt: now.addingTimeInterval(-60))
        let actual = SessionStore.reconcile(previous: [idle, busy], found: [idle, busy], now: now)
        XCTAssertEqual(actual.map(\.pid), [2, 1])
    }
}

final class SessionDormancyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_785_688_512)

    private func session(status: SessionStatus, lastActivityAt: Date?) -> Session {
        Session(
            id: 1, pid: 1, agent: "claude", projectPath: "/x", projectName: "x",
            terminalPID: 2, terminalApp: "iTerm2", elapsed: nil,
            customName: nil, status: status, tabId: nil, tabName: nil,
            lastActivityAt: lastActivityAt
        )
    }

    func test_isDormant_afterADayOfNoActivity() {
        let actual = session(status: .active, lastActivityAt: now.addingTimeInterval(-25 * 3600))
        XCTAssertTrue(actual.isDormant(asOf: now))
    }

    func test_isDormant_recentActivity() {
        let actual = session(status: .active, lastActivityAt: now.addingTimeInterval(-60))
        XCTAssertFalse(actual.isDormant(asOf: now))
    }

    // No activity signal at all (any agent without a sidecar) means we can't
    // tell dormant from busy, so we don't claim either.
    func test_isDormant_noActivitySignal() {
        let actual = session(status: .active, lastActivityAt: nil)
        XCTAssertFalse(actual.isDormant(asOf: now))
    }

    func test_isDormant_finishedSessionIsNotDormant() {
        let actual = session(status: .finished(at: now),
                             lastActivityAt: now.addingTimeInterval(-8 * 24 * 3600))
        XCTAssertFalse(actual.isDormant(asOf: now), "finished is already its own state")
    }
}
