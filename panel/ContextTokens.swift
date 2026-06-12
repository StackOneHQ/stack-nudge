import Foundation

// Folds successive context-window readings into a running cumulative total for
// the handoff ledger. Each Stop captures the *current* context occupancy
// (input + cache tokens at the latest turn), which climbs within a session and
// then drops sharply when the conversation is compacted or /cleared. Overwriting
// the stored figure with the latest reading makes a compacted session
// under-report its real effort (the Tickets tab would show only the
// post-compaction remainder). Instead we sum the growth across compaction
// cycles, so the tab reflects total work done in the session.
enum ContextTokens {

    // A single-reading drop of at least this many tokens reads as a compaction
    // or /clear rather than in-session noise. Shared with the context-fill
    // banner's re-arm logic (Panel.evaluateContextThreshold) so both agree on
    // what "a compaction" looks like.
    static let compactDropThreshold = 20_000

    // Fold `newReading` into the running (total, lastReading):
    //   - growth within a cycle banks the delta;
    //   - a ≥threshold drop is a compaction — the prior peak is already banked,
    //     so a fresh cycle starts from the new occupancy without subtracting;
    //   - a sub-threshold dip keeps the higher baseline, so a recovery only
    //     banks genuine new growth above the prior peak;
    //   - a nil lastReading (a new record, or one written before this model
    //     existed) seeds the baseline without double-counting the prior total.
    static func fold(total: Int?, lastReading: Int?, newReading: Int) -> (total: Int, lastReading: Int) {
        guard let lastReading else {
            return (max(total ?? 0, newReading), newReading)
        }
        let running = total ?? 0
        if newReading > lastReading {
            return (running + (newReading - lastReading), newReading)
        }
        if lastReading - newReading >= compactDropThreshold {
            return (running, newReading)
        }
        return (running, lastReading)
    }
}
