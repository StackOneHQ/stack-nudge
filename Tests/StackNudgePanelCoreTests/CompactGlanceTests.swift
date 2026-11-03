import XCTest

@testable import StackNudgePanelCore

// The pill has room for one extension chip. Which one, and how the rest are
// counted, is the part of the widget that can be got wrong without drawing it.
final class CompactGlanceTests: XCTestCase {

    private func glance(_ id: String, _ tone: ExtensionDocument.Tone) -> ExtensionGlance {
        ExtensionGlance(id: id, label: id, text: "1 DUE", tone: tone, trailing: nil)
    }

    func testNothingToShowShowsNothing() {
        XCTAssertNil(CompactView.glanceToShow([]))
    }

    func testOneGlanceIsShownWithNothingBehindIt() {
        XCTAssertEqual(CompactView.glanceToShow([glance("pylon", .warning)]),
                       .init(glance: glance("pylon", .warning), more: 0))
    }

    // Danger outranks warning wherever it sits in tab order, and the others
    // are counted rather than dropped, so "+1" says there's more to see.
    func testTheMostSevereIsShownAndTheRestCounted() {
        let shown = CompactView.glanceToShow([glance("radar", .warning),
                                              glance("pylon", .danger),
                                              glance("derby", .danger)])
        XCTAssertEqual(shown?.glance.id, "pylon")
        XCTAssertEqual(shown?.more, 2)
    }

    // Driven through the real entry point, as the chip calls it. The window
    // must already be expanding when the mode flips, or the tab renders into
    // the pill's frame; and it is the transient expand, not leaving widget mode.
    func testAClickOpensTheTabOnTheTransientExpand() {
        let nav = PanelNav()
        var modeWhenExpanded: PanelMode?
        var exitedCompact = false
        nav.actions = SettingsActions(
            checkPermissions: {}, openConfig: {}, editPhrases: {},
            browseExtensions: {}, openExtension: { _ in },
            openReleaseNotes: {}, checkForUpdates: {}, beginUpdate: {}, runUpdate: {},
            beginUninstall: {}, runUninstall: {}, runBootstrap: {}, quit: {},
            expandFromCompact: { modeWhenExpanded = nav.mode },
            exitCompactMode: { exitedCompact = true },
            muteFor: { _ in }, resumeNotifications: {},
            applyEventHistorySetting: {}, clearEventHistory: {},
            pasteSlackSetup: {}, detectSlackUser: {}, sendSlackTest: {})
        nav.mode = .events

        nav.openGlance("pylon")

        XCTAssertEqual(modeWhenExpanded, .events, "expanded before the mode flipped")
        XCTAssertEqual(nav.mode, .extensionTab("pylon"))
        XCTAssertFalse(exitedCompact, "a chip must not cost somebody their widget")
    }

    // The chip is often just a dot, so the tooltip and VoiceOver carry what it
    // shed, and say when what they're reading has stopped refreshing.
    func testTheDescriptionCarriesWhatTheChipSheds() {
        let due = ExtensionGlance(id: "pylon", label: "Pylon", text: "2 DUE",
                                  tone: .warning, trailing: "12m")
        XCTAssertEqual(CompactView.glanceDescription(due), "Pylon: 2 DUE, 12m")
        let stale = ExtensionGlance(id: "pylon", label: "Pylon", text: "2 DUE",
                                    tone: .warning, trailing: nil, stale: true)
        XCTAssertEqual(CompactView.glanceDescription(stale), "Pylon: 2 DUE, not refreshed lately")
    }

    func testAmongEqualsTabOrderWins() {
        XCTAssertEqual(CompactView.glanceToShow([glance("radar", .warning),
                                                 glance("pylon", .warning)])?.glance.id,
                       "radar")
    }
}
