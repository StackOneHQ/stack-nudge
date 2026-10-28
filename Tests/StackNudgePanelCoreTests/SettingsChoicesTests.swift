import XCTest

@testable import StackNudgePanelCore

// A list row's click menu and its arrow keys read one list. These never pick:
// picking writes the user's real ~/.stack-nudge/config.
@MainActor
final class SettingsChoicesTests: XCTestCase {

    private static let listRows: [SettingsRow] = [
        .muteDuration, .remindUnanswered, .stalledSessions, .widgetCorner, .widgetOpacity,
        .widgetContent, .mascot, .theme, .agentDoneSound, .permissionSound, .alertThreshold,
        .pollFrequency, .contextAlert, .slackIdle, .historyPerSession,
    ]

    func testEveryListRowOffersItsOptionsWithTheCurrentOneTicked() {
        let nav = PanelNav()
        for row in Self.listRows {
            guard let choices = nav.choices(for: row) else { return XCTFail("\(row) has no options") }
            XCTAssertGreaterThan(choices.labels.count, 1, "\(row)")
            XCTAssertNotNil(choices.current, "\(row): the default value isn't one of its options")
        }
    }

    func testLabelsReadAsTheRowShowsThem() {
        let nav = PanelNav()
        XCTAssertEqual(nav.choices(for: .theme)?.labels, AccentTheme.allCases.map(\.label))
        XCTAssertEqual(nav.choices(for: .widgetOpacity)?.labels.last, "100%")
        XCTAssertEqual(nav.choices(for: .contextAlert)?.labels.first, "Off")
    }

    // Toggles, actions, hotkey recorders and ranges are not lists.
    func testOnlyListRowsHaveOptions() {
        let nav = PanelNav()
        for row: SettingsRow in [.banner, .hotkey, .voiceSpeed, .piApiBudget, .openConfig, .quit] {
            XCTAssertNil(nav.choices(for: row), "\(row)")
        }
    }

    // Stepping is what the arrows do: wrap at either end, start from the
    // fallback when the current value is foreign.
    func testSteppingWrapsAndStartsFromTheFallback() {
        var picked: [Int] = []
        let choices = SettingChoices(labels: ["a", "b", "c"], current: 2, fallback: 0) { picked.append($0) }
        choices.step(forward: true)
        choices.step(forward: false)
        let foreign = SettingChoices(labels: ["a", "b", "c"], current: nil, fallback: 1) { picked.append($0) }
        foreign.step(forward: true)
        XCTAssertEqual(picked, [0, 1, 2])
    }
}
