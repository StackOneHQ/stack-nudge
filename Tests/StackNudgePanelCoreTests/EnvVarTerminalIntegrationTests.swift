import XCTest

@testable import StackNudgePanelCore

// Parser tests for the generic env-var-based conformer. The integration
// itself can't be tested end-to-end without `ps eww` and a real Warp /
// Ghostty session running, but the parser is where bugs hide and it's
// fully pure.
final class EnvVarTerminalIntegrationTests: XCTestCase {

    func test_parseEnvValues_singleProcess() {
        let raw = "12345 /bin/zsh PATH=/usr/bin TERM_SESSION_ID=w0t1p2 USER=x"
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        XCTAssertEqual(result[12345], "w0t1p2")
    }

    func test_parseEnvValues_multipleProcesses() {
        let raw = """
        100 /bin/zsh TERM_SESSION_ID=alpha-1
        200 /bin/zsh USER=x TERM_SESSION_ID=beta-2 LANG=en_US
        """
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        XCTAssertEqual(result[100], "alpha-1")
        XCTAssertEqual(result[200], "beta-2")
    }

    func test_parseEnvValues_envVarParameterRespected() {
        // Same raw output, two different var names: each scan finds
        // only its own.
        let raw = "12345 /bin/zsh VSCODE_IPC_HOOK_CLI=/sock TERM_SESSION_ID=session-x"
        let viaTerm = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        let viaVS   = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "VSCODE_IPC_HOOK_CLI")
        XCTAssertEqual(viaTerm[12345], "session-x")
        XCTAssertEqual(viaVS[12345],   "/sock")
    }

    func test_parseEnvValues_processWithoutVarIsSkipped() {
        let raw = """
        100 /bin/zsh PATH=/usr/bin
        200 /bin/zsh TERM_SESSION_ID=present
        """
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        XCTAssertNil(result[100])
        XCTAssertEqual(result[200], "present")
    }

    func test_parseEnvValues_emptyInput() {
        XCTAssertTrue(EnvVarTerminalIntegration.parseEnvValues("", envVar: "TERM_SESSION_ID").isEmpty)
    }

    func test_parseEnvValues_garbageLineIgnored() {
        let raw = """
        nonsense without a pid TERM_SESSION_ID=ignored
        12345 /bin/zsh TERM_SESSION_ID=kept
        """
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[12345], "kept")
    }

    func test_parseEnvValues_envVarNotFoundForLine() {
        // Variable name doesn't match — extraction returns nothing for
        // that pid. (Substring matching: we only match exact var=…)
        let raw = "12345 /bin/zsh OTHER_VAR=value"
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TERM_SESSION_ID")
        XCTAssertTrue(result.isEmpty)
    }

    func test_parseEnvValues_tmuxPane() {
        // tmux integration keys off TMUX_PANE; the value starts with "%".
        let raw = "99028 /bin/zsh TMUX=/private/tmp/tmux-502/default,12390,0 TMUX_PANE=%4 LC_TERMINAL=iTerm2"
        let result = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX_PANE")
        XCTAssertEqual(result[99028], "%4")
    }

    func test_parseEnvValues_tmuxVarDoesNotMatchPaneVar() {
        // The needle is "<var>=", so a scan for TMUX must not be satisfied by
        // TMUX_PANE=… (the "_" breaks the "TMUX=" match). Order the pane var
        // first to prove the socket var is the one found.
        let raw = "99028 /bin/zsh TMUX_PANE=%4 TMUX=/private/tmp/tmux-502/default,12390,0"
        let socket = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX")
        let pane   = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX_PANE")
        XCTAssertEqual(socket[99028], "/private/tmp/tmux-502/default,12390,0")
        XCTAssertEqual(pane[99028], "%4")
    }
}
