import XCTest

@testable import StackNudgePanelCore

final class TmuxIntegrationTests: XCTestCase {

    func test_tabId_composesServerAndPane() {
        // TMUX = "<socket>,<serverPID>,<n>" → "<serverPID>:<pane>".
        let id = TmuxIntegration.tabId(pane: "%4", tmux: "/private/tmp/tmux-502/default,12390,0")
        XCTAssertEqual(id, "12390:%4")
    }

    func test_tabId_fallsBackToBarePaneWhenTmuxMissing() {
        XCTAssertEqual(TmuxIntegration.tabId(pane: "%1", tmux: nil), "%1")
    }

    func test_tabId_fallsBackWhenTmuxMalformed() {
        // No comma → no server field; empty server field → also fall back.
        XCTAssertEqual(TmuxIntegration.tabId(pane: "%1", tmux: "nocommas"), "%1")
        XCTAssertEqual(TmuxIntegration.tabId(pane: "%2", tmux: "/sock,,0"), "%2")
    }

    func test_tabId_distinctAcrossServers() {
        // Same pane id in two different servers must not collide.
        let a = TmuxIntegration.tabId(pane: "%1", tmux: "/sockA,111,0")
        let b = TmuxIntegration.tabId(pane: "%1", tmux: "/sockB,222,0")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - socketKey

    // The socket is the first comma-field. Titles are looked up one server at a
    // time because pane ids only mean anything within a server, so this is what
    // decides which server a session's title is read from — a wrong answer here
    // shows the pane title of a different tmux entirely.
    func test_socketKey_extractsTheSocketPath() {
        XCTAssertEqual(TmuxIntegration.socketKey("/private/tmp/tmux-502/default,12390,0"),
                       "/private/tmp/tmux-502/default")
    }

    // nil means "don't look up a title", never "use the default socket". The
    // default socket is a real server: guessing it hands a session the title of
    // whichever pane shares its id over there, and "%0" exists on every server.
    // Reachable via the nested-tmux idioms (`TMUX= cmd`, `env -u TMUX cmd`),
    // which clear TMUX but leave TMUX_PANE — pane known, server unknown.
    func test_socketKey_isNilWhenTheServerIsUnknown() {
        XCTAssertNil(TmuxIntegration.socketKey(nil))
        XCTAssertNil(TmuxIntegration.socketKey(",111,0"), "empty socket field is not the default")
        XCTAssertNil(TmuxIntegration.socketKey(""))
    }

    // The two read different fields for different jobs — tabId wants the server
    // pid (identity), socketKey wants the socket path (where to query) — so a
    // TMUX missing only the socket still yields a usable tabId while refusing a
    // title lookup. That asymmetry is the point: identity degrades gracefully,
    // the lookup refuses. What must never happen is the lookup silently
    // resolving to the default server, which is a different tmux entirely.
    func test_malformedTmux_keepsIdentityButRefusesTheTitleLookup() {
        XCTAssertEqual(TmuxIntegration.tabId(pane: "%0", tmux: ",111,0"), "111:%0",
                       "the server pid is still usable as identity")
        XCTAssertNil(TmuxIntegration.socketKey(",111,0"),
                     "but there is no socket to query, and the default is not a guess to make")
    }

    func test_socketKey_separatesServersThatShareAPaneID() {
        XCTAssertNotEqual(TmuxIntegration.socketKey("/sockA,111,0"),
                          TmuxIntegration.socketKey("/sockB,222,0"))
    }

    func test_socketKey_extractsEvenWhenLaterFieldsAreMissing() {
        XCTAssertEqual(TmuxIntegration.socketKey("/only/socket"), "/only/socket")
    }

    // MARK: - parseTitles

    // Lines are "<pane>\t<host>\t<title>" — the host comes from tmux itself so
    // the sentinel comparison is exact rather than a guess at the machine's name.
    private func line(_ pane: String, _ title: String, host: String = "machine.local") -> String {
        "\(pane)\t\(host)\t\(title)\n"
    }

    func test_parseTitles_readsPaneAndTitle() {
        let raw = line("%0", "✳ Review repository structure") + line("%1", "vim README.md")
        let titles = TmuxIntegration.parseTitles(raw)
        XCTAssertEqual(titles["%0"], "✳ Review repository structure")
        XCTAssertEqual(titles["%1"], "vim README.md")
    }

    // tmux seeds every pane's title with the hostname and only replaces it once
    // the program emits an OSC title escape, so an untitled pane is not empty —
    // it reads back as the machine's name. Without this filter every plain shell
    // pane would be labelled "machine.local", and with the toggle on that name
    // would title a banner and a Slack DM.
    func test_parseTitles_dropsTheHostnameSentinel() {
        let raw = line("%0", "machine.local") + line("%1", "real title")
        let titles = TmuxIntegration.parseTitles(raw)
        XCTAssertNil(titles["%0"])
        XCTAssertEqual(titles["%1"], "real title")
    }

    // The host is whatever tmux reports for that line, so the filter follows a
    // machine renamed at runtime and needs no case-folding. An earlier cut
    // derived the sentinel from ProcessInfo.hostName, which returns the
    // lowercased mDNS spelling while tmux seeds from gethostname() — they differ
    // in case here and can be different names entirely on a DHCP/corp-DNS Mac,
    // so nothing was filtered.
    func test_parseTitles_sentinelFollowsWhateverHostTmuxReports() {
        let raw = line("%0", "Renamed-Host.corp.example.com", host: "Renamed-Host.corp.example.com")
            + line("%1", "Machine.local", host: "machine.local")
        let titles = TmuxIntegration.parseTitles(raw)
        XCTAssertNil(titles["%0"], "an exact match against tmux's own host is the sentinel")
        XCTAssertEqual(titles["%1"], "Machine.local",
                       "a different spelling is a real title, not the sentinel")
    }

    // Matching the bare first label too would swallow every pane a user on a
    // machine called "orion" legitimately titled "orion".
    func test_parseTitles_shortHostnameIsARealTitle() {
        let titles = TmuxIntegration.parseTitles(line("%0", "machine", host: "machine.local"))
        XCTAssertEqual(titles["%0"], "machine")
    }

    func test_parseTitles_skipsEmptyAndMalformedLines() {
        let raw = line("%0", "") + "%1\n" + "\n" + "%2\tonly-two-fields\n" + line("%3", "kept")
        let titles = TmuxIntegration.parseTitles(raw)
        XCTAssertNil(titles["%0"], "an empty title is not a title")
        XCTAssertNil(titles["%1"], "no delimiter means no fields")
        XCTAssertNil(titles["%2"], "a missing title field is not a title")
        XCTAssertEqual(titles["%3"], "kept")
        XCTAssertEqual(titles.count, 1)
    }

    // Pipe was the obvious delimiter — every other integration here uses it —
    // but a pane title is arbitrary program output and "|" turns up in shell
    // prompts constantly. tmux accepts neither a tab nor a newline into a pane
    // title (it strips them from an OSC title and rejects a select-pane -T
    // carrying one), so the delimiter can't appear in the payload.
    func test_parseTitles_keepsPipesInsideATitle() {
        let titles = TmuxIntegration.parseTitles(line("%0", "build | tee log.txt"))
        XCTAssertEqual(titles["%0"], "build | tee log.txt")
    }

    func test_parseTitles_emptyInputIsEmpty() {
        XCTAssertTrue(TmuxIntegration.parseTitles("").isEmpty)
    }

    // MARK: - Failure backoff

    // A wedged tmux doesn't fail fast, it hangs: ProcessOutput burns the timeout
    // plus its SIGTERM/SIGKILL/drain waits (~5s) before giving up, and the
    // session scan is latched behind that. Re-probing every 3s poll would pay it
    // forever, so a failure parks that socket briefly.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_backoff_parksAHangingServerAndLetsItBack() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        _ = TmuxIntegration.titles(from: nil, socket: "/sockA", now: now)

        XCTAssertTrue(TmuxIntegration.isBackedOff("/sockA", now: now))
        XCTAssertTrue(TmuxIntegration.isBackedOff(
            "/sockA", now: now.addingTimeInterval(TmuxIntegration.failureBackoff - 1)))
        XCTAssertFalse(TmuxIntegration.isBackedOff(
            "/sockA", now: now.addingTimeInterval(TmuxIntegration.failureBackoff + 1)),
            "it comes back once the window passes")
    }

    // A server that is merely gone is not a hang — tmux exits rc=1 at once with
    // empty stdout, so the poll pays nothing and there is nothing to park.
    // Backing that off would mute titles for half a minute after an ordinary
    // tmux restart.
    func test_backoff_notArmedByAnEmptyResult() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        XCTAssertTrue(TmuxIntegration.titles(from: "", socket: "/sockA", now: now).isEmpty)
        XCTAssertFalse(TmuxIntegration.isBackedOff("/sockA", now: now))
    }

    // Backoff is per socket: one wedged server must not mute a healthy one.
    func test_backoff_isPerSocket() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        _ = TmuxIntegration.titles(from: nil, socket: "/sockA", now: now)
        XCTAssertFalse(TmuxIntegration.isBackedOff("/sockB", now: now))
    }

    // A server that recovers must be trusted again immediately, not left parked
    // for the rest of the window.
    func test_backoff_clearedByASuccessfulRead() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        _ = TmuxIntegration.titles(from: nil, socket: "/sockA", now: now)
        XCTAssertTrue(TmuxIntegration.isBackedOff("/sockA", now: now))

        let recovered = TmuxIntegration.titles(
            from: line("%0", "deploy pipeline"), socket: "/sockA", now: now)
        XCTAssertEqual(recovered["%0"], "deploy pipeline")
        XCTAssertFalse(TmuxIntegration.isBackedOff("/sockA", now: now))
    }

    // MARK: - The query contract

    // Mutation testing found that every pure helper here was covered while the
    // code wiring them to tmux was covered by nothing: deleting #{host} from the
    // format string left the whole suite green, and no session would ever get a
    // title again, because parseTitles' field-count guard silently rejects every
    // line. This builds a line the way tmux would — straight from the format the
    // app actually sends — and pushes it back through the real parser, so the
    // two halves can no longer drift apart in silence.
    func test_formatStringAndParserAgree() {
        let line = TmuxIntegration.paneFormat
            .replacingOccurrences(of: "#{pane_id}", with: "%7")
            .replacingOccurrences(of: "#{host}", with: "machine.local")
            .replacingOccurrences(of: "#{pane_title}", with: "deploy pipeline")
        let titles = TmuxIntegration.parseTitles(line + "\n")
        XCTAssertEqual(titles["%7"], "deploy pipeline",
                       "the format string and parseTitles disagree about the fields")
    }

    // The same contract for the sentinel: an untitled pane's title IS the host,
    // so a format missing #{host} would take the filter down with it.
    func test_formatStringCarriesTheHostForTheSentinel() {
        let line = TmuxIntegration.paneFormat
            .replacingOccurrences(of: "#{pane_id}", with: "%7")
            .replacingOccurrences(of: "#{host}", with: "machine.local")
            .replacingOccurrences(of: "#{pane_title}", with: "machine.local")
        XCTAssertTrue(TmuxIntegration.parseTitles(line + "\n").isEmpty,
                      "an untitled pane must still be filterable")
    }

    // Without -a, list-panes reports only the current session's panes, so every
    // agent in another tmux session silently loses its title.
    func test_listPanesArgs_queriesEverySessionOnTheGivenSocket() {
        let args = TmuxIntegration.listPanesArgs(socket: "/tmp/s.sock")
        XCTAssertTrue(args.contains("-a"), "-a is what makes this all sessions")
        XCTAssertEqual(args.firstIndex(of: "-S").map { args[args.index(after: $0)] },
                       "/tmp/s.sock", "the socket must be explicit")
        XCTAssertEqual(args.firstIndex(of: "-F").map { args[args.index(after: $0)] },
                       TmuxIntegration.paneFormat)
    }

    // Asserts what paneTitles actually SENDS, not what the helpers return.
    // Checking AppActivator.tmuxEnv() alone was useless: it still passed when
    // the call site stopped passing the env, which is how the UTF-8 locale could
    // be deleted with the whole suite green. The locale is not hygiene — without
    // it tmux renders "✳ …" as "_ …" for a launchd-spawned panel, which this
    // project already hit once on the focus path.
    func test_paneTitles_sendsTheFullArgVectorAndAUTF8Locale() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        var sentArgs: [String]?
        var sentEnv: [String: String]?
        _ = TmuxIntegration.paneTitles(
            socket: "/tmp/s.sock",
            tmuxPath: { "/opt/homebrew/bin/tmux" },
            run: { _, args, env in sentArgs = args; sentEnv = env; return "" })

        XCTAssertEqual(sentArgs, TmuxIntegration.listPanesArgs(socket: "/tmp/s.sock"))
        XCTAssertEqual(sentEnv?["LC_ALL"]?.lowercased().contains("utf-8"), true,
                       "tmux decides UTF-8 from LC_ALL/LC_CTYPE/LANG")
    }

    // No tmux binary means no query at all, rather than a spawn of something else.
    func test_paneTitles_withoutATmuxBinaryDoesNotRun() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        var ran = false
        let titles = TmuxIntegration.paneTitles(
            socket: "/tmp/s.sock", tmuxPath: { nil },
            run: { _, _, _ in ran = true; return "" })
        XCTAssertFalse(ran)
        XCTAssertTrue(titles.isEmpty)
    }

    // A parked socket must not be re-probed — that is the whole point of the
    // backoff, and only an observed call proves the skip happens.
    func test_paneTitles_skipsAParkedSocketWithoutSpawning() {
        TmuxIntegration.resetBackoff()
        defer { TmuxIntegration.resetBackoff() }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        _ = TmuxIntegration.titles(from: nil, socket: "/tmp/s.sock", now: when)

        var ran = false
        _ = TmuxIntegration.paneTitles(
            socket: "/tmp/s.sock", now: when,
            tmuxPath: { "/opt/homebrew/bin/tmux" },
            run: { _, _, _ in ran = true; return "" })
        XCTAssertFalse(ran, "a parked socket must not be probed again")
    }

    // MARK: - apply (per-server title mapping)

    private func tmuxSession(pid: Int,
                             terminalApp: String = "tmux",
                             tabName: String? = nil) -> Session {
        Session(id: pid, pid: pid, agent: "claude",
                projectPath: "/Users/x/stackone", projectName: "stackone",
                terminalPID: 2, terminalApp: terminalApp, elapsed: nil,
                customName: nil, status: .active,
                tabId: nil, tabName: tabName, liveTitle: nil, liveTitleSource: nil)
    }

    // The property the whole socketKey design exists for. Both servers have a
    // pane "%0" with different titles; each session must get its own server's.
    // Pooling the maps is a plausible-looking simplification that silently hands
    // a session another tmux's title — and under the naming toggle, another
    // tmux's title into a Slack DM.
    func test_apply_takesTitlesOnlyFromTheSessionsOwnServer() {
        let out = TmuxIntegration.apply(
            [tmuxSession(pid: 10), tmuxSession(pid: 20)],
            panes: [10: "%0", 20: "%0"],
            tmuxes: [10: "/sockA,111,0", 20: "/sockB,222,0"],
            titlesBySocket: ["/sockA": ["%0": "server A work"],
                             "/sockB": ["%0": "server B work"]])
        XCTAssertEqual(out.first { $0.pid == 10 }?.tabName, "server A work")
        XCTAssertEqual(out.first { $0.pid == 20 }?.tabName, "server B work")
        XCTAssertEqual(out.first { $0.pid == 10 }?.tabId, "111:%0")
        XCTAssertEqual(out.first { $0.pid == 20 }?.tabId, "222:%0")
    }

    // An unknown server must yield no title rather than one borrowed from
    // whichever server happens to be in the map.
    func test_apply_unknownServerGetsNoTitle() {
        let out = TmuxIntegration.apply(
            [tmuxSession(pid: 10)],
            panes: [10: "%0"], tmuxes: [:],
            titlesBySocket: ["/sockA": ["%0": "not yours"]])
        XCTAssertNil(out[0].tabName)
        XCTAssertEqual(out[0].tabId, "%0", "identity still degrades gracefully")
    }

    // Non-tmux sessions pass through untouched — the registry runs every
    // integration over the same array.
    func test_apply_leavesOtherTerminalsAlone() {
        let iterm = tmuxSession(pid: 30, terminalApp: "iTerm2", tabName: "set by iTerm2")
        let out = TmuxIntegration.apply([iterm], panes: [30: "%0"],
                                        tmuxes: [30: "/sockA,111,0"],
                                        titlesBySocket: ["/sockA": ["%0": "tmux title"]])
        XCTAssertEqual(out[0].tabName, "set by iTerm2")
        XCTAssertNil(out[0].tabId)
    }

}
