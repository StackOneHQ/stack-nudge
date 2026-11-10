import XCTest

@testable import StackNudgePanelCore

// The app's half of Away: what the presence signal makes it do, and the
// Settings row that decides whether leaving locks the screen. The detection
// itself is extensions/away, tested by its own suite.
final class AwayPresenceTests: XCTestCase {

    func testAwayLocksOnlyWhenTheSettingSaysTo() {
        XCTAssertEqual(PresenceReaction.on(.presence, value: "away", lockWhenAway: true),
                       .away(lock: true))
        XCTAssertTrue(PresenceReaction.on(.presence, value: "away", lockWhenAway: true).locks)
        XCTAssertFalse(PresenceReaction.on(.presence, value: "away", lockWhenAway: false).locks)
        XCTAssertEqual(PresenceReaction.on(.presence, value: "away", lockWhenAway: false).isAway, true)
    }

    func testPresentNeverLocks() {
        let reaction = PresenceReaction.on(.presence, value: "present", lockWhenAway: true)
        XCTAssertEqual(reaction, .present)
        XCTAssertFalse(reaction.locks)
        XCTAssertEqual(reaction.isAway, false)
    }

    // A holder that crashes, restarts or stops is put back to neutral by the
    // registry. That comes through the same onChange as anything the
    // extension says, so it has to read as present, and never lock.
    func testAHolderThatDiesResetsToPresentWithoutLocking() {
        let registry = SignalRegistry()
        var reactions: [PresenceReaction] = []
        registry.onChange = { signal, value in
            reactions.append(PresenceReaction.on(signal, value: value, lockWhenAway: true))
        }
        XCTAssertTrue(registry.claim(.presence, by: "away"))
        registry.set("presence", to: "away", from: "away")
        registry.reset("away")
        XCTAssertEqual(reactions, [.away(lock: true), .present])

        registry.set("presence", to: "away", from: "away")
        registry.release("away")
        XCTAssertEqual(reactions.last, .present)
        XCTAssertEqual(reactions.filter(\.locks).count, 2, "only the two real departures lock")

        // Removing it drops the holder, and its value goes back to neutral too.
        registry.set("presence", to: "away", from: "away")
        registry.forgetHolders { _, _ in false }
        XCTAssertEqual(reactions.last, .present)
    }

    // Saying "away" twice reaches the app once, so the screen isn't locked
    // again under somebody who has just unlocked it.
    func testRepeatingAwayDoesNotReactAgain() {
        let registry = SignalRegistry()
        var count = 0
        registry.onChange = { _, _ in count += 1 }
        registry.claim(.presence, by: "away")
        registry.set("presence", to: "away", from: "away")
        registry.set("presence", to: "away", from: "away")
        XCTAssertEqual(count, 1)
    }

    func testHolderChangesAreAnnounced() {
        let registry = SignalRegistry()
        var announced = 0
        registry.onHoldersChange = { announced += 1 }
        registry.claim(.presence, by: "away")
        registry.claim(.presence, by: "away")
        XCTAssertEqual(announced, 1, "claiming again changes nothing")
        registry.forgetHolders { _, _ in false }
        XCTAssertEqual(announced, 2)
        XCTAssertNil(registry.holders[.presence])
    }

    // MARK: - The lock row

    private func navWithAway(holder: String?) -> PanelNav {
        let nav = PanelNav()
        nav.persistExtensionValue = { _, _ in XCTFail("nothing here should write config") }
        nav.installedExtensions = [ExtensionSettingsPageTests.installed("away")]
        nav.extensionSettingsPages = [ExtensionSettingsPage(id: "away", name: "Away", keys: [])]
        nav.presenceHolderID = holder
        return nav
    }

    // The app's own toggle, on the page of whichever extension holds
    // presence, and nowhere else.
    func testTheLockRowIsOnThePresenceHoldersPageOnly() {
        XCTAssertEqual(navWithAway(holder: "away").rows(in: .extensionPage("away")),
                       [.awayLock, .extensionRemove("away")])
        XCTAssertEqual(navWithAway(holder: nil).rows(in: .extensionPage("away")), [.extensionRemove("away")])
        XCTAssertEqual(navWithAway(holder: "radar").rows(in: .extensionPage("away")), [.extensionRemove("away")])
        let nav = navWithAway(holder: "away")
        let elsewhere = SettingsCategory.allCases.flatMap { nav.rows(in: $0) }
        XCTAssertEqual(elsewhere.contains(.awayLock), false, "a holder with a page keeps it there")
        XCTAssertTrue(nav.awayLock, "locking is on by default")
    }

    // An on/off row: arrows walk past it without flipping it. Space and ⏎ go
    // through activate(), which writes the real config file for this built-in
    // row, so this stops short of it, as the other Settings row tests do.
    func testArrowsDoNotFlipTheLockToggle() {
        let nav = navWithAway(holder: "away")
        nav.mode = .settings
        nav.openExtensionPage("away")
        nav.selectedSettingIndex = nav.index(of: .awayLock)
        XCTAssertEqual(nav.selectedRow, .awayLock)
        XCTAssertFalse(nav.selectedRowIsPicker)
        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertTrue(nav.awayLock)
        XCTAssertFalse(nav.pickingValue)
    }
}
