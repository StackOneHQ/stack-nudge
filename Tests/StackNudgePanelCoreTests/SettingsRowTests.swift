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

    // Only value rows pick; every other row acts on Space / Enter and ignores
    // the arrows.
    func test_selectedRowIsPicker_onlyForValueRows() {
        let nav = PanelNav()
        // Both conditional rows present so index(of:) resolves them for real
        // rather than falling back to 0.
        nav.unwiredAgents = [.codex]
        nav.missingPermissions = [.accessibility]

        func select(_ row: SettingsRow) {
            if let category = nav.category(containing: row) { nav.settingsCategory = category }
            nav.selectedSettingIndex = nav.index(of: row)
        }

        nav.installedExtensions = [
            ExtensionRow(id: "derby", name: "Derby", description: "",
                         installedVersion: "1.0.0", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
        ]

        for row in [SettingsRow.wireAgents, .dismissAgents, .quit, .editPhrases,
                    .openConfig, .releaseNotes, .checkUpdates, .checkPermissions,
                    .uninstall, .disconnectGithub, .openRepo, .browseExtensions,
                    .installedExtension("derby"), .permissions, .hotkey] {
            select(row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertFalse(nav.selectedRowIsPicker, "\(row) should ignore arrows")
        }

        // On/off rows flip on Space / Enter only.
        for row in [SettingsRow.banner, .voiceEnabled, .soundEnabled, .widget,
                    .quotaTracking, .githubLinks, .eventHistory, .pinPanel, .mute] {
            select(row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertFalse(nav.selectedRowIsPicker, "\(row) should ignore arrows")
        }

        for row in [SettingsRow.muteDuration, .theme, .historyPerSession, .agentDoneSound] {
            select(row)
            XCTAssertEqual(nav.selectedRow, row)
            XCTAssertTrue(nav.selectedRowIsPicker, "\(row) should pick")
        }
    }

    // Space starts a pick and Space again settles it. Arrows outside a pick
    // leave the value alone. Stepping the value itself writes the real config
    // file, so the tests stop short of it.
    func test_valueRow_arrowsDoNothingUntilSpaceStartsAPick() {
        let nav = PanelNav()
        nav.settingsCategory = .events
        nav.selectedSettingIndex = nav.index(of: .historyPerSession)
        let before = nav.eventsPerSession

        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertEqual(nav.eventsPerSession, before, "arrows must not step a value nobody picked")
        XCTAssertFalse(nav.pickingValue)

        nav.activate()
        XCTAssertTrue(nav.pickingValue)
        XCTAssertEqual(nav.eventsPerSession, before, "starting a pick doesn't step it")
        nav.activate()
        XCTAssertFalse(nav.pickingValue)
    }

    func test_movingOffTheRowSettlesAPick() {
        let nav = PanelNav()
        nav.settingsCategory = .events
        nav.settingsDetailFocused = true
        nav.selectedSettingIndex = nav.index(of: .historyPerSession)
        nav.activate()
        XCTAssertTrue(nav.pickingValue)

        nav.selectedSettingIndex = nav.index(of: .eventHistory)
        XCTAssertFalse(nav.pickingValue)

        nav.selectedSettingIndex = nav.index(of: .historyPerSession)
        nav.activate()
        nav.settingsDetailFocused = false
        XCTAssertFalse(nav.pickingValue, "backing out to the categories settles it too")

        nav.settingsDetailFocused = true
        nav.selectedSettingIndex = nav.index(of: .historyPerSession)
        nav.activate()
        nav.settingsCategory = .notifications
        XCTAssertFalse(nav.pickingValue, "so does switching category")
    }

    // Drives the arrows rather than reading the predicate, on the one on/off
    // row whose effect goes through SettingsActions instead of the real config
    // file. ←/→ used to mute here; only Space / Enter (activate) should.
    func test_muteRow_ignoresArrows_actsOnActivate() {
        let nav = PanelNav()
        var mutes: [Int] = []
        nav.actions = SettingsActions(
            checkPermissions: {}, openConfig: {}, editPhrases: {},
            browseExtensions: {}, openExtension: { _ in },
            openReleaseNotes: {}, checkForUpdates: {}, beginUpdate: {}, runUpdate: {},
            beginUninstall: {}, runUninstall: {}, runBootstrap: {}, quit: {},
            expandFromCompact: {}, exitCompactMode: {},
            muteFor: { mutes.append($0) }, resumeNotifications: {},
            applyEventHistorySetting: {}, clearEventHistory: {},
            pasteSlackSetup: {}, detectSlackUser: {}, sendSlackTest: {})
        nav.selectedSettingIndex = nav.index(of: .mute)
        XCTAssertEqual(nav.selectedRow, .mute)

        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertTrue(mutes.isEmpty, "arrows must not mute")

        nav.activate()
        XCTAssertEqual(mutes, [nav.muteDurationMinutes])
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
