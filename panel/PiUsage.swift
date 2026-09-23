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

    func allowance(isLocal: Bool, in window: PiWindow) -> Int {
        switch window {
        case .today:    return isLocal ? localDaily : apiDaily
        case .thisWeek: return isLocal ? localWeekly : apiWeekly
        }
    }
}

// One model over one window, measured against the budget for its kind: a local
// model against the local allowance, anything pi priced against the API one.
// The pane lists models by name only; the kind decides the denominator.
struct PiModelUsage: Equatable {
    let key: UsageModelKey
    let name: String
    let tokens: Int
    let tier: QuotaTier
}

// Which window the pi page shows. W toggles it, like the History pane's window.
enum PiWindow: CaseIterable {
    case today
    case thisWeek

    var label: String {
        switch self {
        case .today:    return "Today"
        case .thisWeek: return "This week"
        }
    }
}

// Pi's budget as the Usage tab reads it. A model appears in a window only if it
// ran there and its kind has a budget, so a local-only user never sees an API row.
struct PiQuotaSnapshot: Equatable {
    let today: [PiModelUsage]
    let thisWeek: [PiModelUsage]
    let budget: PiBudget

    func models(in window: PiWindow) -> [PiModelUsage] {
        switch window {
        case .today:    return today
        case .thisWeek: return thisWeek
        }
    }

    var hasTier: Bool { !today.isEmpty || !thisWeek.isEmpty }

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
                         dayTotals: [UsageModelKey: Int],
                         week: DateInterval,
                         weekTotals: [UsageModelKey: Int],
                         budget: PiBudget) -> PiQuotaSnapshot? {
        let snapshot = PiQuotaSnapshot(
            today: models(dayTotals, interval: day, window: .today, budget: budget),
            thisWeek: models(weekTotals, interval: week, window: .thisWeek, budget: budget),
            budget: budget)
        return snapshot.hasTier ? snapshot : nil
    }

    // Closest to its budget first, which is the order the widget and a glance
    // at the page both care about.
    private static func models(_ totals: [UsageModelKey: Int], interval: DateInterval,
                               window: PiWindow, budget: PiBudget) -> [PiModelUsage] {
        // The provider only earns a place in the name when two providers serve
        // the same model name; otherwise it's noise in a narrow pane.
        let shared = Set(Dictionary(grouping: totals.keys, by: \.model).filter { $0.value.count > 1 }.keys)
        return totals.compactMap { key, used -> PiModelUsage? in
            guard let tier = tier(tokens: used, budget: budget.allowance(isLocal: key.isLocal, in: window),
                                  window: interval)
            else { return nil }
            let name = shared.contains(key.model) ? "\(key.model) (\(key.provider ?? "unknown"))" : key.model
            return PiModelUsage(key: key, name: name, tokens: used, tier: tier)
        }
        .sorted {
            $0.tier.utilization != $1.tier.utilization
                ? $0.tier.utilization > $1.tier.utilization
                : $0.name < $1.name
        }
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
