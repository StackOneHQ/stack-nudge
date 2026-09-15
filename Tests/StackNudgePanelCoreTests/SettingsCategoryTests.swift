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

    // The largest category has to fit the pane without scrolling, which was the
    // point of splitting a 51-row list up.
    func testNoCategoryIsAsLongAsTheOldFlatList() {
        let nav = PanelNav()
        let largest = SettingsCategory.allCases.map { nav.rows(in: $0).count }.max() ?? 0
        XCTAssertLessThanOrEqual(largest, 10, "a category grew back into a long list")
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
}
