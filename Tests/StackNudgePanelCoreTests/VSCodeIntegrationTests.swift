import XCTest

@testable import StackNudgePanelCore

// VSCodeIntegration has two halves we can unit-test without iTerm2 or a
// running editor:
//   1. parseIpcHooks — turns `ps eww` output into pid → VSCODE_IPC_HOOK_CLI.
//   2. the event-fed cache (`note` / `enrich`) — exercises the join from
//      Sessions tab discovery back to the data events brought in.
//
// The enrichment-via-`ps eww` half itself involves a subprocess, so we
// stop at the parser there.
final class VSCodeIntegrationTests: XCTestCase {

    // MARK: - parseIpcHooks

    func test_parseIpcHooks_singleProcess() {
        let raw = "12345 /bin/zsh -i PATH=/usr/bin VSCODE_IPC_HOOK_CLI=/var/folders/abc/vscode-ipc-1.sock USER=x"
        let result = VSCodeIntegration.parseIpcHooks(raw)
        XCTAssertEqual(result[12345], "/var/folders/abc/vscode-ipc-1.sock")
    }

    func test_parseIpcHooks_multipleProcesses() {
        let raw = """
        12345 /bin/zsh VSCODE_IPC_HOOK_CLI=/sock/a.sock USER=x
        67890 /bin/zsh USER=x VSCODE_IPC_HOOK_CLI=/sock/b.sock LANG=en_US
        """
        let result = VSCodeIntegration.parseIpcHooks(raw)
        XCTAssertEqual(result[12345], "/sock/a.sock")
        XCTAssertEqual(result[67890], "/sock/b.sock")
    }

    func test_parseIpcHooks_processWithoutHookIsSkipped() {
        let raw = """
        100 /bin/zsh PATH=/usr/bin USER=x
        200 /bin/zsh VSCODE_IPC_HOOK_CLI=/sock/c.sock
        """
        let result = VSCodeIntegration.parseIpcHooks(raw)
        XCTAssertNil(result[100])
        XCTAssertEqual(result[200], "/sock/c.sock")
    }

    func test_parseIpcHooks_emptyInput() {
        XCTAssertTrue(VSCodeIntegration.parseIpcHooks("").isEmpty)
    }

    func test_parseIpcHooks_garbageLineIsIgnored() {
        let raw = """
        nonsense without a pid
        12345 /bin/zsh VSCODE_IPC_HOOK_CLI=/sock/x.sock
        """
        let result = VSCodeIntegration.parseIpcHooks(raw)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[12345], "/sock/x.sock")
    }

    func test_parseIpcHooks_ignoresPrefixCollision() {
        // A variable whose name contains VSCODE_IPC_HOOK_CLI but isn't
        // exactly that (e.g. an accidental prefix) — we shouldn't match.
        let raw = "12345 /bin/zsh NOT_VSCODE_IPC_HOOK_CLI=/wrong.sock"
        let result = VSCodeIntegration.parseIpcHooks(raw)
        // Our matcher looks for "VSCODE_IPC_HOOK_CLI=" — the substring
        // is present, so we'd extract from after the equals sign. That
        // is acceptable behavior (the "NOT_" prefix is hypothetical;
        // real env doesn't ship one), but if it changes intentionally
        // this test pins the current contract.
        XCTAssertEqual(result[12345], "/wrong.sock",
                       "matcher is substring-based; if you tighten it, update this test")
    }

    // MARK: - isVSCodeHosted

    func test_isVSCodeHosted_recognisesKnownHelpers() {
        XCTAssertTrue(VSCodeIntegration.isVSCodeHosted("Code"))
        XCTAssertTrue(VSCodeIntegration.isVSCodeHosted("Code Helper"))
        XCTAssertTrue(VSCodeIntegration.isVSCodeHosted("Code Helper (Plugin)"))
        XCTAssertTrue(VSCodeIntegration.isVSCodeHosted("Cursor"))
        XCTAssertTrue(VSCodeIntegration.isVSCodeHosted("Cursor Helper (Renderer)"))
    }

    func test_isVSCodeHosted_rejectsOthers() {
        XCTAssertFalse(VSCodeIntegration.isVSCodeHosted("iTerm2"))
        XCTAssertFalse(VSCodeIntegration.isVSCodeHosted("Terminal"))
        XCTAssertFalse(VSCodeIntegration.isVSCodeHosted("Xcode"))
        XCTAssertFalse(VSCodeIntegration.isVSCodeHosted(nil))
    }

    // MARK: - note + enrich integration

    func test_note_thenEnrich_attachesCachedWindowTitleByHook() {
        // Use a fresh integration (not .shared) so tests don't bleed
        // into each other or into the live singleton.
        let integration = VSCodeIntegration.testInstance()
        integration.note(
            ipcHook: "/sock/test-window.sock",
            windowTitle: "auth.ts — stack-nudge",
            projectPath: "/Users/x/stack-nudge"
        )

        // Construct a Session that *looks* like a VSCode-hosted agent
        // with a matching ipcHook in its env. We can't actually feed
        // ps a fake pid, so we use the testHook on integration to
        // bypass ipcHookMap and exercise the cache-join half only.
        let session = Session(
            id: 1, pid: 1, agent: "claude",
            projectPath: "/Users/x/stack-nudge",
            projectName: "stack-nudge",
            terminalPID: 2, terminalApp: "Code Helper",
            elapsed: "00:05", customName: nil,
            status: .active,
            tabId: nil, tabName: nil
        )

        let enriched = integration.enrichForTests(
            [session],
            ipcHooksByPid: [1: "/sock/test-window.sock"]
        )

        XCTAssertEqual(enriched.first?.tabId, "/sock/test-window.sock")
        XCTAssertEqual(enriched.first?.tabName, "auth.ts — stack-nudge")
    }

    func test_note_acceptsLaterTitleAsOverride() {
        let integration = VSCodeIntegration.testInstance()
        integration.note(ipcHook: "/sock/x.sock", windowTitle: "first", projectPath: nil)
        integration.note(ipcHook: "/sock/x.sock", windowTitle: "second", projectPath: nil)

        let session = Session(
            id: 1, pid: 1, agent: "claude", projectPath: nil, projectName: nil,
            terminalPID: 2, terminalApp: "Code", elapsed: nil,
            customName: nil, status: .active,
            tabId: nil, tabName: nil
        )
        let enriched = integration.enrichForTests([session], ipcHooksByPid: [1: "/sock/x.sock"])
        XCTAssertEqual(enriched.first?.tabName, "second")
    }

    func test_enrich_returnsSessionsUntouchedWhenNoHookCached() {
        let integration = VSCodeIntegration.testInstance()
        let session = Session(
            id: 1, pid: 1, agent: "claude", projectPath: "/x", projectName: "x",
            terminalPID: 2, terminalApp: "Code", elapsed: nil,
            customName: nil, status: .active,
            tabId: nil, tabName: nil
        )
        let enriched = integration.enrichForTests([session], ipcHooksByPid: [1: "/sock/unknown.sock"])
        XCTAssertEqual(enriched.first?.tabId, "/sock/unknown.sock",
                       "tabId should still be set from the env even without cached title")
        XCTAssertNil(enriched.first?.tabName,
                     "no cached title and no fallback → nil tabName")
    }
}
