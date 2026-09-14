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

// How long until a quota tier resets.
//
// Every accessor returns nil once the deadline has passed. A past reset means the
// snapshot is stale, not that the reset is imminent — the widget's old formatter
// floored at "1m" and showed a held-over snapshot as a live countdown forever.
enum QuotaReset {

    static func remaining(until date: Date, now: Date = Date()) -> TimeInterval? {
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? seconds : nil
    }

    // Widget pill: "2h24m", "2h", "14m".
    static func shortLabel(until date: Date, now: Date = Date()) -> String? {
        guard let remaining = remaining(until: date, now: now) else { return nil }
        let seconds = Int(remaining)
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        return "\(max(1, seconds / 60))m"  // sub-minute is genuinely about to reset
    }

    // Countdown half of the reset line: "in 2 hours".
    static func relativeLabel(until date: Date, now: Date = Date()) -> String? {
        guard remaining(until: date, now: now) != nil else { return nil }
        return RelativeTime.string(date, style: .full, relativeTo: now)
    }

    // Clock half, in the shape Claude Code's own /usage prints: "Jun 30 at
    // 6:50pm", or "Jul 4 at 3am" when the reset lands on the hour. Codex
    // reports its reset as a unix timestamp and Antigravity as ISO 8601, so
    // normalising here is what makes one client's reset read like another's.
    //
    // The locale and the two formats are parseResetsAt's, run in reverse: what
    // this renders, that parser reads back.
    //
    // Rendered in `timeZone`, the machine's by default. Claude's CLI prints the
    // timezone held on the account instead, so the two disagree while
    // travelling; local is the timezone the countdown is measured against.
    static func absoluteLabel(until date: Date,
                              now: Date = Date(),
                              timeZone: TimeZone = .current) -> String? {
        guard remaining(until: date, now: now) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Built fresh per call rather than mutating a shared cached formatter:
        // DateFormatter mutation isn't thread-safe, and stamping timeZone into a
        // static on the way through would hand the next (possibly off-main)
        // caller a quietly wrong string. Two calls per render is cheap.
        let formatter = calendar.component(.minute, from: date) == 0
            ? absoluteFormatter("MMM d 'at' ha")
            : absoluteFormatter("MMM d 'at' h:mma")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    // Both halves: "in 2 hours · Jun 30 at 6:50pm". The countdown says how long
    // you're blocked, the clock time says when to come back; the Usage tab and
    // the quota banner both want the pair.
    static func fullLabel(until date: Date,
                          now: Date = Date(),
                          timeZone: TimeZone = .current) -> String? {
        guard let relative = relativeLabel(until: date, now: now),
              let absolute = absoluteLabel(until: date, now: now, timeZone: timeZone)
        else { return nil }
        return "\(relative) · \(absolute)"
    }

    // Claude prints "3am" on the hour and "6:50pm" otherwise, so matching it
    // takes two formats. absoluteLabel picks the format and builds one per call
    // so nothing shared is mutated; the caller stamps the timezone in.
    private static func absoluteFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // Fixed English, like the CLI line this mirrors and like the parser
        // that reads it back. The symbols have to be set after the locale,
        // which stamps its own over them.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter

    // How far through its window a tier is, 0…1. Shares `remaining`'s
    // past-deadline rule: a stale snapshot draws no marker rather than one
    // pinned confidently to the far right.
    static func elapsedFraction(until date: Date,
                                windowLength: TimeInterval,
                                now: Date = Date()) -> Double? {
        guard windowLength > 0, let remaining = remaining(until: date, now: now) else { return nil }
        // Clamped, not rejected: a window longer than we assume pins to the start.
        return min(1, max(0, 1 - remaining / windowLength))
    }
}

// Names a quota window by its length. Codex reports length, not kind, and the
// slot→window mapping isn't fixed — see CodexUsage.tier.
enum QuotaWindow {

    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 24 * 3600

    static func title(windowLength: TimeInterval) -> String {
        switch windowLength {
        case fiveHours: return "Current session (5h)"
        case sevenDays: return "Current week"
        default:        return "Current window (\(describe(windowLength)))"
        }
    }

    private static func describe(_ length: TimeInterval) -> String {
        let minutes = Int(length.rounded() / 60)
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"    }
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

    // Callers that inject a clock pass `relativeTo` so the rendered string agrees
    // with the decision that produced it.
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
