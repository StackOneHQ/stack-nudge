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
    // Built from the same labels the legend shows. Hardcoding "5h session" here
    // meant the tooltip contradicted the legend above it on any account whose
    // slots don't carry the windows we used to assume.
    var ringDescription: String {
        switch client {
        case .antigravity:
            return "Inner ring: model closest to its limit · Outer ring: monthly prompt credits"
        case .pi:
            return "Inner ring: model closest to today's budget · Outer ring: model closest to this week's"
        default:
            let inner = "Inner ring: \(Self.ringPhrase(shortLabel, short))"
            guard long != nil else { return inner }
            return "\(inner) · Outer ring: \(Self.ringPhrase(longLabel, long))"
        }
    }

    // "5h session quota" / "7d weekly quota", and just "1d quota" for a window
    // we have no word for — rather than calling it a session because of which
    // slot it arrived in.
    static func ringPhrase(_ label: String, _ tier: QuotaTier?) -> String {
        switch tier?.windowLength {
        case QuotaWindow.fiveHours: return "\(label) session quota"
        case QuotaWindow.sevenDays: return "\(label) weekly quota"
        default:                    return "\(label) quota"
        }
    }

    // The slot's old label only when no window is reported at all. A window we
    // haven't special-cased still gets named from its length, or the pill would
    // say "5h" while the Usage tab said "Current window (1d)" for one tier.
    static func ringLabel(_ tier: QuotaTier?, fallback: String) -> String {
        guard let length = tier?.windowLength else { return fallback }
        return QuotaWindow.shortName(length)
    }

    static func make(client: UsageClient?,
                     claude: QuotaSnapshot?,
                     codex: CodexQuotaSnapshot?,
                     antigravity: AntigravityQuotaSnapshot?,
                     pi: PiQuotaSnapshot?) -> WidgetQuota {
        switch client {
        case .claude:
            return WidgetQuota(client: .claude,
                               short: claude?.fiveHour, long: claude?.sevenDay,
                               shortLabel: "5h", longLabel: "7d")
        case .codex:
            // Named from the reported window: a hardcoded "5h" labelled a weekly
            // ring as a session one, contradicting the Usage tab.
            return WidgetQuota(client: .codex,
                               short: codex?.primary, long: codex?.secondary,
                               shortLabel: ringLabel(codex?.primary, fallback: "5h"),
                               longLabel: ringLabel(codex?.secondary, fallback: "7d"))
        case .antigravity:
            // agy reports no 5h/weekly pair — one window per model plus a
            // monthly credit pool. The model closest to its limit is the one
            // about to block you, so it takes the inner ring; the credit pool
            // is the only long-horizon number available for the outer.
            // Keep the identity and labels even with no snapshot, matching the
            // other two branches. Returning .empty here made a single dropped
            // loopback tick flip the tooltip back to "5h session quota" and lose
            // the "Agy" tag, while the Usage tab still said Antigravity.
            let worst = antigravity?.models
                .max(by: { $0.tier.utilization < $1.tier.utilization })
            return WidgetQuota(client: .antigravity,
                               short: worst?.tier,
                               long: creditsTier(antigravity?.promptCredits),
                               shortLabel: "now", longLabel: "mo")
        case .pi:
            // As with Antigravity, the model closest to its budget takes each
            // ring, since it's the one about to run out. Labels are named rather
            // than measured from the window: a DST day is 23 hours long, and
            // "23h" in a 35pt legend slot would be noise.
            let closest: ([PiModelUsage]?) -> QuotaTier? = { models in
                models?.max { $0.tier.utilization < $1.tier.utilization }?.tier
            }
            return WidgetQuota(client: .pi,
                               short: closest(pi?.today),
                               long: closest(pi?.thisWeek),
                               shortLabel: "1d", longLabel: "7d")
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
    // Short tag naming the client in the pill's hover legend. Claude carries one
    // too: leaving it blank made absence the label, so switching to Codex read
    // as a line appearing rather than as a change of client.
    var widgetTag: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Agy"
        case .pi:          return "Pi"
        }
    }
}
