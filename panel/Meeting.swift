import Foundation

// One upcoming meeting occurrence. `id` is the calendar item plus the original
// occurrence start for recurring events.
struct Meeting: Codable, Equatable {
    var id: String
    var itemId: String
    var title: String
    var start: Date
    var end: Date
    var location: String
    var organizer: String
    var joinUrl: String
    var calendar: String
    // When the event was created in the calendar; nil for snapshots saved before this field existed.
    var created: Date? = nil
    var notes: String? = nil
    var eventUrl: String? = nil
    var attendeeCount: Int? = nil

    // What opening it goes to: the join link, else the event in Calendar.app
    // (which just opens Calendar if the id is unknown).
    var link: String { joinUrl.isEmpty ? calendarUrl : joinUrl }

    var calendarUrl: String {
        let escaped = itemId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? itemId
        return "ical://ekevent/\(escaped)?method=show"
    }

    // Notes as one plain line, for a row that has no room for the invite's HTML.
    func notesSnippet(limit: Int = 160) -> String {
        guard let notes else { return "" }
        let flat = MeetingText.plain(notes).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
    }
}

// What the app says about a meeting. `key` is set when a later notice about the
// same thing should replace this one in the queue rather than stack.
struct MeetingNotice: Equatable {
    let kind: String
    let severity: EventSeverity
    let title: String
    let body: String
    let url: String
    var key: String? = nil

    func event(now: Date = Date()) -> NudgeEvent {
        .feed(source: .calendar, tag: "calendar", severity: severity, title: title, message: body,
              url: URL(string: url), key: key, timestamp: now)
    }
}

enum MeetingDiff {
    static let horizon: TimeInterval = 24 * 3600

    // A reminder stays up this long after the start, then goes: by then the
    // meeting is either joined or missed.
    static let reminderTail: TimeInterval = 300

    private static func format(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = template
        return f.string(from: date)
    }

    static func clock(_ date: Date) -> String { format(date, "HH:mm") }
    static func weekdayTime(_ date: Date) -> String { format(date, "EEE HH:mm") }

    // How long a meeting must stay missing before it counts as cancelled; a
    // calendar re-sync can drop events briefly.
    static let cancelGrace: TimeInterval = 300

    // The same meeting under a new id: a re-sync can reissue EventKit identifiers.
    static func sameSlot(_ a: Meeting, _ b: Meeting) -> Bool { a.title == b.title && a.start == b.start && a.end == b.end }

    // Upcoming meetings missing from `new` by id that are not the same meeting under a new id.
    static func missing(old: [Meeting], new: [Meeting], now: Date) -> [Meeting] {
        let ids = Set(new.map(\.id))
        return old.filter { m in !ids.contains(m.id) && m.end > now && !new.contains { sameSlot($0, m) } }
    }

    // Missing meetings not yet past the grace period: kept in the saved snapshot with when they first went missing.
    static func held(old: [Meeting], new: [Meeting], now: Date, missingSince: [String: Date]) -> [String: Date] {
        var out: [String: Date] = [:]
        for m in missing(old: old, new: new, now: now) {
            let since = missingSince[m.id] ?? now
            if now.timeIntervalSince(since) < cancelGrace { out[m.id] = since }
        }
        return out
    }

    // `since` is the previous refresh: a meeting that only shows up now but was
    // created long before arrived through a slow initial sync, so it is not
    // announced as new. `missingSince` (when given) holds cancellations back
    // until a meeting has been missing for `cancelGrace`.
    static func diff(old: [Meeting], new: [Meeting], now: Date, since: Date? = nil, missingSince: [String: Date]? = nil) -> [MeetingNotice] {
        let oldById = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [MeetingNotice] = []

        for m in new.sorted(by: { $0.start < $1.start }) {
            guard let before = oldById[m.id] else {
                guard m.start > now, !old.contains(where: { sameSlot($0, m) }) else { continue }
                if let created = m.created, let since, created < since.addingTimeInterval(-600) { continue }
                out.append(MeetingNotice(kind: "meeting-added", severity: .info,
                                         title: "New meeting: \(m.title)",
                                         body: [weekdayTime(m.start), m.organizer].filter { !$0.isEmpty }.joined(separator: ", "),
                                         url: m.link))
                continue
            }
            let changes = describe(from: before, to: m)
            guard !changes.isEmpty, m.end > now else { continue }
            let soon = m.start > now && m.start.timeIntervalSince(now) <= horizon
            out.append(MeetingNotice(kind: "meeting-changed", severity: soon ? .action : .info,
                                     title: "Meeting changed: \(m.title)", body: changes.joined(separator: "\n"), url: m.link))
        }

        for m in missing(old: old, new: new, now: now).sorted(by: { $0.start < $1.start }) {
            if let missingSince, now.timeIntervalSince(missingSince[m.id] ?? now) < cancelGrace { continue }
            out.append(MeetingNotice(kind: "meeting-cancelled", severity: .info,
                                     title: "Meeting cancelled: \(m.title)", body: weekdayTime(m.start), url: m.link))
        }
        return out
    }

    // One "before → after" line per changed field; the title already carries the new name.
    static func describe(from a: Meeting, to b: Meeting) -> [String] {
        var changes: [String] = []
        if a.start != b.start || a.end != b.end {
            let sameDay = Calendar.current.isDate(a.start, inSameDayAs: b.start)
            func span(_ m: Meeting) -> String { "\(sameDay ? clock(m.start) : weekdayTime(m.start))\u{2013}\(clock(m.end))" }
            changes.append("\(span(a)) \u{2192} \(span(b))")
        }
        if a.title != b.title { changes.append("Was \u{201C}\(a.title)\u{201D}") }
        if a.location != b.location {
            func place(_ s: String) -> String { s.isEmpty ? "none" : (s.count > 40 ? String(s.prefix(39)) + "\u{2026}" : s) }
            changes.append("Location: \(place(a.location)) \u{2192} \(place(b.location))")
        }
        return changes
    }

    static func isJoinUrl(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..., in: url)
        return joinPatterns.contains { $0.firstMatch(in: url, range: range) != nil }
    }

    // Also the queue key of the meeting's reminder, so the heads-up, the start
    // alert and the removal on joining all name the same row.
    static func dueKey(_ m: Meeting) -> String { "meeting:\(m.id):\(Int(m.start.timeIntervalSince1970))" }

    // Meetings inside their heads-up window that have not fired yet.
    static func due(_ meetings: [Meeting], fired: Set<String>, lead: TimeInterval, now: Date) -> [Meeting] {
        meetings.filter { $0.start > now && $0.start.timeIntervalSince(now) <= lead && !fired.contains(dueKey($0)) }
    }

    // When the single heads-up timer should next fire.
    static func nextDue(_ meetings: [Meeting], fired: Set<String>, lead: TimeInterval, now: Date) -> Date? {
        meetings.filter { !fired.contains(dueKey($0)) }
            .map { $0.start.addingTimeInterval(-lead) }
            .filter { $0 > now }
            .min()
    }

    // Meetings that have started, were warned about, and have not had their start alert yet.
    static func startDue(_ meetings: [Meeting], fired: Set<String>, started: Set<String>, now: Date) -> [Meeting] {
        meetings.filter {
            let key = dueKey($0)
            return fired.contains(key) && !started.contains(key) && $0.start <= now && now < $0.start.addingTimeInterval(reminderTail)
        }
    }

    // Warned-about meetings whose reminder is past its tail and should leave the queue.
    static func expired(_ meetings: [Meeting], fired: Set<String>, now: Date) -> [Meeting] {
        meetings.filter { fired.contains(dueKey($0)) && now >= $0.start.addingTimeInterval(reminderTail) }
    }

    // The next start alert or expiry among warned-about meetings, for the shared timer.
    static func nextReminderStep(_ meetings: [Meeting], fired: Set<String>, started: Set<String>, now: Date) -> Date? {
        meetings.filter { fired.contains(dueKey($0)) }.flatMap { m -> [Date] in
            var steps = [m.start.addingTimeInterval(reminderTail)]
            if !started.contains(dueKey(m)) { steps.append(m.start) }
            return steps
        }.filter { $0 > now }.min()
    }

    static func soonNotice(_ m: Meeting, now: Date) -> MeetingNotice {
        let minutes = max(1, Int((m.start.timeIntervalSince(now) / 60).rounded(.up)))
        return MeetingNotice(kind: "meeting-soon", severity: .action, title: "\(m.title) starts in \(minutes) min",
                             body: soonBody(m), url: m.link, key: dueKey(m))
    }

    // Replaces the heads-up under the same key, so it is one row that escalates.
    static func startNotice(_ m: Meeting) -> MeetingNotice {
        MeetingNotice(kind: "meeting-started", severity: .alert, title: "\(m.title) is starting now",
                      body: soonBody(m), url: m.link, key: dueKey(m))
    }

    private static func soonBody(_ m: Meeting) -> String {
        ["\(clock(m.start)) to \(clock(m.end))", m.location].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static let joinPatterns: [NSRegularExpression] = [
        #"https?://meet\.google\.com/[a-z0-9-]+[^\s"'<>)]*"#,
        #"https?://[\w.-]*zoom\.(?:us|com)/(?:j|my|wc|s)/[^\s"'<>)]+"#,
        #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[^\s"'<>)]+"#,
        #"https?://[\w.-]*webex\.com/[^\s"'<>)]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    // First conferencing link in the given texts, tried in order (url field, location, notes).
    static func joinUrl(in texts: [String?]) -> String {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for re in joinPatterns {
                if let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                    return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                }
            }
        }
        return ""
    }
}

// Morning summary preferences; read from the nav settings, never persisted here.
struct SummarySettings: Equatable {
    var enabled = true
    var minutes = 9 * 60
    var weekdaysOnly = true
    var announceEmpty = false

    static let times = [8 * 60, 8 * 60 + 30, 9 * 60, 9 * 60 + 30, 10 * 60]

    static func label(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

extension MeetingDiff {
    // A late summary (after wake or a relaunch) is dropped once it is past this hour.
    static let summaryCutoffHour = 12
    static let summaryMaxListed = 3

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func at(_ date: Date, minutes: Int, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date) ?? date
    }

    private static func allowed(_ day: Date, _ s: SummarySettings, calendar: Calendar) -> Bool {
        !(s.weekdaysOnly && calendar.isDateInWeekend(day))
    }

    // Whether today's summary should go out on this refresh: past the set time, before noon, once per day.
    static func summaryDue(now: Date, settings s: SummarySettings, lastDate: String?, calendar: Calendar = .current) -> Bool {
        guard s.enabled, allowed(now, s, calendar: calendar), lastDate != dayKey(now, calendar: calendar) else { return false }
        return now >= at(now, minutes: s.minutes, calendar: calendar) && now < at(now, minutes: summaryCutoffHour * 60, calendar: calendar)
    }

    // When the summary next becomes due, for the shared timer; nil when disabled.
    static func nextSummaryDue(now: Date, settings s: SummarySettings, lastDate: String?, calendar: Calendar = .current) -> Date? {
        guard s.enabled else { return nil }
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now), allowed(day, s, calendar: calendar) else { continue }
            if offset == 0, lastDate == dayKey(now, calendar: calendar) { continue }
            let due = at(day, minutes: s.minutes, calendar: calendar)
            if due > now { return due }
        }
        return nil
    }

    // Today's meetings from the snapshot, in start order.
    static func todaysMeetings(_ meetings: [Meeting], now: Date, calendar: Calendar = .current) -> [Meeting] {
        meetings.filter { calendar.isDate($0.start, inSameDayAs: now) }.sorted { $0.start < $1.start }
    }

    static func agenda(_ meetings: [Meeting]) -> String {
        var parts = meetings.prefix(summaryMaxListed).map { "\(clock($0.start)) \($0.title)" }
        if meetings.count > summaryMaxListed { parts.append("+\(meetings.count - summaryMaxListed) more") }
        return parts.joined(separator: ", ")
    }

    // nil when there is nothing to say (no meetings and empty days not wanted).
    static func summaryNotice(_ meetings: [Meeting], now: Date, announceEmpty: Bool, calendar: Calendar = .current) -> MeetingNotice? {
        let today = todaysMeetings(meetings, now: now, calendar: calendar)
        let key = "meeting-summary:\(dayKey(now, calendar: calendar))"
        if today.isEmpty {
            return announceEmpty ? MeetingNotice(kind: "meeting-summary", severity: .info, title: "No meetings today", body: "", url: summaryUrl, key: key) : nil
        }
        let title = today.count == 1 ? "Today: 1 meeting" : "Today: \(today.count) meetings"
        return MeetingNotice(kind: "meeting-summary", severity: .info, title: title, body: agenda(today), url: summaryUrl, key: key)
    }

    static let summaryUrl = "ical://"
}

extension Array where Element == Meeting {
    // The same meeting often appears in two selected calendars (a shared team
    // calendar plus the user's own invite copy). Keep one per title and time,
    // preferring the copy with a join link.
    func dedupedByOccurrence() -> [Meeting] {
        var best: [String: Meeting] = [:]
        var order: [String] = []
        for m in self {
            let key = "\(m.title.lowercased())|\(Int(m.start.timeIntervalSince1970))|\(Int(m.end.timeIntervalSince1970))"
            if let kept = best[key] {
                if kept.joinUrl.isEmpty && !m.joinUrl.isEmpty { best[key] = m }
            } else {
                best[key] = m
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }
}
