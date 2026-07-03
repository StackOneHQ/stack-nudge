import XCTest

@testable import StackNudgePanelCore

// The Settings list is now data-driven: one ordered `settingsRows` array feeds
// both rendering and keyboard nav. These pin the order, the conditional rows
// (update prepend, voice collapse), and the index ⇄ row round-trip the view and
// dispatch both rely on.
@MainActor
final class SettingsRowTests: XCTestCase {

    func test_defaultOrder() {
        let nav = PanelNav()
        let rows = nav.settingsRows
        XCTAssertEqual(rows.first, .hotkey)            // no update pending
        XCTAssertEqual(rows.last, .quit)
        XCTAssertEqual(nav.rowCount, rows.count)
    }

    func test_selectFirstRow_andLastRow_jumpToEnds() {
        let nav = PanelNav()
        nav.selectLastRow()
        XCTAssertEqual(nav.selectedSettingIndex, nav.rowCount - 1)
        nav.selectFirstRow()
        XCTAssertEqual(nav.selectedSettingIndex, 0)
    }

    func test_keepOpenWhenEmpty_followsPinPanel() {
        let nav = PanelNav()
        let rows = nav.settingsRows
        let pin = rows.firstIndex(of: .pinPanel)
        XCTAssertNotNil(pin)
        XCTAssertEqual(rows[pin! + 1], .keepOpenWhenEmpty)
    }

    func test_voiceCollapsesUntilCached() {
        let nav = PanelNav()
        nav.voiceModelCached = false
        XCTAssertTrue(nav.settingsRows.contains(.downloadVoiceModel))
        XCTAssertFalse(nav.settingsRows.contains(.voice))

        nav.voiceModelCached = true
        XCTAssertTrue(nav.settingsRows.contains(.voice))
        XCTAssertTrue(nav.settingsRows.contains(.voiceSpeed))
        XCTAssertFalse(nav.settingsRows.contains(.downloadVoiceModel))
    }

    func test_updateRow_prependedWhenAvailable() {
        let nav = PanelNav()
        XCTAssertFalse(nav.settingsRows.contains(.update))
        nav.updateAvailable = "1.2.3"
        XCTAssertEqual(nav.settingsRows.first, .update)
        XCTAssertEqual(nav.index(of: .update), 0)
    }

    func test_permissionsRow_prependedWhenMissing() {
        let nav = PanelNav()
        XCTAssertFalse(nav.settingsRows.contains(.permissions))
        nav.missingPermissions = [.accessibility]
        XCTAssertEqual(nav.settingsRows.first, .permissions)
        XCTAssertEqual(nav.index(of: .permissions), 0)
    }

    func test_permissionsRow_sitsAboveUpdate_whenBothPresent() {
        let nav = PanelNav()
        nav.missingPermissions = [.notifications]
        nav.updateAvailable = "1.2.3"
        XCTAssertEqual(nav.settingsRows.first, .permissions)
        XCTAssertEqual(nav.index(of: .permissions), 0)
        XCTAssertEqual(nav.index(of: .update), 1)
    }

    func test_indexRowRoundTrip() {
        let nav = PanelNav()
        for row in nav.settingsRows {
            nav.selectedSettingIndex = nav.index(of: row)
            XCTAssertEqual(nav.selectedRow, row)
        }
    }
}
