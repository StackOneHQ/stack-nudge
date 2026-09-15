import XCTest

@testable import StackNudgePanelCore

// The key handler is a chain of per-mode blocks ending in the Events bindings,
// which map Return to approve. A mode that declined a key fell through into
// them, so a keystroke elsewhere could approve a pending permission prompt.
final class PanelKeyRoutingTests: XCTestCase {

    func testOnlyEventsOwnsTheEventsKeyBindings() {
        XCTAssertTrue(PanelController.eventsOwnsKeyboard(.events))

        // Listed, not derived: PanelMode gains an associated value with
        // extension tabs, so CaseIterable won't be available.
        let others: [PanelMode] = [
            .sessions, .usage, .outcomes, .settings, .phrases,
            .updateConfirm, .updating, .postUpdate, .bootstrap, .uninstall,
        ]
        for mode in others {
            XCTAssertFalse(PanelController.eventsOwnsKeyboard(mode),
                           "\(mode) must not inherit the Events key bindings")
        }
    }
}
