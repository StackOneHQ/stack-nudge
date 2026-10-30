import XCTest

@testable import StackNudgePanelCore

final class CompanionMenuOptionTests: XCTestCase {

    func testDebugIsHiddenUnlessOptionIsHeld() {
        XCTAssertTrue(CompanionMenu.isDebugHidden(optionHeld: false))
        XCTAssertFalse(CompanionMenu.isDebugHidden(optionHeld: true))
    }

    @MainActor
    func testApplyOptionTogglesOnlyTheTaggedItem() {
        let menu = NSMenu()
        let other = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
        let debug = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debug.tag = CompanionMenu.optionOnlyTag
        menu.addItem(other)
        menu.addItem(debug)
        let entries = CompanionMenu(nav: PanelNav())
        entries.applyOption(true, to: menu)
        XCTAssertFalse(debug.isHidden)
        entries.applyOption(false, to: menu)
        XCTAssertTrue(debug.isHidden)
        XCTAssertFalse(other.isHidden)
    }
}
