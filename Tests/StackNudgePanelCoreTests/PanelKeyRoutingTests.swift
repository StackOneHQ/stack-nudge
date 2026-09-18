import XCTest

@testable import StackNudgePanelCore

// The key handler is a chain of per-mode blocks ending in the Events bindings,
// which map Return to approve. A block that fails to return on some path falls
// into them — so a keystroke elsewhere approves a pending permission prompt.
//
// Every block on main does return on every path, so the guard is unreachable
// today; it's there so the next tab can't reintroduce the shape. The Derby tab
// on feat/token-derby-tab is exactly that shape and does have the live bug.
//
// This asserts the policy over the whole domain — exactly one mode may own
// those bindings — rather than the implementation. It cannot exercise
// panelHandlesKey itself, which needs a live window; pinning the routing
// properly would mean extracting it into a value-returning function the way
// historyKeyAction already is.
final class PanelKeyRoutingTests: XCTestCase {

    // Listed rather than derived: PanelMode carries an associated value, so
    // CaseIterable isn't available. A case missing here is a mode nothing
    // checks, which is how extensionTab slipped through the first version.
    private let allModes: [PanelMode] = [
        .events, .sessions, .usage, .outcomes, .extensionTab("any"),
        .settings, .phrases, .extensions, .extensionConfig("any"),
        .updateConfirm, .updating, .postUpdate,
        .bootstrap, .uninstall,
    ]

    func testExactlyOneModeOwnsTheEventsKeyBindings() {
        let owners = allModes.filter { PanelController.eventsOwnsKeyboard($0) }
        XCTAssertEqual(owners.count, 1, "expected one owner, got \(owners)")
        XCTAssertEqual(owners.first, .events)
    }

    // The tab a user can add is the one most likely to be forgotten.
    func testExtensionTabsNeverOwnThem() {
        for id in ["derby", "", "events"] {
            XCTAssertFalse(PanelController.eventsOwnsKeyboard(.extensionTab(id)))
        }
    }

    // Both Settings sub-pages carry an id or sit off the tab strip, which is
    // how .extensionTab was missed from this list the first time round.
    func testTheExtensionSubPagesNeverOwnThemEither() {
        for id in ["derby", "", "events"] {
            XCTAssertFalse(PanelController.eventsOwnsKeyboard(.extensionConfig(id)))
        }
        XCTAssertFalse(PanelController.eventsOwnsKeyboard(.extensions))
    }
}

// Which tab the strip scrolls to keep in view. The strip is the one row in the
// panel whose width is decided by what the user installs, so it scrolls, and a
// scroll target that names something the strip never renders does nothing at all
// while looking like it works.
final class TabStripAnchorTests: XCTestCase {

    private let tabs: [PanelMode] = [
        .events, .sessions, .usage, .outcomes,
        .extensionTab("derby"), .extensionTab("system"), .settings,
    ]

    func testATabIsItsOwnAnchor() {
        for tab in tabs {
            XCTAssertEqual(PanelContentView.tabStripAnchor(for: tab, in: tabs), tab)
        }
    }

    // Settings' sub-pages draw the strip but are not in it, so the mode itself
    // is an id nothing renders. Its tab is what should stay on screen while you
    // are a level inside it.
    func testSettingsSubPagesAnchorOnTheSettingsTab() {
        for mode: PanelMode in [.phrases, .extensions, .extensionConfig("derby"),
                                .updateConfirm, .uninstall] {
            XCTAssertEqual(PanelContentView.tabStripAnchor(for: mode, in: tabs), .settings)
        }
    }

    // The full-screen takeovers draw no strip at all.
    func testTakeoverModesAnchorNowhere() {
        for mode: PanelMode in [.updating, .postUpdate, .bootstrap] {
            XCTAssertNil(PanelContentView.tabStripAnchor(for: mode, in: tabs))
        }
    }

    // An extension removed while its tab was open leaves the mode naming a tab
    // that is gone. Scrolling to it would be scrolling to nothing.
    func testATabThatIsNoLongerInTheStripAnchorsNowhere() {
        XCTAssertNil(PanelContentView.tabStripAnchor(for: .extensionTab("gone"), in: tabs))
    }
}
