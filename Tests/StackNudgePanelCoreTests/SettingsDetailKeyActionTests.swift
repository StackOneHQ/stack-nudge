import AppKit
import XCTest

@testable import StackNudgePanelCore

// Settings' rows, once a category is open. Raw virtual key codes, since the
// panel's KeyCode table is private: 123 ←, 124 →, 126 ↑, 125 ↓, 48 tab,
// 36 return, 49 space.
final class SettingsDetailKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                        picking: Bool = false) -> PanelController.SettingsDetailKeyAction? {
        PanelController.settingsDetailKeyAction(keyCode: keyCode, modifiers: modifiers,
                                                picking: picking)
    }

    func test_leftGoesBackToTheCategories() {
        XCTAssertEqual(action(123), .back)
    }

    func test_leftAndRightStepAValueBeingPicked() {
        XCTAssertEqual(action(123, picking: true), .step(-1))
        XCTAssertEqual(action(124, picking: true), .step(1))
    }

    func test_spaceAndReturnActOnTheRow() {
        XCTAssertEqual(action(49), .activate)
        XCTAssertEqual(action(36), .activate)
        XCTAssertEqual(action(49, picking: true), .activate)
    }

    func test_upDownAndTabMoveTheRow() {
        XCTAssertEqual(action(126), .moveRow(-1))
        XCTAssertEqual(action(125), .moveRow(1))
        XCTAssertEqual(action(48), .moveRow(1))
        XCTAssertEqual(action(48, .shift), .moveRow(-1))
    }

    // ⇧← used to step a value back; picking replaced it.
    func test_shiftLeftDoesNothing() {
        XCTAssertNil(action(123, .shift))
    }

    func test_commandCombosPassThrough() {
        XCTAssertNil(action(123, .command))
        XCTAssertNil(action(49, .command))
    }
}
