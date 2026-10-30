import AppKit
import SwiftUI
import XCTest

@testable import StackNudgePanelCore

// The keys that mean one thing on every page, text field or not. Raw virtual
// key codes, since the panel's KeyCode table is private: 53 Esc, 123 ←,
// 124 →, 43 comma, 51 delete, 0 "a".
final class GlobalKeyActionTests: XCTestCase {

    private func action(_ keyCode: UInt16,
                        _ modifiers: NSEvent.ModifierFlags = [],
                        recording: Bool = false,
                        inEmptyField: Bool? = nil,
                        isRepeat: Bool = false) -> PanelController.GlobalKeyAction? {
        PanelController.globalKeyAction(keyCode: keyCode, modifiers: modifiers,
                                        recording: recording, inEmptyField: inEmptyField,
                                        isRepeat: isRepeat)
    }

    // Holding ⌫ to clear a field stops at empty. A repeat that cancelled
    // would hand the rest of the held key to the page, and on Sessions the
    // page's ⌫ kills the selected agent.
    func test_heldDeleteDoesNotCancel() {
        XCTAssertNil(action(51, inEmptyField: true, isRepeat: true))
    }

    func test_escapeHidesOutsideAField() {
        XCTAssertEqual(action(53), .hide)
    }

    func test_escapeCancelsAField() {
        XCTAssertEqual(action(53, inEmptyField: false), .cancelField)
        XCTAssertEqual(action(53, inEmptyField: true), .cancelField)
    }

    // Recording a shortcut is editing one: Esc keeps the old shortcut and the
    // panel stays up.
    func test_escapeCancelsARecording() {
        XCTAssertEqual(action(53, recording: true), .cancelField)
    }

    // ⌥Esc and the like are combos a shortcut can be, so a recording gets them.
    func test_escapeWithAModifierIsLeftToARecording() {
        XCTAssertNil(action(53, .option, recording: true))
        XCTAssertNil(action(53, [.command, .shift], recording: true))
        XCTAssertEqual(action(53, .option), .hide)
    }

    // The footer's last hint says which of the two Esc will do.
    func test_footerNamesWhatEscapeDoes() {
        XCTAssertEqual(PageFooter<EmptyView>.escapeLabel(cancels: false), "Hide")
        XCTAssertEqual(PageFooter<EmptyView>.escapeLabel(cancels: true), "Cancel")
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

    // ⌘, is Settings from anywhere, a text field included. A recording may want
    // it as a combo, and a held key shouldn't reopen Settings over and over.
    func test_commandCommaOpensSettings() {
        XCTAssertEqual(action(43, .command), .openSettings)
        XCTAssertEqual(action(43, .command, inEmptyField: false), .openSettings)
        XCTAssertNil(action(43, .command, recording: true))
        XCTAssertNil(action(43, .command, isRepeat: true))
        XCTAssertNil(action(43))
        XCTAssertNil(action(43, [.command, .shift]))
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

    // A sub-page steps from the tab it belongs to.
    func test_commandArrowsStepFromASubPagesTab() {
        let tabs: [PanelMode] = [.events, .sessions, .settings]
        XCTAssertEqual(PanelController.stepTabTarget(from: .phrases, by: -1, in: tabs), .sessions)
        XCTAssertEqual(PanelController.stepTabTarget(from: .permissions, by: -1, in: tabs), .sessions)
        XCTAssertEqual(PanelController.stepTabTarget(from: .sessions, by: 1, in: tabs), .settings)
    }

    // At either end of the strip the key is used up and nothing moves.
    func test_commandArrowsStopAtTheEnds() {
        let tabs: [PanelMode] = [.events, .sessions, .settings]
        XCTAssertEqual(PanelController.stepTabTarget(from: .events, by: -1, in: tabs), .events)
        XCTAssertEqual(PanelController.stepTabTarget(from: .phrases, by: 1, in: tabs), .phrases)
    }

    // Setup and the update screens draw no strip.
    func test_commandArrowsHaveNowhereToGoFromATakeover() {
        let tabs: [PanelMode] = [.events, .sessions, .settings]
        XCTAssertNil(PanelController.stepTabTarget(from: .bootstrap, by: 1, in: tabs))
        XCTAssertNil(PanelController.stepTabTarget(from: .updating, by: -1, in: tabs))
    }

    private func canOpenSettings(_ mode: PanelMode,
                                 returningTo returnMode: PanelMode = .settings) -> Bool {
        PanelController.canOpenSettings(mode: mode, permissionsReturnMode: returnMode,
                                        orderedTabs: [.events, .sessions, .settings])
    }

    // From a tab or a Settings sub-page, ⌘, and the menu go straight to Settings.
    func test_settingsOpensFromATabOrSubPage() {
        XCTAssertTrue(canOpenSettings(.sessions))
        XCTAssertTrue(canOpenSettings(.phrases))
        XCTAssertTrue(canOpenSettings(.permissions))
    }

    // Leaving setup or an install in progress would strand it until a relaunch.
    func test_settingsStaysShutOnSetupAndUpdateScreens() {
        XCTAssertFalse(canOpenSettings(.bootstrap))
        XCTAssertFalse(canOpenSettings(.updating))
        XCTAssertFalse(canOpenSettings(.postUpdate))
        XCTAssertFalse(canOpenSettings(.permissions, returningTo: .bootstrap))
    }

    func test_ordinaryKeysPassThrough() {
        XCTAssertNil(action(0))
        XCTAssertNil(action(0, inEmptyField: true))
    }
}
