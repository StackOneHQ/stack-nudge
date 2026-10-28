import AppKit
import XCTest

@testable import StackNudgePanelCore

// The Permissions page's keys. Raw virtual key codes, since the panel's KeyCode
// table is private: 123 ←, 126 ↑, 125 ↓, 36 return, 76 keypad enter, 15 "r",
// 49 space, 1 "s".
final class PermissionsKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        _ modifiers: NSEvent.ModifierFlags = []) -> PanelController.PermissionsKeyAction? {
        PanelController.permissionsKeyAction(keyCode: keyCode, modifiers: modifiers)
    }

    func test_leftGoesBack() {
        XCTAssertEqual(action(123), .back)
    }

    func test_arrowsMoveTheSelection() {
        XCTAssertEqual(action(126), .moveSelection(-1))
        XCTAssertEqual(action(125), .moveSelection(1))
    }

    func test_enterPromptsAndCommandEnterOpensSystemSettings() {
        XCTAssertEqual(action(36), .prompt)
        XCTAssertEqual(action(76), .prompt)
        XCTAssertEqual(action(36, .command), .openInSettings)
        XCTAssertEqual(action(76, .command), .openInSettings)
    }

    func test_commandRRefreshes() {
        XCTAssertEqual(action(15, .command), .refresh)
    }

    // A stray key must not fall through to Events, where ⏎ approves a prompt.
    func test_otherPlainKeysAreSwallowed() {
        XCTAssertEqual(action(49), .swallow)
        XCTAssertEqual(action(15), .swallow)
        XCTAssertEqual(action(124), .swallow)
        XCTAssertEqual(action(36, .shift), .swallow)
    }

    // ⌘1-9, ⌘↑↓ and the app's own combos are handled elsewhere.
    func test_otherCommandCombosPassThrough() {
        XCTAssertNil(action(1, .command))
        XCTAssertNil(action(126, .command))
    }
}
