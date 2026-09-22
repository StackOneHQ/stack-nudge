import Foundation

// Pi enforces no quota: its API models bill per token against the user's own
// keys, and its local models cost nothing. These denominators are therefore the
// user's own (STACKNUDGE_PI_API_BUDGET / STACKNUDGE_PI_LOCAL_BUDGET), not
// anything that will cut them off, which is why the pane says "budget"
// throughout — a bar that looks like Claude's would be read as a limit.
struct PiBudget: Equatable {
    // Tokens per day, excluding cache reads.
    var apiDaily: Int
    var localDaily: Int

    // A week is seven days' worth. One knob per lane keeps the pair consistent:
    // a separately-set weekly cap can sit below the daily one.
    var apiWeekly: Int { apiDaily * 7 }
    var localWeekly: Int { localDaily * 7 }

    static let apiDailyDefault = 1_500_000
    static let localDailyDefault = 500_000

    static let fallback = PiBudget(apiDaily: apiDailyDefault, localDaily: localDailyDefault)

    // Ladder for the Settings cycle rows. 0 turns a lane off: someone who only
    // runs local models has no use for an API budget, and a row pinned at 0%
    // forever is worse than no row.
    static let dailyOptions: [Int] = [0, 250_000, 500_000, 1_000_000, 1_500_000,
                                      2_000_000, 3_000_000, 5_000_000, 10_000_000]

    static func label(_ tokens: Int) -> String {
        tokens == 0 ? "Off" : TokenFormat.short(tokens)
    }
}

// Pi's budget as the Usage tab's shared tier shape. Tiers are nil where the lane
// has no usage in the window, so a local-only user never sees an empty API row.
struct PiQuotaSnapshot: Equatable {
    let apiToday: QuotaTier?
    let apiThisWeek: QuotaTier?
    let localToday: QuotaTier?
    let localThisWeek: QuotaTier?
    let budget: PiBudget

    var hasTier: Bool {
        apiToday != nil || apiThisWeek != nil || localToday != nil || localThisWeek != nil
    }

    // Sits where the other clients show their subscription tier. Naming a plan
    // Pi doesn't have would be the one claim this pane must not make.
    var planType: String? { "budget" }
}

enum PiUsageBudget {

    // Calendar windows, not trailing ones: a real boundary is what gives the
    // pane's "Resets" line and its ahead-of-pace warning something to measure
    // against. dateInterval also reports the period's true length, so a 23-hour
    // DST day paces correctly, and honours the locale's first weekday.
    static func windows(now: Date, calendar: Calendar = .current) -> (day: DateInterval, week: DateInterval)? {
        guard let day = calendar.dateInterval(of: .day, for: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return nil }
        return (day, week)
    }

    // Far enough back for the weekly window to be complete from the first poll.
    static let retention: TimeInterval = 8 * 86400

    static func snapshot(day: DateInterval,
                         dayTotals: UsageTotals,
                         week: DateInterval,
                         weekTotals: UsageTotals,
                         budget: PiBudget) -> PiQuotaSnapshot? {
        let snapshot = PiQuotaSnapshot(
            apiToday:      tier(tokens: dayTotals.apiTokens,    budget: budget.apiDaily,    window: day),
            apiThisWeek:   tier(tokens: weekTotals.apiTokens,   budget: budget.apiWeekly,   window: week),
            localToday:    tier(tokens: dayTotals.localTokens,  budget: budget.localDaily,  window: day),
            localThisWeek: tier(tokens: weekTotals.localTokens, budget: budget.localWeekly, window: week),
            budget: budget)
        return snapshot.hasTier ? snapshot : nil
    }

    // Left unclamped deliberately: going over a self-imposed budget is the one
    // thing it exists to tell you, and the bar clamps its own width anyway.
    private static func tier(tokens: Int, budget: Int, window: DateInterval) -> QuotaTier? {
        guard tokens > 0, budget > 0 else { return nil }
        return QuotaTier(utilization: Double(tokens) / Double(budget) * 100,
                         resetsAt: window.end,
                         windowLength: window.duration)
    }
}

// Reads pi's transcripts through the same store the Usage graph uses, so a poll
// costs the directory walk rather than a re-parse.
final class PiUsageProbe {

    private let store: UsageHistoryStore
    private let root: String?
    // Serialises refreshes so an overlapping poll can't re-enter the store's
    // scan, matching CodexQuotaProbe's probeQueue.
    private let probeQueue = DispatchQueue(label: "stack-nudge.pi-usage")

    init(store: UsageHistoryStore, root: String? = nil) {
        self.store = store
        self.root = root
    }

    // Calls completion on the main queue. nil means nothing to show — no pi
    // usage in either window, or both lanes budgeted off.
    func fetch(budget: PiBudget,
               now: Date = Date(),
               calendar: Calendar = .current,
               completion: @escaping (PiQuotaSnapshot?) -> Void) {
        probeQueue.async { [store, root] in
            let result = Self.read(store: store, root: root, budget: budget, now: now, calendar: calendar)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func read(store: UsageHistoryStore,
                     root: String?,
                     budget: PiBudget,
                     now: Date,
                     calendar: Calendar) -> PiQuotaSnapshot? {
        guard let windows = PiUsageBudget.windows(now: now, calendar: calendar) else { return nil }
        store.refresh(source: .pi, root: root, now: now, retaining: PiUsageBudget.retention)
        return PiUsageBudget.snapshot(
            day: windows.day,
            dayTotals: store.totals(source: .pi, from: windows.day.start, to: windows.day.end),
            week: windows.week,
            weekTotals: store.totals(source: .pi, from: windows.week.start, to: windows.week.end),
            budget: budget)
    }
}
