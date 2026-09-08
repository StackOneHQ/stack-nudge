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
}
