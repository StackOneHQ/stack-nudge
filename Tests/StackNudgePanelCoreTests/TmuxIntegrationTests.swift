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
}
