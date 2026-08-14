import Foundation

// Shared number formatting so the same token rendering isn't re-implemented per
// view. Callers append " tokens" etc. as needed.
enum TokenFormat {
    // Abbreviated count: "1.2M" / "218K" / "42".
    static func short(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))K" }
        return "\(count)"
    }
}

// Display form of a model id: drop the redundant "claude-" vendor prefix and any
// trailing "-YYYYMMDD" date stamp. "claude-haiku-4-5-20251001" → "haiku-4-5",
// "claude-opus-5" → "opus-5". A non-claude id (e.g. "gpt-5-codex") keeps its name,
// minus a trailing date stamp.
enum ModelName {
    static func short(_ id: String) -> String {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        if let dash = name.range(of: "-2", options: .backwards),
           name[dash.lowerBound...].dropFirst().allSatisfy(\.isNumber) {
            name = String(name[..<dash.lowerBound])
        }
        return name
    }
}

// How long until a quota tier resets, rendered for whichever surface is asking.
//
// Every accessor returns nil once the deadline has passed. That guard lives here
// rather than at each call site because it used to live at none of them: the
// widget's countdown floored at "1m" (`max(1, seconds / 60)`), so an expired or
// held-over snapshot read as a live one-minute countdown forever, and the Usage
// tab rendered "Resets 11 months ago" verbatim. A past reset means the snapshot
// is stale, not that the reset is imminent, so the honest answer is "we don't
// know" and callers fall back to their own empty state.
//
// `now` is injected so the boundary behaviour is testable without freezing the
// clock.
enum QuotaReset {

    // Seconds remaining, or nil once the deadline has passed.
    static func remaining(until date: Date, now: Date = Date()) -> TimeInterval? {
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? seconds : nil
    }

    // Compact countdown for the widget pill: "2h24m", "2h", "14m".
    static func shortLabel(until date: Date, now: Date = Date()) -> String? {
        guard let remaining = remaining(until: date, now: now) else { return nil }
        let seconds = Int(remaining)
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        // Anything under a minute still reads as "1m" rather than "0m" — it is
        // genuinely about to reset, which is the one case the old floor got right.
        return "\(max(1, seconds / 60))m"
    }

    // Prose form for the Usage tab and banners: "in 2 hours".
    static func relativeLabel(until date: Date, now: Date = Date()) -> String? {
        guard remaining(until: date, now: now) != nil else { return nil }
        return RelativeTime.string(date, style: .full, relativeTo: now)
    }
}

// Shared relative-time strings ("5m ago", "in 3 days") with per-style cached
// formatters (these were re-created in CompactView / Sessions / SessionUsage /
// Panel). Formatters are reused on the main thread, matching prior usage.
enum RelativeTime {
    private static let shortStyle      = make(.short)
    private static let abbreviated     = make(.abbreviated)
    private static let full            = make(.full)

    private static func make(_ style: RelativeDateTimeFormatter.UnitsStyle) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        return formatter
    }

    // `relativeTo` defaults to now; callers that inject a clock (QuotaReset, and
    // tests through it) pass their own so the rendered string agrees with the
    // decision that produced it.
    static func string(_ date: Date,
                       style: RelativeDateTimeFormatter.UnitsStyle = .abbreviated,
                       relativeTo reference: Date = Date()) -> String {
        let formatter: RelativeDateTimeFormatter
        switch style {
        case .short: formatter = shortStyle
        case .full:  formatter = full
        default:     formatter = abbreviated
        }
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
