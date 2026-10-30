import AppKit
import XCTest

@testable import StackNudgePanelCore

// O resumes and T starts a session on the Sessions page. Raw virtual key
// codes, since the panel's KeyCode table is private: 31 "o", 17 "t", 45 "n",
// 46 "m".
final class SessionLaunchKeyTests: XCTestCase {

    private func event(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                       isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: isRepeat, keyCode: keyCode)!
    }

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                        isRepeat: Bool = false) -> PanelController.SessionLaunchKeyAction? {
        PanelController.sessionLaunchKeyAction(for: event(keyCode, modifiers, isRepeat: isRepeat))
    }

    func test_oResumesAndTStartsANewSession() {
        XCTAssertEqual(action(31), .resume)
        XCTAssertEqual(action(17), .newSession)
    }

    // Caps lock adds its own flag and must not stop the key working.
    func test_deviceFlagsDoNotCount() {
        XCTAssertEqual(action(31, .capsLock), .resume)
        XCTAssertEqual(action(17, .capsLock), .newSession)
    }

    // ⌘T and friends belong to the app; a modified key is never a launch.
    func test_modifiedKeysPassThrough() {
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            XCTAssertNil(action(31, modifiers))
            XCTAssertNil(action(17, modifiers))
        }
    }

    // Each press reads transcripts and opens a menu, so a held key must not
    // queue one per repeat.
    func test_aHeldKeyActsOnce() {
        XCTAssertEqual(action(31, isRepeat: true), .ignoreRepeat)
        XCTAssertEqual(action(17, isRepeat: true), .ignoreRepeat)
    }

    // N rename and M mute keep their own handling.
    func test_otherSessionKeysAreLeftAlone() {
        XCTAssertNil(action(45))
        XCTAssertNil(action(46))
    }
}
