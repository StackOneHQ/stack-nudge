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

    static func string(_ date: Date,
                       style: RelativeDateTimeFormatter.UnitsStyle = .abbreviated) -> String {
        let formatter: RelativeDateTimeFormatter
        switch style {
        case .short: formatter = shortStyle
        case .full:  formatter = full
        default:     formatter = abbreviated
        }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
