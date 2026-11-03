import AppKit
import XCTest

@testable import StackNudgePanelCore

// What a key does on an extension's tab. Raw virtual key codes, since the
// panel's KeyCode table is private: 36 return, 76 numpad enter, 126 up,
// 125 down, 15 "r", 0 "a", 122 F1.
final class ExtensionTabKeyTests: XCTestCase {

    private func action(_ keyCode: UInt16, _ characters: String? = nil,
                        _ modifiers: NSEvent.ModifierFlags = [],
                        isRepeat: Bool = false) -> PanelController.ExtensionTabKeyAction {
        PanelController.extensionTabKeyAction(keyCode: keyCode, characters: characters,
                                              modifiers: modifiers, isRepeat: isRepeat)
    }

    func test_returnRunsTheRowsReturnBinding() {
        XCTAssertEqual(action(36, "\r"), .run("return"))
        XCTAssertEqual(action(76, "\u{3}"), .run("return"))
    }

    // Documents bind single characters, and the binding is matched lowercase.
    func test_aPlainCharacterIsOfferedToTheDocument() {
        XCTAssertEqual(action(15, "r"), .run("r"))
        XCTAssertEqual(action(15, "R"), .run("r"))
    }

    // Every binding spawns the extension. Holding ⏎ on a row that opens a
    // link used to open it once per autorepeat.
    func test_heldKeysThatStartWorkAreSwallowed() {
        XCTAssertEqual(action(36, "\r", isRepeat: true), .swallow)
        XCTAssertEqual(action(15, "r", isRepeat: true), .swallow)
    }

    // The arrows only move the selection, so they keep their repeat.
    func test_arrowsMoveTheSelectionAndRepeat() {
        XCTAssertEqual(action(126), .move(-1))
        XCTAssertEqual(action(125, isRepeat: true), .move(1))
    }

    // ⌘R comes before the plain-key check that turns modifiers away. Held, it
    // isn't a refresh, and the combination is left to the app.
    func test_commandRRefreshesOnceAndOnlyOnce() {
        XCTAssertEqual(action(15, "r", .command), .forceRefresh)
        XCTAssertEqual(action(15, "r", .command, isRepeat: true), .passThrough)
    }

    // Each page returns false on a combination it doesn't own, so ⌘Q and
    // friends keep working.
    func test_otherModifierCombinationsAreLeftToTheApp() {
        XCTAssertEqual(action(15, "r", [.command, .shift]), .passThrough)
        XCTAssertEqual(action(0, "a", .option), .passThrough)
        XCTAssertEqual(action(36, "\r", .command), .passThrough)
    }

    // An unbound key is still the tab's: it must never fall through to another
    // page's branch, where ⏎ approves a permission prompt.
    func test_aKeyWithNoCharacterIsSwallowed() {
        XCTAssertEqual(action(122, ""), .swallow)
        XCTAssertEqual(action(122, nil), .swallow)
    }

    private func event(_ keyCode: UInt16, _ characters: String,
                       _ modifiers: NSEvent.ModifierFlags = [],
                       isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: keyCode)!
    }

    // What the tab calls. A call site that forgot the repeat flag or left the
    // arrows' device flags in would get this wrong in a way the table above
    // can't see.
    func test_theEventFormReadsTheRepeat() {
        XCTAssertEqual(PanelController.extensionTabKeyAction(for: event(36, "\r")), .run("return"))
        XCTAssertEqual(PanelController.extensionTabKeyAction(for: event(36, "\r", isRepeat: true)),
                       .swallow)
    }

    func test_theEventFormMasksDeviceFlags() {
        XCTAssertEqual(PanelController.extensionTabKeyAction(
            for: event(125, "\u{F701}", [.function, .numericPad])), .move(1))
        XCTAssertEqual(PanelController.extensionTabKeyAction(for: event(15, "r", .capsLock)),
                       .run("r"))
    }
}
