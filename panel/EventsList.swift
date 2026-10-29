import SwiftUI

// Which feed tags the Events tab shows. Agent events are never filtered, so
// this only ever narrows the feed rows.
struct FeedTagFilter: Equatable {
    private(set) var hidden: Set<String> = []

    // Feeds send open-ended tags; an untagged event files under "other".
    static func key(for event: NudgeEvent) -> String {
        let tag = event.tag?.trimmingCharacters(in: .whitespaces) ?? ""
        return tag.isEmpty ? "other" : tag
    }

    // "review-request" reads as "Review request".
    static func label(_ tag: String) -> String {
        let words = tag.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // Tags of the feed events in the list, in the order chips show them.
    static func present(in events: [NudgeEvent]) -> [String] {
        Array(Set(events.filter(\.isFeed).map(key(for:)))).sorted { label($0) < label($1) }
    }

    func shows(_ tag: String) -> Bool { !hidden.contains(tag) }

    func allShown(among present: [String]) -> Bool { present.allSatisfy(shows) }

    func noneShown(among present: [String]) -> Bool {
        !present.isEmpty && !present.contains(where: shows)
    }

    mutating func toggle(_ tag: String) {
        if hidden.contains(tag) { hidden.remove(tag) } else { hidden.insert(tag) }
    }

    mutating func showOnly(_ tag: String, among present: [String]) {
        hidden = Set(present).subtracting([tag])
    }

    // The All/None chip: everything on turns everything off, otherwise on.
    mutating func toggleAll(among present: [String]) {
        hidden = allShown(among: present) ? Set(present) : []
    }

    // Keyboard cycle: All, then each tag on its own, then back to All.
    // Anything else (a hand-picked mix, or none) counts as All, so the first
    // press always lands on the first tag.
    mutating func cycle(among present: [String], forward: Bool) {
        guard present.count > 1 else { return }
        let shown = present.filter(shows)
        let current = shown.count == 1 ? (present.firstIndex(of: shown[0]) ?? -1) : -1
        var next = current + (forward ? 1 : -1)
        if next >= present.count { next = -1 }
        if next < -1 { next = present.count - 1 }
        if next == -1 { hidden = [] } else { showOnly(present[next], among: present) }
    }
}

// Timestamps and day headings for the Events list. The calendar is a
// parameter so tests can pin the time zone.
enum EventTime {

    // "now", "4m", "2h", "Yesterday", then "20 Oct".
    static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600))h" }
        if dayGap(date, now, calendar) == 1 { return "Yesterday" }
        return format(date, template: "dMMM", calendar: calendar)
    }

    // Today as relative; older with the clock time too: "Yesterday 18:05",
    // "Mon 07:45" within the week, "20 Oct 07:45" before that.
    static func listTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return relative(date, now: now, calendar: calendar) }
        let time = format(date, template: "Hm", calendar: calendar)
        switch dayGap(date, now, calendar) {
        case 1:      return "Yesterday \(time)"
        case 2..<7:  return "\(format(date, template: "EEE", calendar: calendar)) \(time)"
        default:     return "\(format(date, template: "dMMM", calendar: calendar)) \(time)"
        }
    }

    // The hover text: the whole date, to the minute.
    static func fullDate(_ date: Date, calendar: Calendar = .current) -> String {
        format(date, template: "EEEdMMMyHm", calendar: calendar)
    }

    // "Today", "Yesterday", the weekday within the week, then "20 Oct" (with
    // the year once it is not this one).
    static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        switch dayGap(date, now, calendar) {
        case 1:      return "Yesterday"
        case 2..<7:  return format(date, template: "EEEE", calendar: calendar)
        default:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            return format(date, template: sameYear ? "dMMM" : "dMMMy", calendar: calendar)
        }
    }

    private static func dayGap(_ date: Date, _ now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                to: calendar.startOfDay(for: now)).day ?? 99
    }

    private static func format(_ date: Date, template: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

// One entry of the rendered list: a day heading or an event.
enum EventListItem: Identifiable, Equatable {
    case day(String)
    case event(NudgeEvent)

    var id: String {
        switch self {
        case .day(let title): return "day:\(title)"
        case .event(let event): return event.id.uuidString
        }
    }

    // Headings only appear once there is a feed event on show, so a queue of
    // nothing but agent prompts looks as it always has. The list is newest
    // first, so a heading goes in wherever the day changes.
    static func items(_ events: [NudgeEvent], now: Date, calendar: Calendar = .current) -> [EventListItem] {
        guard events.contains(where: \.isFeed) else { return events.map(EventListItem.event) }
        var out: [EventListItem] = []
        var lastDay: Date?
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            if day != lastDay {
                out.append(.day(EventTime.dayTitle(event.timestamp, now: now, calendar: calendar)))
                lastDay = day
            }
            out.append(.event(event))
        }
        return out
    }
}

struct DaySeparator: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// Relative time with the full date on hover.
struct EventTimeLabel: View {
    let date: Date

    var body: some View {
        Text(EventTime.listTime(date, now: Date()))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(EventTime.fullDate(date))
    }
}

// One chip per feed tag present, plus All/None. Option-click shows that tag
// only.
struct FeedTagChips: View {
    @ObservedObject var store: EventStore

    var body: some View {
        let present = store.presentTags
        if !present.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(label: store.tagFilter.allShown(among: present) ? "None" : "All",
                         symbol: nil, count: 0, on: false) {
                        store.tagFilter.toggleAll(among: present)
                    }
                    ForEach(present, id: \.self) { tag in
                        chip(label: FeedTagFilter.label(tag),
                             symbol: FeedStyle.symbol(tag: tag, source: sourceSymbolSource(tag)),
                             count: store.unreadCount(forTag: tag),
                             on: store.tagFilter.shows(tag)) {
                            if NSEvent.modifierFlags.contains(.option) {
                                store.tagFilter.showOnly(tag, among: present)
                            } else {
                                store.tagFilter.toggle(tag)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            Divider().opacity(0.4)
        }
    }

    // A tag the style table does not know gets its source's icon.
    private func sourceSymbolSource(_ tag: String) -> EventSource {
        store.events.first { $0.isFeed && FeedTagFilter.key(for: $0) == tag }?.source ?? .script
    }

    private func chip(label: String, symbol: String?, count: Int, on: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(label).font(.caption.weight(.medium))
                if count > 0 { Text("\(count)").font(.caption2.monospacedDigit()).opacity(0.7) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("Click to toggle, option-click to show only this")
    }
}

// What the list says when there is nothing to list: caught up after Clear
// all, or the filter hiding everything that is there.
struct EventsNoticeView: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
