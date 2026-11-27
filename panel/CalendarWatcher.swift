import AppKit
import EventKit
import Foundation

// What the watcher reads from Settings, as one value so a change is one comparison.
struct CalendarSettings: Equatable {
    var leadMinutes = 10
    var summary = SummarySettings()
    var detectJoin = true
    // Calendar identifiers to watch; empty means every calendar.
    var calendarIds: [String] = []

    static let leadOptions = [5, 10, 15]
}

enum CalendarAccess: Equatable {
    case granted, notDetermined, denied
}

// Persisted as ~/.stack-nudge/calendar.json.
struct CalendarState: Codable {
    var version = 1
    var updatedAt: Date
    var calendars: String
    var events: [Meeting]
    var soonFired: [String]
    // Meetings whose start alert went out, or that were joined before it did.
    var startFired: [String]? = nil
    // Day key (yyyy-MM-dd) of the last morning summary, sent or skipped for having no meetings.
    var summaryDate: String? = nil
    // Meetings missing since a refresh, held in `events` until `MeetingDiff.cancelGrace` confirms the cancellation.
    var missingSince: [String: Date]? = nil
}

// Mirrors the user's synced calendars from EventKit into meeting events.
// Read-only and local: no calendar API, nothing leaves the Mac. Main thread only.
final class CalendarWatcher {
    private static let window: TimeInterval = 7 * 24 * 3600
    private static let notesCap = 8000
    private static let staleAfter: TimeInterval = 24 * 3600

    private let events: EventStore
    private let settings: () -> CalendarSettings
    private let clock: () -> Date
    private let stateDir: String
    private let onToday: ([Meeting]) -> Void
    private let onAccess: (CalendarAccess) -> Void
    private var joinWatcher: JoinWatcher!
    // Lazy so that building the watcher never touches the calendar; EventKit is
    // first reached from start(), i.e. once the user has turned the feature on.
    private lazy var ek = EKEventStore()
    private var statePath: String { stateDir + "/calendar.json" }
    private var logPath: String { stateDir + "/calendar.log" }

    private var state: CalendarState?
    private var started = false
    private var requested = false
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var soonTimer: Timer?
    private var debounce: DispatchWorkItem?
    private(set) var granted = false
    private(set) var access: CalendarAccess = .notDetermined

    init(events: EventStore, settings: @escaping () -> CalendarSettings,
         clock: @escaping () -> Date = { Date() },
         stateDir: String = NSHomeDirectory() + "/.stack-nudge",
         detector: JoinDetector = SystemJoinDetector(),
         background: @escaping JoinWatcher.Background = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
         deliver: @escaping JoinWatcher.Deliver = { work in DispatchQueue.main.async(execute: work) },
         autoSchedule: Bool = true,
         onToday: @escaping ([Meeting]) -> Void = { _ in },
         onAccess: @escaping (CalendarAccess) -> Void = { _ in }) {
        self.events = events; self.settings = settings; self.clock = clock; self.stateDir = stateDir
        self.onToday = onToday; self.onAccess = onAccess
        joinWatcher = JoinWatcher(
            detector: detector, clock: clock, enabled: { [weak self] in self?.settings().detectJoin ?? false },
            background: background, deliver: deliver, autoSchedule: autoSchedule,
            onJoined: { [weak self] in self?.joined($0) })
    }

    func start() {
        guard !started else { return }
        started = true
        state = loadState()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
        checkAccess()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        refreshTimer?.tolerance = 10
    }

    func stop() {
        guard started else { return }
        started = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        soonTimer?.invalidate()
        soonTimer = nil
        debounce?.cancel()
        debounce = nil
        joinWatcher.sync([])
        onToday([])
    }

    // A setting changed: re-read the calendar so the new lead time, summary and selection apply now.
    func settingsChanged() {
        guard started else { return }
        tick()
    }

    // MARK: Access

    private func checkAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let ok: Bool
        if #available(macOS 14.0, *) { ok = status == .fullAccess } else { ok = status == .authorized }
        let next: CalendarAccess = ok ? .granted : status == .notDetermined ? .notDetermined : .denied
        if next != access {
            log("access \(next) (raw \(status.rawValue))")
            // The identifiers STACKNUDGE_CALENDARS takes; there is no picker to read them from.
            if ok { log("calendars: " + ek.calendars(for: .event).map { "\($0.title) [\($0.source.title)] id=\($0.calendarIdentifier)" }.joined(separator: "; ")) }
            access = next
            onAccess(next)
        }
        granted = ok
        if ok {
            refresh()
        } else if status == .notDetermined, !requested {
            requested = true
            requestAccess()
        }
    }

    private func requestAccess() {
        Task { @MainActor in
            do {
                if #available(macOS 14.0, *) {
                    _ = try await ek.requestFullAccessToEvents()
                } else {
                    _ = try await ek.requestAccess(to: .event)
                }
            } catch {
                log("access request failed: \(error.localizedDescription)")
            }
            ek.reset()
            if started { checkAccess() }
        }
    }

    // MARK: Calendars

    var calendars: [EKCalendar] {
        granted ? ek.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : []
    }

    // MARK: Refresh

    private func tick() {
        if granted { refresh() } else { checkAccess() }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func snapshot(now: Date, calendars: [EKCalendar]) -> [Meeting] {
        guard !calendars.isEmpty else { return [] }
        // From midnight, so today's finished meetings stay available to a view of the day.
        let predicate = ek.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: now.addingTimeInterval(Self.window), calendars: calendars)
        var seen = Set<String>()
        return ek.events(matching: predicate).compactMap { e -> Meeting? in
            guard !e.isAllDay, e.status != .canceled, e.startDate != nil, e.endDate != nil else { return nil }
            if e.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { return nil }
            let itemId = e.calendarItemIdentifier
            let recurring = e.hasRecurrenceRules || e.isDetached
            let occurrence = e.occurrenceDate ?? e.startDate!
            let id = recurring ? "\(itemId)@\(Int(occurrence.timeIntervalSince1970))" : itemId
            guard seen.insert(id).inserted else { return nil }
            return Meeting(
                id: id, itemId: itemId, title: e.title ?? "(no title)", start: e.startDate, end: e.endDate,
                location: e.location ?? "", organizer: Self.organizer(e),
                joinUrl: MeetingDiff.joinUrl(in: [e.url?.absoluteString, e.location, e.notes]),
                calendar: e.calendar.title, created: e.creationDate,
                notes: e.notes.map { String($0.prefix(Self.notesCap)) }, eventUrl: e.url?.absoluteString, attendeeCount: e.attendees?.count)
        }.sorted { $0.start < $1.start }.dedupedByOccurrence()
    }

    private static func organizer(_ e: EKEvent) -> String {
        guard let o = e.organizer else { return "" }
        if let name = o.name, !name.isEmpty { return name }
        return o.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
    }

    private func refresh() {
        guard granted else { return }
        let ids = Set(settings().calendarIds)
        let selected = calendars.filter { ids.isEmpty || ids.contains($0.calendarIdentifier) }
        let signature = selected.map(\.calendarIdentifier).sorted().joined(separator: ",")
        let now = clock()
        apply(current: snapshot(now: now, calendars: selected), signature: signature, now: now)
    }

    // Everything after the calendar has been read: diffs, reminders, the summary and the join check.
    func apply(current: [Meeting], signature: String, now: Date) {
        let s = settings()
        let lead = TimeInterval(s.leadMinutes * 60)

        // The first run, a changed calendar selection or a long gap rebases silently instead of flooding.
        let previous = state.flatMap { $0.calendars == signature && now.timeIntervalSince($0.updatedAt) < Self.staleAfter ? $0 : nil }
        let missingSince = state?.missingSince ?? [:]
        let notices = previous.map { MeetingDiff.diff(old: $0.events, new: current, now: now, since: $0.updatedAt, missingSince: missingSince) } ?? []
        let held = previous.map { MeetingDiff.held(old: $0.events, new: current, now: now, missingSince: missingSince) } ?? [:]
        let heldMeetings = previous?.events.filter { held[$0.id] != nil } ?? []

        // A reminder for a meeting that was moved, cancelled or dropped goes with it.
        let live = Set(current.map(MeetingDiff.dueKey))
        let firedBefore = Set(state?.soonFired ?? [])
        for key in firedBefore.subtracting(live) { events.remove(key: key) }
        var fired = firedBefore.intersection(live)
        var startFired = Set(state?.startFired ?? []).intersection(live)

        for n in notices { emit(n, now: now) }
        for m in MeetingDiff.due(current, fired: fired, lead: lead, now: now) {
            emit(MeetingDiff.soonNotice(m, now: now), now: now)
            fired.insert(MeetingDiff.dueKey(m))
        }
        for m in MeetingDiff.startDue(current, fired: fired, started: startFired, now: now) {
            emit(MeetingDiff.startNotice(m), now: now)
            startFired.insert(MeetingDiff.dueKey(m))
        }
        for m in MeetingDiff.expired(current, fired: fired, now: now) { events.remove(key: MeetingDiff.dueKey(m)) }

        var summaryDate = state?.summaryDate
        if MeetingDiff.summaryDue(now: now, settings: s.summary, lastDate: summaryDate) {
            if let n = MeetingDiff.summaryNotice(current, now: now, announceEmpty: s.summary.announceEmpty) { emit(n, now: now) }
            summaryDate = MeetingDiff.dayKey(now)
        }

        onToday(MeetingDiff.todaysMeetings(current, now: now))
        state = CalendarState(updatedAt: now, calendars: signature, events: current + heldMeetings, soonFired: fired.sorted(),
                              startFired: startFired.isEmpty ? nil : startFired.sorted(), summaryDate: summaryDate,
                              missingSince: held.isEmpty ? nil : held)
        saveState()
        joinWatcher.sync(current.filter { fired.contains(MeetingDiff.dueKey($0)) }
            .map { JoinCandidate(id: MeetingDiff.dueKey($0), url: $0.joinUrl, start: $0.start) })
        scheduleNext(current, fired: fired, startFired: startFired, summaryDate: summaryDate, settings: s, now: now)
        if previous == nil || !notices.isEmpty {
            log("refresh: \(current.count) meetings, \(notices.count) changes\(previous == nil ? " (seed)" : "")")
        }
    }

    // One timer for whatever is due next: a heads-up, a start alert, an expiry,
    // the summary, or the moment a join check opens.
    private func scheduleNext(_ meetings: [Meeting], fired: Set<String>, startFired: Set<String>, summaryDate: String?, settings s: CalendarSettings, now: Date) {
        soonTimer?.invalidate()
        soonTimer = nil
        let joinChecks = meetings.filter { fired.contains(MeetingDiff.dueKey($0)) && !$0.joinUrl.isEmpty }
            .map { $0.start.addingTimeInterval(-JoinWatcher.lead) }.filter { $0 > now }.min()
        let candidates = [
            MeetingDiff.nextDue(meetings, fired: fired, lead: TimeInterval(s.leadMinutes * 60), now: now),
            MeetingDiff.nextReminderStep(meetings, fired: fired, started: startFired, now: now),
            MeetingDiff.nextSummaryDue(now: now, settings: s.summary, lastDate: summaryDate),
            joinChecks,
        ]
        guard let next = candidates.compactMap({ $0 }).min() else { return }
        soonTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            self?.tick()
        }
    }

    private func emit(_ n: MeetingNotice, now: Date) {
        events.append(n.event(now: now))
    }

    // MARK: Joining

    private func joined(_ c: JoinCandidate) {
        events.remove(key: c.id)
        // Recorded so the start alert does not come back for a meeting already joined.
        let keys = Set(state?.startFired ?? []).union([c.id])
        state?.startFired = keys.sorted()
        saveState()
    }

    // MARK: Persistence

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func loadState() -> CalendarState? {
        guard let data = FileManager.default.contents(atPath: statePath) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(CalendarState.self, from: data)
    }

    private func saveState() {
        guard let state, let data = try? Self.encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
