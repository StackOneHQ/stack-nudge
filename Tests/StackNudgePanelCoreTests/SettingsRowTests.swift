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

    // The reconciliation banner contributes one indexed row per button, so
    // ↑/↓ can reach both Set up and Not now. Only the row layout is asserted
    // here — wireAllUnwiredAgents / dismissAllUnwiredAgents write to agent
    // hook configs and ~/.stack-nudge, so exercising them would touch the
    // real home directory.
    func test_unwiredBanner_prependsBothButtonRows() {
        let nav = PanelNav()
        XCTAssertFalse(nav.settingsRows.contains(.wireAgents))
        XCTAssertFalse(nav.settingsRows.contains(.dismissAgents))

        nav.unwiredAgents = [.antigravity, .codex]
        XCTAssertEqual(nav.index(of: .wireAgents), 0)
        XCTAssertEqual(nav.index(of: .dismissAgents), 1)
    }

    func test_unwiredBanner_sitsAbovePermissionsAndUpdate() {
        let nav = PanelNav()
        nav.unwiredAgents = [.codex]
        nav.missingPermissions = [.accessibility]
        nav.updateAvailable = "1.2.3"
        XCTAssertEqual(nav.settingsRows.first, .wireAgents)
        XCTAssertEqual(nav.index(of: .dismissAgents), 1)
        XCTAssertEqual(nav.index(of: .permissions), 2)
        XCTAssertEqual(nav.index(of: .update), 3)
    }

    // Arrows must not act on either banner row — Set up rewrites hook configs
    // and Not now persists a dismissal, so both are Enter-only.
    func test_unwiredBanner_ignoresCycle() {
        let nav = PanelNav()
        nav.unwiredAgents = [.antigravity]
        nav.selectedSettingIndex = nav.index(of: .wireAgents)
        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertEqual(nav.unwiredAgents, [.antigravity])

        nav.selectedSettingIndex = nav.index(of: .dismissAgents)
        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertEqual(nav.unwiredAgents, [.antigravity])
        XCTAssertTrue(nav.dismissedAgents.isEmpty)
    }

    // The footer dims its Cycle hint from this, so it has to agree with
    // applyCycle's no-op branch row for row.
    func test_selectedRowRespondsToArrows_matchesCycleBehaviour() {
        let nav = PanelNav()
        // Both conditional rows present so index(of:) resolves them for real
        // rather than falling back to 0.
        nav.unwiredAgents = [.codex]
        nav.missingPermissions = [.accessibility]

        for row in [SettingsRow.wireAgents, .dismissAgents, .quit, .editPhrases,
                    .openConfig, .releaseNotes, .checkUpdates, .checkPermissions,
                    .uninstall, .disconnectGithub] {
            nav.selectedSettingIndex = nav.index(of: row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertFalse(nav.selectedRowRespondsToArrows, "\(row) should ignore arrows")
        }

        for row in [SettingsRow.banner, .muteDuration, .theme, .historyPerSession,
                    .permissions, .hotkey] {
            nav.selectedSettingIndex = nav.index(of: row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertTrue(nav.selectedRowRespondsToArrows, "\(row) should act on arrows")
        }
    }

    func test_indexRowRoundTrip() {
        let nav = PanelNav()
        for row in nav.settingsRows {
            nav.selectedSettingIndex = nav.index(of: row)
            XCTAssertEqual(nav.selectedRow, row)
        }
    }
}
