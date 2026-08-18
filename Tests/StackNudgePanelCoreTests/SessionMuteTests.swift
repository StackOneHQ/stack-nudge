import XCTest

@testable import StackNudgePanelCore

// Per-session mute: which sessions share a mute, and whether unmuting is the
// inverse of muting. Both went wrong for sessions in the same project, which
// is the common case for anyone running two agents in one repo.
@MainActor
final class SessionMuteTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stack-nudge-mute-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    private func makeStore() -> SessionPersistence { SessionPersistence(path: tempURL) }

    private func session(pid: Int,
                         path: String = "/Users/x/redteaming",
                         tabId: String? = nil,
                         tty: String? = nil,
                         claudeSessionID: String? = nil) -> Session {
        Session(
            id: pid, pid: pid, agent: "claude",
            projectPath: path, projectName: "redteaming",
            terminalPID: 1, terminalApp: "Zed", elapsed: "01:00",
            customName: nil, status: .active,
            tabId: tabId, tabName: nil, tty: tty,
            claudeSessionID: claudeSessionID
        )
    }

    // MARK: - Scope ladder

    func test_muteScope_prefersTabIdThenTtyThenSessionID() {
        XCTAssertEqual(SessionPersistence.muteScope(
            for: session(pid: 1, tabId: "w1", tty: "ttys014", claudeSessionID: "uuid")), "w1")
        XCTAssertEqual(SessionPersistence.muteScope(
            for: session(pid: 1, tty: "ttys014", claudeSessionID: "uuid")), "ttys014")
        // Sidecar-only sessions (no controlling terminal) still get an identity.
        XCTAssertEqual(SessionPersistence.muteScope(
            for: session(pid: 1, claudeSessionID: "uuid")), "uuid")
        XCTAssertNil(SessionPersistence.muteScope(for: session(pid: 1)))
    }

    func test_muteScope_ignoresEmptyStrings() {
        XCTAssertEqual(SessionPersistence.muteScope(
            for: session(pid: 1, tabId: "", tty: "ttys014")), "ttys014")
    }

    // MARK: - Isolation

    // The reported bug: two agents in one repo under a terminal we have no
    // conformer for (Zed, a bare shell) both resolved to the project-wide key,
    // so muting either silenced both.
    func test_mutingOneSession_leavesSiblingInSameProjectAudible() {
        let store = makeStore()
        let first  = session(pid: 1, tty: "ttys014")
        let second = session(pid: 2, tty: "ttys016")

        store.toggleMuted(first)

        XCTAssertTrue(store.isMuted(first))
        XCTAssertFalse(store.isMuted(second))
    }

    func test_mutesAreScopedPerSessionForAgentsWithoutASidecar() {
        // codex and gemini expose no per-session id at all; the tty is the only
        // thing separating them, so this is the whole fix for those agents.
        let store = makeStore()
        func codex(pid: Int, tty: String) -> Session {
            Session(id: pid, pid: pid, agent: "codex",
                    projectPath: "/Users/x/redteaming", projectName: "redteaming",
                    terminalPID: 1, terminalApp: "Zed", elapsed: "01:00",
                    customName: nil, status: .active,
                    tabId: nil, tabName: nil, tty: tty)
        }
        store.toggleMuted(codex(pid: 1, tty: "ttys037"))

        XCTAssertTrue(store.isMuted(codex(pid: 1, tty: "ttys037")))
        XCTAssertFalse(store.isMuted(codex(pid: 2, tty: "ttys038")))
    }

    // MARK: - Toggle is an inverse

    func test_toggleMuted_roundTrips() {
        let store = makeStore()
        let target = session(pid: 1, tty: "ttys014")

        store.toggleMuted(target)
        XCTAssertTrue(store.isMuted(target))
        store.toggleMuted(target)
        XCTAssertFalse(store.isMuted(target))
    }

    func test_unmuting_leavesNoEntryBehind() {
        let store = makeStore()
        let target = session(pid: 1, tty: "ttys014")

        store.toggleMuted(target)
        store.toggleMuted(target)

        XCTAssertTrue(store.entries.isEmpty, "an unmuted, unnamed session should hold no preference")
    }

    // A project-wide entry is what the legacy muted-sessions.json migration
    // writes, and what any pre-fix mute left behind. Sessions inherit it...
    func test_projectWideMute_isInheritedBySessionsWithoutAnOpinion() {
        let store = makeStore()
        store.toggleMuted(session(pid: 1))          // no scope → project-wide key

        XCTAssertTrue(store.isMuted(session(pid: 2, tty: "ttys014")))
    }

    // ...and clicking unmute on one of them used to negate the *stored* flag,
    // which was false, so the session re-muted itself and could never be
    // cleared from its own row.
    func test_inheritedMute_canBeClearedOnOneSessionOnly() {
        let store = makeStore()
        store.toggleMuted(session(pid: 1))
        let target  = session(pid: 2, tty: "ttys014")
        let sibling = session(pid: 3, tty: "ttys016")

        store.toggleMuted(target)

        XCTAssertFalse(store.isMuted(target))
        XCTAssertTrue(store.isMuted(sibling), "the project-wide mute still covers everyone else")
    }

    func test_clearedInheritedMute_canBeReapplied() {
        let store = makeStore()
        store.toggleMuted(session(pid: 1))
        let target = session(pid: 2, tty: "ttys014")

        store.toggleMuted(target)
        store.toggleMuted(target)

        XCTAssertTrue(store.isMuted(target))
    }

    func test_explicitUnmute_survivesReload() {
        let first = makeStore()
        first.toggleMuted(session(pid: 1))
        let target = session(pid: 2, tty: "ttys014")
        first.toggleMuted(target)

        XCTAssertFalse(makeStore().isMuted(target))
    }

    // MARK: - Legacy files

    func test_legacyEntryWithoutMutedField_decodesAsNoOpinion() throws {
        try Data(#"{"claude::/Users/x/redteaming":{"customName":"attack","lastSeenAt":1}}"#.utf8)
            .write(to: tempURL)
        let store = makeStore()

        XCTAssertFalse(store.isMuted(session(pid: 1, tty: "ttys014")))
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/Users/x/redteaming"), "attack")
    }

    func test_renamedSession_keepsItsNameWhenMuteIsCleared() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/Users/x/redteaming", tabId: "w1", "attack")
        let target = session(pid: 1, tabId: "w1")

        store.toggleMuted(target)
        store.toggleMuted(target)

        XCTAssertFalse(store.isMuted(target))
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/Users/x/redteaming", tabId: "w1"),
                       "attack")
    }
}
