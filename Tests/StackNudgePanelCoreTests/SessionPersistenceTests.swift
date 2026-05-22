import XCTest

@testable import StackNudgePanelCore

@MainActor
final class SessionPersistenceTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        // Unique path per test so parallel runs don't clobber each other,
        // and so a leftover file from a crashed run doesn't bleed in.
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stack-nudge-persist-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        super.tearDown()
    }

    private func makeStore() -> SessionPersistence {
        SessionPersistence(path: tempURL)
    }

    // MARK: - load / empty state

    func test_init_withNoFile_hasEmptyEntries() {
        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.customName(agent: "claude", projectPath: "/x"))
    }

    func test_load_malformedFile_startsFreshWithoutCrashing() throws {
        try Data("{ not json".utf8).write(to: tempURL)
        let store = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
        // Verify the store is still usable after a recovered load.
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    // MARK: - set / read roundtrip

    func test_setCustomName_persistsValue() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    func test_setCustomName_survivesNewInstanceFromSameFile() {
        let first = makeStore()
        first.setCustomName(agent: "claude", projectPath: "/x", "Auth")

        let second = makeStore()
        XCTAssertEqual(second.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    func test_setCustomName_trimsSurroundingWhitespace() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "  Auth  ")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    func test_setCustomName_doesNotDisturbOtherKeys() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/auth",  "Auth")
        store.setCustomName(agent: "claude", projectPath: "/other", "Other")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/auth"),  "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/other"), "Other")
    }

    // MARK: - removal

    func test_setCustomName_emptyString_removesEntry() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.setCustomName(agent: "claude", projectPath: "/x", "")
        XCTAssertNil(store.customName(agent: "claude", projectPath: "/x"))
    }

    func test_setCustomName_whitespaceOnly_removesEntry() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.setCustomName(agent: "claude", projectPath: "/x", "   \n  ")
        XCTAssertNil(store.customName(agent: "claude", projectPath: "/x"))
    }

    func test_setCustomName_nil_removesEntry() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.setCustomName(agent: "claude", projectPath: "/x", nil)
        XCTAssertNil(store.customName(agent: "claude", projectPath: "/x"))
    }

    func test_removal_survivesNewInstance() {
        let first = makeStore()
        first.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        first.setCustomName(agent: "claude", projectPath: "/x", nil)

        let second = makeStore()
        XCTAssertNil(second.customName(agent: "claude", projectPath: "/x"))
    }

    // MARK: - lookup edge cases

    func test_customName_unknownKey_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.customName(agent: "claude", projectPath: "/missing"))
    }

    func test_customName_nilProjectPath_returnsNil() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        XCTAssertNil(store.customName(agent: "claude", projectPath: nil))
    }

    // MARK: - agent canonicalization

    // notify.sh emits "claude-code" while SessionStore observes "claude" —
    // the persistence layer must canonicalize both sides so an event for
    // "claude-code" finds the entry the user wrote via a "claude" session.
    func test_customName_canonicalizesAgent_claudeCodeFindsClaudeEntry() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        XCTAssertEqual(store.customName(agent: "claude-code", projectPath: "/x"), "Auth")
    }

    func test_setCustomName_canonicalizesAgent_cursorAndClaudeShareEntry() {
        let store = makeStore()
        store.setCustomName(agent: "cursor", projectPath: "/x", "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    // MARK: - noteSeen

    func test_noteSeen_unknownEntry_isNoOp() {
        let store = makeStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        store.noteSeen(agent: "claude", projectPath: "/never-renamed")
        // No write should have happened — we don't track unrenamed sessions.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func test_noteSeen_nilProjectPath_isNoOp() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        // Doesn't crash and doesn't affect persisted state.
        store.noteSeen(agent: "claude", projectPath: nil)
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    // The second-call-same-launch guard is hard to observe externally; the
    // best proxy is that lastSeenAt doesn't move backward and the value
    // remains readable. Here we exercise the path without assertion of
    // file mtime (too brittle), just confirming the entry still resolves.
    func test_noteSeen_repeatCalls_stableLookup() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.noteSeen(agent: "claude", projectPath: "/x")
        store.noteSeen(agent: "claude", projectPath: "/x")
        store.noteSeen(agent: "claude-code", projectPath: "/x")  // canonicalized too
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"), "Auth")
    }

    // MARK: - tabId-aware lookups (Stage 2)

    // The whole point of widening the join key: two tabs in the same
    // (agent, projectPath) can carry independent names.
    func test_setCustomName_withTabId_keepsTabsIndependent() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-A", "Auth tests")
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-B", "Auth main")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-A"), "Auth tests")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-B"), "Auth main")
    }

    // A pre-Stage-2 rename (no tabId) must continue to apply to every
    // tab in that project, until a more specific override is written.
    func test_customName_fallsBackFromTabIdToGenericKey() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")  // generic
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-A"), "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-B"), "Auth")
    }

    // A tab-scoped override beats the generic entry without erasing it.
    func test_customName_tabSpecificOverridesGeneric() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-A", "Auth tests")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-A"), "Auth tests")
        // The generic entry is still there for tabs without an override.
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-B"), "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"),                 "Auth")
    }

    // Clearing a tab-scoped override doesn't touch the generic fallback.
    func test_clearingTabIdEntry_keepsGenericEntry() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", "Auth")
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-A", "Auth tests")
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-A", nil)
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x", tabId: "tab-A"), "Auth")
        XCTAssertEqual(store.customName(agent: "claude", projectPath: "/x"),                 "Auth")
    }

    // Backward-compat across restarts: a Stage-1-era file (only generic
    // keys) must still resolve when a Stage-2 reader asks with tabId.
    func test_genericEntryWrittenWithoutTabId_readableViaTabIdLookup() {
        let first = makeStore()
        first.setCustomName(agent: "claude", projectPath: "/x", "Auth")

        let second = makeStore()
        XCTAssertEqual(second.customName(agent: "claude", projectPath: "/x", tabId: "some-tab"), "Auth")
    }

    // tabId canonicalizes the agent on both sides, same as the generic
    // path — claude-code from an event still finds a claude rename.
    func test_customName_canonicalizesAgent_withTabId() {
        let store = makeStore()
        store.setCustomName(agent: "claude", projectPath: "/x", tabId: "tab-A", "Auth tests")
        XCTAssertEqual(store.customName(agent: "claude-code", projectPath: "/x", tabId: "tab-A"), "Auth tests")
    }
}
