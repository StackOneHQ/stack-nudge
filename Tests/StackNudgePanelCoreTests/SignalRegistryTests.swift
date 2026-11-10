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

    // Stopped for an update or a quit: neutral, but it stays the holder, so
    // its replacement gets the signal back rather than whoever asks first.
    func testReleasingResetsToNeutralButKeepsTheHolder() {
        registry.claim(.presence, by: "away")
        _ = registry.set("presence", to: "away", from: "away")
        registry.release("away")
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertEqual(registry.holders[.presence], "away")
        XCTAssertFalse(registry.claim(.presence, by: "rival"))
    }

    // Removed, refused, or the grant gone: neutral, and free for somebody else.
    func testForgettingAHolderResetsToNeutralAndFreesTheSignal() {
        registry.claim(.presence, by: "away")
        _ = registry.set("presence", to: "away", from: "away")
        registry.forgetHolders { _, id in id != "away" }
        XCTAssertEqual(registry.value(.presence), "present")
        XCTAssertNil(registry.holders[.presence])
        XCTAssertTrue(registry.claim(.presence, by: "rival"))
        XCTAssertEqual(changes, ["presence=away", "presence=present"])
    }

    // MARK: - The record

    private func recordPath() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("signals-\(UUID().uuidString)/.signals.json").path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        return path
    }

    // The first holder is written down, and a registry built from the record
    // after a relaunch honours it whoever asks first.
    func testTheHolderIsRecordedAndHonouredAfterARelaunch() throws {
        let path = recordPath()
        XCTAssertTrue(SignalRegistry(path: path).claim(.presence, by: "away"))
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"presence":"away"}"#)

        let relaunched = SignalRegistry(path: path)
        XCTAssertEqual(relaunched.holders[.presence], "away")
        XCTAssertFalse(relaunched.claim(.presence, by: "rival"))
        XCTAssertTrue(relaunched.claim(.presence, by: "away"))
    }

    func testForgettingAHolderClearsTheRecord() {
        let path = recordPath()
        let registry = SignalRegistry(path: path)
        registry.claim(.presence, by: "away")
        registry.forgetHolders { _, _ in false }
        XCTAssertNil(SignalRegistry(path: path).holders[.presence])
    }

    // An unreadable record, or one naming a signal or an id this host can't
    // use, means nobody holds anything yet. Never a crash, never a stray holder.
    func testABrokenRecordReadsAsNobodyHolding() throws {
        let path = recordPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "nope".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SignalRegistry(path: path).holders, [:])
        try #"{"presence":"../x","mute":"away"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SignalRegistry(path: path).holders, [:])
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
