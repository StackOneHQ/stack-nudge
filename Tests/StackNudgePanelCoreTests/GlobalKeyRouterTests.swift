import AppKit
import XCTest

@testable import StackNudgePanelCore

// The global keys across a sequence of presses: what a held key does once the
// field or recording it ended has let go. Driven with real NSEvents, so the
// modifier masking and the repeat flag are the router's own. Raw virtual key
// codes, since the panel's KeyCode table is private: 53 Esc, 51 delete, 18 "1",
// 123 ←, 0 "a".
final class GlobalKeyRouterTests: XCTestCase {

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                     isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: isRepeat, keyCode: keyCode)!
    }

    private func field(_ text: String = "", composing: Bool = false) -> NSTextView {
        let view = NSTextView()
        view.string = text
        if composing {
            view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return view
    }

    // Recording takes ⌘Esc and ends. The rest of the held key then reads as
    // Esc outside a field, which used to hide the panel, with ⌘ still down or
    // let go first.
    func test_heldCommandEscapeAfterRecordingIsSwallowed() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertNil(router.route(key(53, .command), recording: true, fieldEditor: nil))
        XCTAssertEqual(router.route(key(53, .command, isRepeat: true), recording: false, fieldEditor: nil),
                       .swallowRepeat)
        XCTAssertEqual(router.route(key(53, isRepeat: true), recording: false, fieldEditor: nil),
                       .swallowRepeat)
    }

    func test_heldEscapeAfterCancellingAFieldIsSwallowed() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertEqual(router.route(key(53), recording: false, fieldEditor: field("abc")), .cancelField)
        XCTAssertEqual(router.route(key(53, isRepeat: true), recording: false, fieldEditor: nil),
                       .swallowRepeat)
    }

    func test_heldDeleteAfterCancellingAFieldIsSwallowed() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertEqual(router.route(key(51), recording: false, fieldEditor: field()), .cancelField)
        XCTAssertEqual(router.route(key(51, isRepeat: true), recording: false, fieldEditor: nil),
                       .swallowRepeat)
    }

    func test_aFreshPressAfterwardsActsNormally() {
        var router = PanelController.GlobalKeyRouter()
        _ = router.route(key(53), recording: false, fieldEditor: field())
        XCTAssertEqual(router.route(key(53), recording: false, fieldEditor: nil), .hide)
        XCTAssertNil(router.swallowingRepeatsOf)
    }

    func test_anotherHeldKeyStillWorks() {
        var router = PanelController.GlobalKeyRouter()
        _ = router.route(key(53), recording: false, fieldEditor: field())
        XCTAssertEqual(router.route(key(123, .command, isRepeat: true), recording: false, fieldEditor: nil),
                       .stepTab(-1))
    }

    // Holding ⌫ to clear a field stops at empty rather than cancelling it.
    func test_heldDeleteIntoAnEmptyFieldDoesNotCancel() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertNil(router.route(key(51, isRepeat: true), recording: false, fieldEditor: field()))
    }

    // A bare key during a recording isn't taken (a shortcut needs a modifier),
    // so there's nothing to swallow afterwards.
    func test_aBareKeyDuringARecordingArmsNothing() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertNil(router.route(key(0), recording: true, fieldEditor: nil))
        XCTAssertNil(router.swallowingRepeatsOf)
    }

    // Only a recording takes a combo. Outside one, a held ⌘1 has to keep
    // reaching the page.
    func test_aComboOutsideARecordingArmsNothing() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertNil(router.route(key(18, .command), recording: false, fieldEditor: nil))
        XCTAssertNil(router.swallowingRepeatsOf)
        XCTAssertNil(router.route(key(18, .command, isRepeat: true), recording: false, fieldEditor: nil))
    }

    // An input method composing text owns Esc and ⌫, and its held Esc isn't
    // swallowed afterwards either.
    func test_anInputMethodKeepsEscape() {
        var router = PanelController.GlobalKeyRouter()
        let composing = field("abc", composing: true)
        XCTAssertNil(router.route(key(53), recording: false, fieldEditor: composing))
        XCTAssertNil(router.swallowingRepeatsOf)
        XCTAssertNil(router.route(key(53, isRepeat: true), recording: false, fieldEditor: composing))
    }

    func test_tabsStillStepWhileComposing() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertEqual(router.route(key(123, .command), recording: false,
                                    fieldEditor: field("abc", composing: true)),
                       .stepTab(-1))
    }

    // Arrow keys arrive with .function and .numericPad set, and caps lock adds
    // its own flag. None of them is a modifier here.
    func test_deviceFlagsDoNotCountAsModifiers() {
        var router = PanelController.GlobalKeyRouter()
        XCTAssertEqual(router.route(key(123, [.command, .function, .numericPad]), recording: false,
                                    fieldEditor: nil),
                       .stepTab(-1))
        XCTAssertEqual(router.route(key(53, .capsLock), recording: false, fieldEditor: nil), .hide)
    }
}

// What the panel does when focus goes elsewhere.
final class ResignKeyOutcomeTests: XCTestCase {

    private func outcome(_ mode: PanelMode, compact: Bool = false, pinned: Bool = false,
                         expanded: Bool = false) -> PanelController.ResignKeyOutcome {
        PanelController.resignKeyOutcome(mode: mode, compactMode: compact, pinned: pinned,
                                         compactExpanded: expanded)
    }

    func test_thePanelHides() {
        XCTAssertEqual(outcome(.settings), .hide)
    }

    func test_aPinnedPanelStays() {
        XCTAssertEqual(outcome(.settings, pinned: true), .stay)
    }

    func test_theExpandedWidgetCollapsesUnlessPinned() {
        XCTAssertEqual(outcome(.settings, compact: true, expanded: true), .collapse)
        XCTAssertEqual(outcome(.settings, compact: true, pinned: true, expanded: true), .stay)
        XCTAssertEqual(outcome(.settings, compact: true), .stay)
    }

    // Every action on Permissions hands focus to a grant prompt or System
    // Settings, so it stays up, in the widget too.
    func test_permissionsAlwaysStays() {
        XCTAssertEqual(outcome(.permissions), .stay)
        XCTAssertEqual(outcome(.permissions, compact: true, expanded: true), .stay)
    }
}
