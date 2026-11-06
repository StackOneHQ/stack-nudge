import XCTest

@testable import StackNudgePanelCore

// One holder per signal, values from the app's own table, and a holder that
// goes away always leaves the signal neutral.
final class SignalRegistryTests: XCTestCase {

    private var registry = SignalRegistry()
    private var changes: [String] = []

    override func setUp() {
        registry = SignalRegistry()
        changes = []
        registry.onChange = { [unowned self] signal, value in
            self.changes.append("\(signal.rawValue)=\(value)")
        }
    }

    func testASignalReadsNeutralUntilItsHolderSetsIt() {
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertTrue(registry.claim(.presence, by: "away"))
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertNil(registry.set("presence", to: "away", from: "away"))
        XCTAssertEqual(registry.value(.presence), "away")
        XCTAssertEqual(registry.values, [.presence: "away"])
        XCTAssertEqual(changes, ["presence=away"])
    }

    // The first one granted keeps it; the second is refused with a reason, and
    // can't set it either.
    func testOnlyOneExtensionMayHoldASignal() {
        XCTAssertTrue(registry.claim(.presence, by: "away"))
        XCTAssertFalse(registry.claim(.presence, by: "rival"))
        XCTAssertEqual(registry.holders[.presence], "away")
        XCTAssertEqual(registry.refusals["rival"], .heldByAnother(signal: "presence", holder: "away"))
        XCTAssertEqual(registry.set("presence", to: "away", from: "rival"),
                       .heldByAnother(signal: "presence", holder: "away"))
        XCTAssertEqual(registry.value(.presence), "present")
    }

    // A restart claims again; that isn't a second holder.
    func testClaimingAgainIsFineForTheHolder() {
        XCTAssertTrue(registry.claim(.presence, by: "away"))
        XCTAssertTrue(registry.claim(.presence, by: "away"))
    }

    func testUnknownSignalsAndValuesAreRefused() {
        registry.claim(.presence, by: "away")
        XCTAssertEqual(registry.set("mute", to: "on", from: "away"), .unknownSignal("mute"))
        XCTAssertEqual(registry.set("presence", to: "asleep", from: "away"),
                       .unknownValue(signal: "presence", value: "asleep"))
        XCTAssertEqual(registry.refusals["away"], .unknownValue(signal: "presence", value: "asleep"))
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertEqual(changes, [])
    }

    func testNobodyHoldingMeansNobodyCanSet() {
        XCTAssertEqual(registry.set("presence", to: "away", from: "away"),
                       .notHolding(signal: "presence"))
    }

    // A crash resets the value but keeps the holder, so it can say "away" again
    // once it's back without another extension having taken the signal.
    func testACrashResetsToNeutralButKeepsTheHolder() {
        registry.claim(.presence, by: "away")
        _ = registry.set("presence", to: "away", from: "away")
        registry.reset("away")
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertEqual(registry.holders[.presence], "away")
        XCTAssertFalse(registry.claim(.presence, by: "rival"))
        XCTAssertEqual(changes, ["presence=away", "presence=present"])
    }

    // Stopped, disabled, removed, or the grant gone: neutral, and the signal is
    // free for somebody else.
    func testReleasingResetsToNeutralAndFreesTheSignal() {
        registry.claim(.presence, by: "away")
        _ = registry.set("presence", to: "away", from: "away")
        registry.release("away")
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertNil(registry.holders[.presence])
        XCTAssertTrue(registry.claim(.presence, by: "rival"))
    }

    // Saying the same thing again isn't a change, so a reaction isn't repeated.
    func testRepeatingAValueIsNotAChange() {
        registry.claim(.presence, by: "away")
        _ = registry.set("presence", to: "away", from: "away")
        _ = registry.set("presence", to: "away", from: "away")
        _ = registry.set("presence", to: "present", from: "away")
        XCTAssertEqual(changes, ["presence=away", "presence=present"])
    }
}
