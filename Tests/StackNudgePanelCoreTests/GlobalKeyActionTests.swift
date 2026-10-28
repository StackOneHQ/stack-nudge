import AppKit
import XCTest

@testable import StackNudgePanelCore

// The keys that mean one thing on every page, text field or not. Raw virtual
// key codes, since the panel's KeyCode table is private: 53 Esc, 123 ←,
// 124 →, 51 delete, 0 "a".
final class GlobalKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        _ modifiers: NSEvent.ModifierFlags = [],
                        recording: Bool = false,
                        inEmptyField: Bool? = nil) -> PanelController.GlobalKeyAction? {
        PanelController.globalKeyAction(keyCode: keyCode, modifiers: modifiers,
                                        recording: recording, inEmptyField: inEmptyField)
    }

    func test_escapeHidesOutsideAField() {
        XCTAssertEqual(action(53), .hide)
        XCTAssertEqual(action(53, recording: true), .hide)
    }

    func test_escapeCancelsAField() {
        XCTAssertEqual(action(53, inEmptyField: false), .cancelField)
        XCTAssertEqual(action(53, inEmptyField: true), .cancelField)
    }

    func test_commandArrowsStepTheTabsEvenFromAField() {
        XCTAssertEqual(action(123, .command), .stepTab(-1))
        XCTAssertEqual(action(124, .command), .stepTab(1))
        XCTAssertEqual(action(123, .command, inEmptyField: false), .stepTab(-1))
    }

    // Recording takes the next combo, and ⌘← is a combo someone may want.
    func test_commandArrowsAreLeftToHotkeyRecording() {
        XCTAssertNil(action(123, .command, recording: true))
        XCTAssertNil(action(124, .command, recording: true))
    }

    // Plain arrows belong to the page, and ⇧⌘← to the field editor.
    func test_otherArrowsAreLeftToThePage() {
        XCTAssertNil(action(123))
        XCTAssertNil(action(124))
        XCTAssertNil(action(123, [.command, .shift]))
    }

    // ⌫ in a field that's already empty; anywhere else it's the page's or the
    // field's own key.
    func test_deleteCancelsOnlyAnEmptyField() {
        XCTAssertEqual(action(51, inEmptyField: true), .cancelField)
        XCTAssertNil(action(51, inEmptyField: false))
        XCTAssertNil(action(51))
        XCTAssertNil(action(51, .command, inEmptyField: true))
    }

    func test_ordinaryKeysPassThrough() {
        XCTAssertNil(action(0))
        XCTAssertNil(action(0, inEmptyField: true))
    }
}
