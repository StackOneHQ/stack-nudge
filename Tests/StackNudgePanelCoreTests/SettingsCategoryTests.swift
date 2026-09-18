import XCTest

@testable import StackNudgePanelCore

// Settings was one 51-row list whose sections named control types rather than
// subjects: "Toggles" held ten rows spanning notifications, panel behaviour and
// session naming, while "Hotkey" was a category of one.
@MainActor
final class SettingsCategoryTests: XCTestCase {

    // Every row that used to be reachable still is. A row left out of every
    // category would vanish from the UI with nothing to catch it.
    func testEveryCategoryRowIsReachableAndUnique() {
        let nav = PanelNav()
        var seen: [SettingsRow] = []
        for category in SettingsCategory.allCases {
            seen += nav.rows(in: category)
        }
        XCTAssertEqual(Set(seen).count, seen.count, "a row appears in two categories")
        // The rows that only exist conditionally live outside the categories.
        for row in [SettingsRow.banner, .voiceEnabled, .widget, .quotaTracking,
                    .slackEnabled, .hotkey, .eventHistory, .quit] {
            XCTAssertTrue(seen.contains(row), "\(row) is in no category")
        }
    }

    // The regrouping moved all 51 rows by hand. A row left out of every category
    // would simply disappear from Settings, with nothing else to catch it.
    func testEverySettingsRowHasAHome() {
        let nav = PanelNav()
        // Attention rows are conditional, so name them rather than reading a
        // state where they happen to be absent.
        var covered: Set<SettingsRow> = [.wireAgents, .dismissAgents, .permissions, .update]
        // The Extensions category lists one row per installed extension, so the
        // representative that SettingsRow.allCases carries needs an extension
        // to be a row for. Seeding it here rather than excusing the case is the
        // whole point: allCases includes it precisely so this guard covers the
        // one row `activate()` can forget silently.
        nav.installedExtensions = [
            ExtensionRow(id: SettingsRow.representativeExtensionID, name: "Derby",
                         description: "", installedVersion: "1.0.0", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
        ]
        // The voice category swaps rows on whether the model is cached; both
        // branches are reachable, so both count as homes.
        for cached in [true, false] {
            nav.voiceModelCached = cached
            for category in SettingsCategory.allCases {
                covered.formUnion(nav.rows(in: category))
            }
        }
        let orphaned = Set(SettingsRow.allCases).subtracting(covered)
        XCTAssertTrue(orphaned.isEmpty, "rows with no category: \(orphaned)")
    }

    // The category grows and shrinks with what is installed, and the browse row
    // is always last so the list reads as "what you have, then how to get more".
    func testTheExtensionsCategoryListsWhatIsInstalled() {
        let nav = PanelNav()
        XCTAssertEqual(nav.rows(in: .extensions), [.browseExtensions])

        nav.installedExtensions = [
            ExtensionRow(id: "derby", name: "Derby", description: "",
                         installedVersion: "1.0.0", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
            ExtensionRow(id: "system", name: "System", description: "",
                         installedVersion: "1.1.1", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
        ]
        XCTAssertEqual(nav.rows(in: .extensions),
                       [.installedExtension("derby"), .installedExtension("system"),
                        .browseExtensions])
    }

    // A refusal is an installed thing that is broken, so it belongs with the
    // installed ones. Splitting it away from them is what produced an orange
    // "Remove" sitting directly above a card offering "Install".
    func testARefusedExtensionIsListedHereToo() {
        let nav = PanelNav()
        nav.installedExtensions = [
            ExtensionRow(id: "broken", name: "broken", description: "",
                         installedVersion: nil, availableVersion: nil,
                         refusedReason: "needs manifest schema 2", requires: [], config: []),
        ]
        XCTAssertEqual(nav.rows(in: .extensions),
                       [.installedExtension("broken"), .browseExtensions])
    }

    // Enter on an extension card opens it. activate()'s switch ends in
    // `default: applyCycle`, so omitting the case is not a build error — it is
    // Enter quietly doing nothing on the one row whose purpose is being opened.
    func testEnterOnAnExtensionCardOpensIt() {
        let nav = PanelNav()
        var opened: [String] = []
        nav.actions = Self.actions(openExtension: { opened.append($0) })
        nav.installedExtensions = [
            ExtensionRow(id: "derby", name: "Derby", description: "",
                         installedVersion: "1.0.0", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
        ]
        nav.settingsCategory = .extensions
        nav.selectedSettingIndex = nav.index(of: .installedExtension("derby")) ?? 0
        nav.activate()
        XCTAssertEqual(opened, ["derby"])
    }

    // Arrows must not act on it — the card is an action row, and ←/→ grazing it
    // should do nothing rather than half-open something.
    func testArrowsDoNothingOnAnExtensionCard() {
        let nav = PanelNav()
        nav.installedExtensions = [
            ExtensionRow(id: "derby", name: "Derby", description: "",
                         installedVersion: "1.0.0", availableVersion: nil,
                         refusedReason: nil, requires: [], config: []),
        ]
        nav.settingsCategory = .extensions
        nav.selectedSettingIndex = nav.index(of: .installedExtension("derby")) ?? 0
        XCTAssertFalse(nav.selectedRowRespondsToArrows)
    }

    // SettingsActions has one closure per wired effect and a memberwise init,
    // so a stub has to name all of them — which is the point: adding an action
    // fails to compile here rather than silently going unexercised.
    private static func actions(
        openExtension: @escaping (String) -> Void = { _ in }
    ) -> SettingsActions {
        SettingsActions(
            checkPermissions: {}, openConfig: {}, editPhrases: {},
            browseExtensions: {}, openExtension: openExtension,
            openReleaseNotes: {}, checkForUpdates: {}, beginUpdate: {}, runUpdate: {},
            beginUninstall: {}, runUninstall: {}, runBootstrap: {}, quit: {},
            expandFromCompact: {}, exitCompactMode: {},
            muteFor: { _ in }, resumeNotifications: {},
            applyEventHistorySetting: {}, clearEventHistory: {},
            pasteSlackSetup: {}, detectSlackUser: {}, sendSlackTest: {})
    }

    // Removing an extension left selectedSettingIndex pointing at the same
    // *number* in a shorter list, so the ring moved onto the card below the one
    // just deleted — and ⏎ then opened an extension nobody chose, with its
    // Remove button under the cursor that had just clicked Remove.
    func testRemovingAnExtensionAboveTheSelectionKeepsTheSelectedOne() {
        let nav = PanelNav()
        nav.installedExtensions = [row("a"), row("b"), row("c")]
        nav.settingsCategory = .extensions
        nav.selectedSettingIndex = nav.index(of: .installedExtension("b")) ?? 0
        XCTAssertEqual(nav.selectedRow, .installedExtension("b"))

        // "b" moves from index 1 to index 0. An index that stayed put would now
        // be pointing at "c" — a card the user never selected, whose Remove
        // button sits exactly where the last one did.
        nav.installedExtensions = [row("b"), row("c")]
        XCTAssertEqual(nav.selectedRow, .installedExtension("b"))
        XCTAssertEqual(nav.selectedSettingIndex, nav.index(of: .installedExtension("b")))
    }

    // The row it was on is gone, so it falls back to the first row of the
    // category rather than to whatever inherited the index.
    func testRemovingTheSelectedExtensionFallsBackToTheFirstRow() {
        let nav = PanelNav()
        nav.installedExtensions = [row("a"), row("b")]
        nav.settingsCategory = .extensions
        nav.selectedSettingIndex = nav.index(of: .installedExtension("b")) ?? 0

        nav.installedExtensions = [row("a")]
        XCTAssertEqual(nav.selectedRow, .installedExtension("a"))
    }

    // A change that doesn't reshape the list must not move the selection —
    // re-anchoring on every publish would fight the user's own arrow keys.
    func testAnUnchangedExtensionListLeavesTheSelectionAlone() {
        let nav = PanelNav()
        nav.installedExtensions = [row("a"), row("b")]
        nav.settingsCategory = .extensions
        nav.selectedSettingIndex = nav.index(of: .browseExtensions) ?? 0
        let before = nav.selectedSettingIndex

        nav.installedExtensions = [row("a"), row("b")]
        XCTAssertEqual(nav.selectedSettingIndex, before)
        XCTAssertEqual(nav.selectedRow, .browseExtensions)
    }

    private func row(_ id: String) -> ExtensionRow {
        ExtensionRow(id: id, name: id, description: "", installedVersion: "1.0.0",
                     availableVersion: nil, refusedReason: nil, requires: [], config: [])
    }

    func testAttentionRowsAreAbsentUntilTheyApply() {
        let nav = PanelNav()
        XCTAssertTrue(nav.settingsAttentionRows.isEmpty)
        nav.updateAvailable = "1.35.0"
        XCTAssertEqual(nav.settingsAttentionRows, [.update])
    }

    // They repeat across categories on purpose: they render pinned above the
    // split, so they must stay reachable whichever category is selected.
    func testAttentionRowsIndexFirstInEveryCategory() {
        let nav = PanelNav()
        nav.updateAvailable = "1.35.0"
        for category in SettingsCategory.allCases {
            nav.settingsCategory = category
            XCTAssertEqual(nav.settingsRows.first, .update, "\(category) buried the update row")
        }
    }

    func testSelectedCategoryDrivesTheNavigableRows() {
        let nav = PanelNav()
        nav.settingsCategory = .actions
        XCTAssertEqual(nav.settingsRows, nav.rows(in: .actions))
        XCTAssertFalse(nav.settingsRows.contains(.banner))
    }

    // A stale index would point into the previous category's list, so Enter
    // would act on whatever happened to sit at that offset.
    func testChangingCategoryResetsTheRowSelection() {
        let nav = PanelNav()
        nav.settingsCategory = .integrations
        nav.selectedSettingIndex = 6
        nav.settingsCategory = .events
        XCTAssertEqual(nav.selectedRow, nav.rows(in: .events).first)
    }

    // With no attention rows the first rendered row is index 0; with them it
    // isn't, and asserting 0 outright cemented the bug rather than catching it.
    func testResetLandsPastAnyAttentionRows() {
        let nav = PanelNav()
        nav.updateAvailable = "1.35.0"
        nav.missingPermissions = [.accessibility]
        nav.settingsCategory = .usage
        XCTAssertEqual(nav.selectedSettingIndex, 2)
        XCTAssertEqual(nav.selectedRow, nav.rows(in: .usage).first)
    }

    // They're still reachable — ↑ from the first row walks up into the banners,
    // which is where they're drawn.
    func testAttentionRowsRemainReachableAbove() {
        let nav = PanelNav()
        nav.updateAvailable = "1.35.0"
        nav.settingsCategory = .usage
        nav.selectPrevRow()
        XCTAssertEqual(nav.selectedRow, .update)
    }

    func testReselectingTheSameCategoryKeepsTheSelection() {
        let nav = PanelNav()
        nav.settingsCategory = .usage
        nav.selectedSettingIndex = 3
        nav.settingsCategory = .usage
        XCTAssertEqual(nav.selectedSettingIndex, 3)
    }

    // MARK: - Category movement

    func testCategoryMovementWrapsBothWays() {
        let nav = PanelNav()
        nav.settingsCategory = SettingsCategory.allCases.last!
        nav.selectNextCategory()
        XCTAssertEqual(nav.settingsCategory, SettingsCategory.allCases.first)
        nav.selectPrevCategory()
        XCTAssertEqual(nav.settingsCategory, SettingsCategory.allCases.last)
    }

    func testEveryCategoryHasRowsAndAShortLabel() {
        let nav = PanelNav()
        for category in SettingsCategory.allCases {
            XCTAssertFalse(nav.rows(in: category).isEmpty, "\(category) is empty")
            // The sidebar is ~124pt; anything longer truncates.
            XCTAssertLessThanOrEqual(category.label.count, 14, "\(category.label) is too long")
        }
    }

    // A cap, not a fits-without-scrolling guarantee: roughly six rows fit the
    // pane, so the longer categories do scroll. The point is that none grows
    // back toward the 51-row list this replaced.
    func testNoCategoryGrowsBackTowardTheOldFlatList() {
        let nav = PanelNav()
        let largest = SettingsCategory.allCases.map { nav.rows(in: $0).count }.max() ?? 0
        XCTAssertLessThanOrEqual(largest, 10, "a category grew back into a long list")
    }
}

// Extensions get their own category rather than a row inside another one,
// because per-extension configuration has to land somewhere and growing an
// unrelated category is how the flat list came back last time.
@MainActor
final class ExtensionsCategoryTests: XCTestCase {

    func testExtensionsIsItsOwnCategory() {
        XCTAssertTrue(SettingsCategory.allCases.contains(.extensions))
        XCTAssertEqual(SettingsCategory.extensions.label, "Extensions")
    }

    func testTheBrowserRowLivesThere() {
        let nav = PanelNav()
        XCTAssertEqual(nav.rows(in: .extensions), [.browseExtensions])
    }

    // It used to sit under Actions, and moving it must not leave it in both.
    func testTheBrowserRowIsNotAlsoSomewhereElse() {
        let nav = PanelNav()
        let elsewhere = SettingsCategory.allCases
            .filter { $0 != .extensions }
            .flatMap { nav.rows(in: $0) }
        XCTAssertFalse(elsewhere.contains(.browseExtensions))
    }

    // Entering the category selects its first row, and that row must be the one
    // the pane is actually showing — the same invariant the attention-row fix
    // exists to keep.
    func testEnteringTheCategorySelectsTheBrowserRow() {
        let nav = PanelNav()
        nav.settingsCategory = .extensions
        XCTAssertEqual(nav.selectedRow, .browseExtensions)
    }
}

// Proves the reported defect: attention rows prepend to settingsRows but render
// above the split, not in the detail. Resetting the index to a literal 0 on
// category change therefore selects an invisible row, and Enter fires it.
@MainActor
final class SettingsAttentionSelectionTests: XCTestCase {

    func testEnteringACategoryDoesNotSelectAnInvisibleAttentionRow() {
        let nav = PanelNav()
        nav.unwiredAgents = [.codex]
        nav.settingsCategory = .appearance
        XCTAssertNotEqual(nav.selectedRow, .wireAgents,
                          "Enter here would wire every detected agent's hooks")
        XCTAssertEqual(nav.selectedRow, nav.rows(in: .appearance).first)
    }

    // The same defect reached by a timer instead of a keypress. The attention
    // rows sit in front of the category's, so their count moving shifts every
    // index behind it — and the update check is a repeating Timer while the
    // permissions probe is an async callback, so both land while Settings is
    // open and nobody has touched the keyboard.
    func testAnUpdateArrivingDoesNotSlideTheSelectionOntoTheUpdateRow() {
        let nav = PanelNav()
        nav.settingsCategory = .appearance
        let expected = nav.selectedRow

        nav.updateAvailable = "1.35.0"

        XCTAssertNotEqual(nav.selectedRow, .update,
                          "Enter here would start the updater")
        XCTAssertEqual(nav.selectedRow, expected, "the selection must not move at all")
    }

    func testPermissionsGoingMissingDoesNotSlideTheSelection() {
        let nav = PanelNav()
        nav.settingsCategory = .voice
        let expected = nav.selectedRow

        nav.missingPermissions = [.notifications]

        XCTAssertNotEqual(nav.selectedRow, .permissions)
        XCTAssertEqual(nav.selectedRow, expected)
    }

    func testAnAgentBecomingUnwiredDoesNotSlideTheSelection() {
        let nav = PanelNav()
        nav.settingsCategory = .panel
        let expected = nav.selectedRow

        nav.unwiredAgents = [.codex]

        XCTAssertNotEqual(nav.selectedRow, .wireAgents,
                          "Enter here would rewrite every detected agent's hooks")
        XCTAssertEqual(nav.selectedRow, expected)
    }

    // The selection is held by row identity, so it follows its row rather than
    // its number — the whole point of anchoring instead of re-clamping.
    func testTheSelectionFollowsItsRowWhenAttentionRowsAppear() {
        let nav = PanelNav()
        nav.settingsCategory = .appearance
        nav.selectNextRow()
        let expected = nav.selectedRow
        let indexBefore = nav.selectedSettingIndex

        nav.updateAvailable = "1.35.0"

        XCTAssertEqual(nav.selectedRow, expected, "same row")
        XCTAssertEqual(nav.selectedSettingIndex, indexBefore + 1, "moved along by one")
    }

    // A deliberate selection on an attention row is still a selection, and must
    // survive an unrelated attention row arriving beside it.
    func testASelectedAttentionRowKeepsTheSelection() {
        let nav = PanelNav()
        nav.unwiredAgents = [.codex]
        nav.settingsCategory = .appearance
        nav.selectedSettingIndex = nav.index(of: .wireAgents)
        XCTAssertEqual(nav.selectedRow, .wireAgents)

        nav.updateAvailable = "1.35.0"

        XCTAssertEqual(nav.selectedRow, .wireAgents)
    }

    // A row that goes away entirely hands the selection to the category rather
    // than to whatever inherited its index — inheriting an index is exactly how
    // a keypress meant for a toggle ends up starting an updater.
    func testASelectionOnAVanishedRowFallsBackToTheCategory() {
        // Three attention rows, selection on the first. Wiring the agents
        // removes two of them, so the selected row is gone and the index it
        // held now belongs to the update banner. Keeping the number would put
        // the selection there — Enter starts the updater — which is the whole
        // reason a vanished row falls back to the category instead.
        let nav = PanelNav()
        nav.unwiredAgents = [.codex]
        nav.updateAvailable = "1.35.0"
        nav.settingsCategory = .appearance
        nav.selectedSettingIndex = nav.index(of: .wireAgents)
        XCTAssertEqual(nav.selectedRow, .wireAgents)

        nav.unwiredAgents = []

        XCTAssertNotEqual(nav.selectedRow, .update,
                          "the vanished row's index now belongs to the updater")
        XCTAssertEqual(nav.selectedRow, nav.rows(in: .appearance).first)
    }
}
