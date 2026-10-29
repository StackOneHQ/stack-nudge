import AppKit
import XCTest

@testable import StackNudgePanelCore

// The guards that stop a stray ⌫ killing an agent or removing a phrase. Raw
// virtual key codes, since the panel's KeyCode table is private: 51 delete,
// 117 forward delete, 53 Esc, 15 "r", 0 "a".
final class DestructiveKeyTests: XCTestCase {

    private func destructive(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                             isRepeat: Bool = false) -> PanelController.DestructiveKeyAction? {
        PanelController.destructiveKeyAction(keyCode: keyCode, modifiers: modifiers,
                                             isRepeat: isRepeat)
    }

    func test_commandDeleteActs() {
        XCTAssertEqual(destructive(51, .command), .act)
        XCTAssertEqual(destructive(117, .command), .act)
    }

    // ⌫ also empties and cancels a text field, so one press too many must not
    // kill. R used to kill on Sessions too.
    func test_bareDeleteAndRDoNothing() {
        XCTAssertNil(destructive(51))
        XCTAssertNil(destructive(117))
        XCTAssertNil(destructive(15))
        XCTAssertNil(destructive(51, [.command, .shift]))
    }

    // The selection moves on after each kill, so a held key would take out
    // the next agent.
    func test_heldCommandDeleteActsOnce() {
        XCTAssertEqual(destructive(51, .command, isRepeat: true), .ignoreRepeat)
    }

    // After ⌫ or Esc cancels a field, the rest of that held key is eaten so it
    // can't reach the page (kill, hide) once the field lets go.
    func test_repeatsOfTheCancellingKeyAreSwallowed() {
        let gate = PanelController.repeatGate(keyCode: 51, isRepeat: true, armed: 51)
        XCTAssertTrue(gate.swallow)
        XCTAssertEqual(gate.armed, 51)
        XCTAssertTrue(PanelController.repeatGate(keyCode: 53, isRepeat: true, armed: 53).swallow)
    }

    func test_aFreshPressDisarms() {
        let gate = PanelController.repeatGate(keyCode: 51, isRepeat: false, armed: 51)
        XCTAssertFalse(gate.swallow)
        XCTAssertNil(gate.armed)
        XCTAssertNil(PanelController.repeatGate(keyCode: 0, isRepeat: false, armed: 51).armed)
    }

    func test_otherKeysPassWhileArmed() {
        let gate = PanelController.repeatGate(keyCode: 0, isRepeat: true, armed: 51)
        XCTAssertFalse(gate.swallow)
        XCTAssertEqual(gate.armed, 51)
        XCTAssertFalse(PanelController.repeatGate(keyCode: 51, isRepeat: true, armed: nil).swallow)
    }
}
