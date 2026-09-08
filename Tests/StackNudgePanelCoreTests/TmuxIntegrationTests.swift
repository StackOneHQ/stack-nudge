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

    func test_socketKey_isEmptyForTheDefaultSocket() {
        // "" stands for "tmux's own default"; paneTitles turns it back into no
        // -S flag. tmux never hands us an empty socket path, so it can't clash.
        XCTAssertEqual(TmuxIntegration.socketKey(nil), "")
        XCTAssertEqual(TmuxIntegration.socketKey(",111,0"), "")
    }

    func test_socketKey_separatesServersThatShareAPaneID() {
        XCTAssertNotEqual(TmuxIntegration.socketKey("/sockA,111,0"),
                          TmuxIntegration.socketKey("/sockB,222,0"))
    }

    // MARK: - parseTitles

    // Lowercased, as hostNames() produces them.
    private let hosts: Set<String> = ["machine.local", "machine"]

    func test_parseTitles_readsPaneAndTitle() {
        let raw = "%0\t✳ Review repository structure\n%1\tvim README.md\n"
        let titles = TmuxIntegration.parseTitles(raw, hostNames: hosts)
        XCTAssertEqual(titles["%0"], "✳ Review repository structure")
        XCTAssertEqual(titles["%1"], "vim README.md")
    }

    // tmux seeds every pane's title with the hostname and only replaces it once
    // the program emits an OSC title escape, so an untitled pane is not empty —
    // it reads back as the machine's name. Without this filter every plain shell
    // pane would be labelled "Machine.local", and with the toggle on that name
    // would title a banner and a Slack DM.
    func test_parseTitles_dropsTheHostnameSentinel() {
        let raw = "%0\tmachine.local\n%1\tmachine\n%2\treal title\n"
        let titles = TmuxIntegration.parseTitles(raw, hostNames: hosts)
        XCTAssertNil(titles["%0"])
        XCTAssertNil(titles["%1"], "the short hostname is the same sentinel")
        XCTAssertEqual(titles["%2"], "real title")
    }

    // Regression guard for a bug an exact-match filter shipped with, and that
    // same-case fixtures hid: the two sides disagree on capitalisation. tmux
    // seeds the title from the SystemConfiguration name ("Machine.local") while
    // ProcessInfo.hostName returns the lowercased mDNS spelling, so nothing was
    // ever filtered and every untitled pane was named after the machine.
    func test_parseTitles_dropsTheHostnameRegardlessOfCase() {
        let raw = "%0\tMachine.local\n%1\tMACHINE\n%2\tMachine-Learning Notes\n"
        let titles = TmuxIntegration.parseTitles(raw, hostNames: hosts)
        XCTAssertNil(titles["%0"], "tmux's capitalised hostname is still the sentinel")
        XCTAssertNil(titles["%1"])
        XCTAssertEqual(titles["%2"], "Machine-Learning Notes",
                       "only an exact (case-insensitive) hostname is a sentinel")
    }

    // The filter is only correct if the two halves agree, so assert the contract
    // between them rather than trusting each in isolation: whatever spelling
    // tmux hands back, lowercasing it must land inside hostNames().
    func test_hostNamesAreLowercasedForThatComparison() {
        let names = TmuxIntegration.hostNames()
        for name in names {
            XCTAssertEqual(name, name.lowercased(), "hostNames() must be pre-lowercased")
        }
        // The real hostname, capitalised the way tmux would, must still filter.
        let asTmuxWouldSeedIt = ProcessInfo.processInfo.hostName.uppercased()
        let titles = TmuxIntegration.parseTitles("%0\t\(asTmuxWouldSeedIt)\n", hostNames: names)
        XCTAssertTrue(titles.isEmpty, "the live hostname must filter in any case")
    }

    func test_parseTitles_skipsEmptyAndMalformedLines() {
        let raw = "%0\t\n%1\n\n%2\tkept\n"
        let titles = TmuxIntegration.parseTitles(raw, hostNames: hosts)
        XCTAssertNil(titles["%0"], "an empty title is not a title")
        XCTAssertNil(titles["%1"], "no delimiter means no title field")
        XCTAssertEqual(titles["%2"], "kept")
        XCTAssertEqual(titles.count, 1)
    }

    // Pipe was the obvious delimiter — every other integration here uses it —
    // but a pane title is arbitrary program output and "|" turns up in shell
    // prompts constantly. Tab is the one character tmux collapses out of
    // #{pane_title}, so it can't appear in the payload and split a title in two.
    func test_parseTitles_keepsPipesInsideATitle() {
        let titles = TmuxIntegration.parseTitles("%0\tbuild | tee log.txt\n", hostNames: hosts)
        XCTAssertEqual(titles["%0"], "build | tee log.txt")
    }

    func test_parseTitles_emptyInputIsEmpty() {
        XCTAssertTrue(TmuxIntegration.parseTitles("", hostNames: hosts).isEmpty)
    }

    // The real hostname set is derived from ProcessInfo, so assert the shape the
    // filter depends on rather than this machine's name: both the dotted form
    // and its first label, since which one tmux seeds depends on resolution.
    func test_hostNames_includesBothTheLongAndShortForm() {
        let names = TmuxIntegration.hostNames()
        XCTAssertFalse(names.isEmpty)
        let full = ProcessInfo.processInfo.hostName
        XCTAssertTrue(names.contains(full))
        if let short = full.split(separator: ".").first {
            XCTAssertTrue(names.contains(String(short)))
        }
    }
}
