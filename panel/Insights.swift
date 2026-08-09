import Foundation

// Pure spend-to-outcome rollup behind the Insights tab. A function of the
// handoff ledger plus the per-branch outcome + PR maps the Tickets tab already
// computes (nav.outcomeByBranch / nav.pullRequestByBranch), so Insights agrees
// with the Tickets tab by construction rather than re-deriving git state. No
// I/O, no network; the same posture as OutcomesView.groups.
//
// Step 1 is token-only: `contextTokens` is the same cumulative-effort proxy the
// Tickets tab sums, not output tokens or dollar cost. The dollar and cache
// lenses (a real input/output/cache split) and reclaimed-time arrive with the
// HandoffRecord fields added in later steps, and this type grows with them.

// The five OutcomeStatus values collapse into three spend buckets for the
// headline. Merged/pushed shipped; committed/needs-review that has gone quiet
// past the staleness cutoff is abandoned; everything else (recent unshipped
// work, and `clean`) is still in flight.
enum SpendBucket: String, CaseIterable {
    case shipped
    case abandoned
    case inFlight

    // Headline label. `inFlight` reads "in flight" rather than the raw case name.
    var label: String {
        switch self {
        case .shipped:   return "shipped"
        case .abandoned: return "abandoned"
        case .inFlight:  return "in flight"
        }
    }
}

// Trailing windows the Insights tab cycles through with `W`. All are trailing
// (now - seconds), not calendar periods, so the labels say so. `abandoned` only
// surfaces on windows wider than the 14-day staleness cutoff.
enum InsightsWindow: CaseIterable {
    case day
    case week
    case month
    case quarter

    var label: String {
        switch self {
        case .day:     return "Last 24h"
        case .week:    return "Last 7 days"
        case .month:   return "Last 30 days"
        case .quarter: return "Last 90 days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .day:     return 86_400
        case .week:    return 7 * 86_400
        case .month:   return 30 * 86_400
        case .quarter: return 90 * 86_400
        }
    }
}

// One row in the "top tickets by spend" list: a ticket (or unticketed repo)
// group, its token spend, and its dominant outcome. `prURL` lets the row open
// the PR when there's no ticket deep-link.
struct TicketSpend: Identifiable, Equatable {
    let id: String              // group dedup key ("t:<ticket>" / "r:<repoRoot>")
    let label: String           // ticket key, or repo basename
    let isTicket: Bool
    let tokens: Int
    let status: OutcomeStatus?  // dominant effective status across the group's branches
    let bucket: SpendBucket
    let prURL: String?
}

struct InsightsSummary: Equatable {
    let window: DateInterval
    let totalTokens: Int
    let sessionCount: Int
    let ticketCount: Int                        // distinct tickets touched in-window

    // Headline: tokens by spend bucket.
    let tokensByBucket: [SpendBucket: Int]

    // Detail: the effective per-status split (PR state preferred), the agent
    // mix, and the model mix. Model keys are the raw reported ids (e.g.
    // "claude-opus-4-8", "gpt-5-codex"): distinct minor versions are genuinely
    // different models, so the data layer keeps them apart and the view formats.
    let tokensByStatus: [OutcomeStatus: Int]
    let tokensByAgent: [String: Int]
    let tokensByModel: [String: Int]

    // Shipped (merged + pushed) tokens per agent, paired with tokensByAgent to
    // give each agent's shipped share: which agent's work actually merges.
    let shippedTokensByAgent: [String: Int]

    // The heaviest-spend groups in the window, most tokens first, for the
    // drill-down list. Bounded to Insights.maxTopTickets.
    let topTickets: [TicketSpend]

    // Shipped share of total effort. 0 when nothing ran, so the headline reads
    // "0% shipped" on an empty window rather than dividing by zero.
    var shippedShare: Double {
        guard totalTokens > 0 else { return 0 }
        return Double(tokensByBucket[.shipped] ?? 0) / Double(totalTokens)
    }
}

enum Insights {

    // A branch quiet for this long with unshipped work reads as abandoned. Only
    // meaningful once the window is at least this wide: a 7-day window cannot
    // contain a branch that has been quiet for 14 days, so its abandoned bucket
    // is naturally empty. Overridable in summarize() for tests.
    static let defaultStaleness: TimeInterval = 14 * 86_400

    // How many rows the top-tickets drill-down shows.
    static let maxTopTickets = 6

    // Highest (most-shipped) status wins when a group spans branches at
    // different stages: a ticket with one merged branch reads "merged".
    private static let statusPrecedence: [OutcomeStatus] = [.merged, .pushed, .committed, .needsReview, .clean]

    static func summarize(records: [HandoffRecord],
                          outcomeByBranch: [String: OutcomeStatus],
                          pullRequestByBranch: [String: PullRequestInfo],
                          now: Date,
                          window: TimeInterval,
                          staleness: TimeInterval = defaultStaleness) -> InsightsSummary {
        let windowStart = now.addingTimeInterval(-window)
        let inWindow = records.filter { $0.updatedAt >= windowStart && $0.updatedAt <= now }

        // Per-branch last activity, for the abandoned test. Max updatedAt over
        // the branch's in-window records; a branch spans multiple session rows.
        var lastActivityByBranch: [String: Date] = [:]
        for record in inWindow {
            let key = PanelNav.outcomeKey(record.repoRoot, record.branch)
            if let seen = lastActivityByBranch[key], seen >= record.updatedAt { continue }
            lastActivityByBranch[key] = record.updatedAt
        }

        var tokensByBucket: [SpendBucket: Int] = [:]
        var tokensByStatus: [OutcomeStatus: Int] = [:]
        var tokensByAgent: [String: Int] = [:]
        var shippedTokensByAgent: [String: Int] = [:]
        var tokensByModel: [String: Int] = [:]
        var tickets = Set<String>()
        var total = 0

        for record in inWindow {
            let tokens = record.contextTokens ?? 0
            total += tokens

            let key = PanelNav.outcomeKey(record.repoRoot, record.branch)
            let status = OutcomeWatcher.effective(local: outcomeByBranch[key],
                                                  pr: pullRequestByBranch[key])
            if let status { tokensByStatus[status, default: 0] += tokens }

            let bucket = spendBucket(status: status,
                                     branchLastActivity: lastActivityByBranch[key],
                                     now: now, staleness: staleness)
            tokensByBucket[bucket, default: 0] += tokens

            let agent = Agent.canonical(record.agent)
            tokensByAgent[agent, default: 0] += tokens
            if bucket == .shipped { shippedTokensByAgent[agent, default: 0] += tokens }
            if let model = record.model { tokensByModel[model, default: 0] += tokens }

            if let ticket = record.ticket ?? TicketAttribution.ticket(branch: record.branch) {
                tickets.insert(ticket)
            }
        }

        // Reuse the Tickets tab's grouping so the drill-down agrees with it, then
        // classify each group and keep the heaviest.
        let topTickets = OutcomesView.groups(from: inWindow)
            .map { group -> TicketSpend in
                let status = dominantStatus(branches: group.branches,
                                            outcomeByBranch: outcomeByBranch,
                                            pullRequestByBranch: pullRequestByBranch)
                let lastActivity = groupLastActivity(branches: group.branches,
                                                     lastActivityByBranch: lastActivityByBranch)
                return TicketSpend(
                    id: group.id, label: group.label, isTicket: group.isTicket,
                    tokens: group.totalTokens, status: status,
                    bucket: spendBucket(status: status, branchLastActivity: lastActivity,
                                        now: now, staleness: staleness),
                    prURL: groupPRURL(branches: group.branches, pullRequestByBranch: pullRequestByBranch))
            }
            .sorted { $0.tokens > $1.tokens }
            .prefix(maxTopTickets)

        return InsightsSummary(
            window: DateInterval(start: windowStart, end: now),
            totalTokens: total,
            sessionCount: inWindow.count,
            ticketCount: tickets.count,
            tokensByBucket: tokensByBucket,
            tokensByStatus: tokensByStatus,
            tokensByAgent: tokensByAgent,
            tokensByModel: tokensByModel,
            shippedTokensByAgent: shippedTokensByAgent,
            topTickets: Array(topTickets))
    }

    // Highest-precedence effective status across a group's branches, or nil when
    // none has resolved yet.
    static func dominantStatus(branches: [BranchBreakdown],
                               outcomeByBranch: [String: OutcomeStatus],
                               pullRequestByBranch: [String: PullRequestInfo]) -> OutcomeStatus? {
        var best: OutcomeStatus?
        for branch in branches {
            let key = PanelNav.outcomeKey(branch.repoRoot, branch.branch)
            guard let status = OutcomeWatcher.effective(local: outcomeByBranch[key],
                                                        pr: pullRequestByBranch[key]),
                  let rank = statusPrecedence.firstIndex(of: status) else { continue }
            if best == nil || rank < (statusPrecedence.firstIndex(of: best!) ?? .max) {
                best = status
            }
        }
        return best
    }

    // A PR to open for the group: prefer a merged one, else the first present.
    static func groupPRURL(branches: [BranchBreakdown],
                           pullRequestByBranch: [String: PullRequestInfo]) -> String? {
        var firstURL: String?
        for branch in branches {
            let key = PanelNav.outcomeKey(branch.repoRoot, branch.branch)
            guard let pr = pullRequestByBranch[key] else { continue }
            if pr.state == .merged { return pr.url }
            if firstURL == nil { firstURL = pr.url }
        }
        return firstURL
    }

    private static func groupLastActivity(branches: [BranchBreakdown],
                                          lastActivityByBranch: [String: Date]) -> Date? {
        var latest: Date?
        for branch in branches {
            let key = PanelNav.outcomeKey(branch.repoRoot, branch.branch)
            guard let activity = lastActivityByBranch[key] else { continue }
            if latest == nil || activity > latest! { latest = activity }
        }
        return latest
    }

    // Collapse an effective status + branch recency into a spend bucket. Missing
    // status (branch not yet resolved) and `clean` both read as in-flight: they
    // are neither shipped nor demonstrably abandoned.
    static func spendBucket(status: OutcomeStatus?,
                            branchLastActivity: Date?,
                            now: Date,
                            staleness: TimeInterval) -> SpendBucket {
        switch status {
        case .merged, .pushed:
            return .shipped
        case .committed, .needsReview:
            if let last = branchLastActivity, now.timeIntervalSince(last) > staleness {
                return .abandoned
            }
            return .inFlight
        case .clean, .none:
            return .inFlight
        }
    }
}
