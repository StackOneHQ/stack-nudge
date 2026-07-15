import XCTest

@testable import StackNudgePanelCore

// Timed global mute: the transient state lives on PanelNav (muteUntil), the
// persistent default duration is a config-backed cycle row, and the countdown
// label is a pure helper. PanelController owns the timer/side-effects and is
// not exercised here.
@MainActor
final class MuteStateTests: XCTestCase {

    func test_muteRowsAreContiguous() {
        // Render/keyboard order: the one-click mute action sits between the
        // "mute when focused" toggle and the default-duration cycle, so the
        // trigger and its knob stay adjacent.
        let nav = PanelNav()
        let rows = nav.settingsRows
        guard let i = rows.firstIndex(of: .muteWhenFocused) else {
            return XCTFail("muteWhenFocused row missing")
        }
        XCTAssertEqual(rows[i + 1], .mute)
        XCTAssertEqual(rows[i + 2], .muteDuration)
    }

    func test_isMuted_reflectsMuteUntil() {
        let nav = PanelNav()
        XCTAssertFalse(nav.isMuted)                          // nil → not muted
        nav.muteUntil = Date().addingTimeInterval(600)
        XCTAssertTrue(nav.isMuted)                           // future → muted
        nav.muteUntil = Date().addingTimeInterval(-1)
        XCTAssertFalse(nav.isMuted)                          // past → lifted
    }

    func test_defaultDuration_isAValidOption() {
        // The cycle row snaps to a member; the initial value must already be one.
        let nav = PanelNav()
        XCTAssertTrue(PanelNav.muteDurationOptions.contains(nav.muteDurationMinutes))
    }

    func test_muteRemainingLabel_ceilsToWholeMinutes() {
        XCTAssertEqual(PanelNav.muteRemainingLabel(until: Date().addingTimeInterval(90)), "2m")
        XCTAssertEqual(PanelNav.muteRemainingLabel(until: Date().addingTimeInterval(30)), "1m")
        // Already elapsed clamps to 0 rather than going negative.
        XCTAssertEqual(PanelNav.muteRemainingLabel(until: Date().addingTimeInterval(-5)), "0m")
    }
}
