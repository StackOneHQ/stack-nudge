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
        let raw = "42 /bin/zsh TMUX_PANE=%1 LC_TERMINAL=Apple_Terminal"
        let target = TmuxFocus.parse(psOutput: raw, pid: 42)
        XCTAssertEqual(target?.pane, "%1")
        XCTAssertNil(target?.socket)
        XCTAssertEqual(target?.hostBundleID, "com.apple.Terminal")
    }

    func test_hostBundleID_knownHosts() {
        XCTAssertEqual(TmuxFocus.hostBundleID(forLCTerminal: "iTerm2"), "com.googlecode.iterm2")
        XCTAssertEqual(TmuxFocus.hostBundleID(forLCTerminal: "Apple_Terminal"), "com.apple.Terminal")
    }

    func test_hostBundleID_unknownOrNilIsNil() {
        XCTAssertNil(TmuxFocus.hostBundleID(forLCTerminal: "WezTerm"))
        XCTAssertNil(TmuxFocus.hostBundleID(forLCTerminal: nil))
    }
}
