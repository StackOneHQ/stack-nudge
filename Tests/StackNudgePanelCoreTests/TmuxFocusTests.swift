import XCTest

@testable import StackNudgePanelCore

// Pure-parse tests for the tmux focus resolver. The live path (`target`) needs
// `ps eww` against a real tmux pane, but `parse` is where the extraction rules
// live and is fully pure.
final class TmuxFocusTests: XCTestCase {

    func test_parse_extractsPaneSocketAndHost() {
        let raw = "99028 /bin/zsh TMUX=/private/tmp/tmux-502/default,12390,0 TMUX_PANE=%4 LC_TERMINAL=iTerm2"
        let target = TmuxFocus.parse(psOutput: raw, pid: 99028)
        XCTAssertEqual(target?.pane, "%4")
        // TMUX is "<socket>,<serverPID>,<sessionN>" — only the socket path.
        XCTAssertEqual(target?.socket, "/private/tmp/tmux-502/default")
        XCTAssertEqual(target?.hostBundleID, "com.googlecode.iterm2")
    }

    func test_parse_nilWhenNotInTmux() {
        // No TMUX_PANE → the process isn't inside tmux.
        let raw = "99028 /bin/zsh TERM_PROGRAM=iTerm.app ITERM_SESSION_ID=w0t1p0:ABC"
        XCTAssertNil(TmuxFocus.parse(psOutput: raw, pid: 99028))
    }

    func test_parse_socketNilWhenTmuxUnset() {
        // A pane var with no TMUX socket (unusual, but must not crash): socket
        // is nil and focus falls back to the default socket.
        let raw = "42 /bin/zsh TMUX_PANE=%1 LC_TERMINAL=iTerm2"
        let target = TmuxFocus.parse(psOutput: raw, pid: 42)
        XCTAssertEqual(target?.pane, "%1")
        XCTAssertNil(target?.socket)
        XCTAssertEqual(target?.hostBundleID, "com.googlecode.iterm2")
    }

    func test_normalizedTitle_stripsAnimatedSpinner() {
        // codex renders a braille spinner; different frames must normalize to
        // the same stable title so the tmux read and iTerm2 name still match.
        XCTAssertEqual(AppActivator.normalizedTitle("⠦ stackone"), "stackone")
        XCTAssertEqual(AppActivator.normalizedTitle("⠋ stackone"),
                       AppActivator.normalizedTitle("⠧ stackone"))
    }

    func test_normalizedTitle_leavesStablePrefixesAlone() {
        // Claude's "✳" is not a braille glyph; agy has no decoration.
        XCTAssertEqual(AppActivator.normalizedTitle("✳ Bump stackvox to version 0.6.0"),
                       "✳ Bump stackvox to version 0.6.0")
        XCTAssertEqual(AppActivator.normalizedTitle("StackOne.local"), "StackOne.local")
    }

    func test_hostBundleID_iTerm2() {
        XCTAssertEqual(TmuxFocus.hostBundleID(forLCTerminal: "iTerm2"), "com.googlecode.iterm2")
    }

    func test_hostBundleID_unmappableHostsAreNil() {
        // Terminal.app doesn't propagate LC_TERMINAL through tmux, so it (and
        // any other host) resolves to nil — pane select still happens, no raise.
        XCTAssertNil(TmuxFocus.hostBundleID(forLCTerminal: "Apple_Terminal"))
        XCTAssertNil(TmuxFocus.hostBundleID(forLCTerminal: "WezTerm"))
        XCTAssertNil(TmuxFocus.hostBundleID(forLCTerminal: nil))
    }

    private func writeSidecar(_ json: String, pid: Int, dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? json.write(toFile: "\(dir)/\(pid).json", atomically: true, encoding: .utf8)
    }

    func test_sidecarTarget_resolvesPaneSocketAndHost() {
        // pi's env is unreadable via `ps`, so the in-process extension writes the
        // pane here; the panel focuses by pid without any `ps` call.
        let dir = NSTemporaryDirectory() + "pi-sessions-\(UUID().uuidString)"
        writeSidecar(
            #"{"pane":"%39","socket":"/private/tmp/tmux-502/default","lcTerminal":"iTerm2"}"#,
            pid: 4242, dir: dir)

        let actual = TmuxFocus.sidecarTarget(pid: 4242, dir: dir)

        XCTAssertEqual(actual?.pane, "%39")
        XCTAssertEqual(actual?.socket, "/private/tmp/tmux-502/default")
        XCTAssertEqual(actual?.hostBundleID, "com.googlecode.iterm2")
    }

    func test_sidecarTarget_nilWhenMissingOrPaneless() {
        let dir = NSTemporaryDirectory() + "pi-sessions-\(UUID().uuidString)"
        XCTAssertNil(TmuxFocus.sidecarTarget(pid: 1, dir: dir))  // no file
        writeSidecar(#"{"socket":"/tmp/s"}"#, pid: 7, dir: dir)  // no pane
        XCTAssertNil(TmuxFocus.sidecarTarget(pid: 7, dir: dir))
    }

    func test_sidecarTarget_emptySocketBecomesNil() {
        let dir = NSTemporaryDirectory() + "pi-sessions-\(UUID().uuidString)"
        writeSidecar(#"{"pane":"%1","socket":""}"#, pid: 9, dir: dir)
        let actual = TmuxFocus.sidecarTarget(pid: 9, dir: dir)
        XCTAssertEqual(actual?.pane, "%1")
        XCTAssertNil(actual?.socket)      // empty socket → default socket
        XCTAssertNil(actual?.hostBundleID) // no lcTerminal → no host raise
    }
}
