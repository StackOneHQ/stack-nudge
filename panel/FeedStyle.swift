import SwiftUI

// How feed events look in the Events tab and history: an icon per tag, a
// colour per tag, a colour per severity, and a chip naming the source. Tags
// are open-ended strings from the feeds; one this table doesn't know gets the
// source's icon and colour.
enum FeedStyle {

    static func symbol(for event: NudgeEvent) -> String {
        symbol(tag: event.tag, source: event.source)
    }

    static func symbol(tag: String?, source: EventSource) -> String {
        switch tag {
        case "review":         return "text.bubble.fill"
        case "review-request": return "person.crop.circle.badge.questionmark"
        case "ci":             return "gearshape.2.fill"
        case "ready":          return "checkmark.seal.fill"
        case "deploy":         return "shippingbox.fill"
        case "pipeline":       return "arrow.triangle.branch"
        case "calendar":       return "calendar"
        default:               return sourceSymbol(source)
        }
    }

    // One colour per known tag, shared by the row icon and the filter chip so
    // the two match. System colours adapt to light and dark. A tag the table
    // does not know takes its source's colour.
    static func color(tag: String?, source: EventSource) -> Color {
        switch tag?.trimmingCharacters(in: .whitespaces) {
        case "review":         return .blue
        case "review-request": return .purple
        case "ci":             return .orange
        case "ready":          return .green
        case "deploy":         return .brown
        case "pipeline":       return .indigo
        case "calendar":       return .mint
        case "plan":           return .teal
        case "audit":          return .pink
        default:               return sourceColor(source)
        }
    }

    static func sourceColor(_ source: EventSource) -> Color {
        switch source {
        case .github:   return .blue
        case .calendar: return .mint
        case .ai:       return .purple
        case .script:   return .gray
        case .agent:    return .secondary
        }
    }

    static func sourceSymbol(_ source: EventSource) -> String {
        switch source {
        case .github:   return "chevron.left.forwardslash.chevron.right"
        case .calendar: return "calendar"
        case .script:   return "terminal.fill"
        case .agent:    return "checkmark.circle.fill"
        }
    }

    // Semantic, not themed: an alert reads red whatever the accent colour.
    static func color(for severity: EventSeverity) -> Color {
        switch severity {
        case .info:   return .secondary
        case .action: return .orange
        case .alert:  return .red
        }
    }

    static func chip(for event: NudgeEvent) -> String {
        var label = event.source.label
        if let repo = event.repo, !repo.isEmpty {
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            label += " · " + name + (event.pr.map { "#\($0)" } ?? "")
        }
        return label
    }
}
