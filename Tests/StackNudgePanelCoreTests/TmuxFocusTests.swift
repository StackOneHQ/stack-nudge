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

    // MARK: - iTerm2 session matching

    private func row(_ guid: String, tty: String = "", pane: String = "", role: String = "",
                     paneTitle: String = "", autoName: String = "", name: String = ""
    ) -> AppActivator.ITermSessionRow {
        AppActivator.ITermSessionRow(guid: guid, tty: tty, tmuxPane: pane, tmuxRole: role,
                                     tmuxPaneTitle: paneTitle, autoName: autoName, name: name)
    }

    private let controlClient = AppActivator.TmuxClient(controlMode: true, activity: 5, pid: 29208,
                                                        tty: "/dev/ttys035")

    private func match(_ pane: String, _ title: String?,
                       clients: [AppActivator.TmuxClient]?,
                       _ rows: [AppActivator.ITermSessionRow]) -> String? {
        AppActivator.matchITermSession(pane: pane, title: title, clients: clients, in: rows)
    }

    func test_parseITermSessions_splitsOnUnitSeparatorAndBlanksMissingValue() {
        let raw = ["G1", "missing value", "6", "client", "✳ a|b", "tmux", "✳ a|b (claude)"]
            .joined(separator: "\u{1F}") + "\nshort\u{1F}row\n"

        let actual = AppActivator.parseITermSessions(raw)

        XCTAssertEqual(actual, [row("G1", pane: "6", role: "client", paneTitle: "✳ a|b",
                                    autoName: "tmux", name: "✳ a|b (claude)")])
    }

    func test_parseTmuxClients_mostRecentlyActiveFirst() {
        let raw = "1 100 29208 /dev/ttys035\n0 300 4411 /dev/ttys004\nbad line\n"

        let actual = AppActivator.parseTmuxClients(raw)

        XCTAssertEqual(actual.map(\.pid), [4411, 29208])
        XCTAssertEqual(actual.map(\.controlMode), [false, true])
        XCTAssertEqual(actual.first?.tty, "/dev/ttys004")
    }

    func test_applyClientEnvironment_readsHostAndITermSession() {
        // The client's env names the terminal drawing it now, even when the
        // agent's env (LC_TERMINAL from when the pane started) says otherwise.
        let ps = """
            29208 tmux -CC __CFBundleIdentifier=com.googlecode.iterm2 ITERM_SESSION_ID=w0t0p0:GW TERM_PROGRAM=iTerm.app
            4411 tmux attach TERM_PROGRAM=Apple_Terminal
            """
        let clients = [controlClient,
                       AppActivator.TmuxClient(controlMode: false, activity: 1, pid: 4411, tty: "/dev/ttys004")]

        let actual = AppActivator.applyClientEnvironment(ps, to: clients)

        XCTAssertEqual(actual.map(\.hostBundleID), ["com.googlecode.iterm2", "com.apple.Terminal"])
        XCTAssertEqual(actual.map(\.iTermSessionGUID), ["GW", nil])
    }

    func test_match_ccPaneNumberWinsOverASharedTitle() {
        // "Name (Job)" titles and a profile-named autoName: only the pane number
        // tells these two apart.
        let rows = [
            row("A", pane: "21", paneTitle: "✳ same", autoName: "tmux", name: "✳ same (claude)"),
            row("B", pane: "43", paneTitle: "✳ same", autoName: "tmux", name: "✳ same (claude)"),
        ]
        XCTAssertEqual(match("%43", "✳ same", clients: [controlClient], rows), "B")
    }

    func test_match_piPaneFromSidecarMatchesByNumber() {
        let rows = [row("P", pane: "38", paneTitle: "π - stackone", name: "π - stackone (pi)")]
        XCTAssertEqual(match("%38", "π - stackone", clients: [controlClient], rows), "P")
    }

    func test_match_paneNumbersIgnoredWithoutAControlModeClientOnThisServer() {
        // %6 on a server iTerm2 isn't attached to via -CC is not the %6 tab
        // iTerm2 shows for some other server.
        let rows = [row("OTHER-SERVER", pane: "6", paneTitle: "✳ task", name: "✳ task")]
        XCTAssertNil(match("%6", "✳ task", clients: [], rows))
    }

    func test_match_paneNumberTieAcrossServersBreaksOnTitle() {
        let rows = [
            row("S1", pane: "6", paneTitle: "✳ one", name: "✳ one (claude)"),
            row("S2", pane: "6", paneTitle: "✳ two", name: "✳ two (claude)"),
        ]
        XCTAssertEqual(match("%6", "✳ two", clients: [controlClient], rows), "S2")
    }

    func test_match_tmuxDrawnInAnOrdinaryTabUsesTheClientsITermSession() {
        // Not -CC: iTerm2 sees one plain session running the tmux client, named
        // whatever tmux set, so the client's own ITERM_SESSION_ID is the key.
        var client = AppActivator.TmuxClient(controlMode: false, activity: 1, pid: 4411, tty: "/dev/ttys004")
        client.iTermSessionGUID = "HOST"
        let rows = [row("OTHER", tty: "/dev/ttys001", name: "zsh"),
                    row("HOST", tty: "/dev/ttys004", name: "tmux (tmux)")]
        XCTAssertEqual(match("%6", "✳ stack-nudge", clients: [client], rows), "HOST")
    }

    func test_match_ordinaryTabFallsBackToTheClientTTY() {
        let client = AppActivator.TmuxClient(controlMode: false, activity: 1, pid: 4411, tty: "/dev/ttys004")
        let rows = [row("OTHER", tty: "/dev/ttys001"), row("HOST", tty: "/dev/ttys004")]
        XCTAssertEqual(match("%6", nil, clients: [client], rows), "HOST")
    }

    func test_match_titleIsNeverTrustedForTmuxDrawnInAnOrdinaryTab() {
        // Without -CC, iTerm2 titles don't mirror pane titles; a same-named
        // unrelated tab must not be focused.
        let client = AppActivator.TmuxClient(controlMode: false, activity: 1, pid: 4411, tty: "/dev/ttys004")
        let rows = [row("UNRELATED", tty: "/dev/ttys009", name: "✳ stack-nudge")]
        XCTAssertNil(match("%6", "✳ stack-nudge", clients: [client], rows))
    }

    func test_match_neverSelectsTheGatewaySession() {
        let rows = [row("GATEWAY", tty: "/dev/ttys035", role: "gateway", name: "tmux -CC")]
        XCTAssertNil(match("%6", "tmux -CC", clients: [controlClient], rows))
    }

    func test_match_preVariableITermFallsBackToName() {
        // Before 3.3 there are no tmux variables; name is the only title,
        // with or without the job appended.
        XCTAssertEqual(match("%6", "✳ stack-nudge", clients: [controlClient],
                             [row("OLD", name: "✳ stack-nudge")]), "OLD")
        XCTAssertEqual(match("%6", "✳ stack-nudge", clients: [controlClient],
                             [row("OLD", name: "✳ stack-nudge (claude)")]), "OLD")
        // tmux unreachable: the -CC fallbacks stay available.
        XCTAssertEqual(match("%6", "✳ stack-nudge", clients: nil,
                             [row("OLD", name: "✳ stack-nudge (claude)")]), "OLD")
    }

    func test_match_ambiguousTitleWithoutPaneNumbersIsNil() {
        let rows = [row("A", name: "✳ same (claude)"), row("B", name: "✳ same (claude)")]
        XCTAssertNil(match("%6", "✳ same", clients: [controlClient], rows))
    }

    func test_match_titlePrefixAloneIsNotAJobSuffix() {
        XCTAssertNil(match("%6", "✳ stack-nudge", clients: [controlClient],
                           [row("A", name: "✳ stack-nudge-extras")]))
    }
}
