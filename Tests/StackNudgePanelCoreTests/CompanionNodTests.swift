import XCTest

@testable import StackNudgePanelCore

final class CompanionNodTests: XCTestCase {

    private let now = Date()

    private func agent(_ kind: NudgeKind) -> NudgeEvent {
        NudgeEvent(agent: "claude", kind: kind, title: "t", message: "m")
    }

    private func nod(_ arrivals: [NudgeEvent], interrupts: @escaping (NudgeEvent) -> Bool = { _ in true },
                     muted: Bool = false, reduceMotion: Bool = false, gateActive: Bool = true,
                     before: SkinMode = .idle, after: SkinMode = .idle, last: Date? = nil) -> Bool {
        CompanionNod.shouldNod(arrivals: arrivals, interrupts: interrupts, muted: muted, reduceMotion: reduceMotion,
                               gateActive: gateActive, before: before, after: after, lastNod: last, now: now)
    }

    func testAFinishedTurnNodsWhenIdleOrSleeping() {
        XCTAssertTrue(nod([agent(.stop)]))
        XCTAssertTrue(nod([agent(.stop)], before: .sleeping))
    }

    func testBusyPosesSkipIt() {
        for pose in [SkinMode.alert, .pending, .thinking, .error, .muted] {
            XCTAssertFalse(nod([agent(.stop)], before: pose), "before \(pose)")
            XCTAssertFalse(nod([agent(.stop)], after: pose), "after \(pose)")
        }
    }

    func testOnlyAFinishedTurnCounts() {
        XCTAssertFalse(nod([agent(.permission)]))
        XCTAssertFalse(nod([agent(.other)]))
        XCTAssertFalse(nod([]))
        XCTAssertTrue(nod([agent(.permission), agent(.stop)]))
    }

    func testEventsThatMayNotInterruptDoNotCount() {
        XCTAssertFalse(nod([agent(.stop)], interrupts: { _ in false }))
        let quiet = agent(.stop)
        let loud = agent(.stop)
        XCTAssertTrue(nod([quiet, loud], interrupts: { $0.id == loud.id }))
    }

    func testMutedReduceMotionAndAnInactiveGateSkipIt() {
        XCTAssertFalse(nod([agent(.stop)], muted: true))
        XCTAssertFalse(nod([agent(.stop)], reduceMotion: true))
        XCTAssertFalse(nod([agent(.stop)], gateActive: false))
    }

    func testABurstWithinTheWindowNodsOnce() {
        XCTAssertFalse(nod([agent(.stop)], last: now.addingTimeInterval(-1)))
        XCTAssertTrue(nod([agent(.stop)], last: now.addingTimeInterval(-3)))
    }
}
