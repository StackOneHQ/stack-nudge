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

    // MARK: - Footer hints

    private func document(_ json: String) -> ExtensionDocument {
        guard case .success(let d) = ExtensionDocument.parse(Data(json.utf8)) else {
            fatalError("fixture didn't parse")
        }
        return d
    }

    // The footer's hints are now buttons, so what it renders has to be exactly
    // what the keyboard can reach — otherwise a click does something no key
    // can, and a key cap beside it is a lie.
    func testAShadowedDocumentActionIsNotOffered() {
        let d = document("""
            {"schema":1,
             "rows":[{"id":"h1","title":"A","actions":[{"id":"open","label":"Open","key":"o"}]}],
             "actions":[{"id":"help","label":"Help","key":"o"},
                        {"id":"refresh","label":"Sync","key":"r"}]}
            """)
        let hints = ExtensionTabView.hintedActions(in: d, selectedRow: "h1")
        // "o" belongs to the row action while that row is selected, exactly as
        // ExtensionHost.resolve decides it.
        XCTAssertEqual(hints.map(\.id), ["open", "refresh"])
        XCTAssertEqual(ExtensionHost.resolve(key: "o", in: d, selectedRow: "h1")?.action, "open")
    }

    // With nothing selected the row action is unreachable, so the document
    // action stops being shadowed and comes back.
    func testTheDocumentActionReturnsWhenNoRowIsSelected() {
        let d = document("""
            {"schema":1,
             "rows":[{"id":"h1","title":"A","actions":[{"id":"open","label":"Open","key":"o"}]}],
             "actions":[{"id":"help","label":"Help","key":"o"}]}
            """)
        XCTAssertEqual(ExtensionTabView.hintedActions(in: d, selectedRow: nil).map(\.id), ["help"])
        XCTAssertEqual(ExtensionHost.resolve(key: "o", in: d, selectedRow: nil)?.action, "help")
    }

    // Every hint the footer draws must resolve to something, or the button is
    // an affordance for nothing.
    func testEveryHintResolvesToAnAction() {
        let d = document("""
            {"schema":1,
             "rows":[{"id":"h1","title":"A","actions":[{"id":"open","label":"Open","key":"o"}]}],
             "actions":[{"id":"refresh","label":"Sync","key":"r"},
                        {"id":"quiet","label":"No key","key":"!"}]}
            """)
        for selected in [nil, "h1"] {
            for hint in ExtensionTabView.hintedActions(in: d, selectedRow: selected) {
                XCTAssertNotNil(hint.key, "a keyless action must not be offered")
                XCTAssertNotNil(ExtensionHost.resolve(key: hint.key ?? "", in: d,
                                                      selectedRow: selected),
                                "\(hint.id) is drawn but unreachable")
            }
        }
    }

    // A refused key means no binding, so there is nothing to advertise.
    func testAnActionWhoseKeyWasRefusedIsNotOffered() {
        let d = document("""
            {"schema":1,"rows":[],
             "actions":[{"id":"nope","label":"Nope","key":"cmd+r"},
                        {"id":"fine","label":"Fine","key":"r"}]}
            """)
        XCTAssertEqual(ExtensionTabView.hintedActions(in: d, selectedRow: nil).map(\.id), ["fine"])
    }
}
