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

    // Removing an extension while its tab is open leaves mode on a tab that no
    // longer exists, which renders nothing at all.
    func testRemovingTheOpenExtensionFallsBackToEvents() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby")])
        n.mode = .extensionTab("derby")
        n.extensionTabs = []
        n.reconcileModeWithTabs()
        XCTAssertEqual(n.mode, .events)
    }

    func testRemovingAnotherExtensionLeavesTheOpenOneAlone() {
        let n = nav(with: [ExtensionTab(id: "derby", label: "Derby"),
                           ExtensionTab(id: "radar", label: "Radar")])
        n.mode = .extensionTab("derby")
        n.extensionTabs = [ExtensionTab(id: "derby", label: "Derby")]
        n.reconcileModeWithTabs()
        XCTAssertEqual(n.mode, .extensionTab("derby"))
    }

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

    func testEveryTabUpToNineIsReachableByNumber() {
        // Five built-ins plus four extensions exactly fills ⌘1…⌘9.
        let many = (1...4).map { ExtensionTab(id: "e\($0)", label: "E\($0)") }
        let n = nav(with: many)
        XCTAssertEqual(n.orderedTabs.count, 9)
        XCTAssertLessThanOrEqual(n.orderedTabs.count, PanelNav.maxNumberedTabs)
    }

    // Past nine the strip still renders them; only ←/→ can reach them.
    func testTabsBeyondNineStillOrderButExceedTheDigits() {
        let many = (1...8).map { ExtensionTab(id: "e\($0)", label: "E\($0)") }
        let n = nav(with: many)
        XCTAssertEqual(n.orderedTabs.count, 13)
        XCTAssertGreaterThan(n.orderedTabs.count, PanelNav.maxNumberedTabs)
        XCTAssertEqual(n.orderedTabs.last, .settings)
    }
}
