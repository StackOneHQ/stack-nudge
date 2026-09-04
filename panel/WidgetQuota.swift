import Foundation

// What the compact widget's gauge needs from whichever client the Usage tab
// has selected. The pill has room for exactly two rings and one countdown, so
// each client's tiers are reduced to a short window (inner ring) and a long
// window (outer ring) here rather than in the view — the mapping differs per
// client and is worth testing without standing up SwiftUI.
struct WidgetQuota: Equatable {
    let client: UsageClient?
    let short: QuotaTier?
    let long: QuotaTier?
    // Two- to three-character legend prefixes ("5h 50%"). The pill's legend
    // slot is ~35pt wide in usage mode, so anything longer squeezes the
    // expand button.
    let shortLabel: String
    let longLabel: String

    static let empty = WidgetQuota(client: nil, short: nil, long: nil,
                                   shortLabel: "5h", longLabel: "7d")

    var hasData: Bool { short != nil || long != nil }

    // Border urgency, pulse rate and the pill's refresh cadence all key off
    // the short window alone — that's the one that blocks you first, and it
    // preserves the pre-multi-client behaviour where those read `fiveHour`.
    var shortUtilization: Double { short?.utilization ?? 0 }

    // The mascot's stress signal instead keys off whichever window is tighter,
    // matching the old `five >= 75 || seven >= 75`.
    var peakUtilization: Double {
        max(short?.utilization ?? 0, long?.utilization ?? 0)
    }

    // The pill counts down to the short window's reset, since that's the one
    // that frees up first.
    var countdownTarget: Date? { short?.resetsAt }

    // Tooltip describing what the two rings mean for this client. Claude and
    // Codex share a 5h/weekly shape; Antigravity's rings mean something else
    // entirely, so the help text can't be a constant.
    var ringDescription: String {
        switch client {
        case .antigravity:
            return "Inner ring: model closest to its limit · Outer ring: monthly prompt credits"
        default:
            return "Inner ring: 5h session quota · Outer ring: 7d weekly quota"
        }
    }

    static func make(client: UsageClient?,
                     claude: QuotaSnapshot?,
                     codex: CodexQuotaSnapshot?,
                     antigravity: AntigravityQuotaSnapshot?) -> WidgetQuota {
        switch client {
        case .claude:
            return WidgetQuota(client: .claude,
                               short: claude?.fiveHour, long: claude?.sevenDay,
                               shortLabel: "5h", longLabel: "7d")
        case .codex:
            return WidgetQuota(client: .codex,
                               short: codex?.primary, long: codex?.secondary,
                               shortLabel: "5h", longLabel: "7d")
        case .antigravity:
            // agy reports no 5h/weekly pair — one window per model plus a
            // monthly credit pool. The model closest to its limit is the one
            // about to block you, so it takes the inner ring; the credit pool
            // is the only long-horizon number available for the outer.
            guard let antigravity else { return .empty }
            let worst = antigravity.models
                .max(by: { $0.tier.utilization < $1.tier.utilization })
            return WidgetQuota(client: .antigravity,
                               short: worst?.tier,
                               long: creditsTier(antigravity.promptCredits),
                               shortLabel: "now", longLabel: "mo")
        case nil:
            return .empty
        }
    }

    // Credits are reported as "available of monthly", the inverse of the
    // utilization every other tier uses. No reset time is published, so the
    // countdown falls through to the short window.
    private static func creditsTier(_ credits: AntigravityQuotaSnapshot.Credits?) -> QuotaTier? {
        guard let credits, credits.monthly > 0 else { return nil }
        let used = Double(credits.monthly - credits.available) / Double(credits.monthly) * 100
        return QuotaTier(utilization: max(0, min(100, used)), resetsAt: nil)
    }
}

extension UsageClient {
    // Short tag naming the client in the pill's hover legend. nil for Claude:
    // it's the default selection, so labelling it would put a line on every
    // pill belonging to a user who never switches client.
    var widgetTag: String? {
        switch self {
        case .claude:      return nil
        case .codex:       return "Codex"
        case .antigravity: return "Agy"
        }
    }
}
