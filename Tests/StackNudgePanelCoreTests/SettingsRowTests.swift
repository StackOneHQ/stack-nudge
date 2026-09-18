import XCTest

@testable import StackNudgePanelCore

// settingsRows feeds both rendering and keyboard nav. It is now the attention
// rows plus the selected category's, so anything reaching for a row by identity
// selects that row's category first — index(of:) answers 0 for a row that isn't
// in the current list.
@MainActor
final class SettingsRowTests: XCTestCase {

    func test_defaultCategoryIsNotifications() {
        let nav = PanelNav()
        XCTAssertEqual(nav.settingsCategory, .notifications)
        XCTAssertEqual(nav.settingsRows.first, .banner)  // no attention rows pending
        XCTAssertEqual(nav.rowCount, nav.settingsRows.count)
    }

    func test_keepOpenWhenEmpty_followsPinPanel() {
        let nav = PanelNav()
        let rows = nav.rows(in: .panel)
        let pin = rows.firstIndex(of: .pinPanel)
        XCTAssertNotNil(pin)
        XCTAssertEqual(rows[pin! + 1], .keepOpenWhenEmpty)
    }

    func test_voiceCollapsesUntilCached() {
        let nav = PanelNav()
        nav.voiceModelCached = false
        XCTAssertTrue(nav.rows(in: .voice).contains(.downloadVoiceModel))
        XCTAssertFalse(nav.rows(in: .voice).contains(.voice))

        nav.voiceModelCached = true
        XCTAssertTrue(nav.rows(in: .voice).contains(.voice))
        XCTAssertTrue(nav.rows(in: .voice).contains(.voiceSpeed))
        XCTAssertFalse(nav.rows(in: .voice).contains(.downloadVoiceModel))
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

        func select(_ row: SettingsRow) {
            if let category = nav.category(containing: row) { nav.settingsCategory = category }
            nav.selectedSettingIndex = nav.index(of: row)
        }

        for row in [SettingsRow.wireAgents, .dismissAgents, .quit, .editPhrases,
                    .openConfig, .releaseNotes, .checkUpdates, .checkPermissions,
                    .uninstall, .disconnectGithub, .openRepo] {
            select(row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertFalse(nav.selectedRowRespondsToArrows, "\(row) should ignore arrows")
        }

        for row in [SettingsRow.banner, .muteDuration, .theme, .historyPerSession,
                    .permissions, .hotkey] {
            select(row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertTrue(nav.selectedRowRespondsToArrows, "\(row) should act on arrows")
        }
    }

    // Round-trips every row in every category, not just the one that happens
    // to be selected.
    func test_indexRowRoundTrip() {
        let nav = PanelNav()
        for category in SettingsCategory.allCases {
            nav.settingsCategory = category
            for row in nav.settingsRows {
                nav.selectedSettingIndex = nav.index(of: row)
                XCTAssertEqual(nav.selectedRow, row)
            }
        }
    }

    func test_snapToCorners_defaultsOn() {
        XCTAssertTrue(PanelNav().compactSnap)
    }

    func test_snapToCorners_sitsRightAfterWidget() {
        let rows = PanelNav().rows(in: .appearance)
        let widget = rows.firstIndex(of: .widget)
        XCTAssertNotNil(widget)
        XCTAssertEqual(rows[widget! + 1], .snapToCorners)
        XCTAssertEqual(rows[widget! + 2], .widgetCorner)
    }
}
