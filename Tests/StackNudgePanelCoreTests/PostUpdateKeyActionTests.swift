import AppKit
import XCTest

@testable import StackNudgePanelCore

// The post-update screen's keys. Raw virtual key codes, since the panel's
// KeyCode table is private: 48 tab, 36 return, 76 keypad enter, 123 ←, 53 esc.
final class PostUpdateKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                        focus: PostUpdateFocus = .gotIt,
                        offer: Bool = true) -> PanelController.PostUpdateKeyAction {
        PanelController.postUpdateKeyAction(keyCode: keyCode, modifiers: modifiers,
                                            focus: focus, offerShowing: offer)
    }

    func test_tabMovesFocusToTurnOnAndBack() {
        XCTAssertEqual(action(48, focus: .gotIt), .moveFocus(.turnOn))
        XCTAssertEqual(action(48, focus: .turnOn), .moveFocus(.gotIt))
    }

    func test_shiftTabMovesFocusTheOtherWay() {
        XCTAssertEqual(action(48, .shift, focus: .gotIt), .moveFocus(.turnOn))
        XCTAssertEqual(action(48, .shift, focus: .turnOn), .moveFocus(.gotIt))
    }

    func test_enterPressesTheFocusedButton() {
        XCTAssertEqual(action(36, focus: .gotIt), .dismiss)
        XCTAssertEqual(action(76, focus: .gotIt), .dismiss)
        XCTAssertEqual(action(36, focus: .turnOn), .turnOn)
        XCTAssertEqual(action(76, focus: .turnOn), .turnOn)
    }

    func test_withoutTheCardTabDoesNothingAndEnterDismisses() {
        XCTAssertEqual(action(48, offer: false), .swallow)
        XCTAssertEqual(action(48, .shift, offer: false), .swallow)
        XCTAssertEqual(action(36, focus: .turnOn, offer: false), .dismiss)
    }

    func test_otherKeysAreSwallowed() {
        XCTAssertEqual(action(123), .swallow)
        XCTAssertEqual(action(53), .swallow)
        XCTAssertEqual(action(36, .command), .swallow)
    }

    func test_focusOtherFlips() {
        XCTAssertEqual(PostUpdateFocus.gotIt.other, .turnOn)
        XCTAssertEqual(PostUpdateFocus.turnOn.other, .gotIt)
    }
}
