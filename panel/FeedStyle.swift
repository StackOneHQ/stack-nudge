import SwiftUI

// How feed events look in the Events tab and history: an icon per tag, a
// colour per severity, and a chip naming the source. Tags are open-ended
// strings from the feeds; one this table doesn't know gets the source's icon.
enum FeedStyle {

    static func symbol(for event: NudgeEvent) -> String {
        switch event.tag {
        case "review":         return "text.bubble.fill"
        case "review-request": return "person.crop.circle.badge.questionmark"
        case "ci":             return "gearshape.2.fill"
        case "ready":          return "checkmark.seal.fill"
        case "deploy":         return "shippingbox.fill"
        case "pipeline":       return "arrow.triangle.branch"
        case "calendar":       return "calendar"
        default:               return sourceSymbol(event.source)
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
