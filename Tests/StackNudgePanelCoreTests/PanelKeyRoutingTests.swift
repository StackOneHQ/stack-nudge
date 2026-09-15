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
        .settings, .phrases, .updateConfirm, .updating, .postUpdate,
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
}
