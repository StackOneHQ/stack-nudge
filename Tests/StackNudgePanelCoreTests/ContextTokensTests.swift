import XCTest

@testable import StackNudgePanelCore

// ContextTokens.fold turns the per-Stop context-occupancy reading into a running
// cumulative total. These pin the four cases that matter: monotonic growth,
// compaction reset, sub-threshold noise, and seeding (new + pre-upgrade records).
final class ContextTokensTests: XCTestCase {

    func test_newRecord_seedsToReading() {
        let folded = ContextTokens.fold(total: nil, lastReading: nil, newReading: 100)
        XCTAssertEqual(folded.total, 100)
        XCTAssertEqual(folded.lastReading, 100)
    }

    func test_monotonicGrowth_sumsToFinalReading() {
        // No compaction: cumulative tracks the latest reading exactly.
        var state = ContextTokens.fold(total: nil, lastReading: nil, newReading: 10_000)
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 50_000)
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 120_000)
        XCTAssertEqual(state.total, 120_000)
    }

    func test_compaction_banksPeakThenAccumulatesNewCycle() {
        // Grow to a 180K peak, compact down to 40K, climb to 160K. Effort =
        // peak (180K) + new-cycle growth (160K − 40K) = 300K — not the 160K a
        // last-reading-wins capture would show.
        var state = ContextTokens.fold(total: nil, lastReading: nil, newReading: 180_000)
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 40_000)
        XCTAssertEqual(state.total, 180_000)        // drop banks nothing
        XCTAssertEqual(state.lastReading, 40_000)   // new cycle baseline
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 160_000)
        XCTAssertEqual(state.total, 300_000)
    }

    func test_subThresholdDip_keepsBaseline_soOnlyRealGrowthBanks() {
        // A 5K dip is noise, not a compaction: the baseline stays at the peak,
        // so a recovery only banks growth above it (185K − 180K = 5K).
        var state = ContextTokens.fold(total: 180_000, lastReading: 180_000, newReading: 175_000)
        XCTAssertEqual(state.total, 180_000)
        XCTAssertEqual(state.lastReading, 180_000)
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 185_000)
        XCTAssertEqual(state.total, 185_000)
    }

    func test_dropExactlyAtThreshold_countsAsCompaction() {
        let folded = ContextTokens.fold(total: 180_000, lastReading: 180_000, newReading: 160_000)
        XCTAssertEqual(folded.total, 180_000)       // 20K drop == threshold → reset, no subtract
        XCTAssertEqual(folded.lastReading, 160_000)
    }

    func test_preUpgradeRecord_seedsWithoutDoubleCounting() {
        // Legacy record: a single stored figure, no lastReading. Seeding must not
        // add the new reading on top of the stored total.
        var state = ContextTokens.fold(total: 80_000, lastReading: nil, newReading: 90_000)
        XCTAssertEqual(state.total, 90_000)
        XCTAssertEqual(state.lastReading, 90_000)
        state = ContextTokens.fold(total: state.total, lastReading: state.lastReading, newReading: 110_000)
        XCTAssertEqual(state.total, 110_000)
    }

    func test_preUpgradeRecord_lowerReadingKeepsHigherTotal() {
        // Legacy total above the current reading (upgraded mid-compaction) is kept.
        let folded = ContextTokens.fold(total: 180_000, lastReading: nil, newReading: 40_000)
        XCTAssertEqual(folded.total, 180_000)
        XCTAssertEqual(folded.lastReading, 40_000)
    }
}
