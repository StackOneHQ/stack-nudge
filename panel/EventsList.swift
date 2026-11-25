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

    // "review-request" reads as "Review request"; acronyms stay in capitals ("CI", "PR closed").
    static func label(_ tag: String) -> String {
        let words = tag.split(separator: "-").map { word in
            acronyms.contains(word.lowercased()) ? word.uppercased() : String(word)
        }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static let acronyms: Set<String> = ["ci", "pr", "ai", "ui", "api", "mcp"]

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

    // One chip's action, shared by the mouse and the keyboard so the two
    // cannot drift: a plain press toggles, `only` shows just that tag. On the
    // All/None chip `only` means nothing more than a plain press.
    mutating func apply(_ chip: FeedChip, only: Bool, among present: [String]) {
        switch chip {
        case .all:           toggleAll(among: present)
        case .tag(let tag):  if only { showOnly(tag, among: present) } else { toggle(tag) }
        }
    }
}

// A stop in the chip row: the All/None chip first, then one per tag present.
enum FeedChip: Hashable {
    case all
    case tag(String)

    static func row(among present: [String]) -> [FeedChip] { [.all] + present.map(FeedChip.tag) }

    // Where F lands: the chip last used, or the first one when there is none
    // or its tag has gone.
    static func focusTarget(last: FeedChip?, among present: [String]) -> FeedChip {
        guard let last, row(among: present).contains(last) else { return .all }
        return last
    }

    // ←→ stop at the ends rather than wrap, so the row's edges stay findable.
    func moved(by delta: Int, among present: [String]) -> FeedChip {
        let chips = FeedChip.row(among: present)
        let index = chips.firstIndex(of: self) ?? 0
        return chips[min(max(index + delta, 0), chips.count - 1)]
    }
}

// What a keystroke does while the chip row has the keyboard.
enum FeedChipKeyAction: Equatable {
    case move(Int)
    case toggle
    case only
    case back
    // List keys must not act on a list the user is not looking at.
    case swallow
}

// Timestamps for the Events list. The calendar is a
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

    private static func dayGap(_ date: Date, _ now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                to: calendar.startOfDay(for: now)).day ?? 99
    }

    private struct FormatterKey: Hashable {
        let template: String
        let calendar: Calendar
    }

    // Building a DateFormatter is slow, and every visible row formats a date
    // or two per render, so scrolling rebuilt dozens of them a frame.
    private static let formatters = NSLock()
    private static var cache: [FormatterKey: DateFormatter] = [:]

    private static func format(_ date: Date, template: String, calendar: Calendar) -> String {
        formatters.lock()
        defer { formatters.unlock() }
        let key = FormatterKey(template: template, calendar: calendar)
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            cache[key] = formatter
        }
        return formatter.string(from: date)
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
// only. `focused` is the chip the keyboard is on, nil while the list has it.
struct FeedTagChips: View {
    @ObservedObject var store: EventStore
    var focused: FeedChip?

    var body: some View {
        let present = store.presentTags
        if !present.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        allChip(present: present)
                        ForEach(present, id: \.self) { tag in
                            tagChip(tag, present: present)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .onChange(of: focused) { chip in
                    if let chip { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(chip) } }
                }
            }
            Divider().opacity(0.4)
        }
    }

    private func allChip(present: [String]) -> some View {
        chip(.all, label: store.tagFilter.allShown(among: present) ? "None" : "All",
             symbol: nil, count: 0, color: nil, on: false, present: present)
    }

    private func tagChip(_ tag: String, present: [String]) -> some View {
        let source = sourceForTag(tag)
        return chip(.tag(tag), label: FeedTagFilter.label(tag),
                    symbol: FeedStyle.symbol(tag: tag, source: source),
                    count: store.unreadCount(forTag: tag),
                    color: FeedStyle.color(tag: tag, source: source),
                    on: store.tagFilter.shows(tag), present: present)
    }

    // A tag the style table does not know gets its source's icon and colour.
    private func sourceForTag(_ tag: String) -> EventSource {
        store.events.first { $0.isFeed && FeedTagFilter.key(for: $0) == tag }?.source ?? .script
    }

    // Included: the tag's colour, softly filled. Excluded: outlined in it with
    // quiet text. All/None has no tag, so it stays neutral.
    private func chip(_ target: FeedChip, label: String, symbol: String?, count: Int,
                      color: Color?, on: Bool, present: [String]) -> some View {
        let tint = color ?? .secondary
        let lit = color != nil && on
        return Button {
            store.tagFilter.apply(target, only: NSEvent.modifierFlags.contains(.option), among: present)
        } label: {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(label).font(.caption2.weight(.medium))
                if count > 0 { Text("\(count)").font(.caption2.monospacedDigit()).opacity(0.7) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(lit ? tint : Color.secondary)
            .background(Capsule().fill(lit ? tint.opacity(0.16)
                                           : color == nil ? Color.primary.opacity(0.06) : Color.clear))
            .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: color != nil && !on ? 1 : 0))
            .overlay(Capsule().inset(by: -2).strokeBorder(Color.accentColor,
                                                          lineWidth: focused == target ? 1.5 : 0))
        }
        .buttonStyle(.plain)
        .id(target)
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
