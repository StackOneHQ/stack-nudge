import XCTest

@testable import StackNudgePanelCore

// orderedTabs is the only source of tab order — the strip, ⌘-number and ←/→ all
// read it, so a tab can't be drawn in one place and answer to another.
@MainActor
final class ExtensionTabTests: XCTestCase {

    private func nav(with tabs: [ExtensionTab]) -> PanelNav {
        let nav = PanelNav()
        nav.extensionTabs = tabs
        return nav
    }

    func testNoExtensionsLeavesTheBuiltInOrder() {
        XCTAssertEqual(nav(with: []).orderedTabs,
                       [.events, .sessions, .usage, .outcomes, .settings])
    }

    // Extensions sit before Settings, so Settings stays last wherever it lands.
    func testExtensionTabsSitBeforeSettings() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby"),
                           ExtensionTab(id: "radar", label: "Radar")])
        XCTAssertEqual(n.orderedTabs, [.events, .sessions, .usage, .outcomes,
                                       .extensionTab("derby"), .extensionTab("radar"), .settings])
        XCTAssertEqual(n.orderedTabs.last, .settings)
    }

    func testInstallOrderIsPreserved() {
        let n = nav(with: [ExtensionTab(id: "b", label: "B"), ExtensionTab(id: "a", label: "A")])
        XCTAssertEqual(n.orderedTabs[4], .extensionTab("b"))
        XCTAssertEqual(n.orderedTabs[5], .extensionTab("a"))
    }

    func testLookupByID() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby")])
        XCTAssertEqual(n.extensionTab(id: "derby")?.label, "Derby")
        XCTAssertNil(n.extensionTab(id: "absent"))
    }

    // MARK: - Dead tabs

    // Reconciliation is only ever about extension tabs; a built-in must survive
    // it even when no extensions are installed.
    func testBuiltInTabsAreNeverReconciledAway() {
        let n = nav(with: [])
        for mode in [PanelMode.usage, .settings, .outcomes] {
            n.mode = mode
            n.reconcileModeWithTabs()
            XCTAssertEqual(n.mode, mode)
        }
    }

    // MARK: - Numbering

    // The invariant the whole commit exists for: ⌘(i+1) selects orderedTabs[i].
    // Cross-checked against Hotkey.parse rather than the literals in tabDigits,
    // so a wrong keycode there fails here instead of silently doing nothing.
    func testTabDigitsAreTheKeycodesForOneThroughNine() {
        XCTAssertEqual(PanelController.tabDigits.count, PanelNav.maxNumberedTabs)
        for (index, code) in PanelController.tabDigits.enumerated() {
            guard let parsed = Hotkey.parse("cmd+\(index + 1)") else {
                return XCTFail("cmd+\(index + 1) didn't parse")
            }
            XCTAssertEqual(UInt32(code), parsed.keyCode,
                           "tabDigits[\(index)] is not the keycode for \(index + 1)")
        }
    }

    // Five built-ins plus four extensions exactly fills ⌘1…⌘9, and each digit
    // must land on the tab drawn in that position.
    func testEveryNumberedDigitSelectsTheTabDrawnThere() {
        let n = nav(with: (1...4).map { ExtensionTab(id: "e\($0)", label: "E\($0)") })
        XCTAssertEqual(n.orderedTabs.count, PanelNav.maxNumberedTabs)
        XCTAssertEqual(n.orderedTabs[4], .extensionTab("e1"))
        XCTAssertEqual(n.orderedTabs[8], .settings)
        for index in PanelController.tabDigits.indices {
            XCTAssertTrue(n.orderedTabs.indices.contains(index),
                          "digit \(index + 1) has no tab to select")
        }
    }

    // Past nine the strip still draws them; only ←/→ reach them, and Settings
    // is the one that loses its number.
    func testTabsBeyondNineAreOrderedButUnnumbered() {
        let n = nav(with: (1...8).map { ExtensionTab(id: "e\($0)", label: "E\($0)") })
        XCTAssertEqual(n.orderedTabs.count, 13)
        XCTAssertEqual(n.orderedTabs.last, .settings)
        XCTAssertGreaterThan(n.orderedTabs.count, PanelController.tabDigits.count)
    }

    // MARK: - Duplicate ids

    // Two tabs sharing an id are structurally equal: ForEach would drop a row,
    // firstIndex(of:) could never reach the second, and the lookup would return
    // the first one's label for both.
    func testDuplicateIDsCollapseToTheFirst() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby"),
                           ExtensionTab(id: "derby", label: "Impostor"),
                           ExtensionTab(id: "radar", label: "Radar")])
        XCTAssertEqual(n.orderedTabs,
                       [.events, .sessions, .usage, .outcomes,
                        .extensionTab("derby"), .extensionTab("radar"), .settings])
        XCTAssertEqual(n.extensionTab(id: "derby")?.label, "Derby")
    }

    // MARK: - Reconciliation is automatic

    // The reconcile used to exist but was never called from production — the
    // tests invoked it directly and passed while the behaviour was absent.
    func testRemovingTheOpenExtensionReconcilesWithoutAnExplicitCall() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby")])
        n.mode = .extensionTab("derby")
        n.extensionTabs = []
        XCTAssertEqual(n.mode, .events)
    }

    func testReplacingTheListKeepsAStillInstalledOpenTab() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby"),
                           ExtensionTab(id: "radar", label: "Radar")])
        n.mode = .extensionTab("derby")
        n.extensionTabs = [ExtensionTab(id: "derby", label: "Derby renamed")]
        XCTAssertEqual(n.mode, .extensionTab("derby"))
    }
}
