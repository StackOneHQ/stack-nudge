import Foundation
import SwiftUI

enum NudgeKind: String {
    case stop
    case permission
    case other

    init(rawWireValue: String) {
        self = NudgeKind(rawValue: rawWireValue) ?? .other
    }
}

// Where an event came from. Agent hooks are the original and still the
// default; the rest are in-app feeds (GitHub, the calendar) or a script
// posting through the socket. They carry no agent process, session or
// FIFO, so anything keyed on those must ask `isFeed` first.
enum EventSource: String, CaseIterable {
    // `extension` is a service extension's feed; which one is the event's
    // `extensionID`, and each has its own cap. mcp: a nudge an MCP client
    // raised with the notify tool. Only the MCP server makes these; the hook
    // socket refuses the source (see EventListener.feedSource), since a nudge
    // marked as a client's can take you back to that client's terminal or app.
    case agent, github, calendar, script, mcp, `extension`

    var label: String {
        switch self {
        case .agent:     return "Agent"
        case .github:    return "GitHub"
        case .calendar:  return "Calendar"
        case .script:    return "Script"
        case .mcp:       return "MCP"
        case .extension: return "Extension"
        }
    }
}

// What ⏎ does on an extension's feed event, in place of opening its link: the
// press goes back to the extension, which acts on it. Never persisted, so an
// event restored at launch comes back without it.
struct FeedAction: Equatable {
    let id: String
    let label: String
}

// How much a feed event asks of you: info is a heads-up, action wants
// something done, alert wants it now. Agent events don't use it; their kind
// already says (a permission prompt is the action).
enum EventSeverity: String, CaseIterable {
    case info, action, alert

    var rank: Int {
        switch self {
        case .info:   return 0
        case .action: return 1
        case .alert:  return 2
        }
    }
}

// One comment folded into a grouped PR feedback row. Kept on the grouped event
// in a bounded form (EventStore.maxMembers) so the row can expand to show each.
struct FeedMember: Equatable {
    let title: String
    let message: String
    let url: URL?
    let at: Date
}

struct NudgeEvent: Identifiable, Equatable {
    let id: UUID
    let agent: String
    let kind: NudgeKind
    let title: String
    let message: String
    let projectPath: String?
    let bundleID: String?
    let windowTitle: String?
    let ipcHook: String?
    let hasActionButton: Bool
    let timestamp: Date
    // When set and in the future, the user has snoozed this event. The panel
    // dims it; a timer scheduled in PanelController will fire a fresh banner
    // when the snooze elapses. EventStore.setSnoozedUntil replaces the
    // whole struct since we keep all fields immutable.
    let snoozedUntil: Date?
    // Session enrichment — populated by notify.sh's walk_session_chain. Used
    // by AppActivator for precise pane focus and by the future sessions
    // feature for grouping events back to their source CC/Gemini/Codex
    // process.
    let agentPID: Int?
    let shellPID: Int?
    let terminalPID: Int?
    let terminalApp: String?
    let termProgram: String?
    let sessionID: String?
    // User-visible iTerm2 tab/session name, captured at event time via
    // an osascript query in notify.sh. Empty for non-iTerm terminals or
    // when Automation permission hasn't been granted yet.
    let itermTabName: String?
    // FIFO that the source notify.sh hook is blocking on. Writing
    // "allow" or "deny" to it lets stack-nudge return a PermissionRequest
    // decision to Claude Code without touching the terminal UI.
    let fifoPath: String?
    // pid of the notify.sh hook waiting on `fifoPath`; nil from older hooks.
    let hookPID: Int?
    // Curated phrase for the voice engine (different from the visible
    // `message` — the banner shows the tool / file context, the voice
    // speaks a conversational sentence).
    let voiceMessage: String?
    // Same phrase with its `%s` placeholder still in place, so the app can
    // substitute the session's name (which only the app knows) instead of the
    // cwd basename the hook substituted into voiceMessage. nil from an older
    // installed notify.sh, in which case voiceMessage is all we have.
    let voiceTemplate: String?
    // Name of a /System/Library/Sounds/*.aiff chime to play. Picked by
    // notify.sh based on event kind (Glass for stop, Ping for permission)
    // and overridable via STACKNUDGE_SOUND_STOP / STACKNUDGE_SOUND_PERMISSION.
    let soundName: String?
    // When true, this event bypasses the mute-when-focused gate. Used by
    // the legacy install.sh `welcome` event, fired while the user is
    // staring at the install terminal.
    let bypassMute: Bool
    // Claude Code's session UUID (distinct from `sessionID` which is the
    // iTerm/terminal session id) and the JSONL transcript path. Used to
    // compute per-session context-window usage. Populated only for Claude
    // Code hook events; nil for other agents.
    let claudeSessionID: String?
    let transcriptPath: String?
    // Feed fields; all nil or default for agent events.
    let source: EventSource
    // Groups feed events for filters and icons ("review", "ci", "calendar").
    let tag: String?
    let severity: EventSeverity
    // What opening the event opens. Only http(s) reaches here.
    let url: URL?
    let repo: String?
    let pr: Int?
    // A feed event with a key replaces the one already queued under it, so a
    // PR whose CI flips twice is one row, not two.
    let key: String?
    // Feed events start unread and go read when opened or marked. Agent events
    // never use it: a prompt is pending until answered, not read.
    let isRead: Bool
    // The comments a grouped feedback row stands for, newest first; empty for
    // an ordinary event.
    let members: [FeedMember]
    // The service extension that posted it, for source `extension`.
    let extensionID: String?
    let feedAction: FeedAction?

    var isFeed: Bool { source != .agent }

    init(agent: String, kind: NudgeKind, title: String, message: String,
         projectPath: String? = nil, bundleID: String? = nil,
         windowTitle: String? = nil, ipcHook: String? = nil,
         hasActionButton: Bool = false, timestamp: Date = Date(),
         agentPID: Int? = nil, shellPID: Int? = nil,
         terminalPID: Int? = nil, terminalApp: String? = nil,
         termProgram: String? = nil, sessionID: String? = nil,
         itermTabName: String? = nil,
         fifoPath: String? = nil,
         hookPID: Int? = nil,
         voiceMessage: String? = nil,
         voiceTemplate: String? = nil,
         soundName: String? = nil,
         bypassMute: Bool = false,
         claudeSessionID: String? = nil,
         transcriptPath: String? = nil,
         source: EventSource = .agent,
         tag: String? = nil,
         severity: EventSeverity = .info,
         url: URL? = nil,
         repo: String? = nil,
         pr: Int? = nil,
         key: String? = nil,
         isRead: Bool = false,
         members: [FeedMember] = [],
         extensionID: String? = nil,
         feedAction: FeedAction? = nil,
         snoozedUntil: Date? = nil,
         id: UUID = UUID()) {
        self.id = id
        self.agent = agent
        self.kind = kind
        self.title = title
        self.message = message
        self.projectPath = projectPath
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.ipcHook = ipcHook
        self.hasActionButton = hasActionButton
        self.timestamp = timestamp
        self.agentPID = agentPID
        self.shellPID = shellPID
        self.terminalPID = terminalPID
        self.terminalApp = terminalApp
        self.termProgram = termProgram
        self.sessionID = sessionID
        self.itermTabName = itermTabName
        self.fifoPath = fifoPath
        self.hookPID = hookPID
        self.voiceMessage = voiceMessage
        self.voiceTemplate = voiceTemplate
        self.soundName = soundName
        self.bypassMute = bypassMute
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = transcriptPath
        self.source = source
        self.tag = tag
        self.severity = severity
        self.url = url
        self.repo = repo
        self.pr = pr
        self.key = key
        self.isRead = isRead
        self.members = members
        self.extensionID = extensionID
        self.feedAction = feedAction
        self.snoozedUntil = snoozedUntil
    }

    var isUnread: Bool { isFeed && !isRead }

    // A feed event: no agent process behind it, so `agent` holds the source's
    // name for the places that display it.
    // An extension's event shows the extension's name there instead.
    static func feed(source: EventSource, tag: String?, severity: EventSeverity = .info,
                     title: String, message: String, url: URL? = nil,
                     repo: String? = nil, pr: Int? = nil, key: String? = nil,
                     timestamp: Date = Date(), isRead: Bool = false,
                     members: [FeedMember] = [], name: String? = nil,
                     extensionID: String? = nil, action: FeedAction? = nil,
                     id: UUID = UUID()) -> NudgeEvent {
        NudgeEvent(agent: name ?? source.label, kind: .other, title: title, message: message,
                   timestamp: timestamp, source: source, tag: tag, severity: severity,
                   url: url, repo: repo, pr: pr, key: key, isRead: isRead,
                   members: Array(members.prefix(EventStore.maxMembers)),
                   extensionID: extensionID, feedAction: action, id: id)
    }

    // Whole-struct copy with the snoozedUntil overridden. EventStore uses
    // this when the user snoozes / when the snooze elapses.
    func with(snoozedUntil: Date?) -> NudgeEvent {
        copy(snoozedUntil: snoozedUntil, isRead: isRead)
    }

    func with(isRead: Bool) -> NudgeEvent {
        copy(snoozedUntil: snoozedUntil, isRead: isRead)
    }

    func withoutAction() -> NudgeEvent {
        copy(snoozedUntil: snoozedUntil, isRead: isRead, feedAction: nil)
    }

    private func copy(snoozedUntil: Date?, isRead: Bool) -> NudgeEvent {
        copy(snoozedUntil: snoozedUntil, isRead: isRead, feedAction: feedAction)
    }

    private func copy(snoozedUntil: Date?, isRead: Bool, feedAction: FeedAction?) -> NudgeEvent {
        NudgeEvent(
            agent: agent, kind: kind, title: title, message: message,
            projectPath: projectPath, bundleID: bundleID,
            windowTitle: windowTitle, ipcHook: ipcHook,
            hasActionButton: hasActionButton, timestamp: timestamp,
            agentPID: agentPID, shellPID: shellPID,
            terminalPID: terminalPID, terminalApp: terminalApp,
            termProgram: termProgram, sessionID: sessionID,
            itermTabName: itermTabName,
            fifoPath: fifoPath,
            hookPID: hookPID,
            voiceMessage: voiceMessage,
            voiceTemplate: voiceTemplate,
            soundName: soundName,
            bypassMute: bypassMute,
            claudeSessionID: claudeSessionID,
            transcriptPath: transcriptPath,
            source: source, tag: tag, severity: severity,
            url: url, repo: repo, pr: pr, key: key,
            isRead: isRead, members: members,
            extensionID: extensionID, feedAction: feedAction,
            snoozedUntil: snoozedUntil,
            id: id  // preserve identity across snooze cycles
        )
    }
}

final class EventStore: ObservableObject {

    @Published private(set) var events: [NudgeEvent] = []
    @Published var selectedID: NudgeEvent.ID?
    // Per session, never persisted: a filter left on from yesterday would hide
    // today's events with no sign of why.
    @Published var tagFilter = FeedTagFilter() {
        didSet {
            if !visibleEvents.contains(where: { $0.id == selectedID }) {
                selectedID = visibleEvents.first?.id
            }
        }
    }
    // Grouped rows the user has opened. Not persisted.
    @Published var expandedIDs: Set<NudgeEvent.ID> = []
    // True after Clear all, until the next event lands: the empty list then
    // reads "All caught up" rather than "No nudges yet".
    @Published private(set) var clearedFeed = false

    var maxEventsPerSession: Int = 5 {
        didSet { if maxEventsPerSession != oldValue { prune() } }
    }
    private let maxEventsTotal = 100
    // Feeds have no sessions; each source gets its own allowance instead, so a
    // busy week of PRs can't push agent prompts out of the queue or vice versa.
    static let maxEventsPerFeed = 20
    // Comments kept on a grouped feedback row. Bounded so a PR that gets a
    // hundred comments is still one small event.
    static let maxMembers = 50
    // Feed events older than this are not brought back from the log at launch.
    static let restoreWindow: TimeInterval = 7 * 24 * 60 * 60

    private func sessionKey(_ e: NudgeEvent) -> String {
        if e.isFeed { return Self.feedKey(e) }
        return e.claudeSessionID ?? "\(e.agent):\(e.projectPath ?? "")"
    }

    // Which cap a feed event counts against: its source's, and each
    // extension's own, so one extension can't push another's events out.
    static func feedKey(_ e: NudgeEvent) -> String {
        guard e.source == .extension else { return "feed:\(e.source.rawValue)" }
        return "feed:extension:\(e.extensionID ?? "")"
    }

    // Whether `incoming` replaces `existing` by key. Only within one source,
    // and one extension: a key is the poster's own name for its event, so one
    // poster can't replace another's by guessing it.
    static func replaces(_ existing: NudgeEvent, with incoming: NudgeEvent) -> Bool {
        existing.isFeed && incoming.isFeed && incoming.key != nil && existing.key == incoming.key
            && feedKey(existing) == feedKey(incoming)
    }

    private func prune() {
        var counts: [String: Int] = [:]
        events = events.filter { e in
            let k = sessionKey(e)
            counts[k, default: 0] += 1
            return counts[k]! <= (e.isFeed ? Self.maxEventsPerFeed : maxEventsPerSession)
        }
        // Past the overall ceiling the oldest feed events go first, so feeds,
        // however many sources there are, can't push a waiting prompt out.
        var excess = events.count - maxEventsTotal
        guard excess > 0 else { return }
        var dropped = Set<UUID>()
        for event in events.reversed() where excess > 0 && event.isFeed {
            dropped.insert(event.id)
            excess -= 1
        }
        events.removeAll { dropped.contains($0.id) }
        if events.count > maxEventsTotal {
            events = Array(events.prefix(maxEventsTotal))
        }
    }

    /// Called on main queue after each new event is inserted.
    var onAppend: ((NudgeEvent) -> Void)?

    // Durable history behind the live queue. nil disables recording (Settings →
    // Event history), in which case nothing is written and the History pane
    // shows only what the log already held.
    var log: EventLog?

    func append(_ event: NudgeEvent) {
        // Claude Code occasionally fires the same hook twice in rapid
        // succession (observed on Stop). Drop the second event when an
        // identical one landed within the dedup window. The title, source,
        // key, extension and action count too: two nudges sharing a message,
        // such as an MCP client's notify with none, are two things, and a keyed
        // one replaces its earlier self below rather than being dropped as a
        // repeat.
        let dedupWindow: TimeInterval = 2
        if events.contains(where: { existing in
            abs(event.timestamp.timeIntervalSince(existing.timestamp)) < dedupWindow
                && existing.agent == event.agent
                && existing.kind == event.kind
                && existing.source == event.source
                && existing.title == event.title
                && existing.message == event.message
                && existing.claudeSessionID == event.claudeSessionID
                && existing.key == event.key
                && existing.extensionID == event.extensionID
                && existing.feedAction == event.feedAction
        }) {
            return
        }
        clearedFeed = false
        var event = event
        // A keyed feed event replaces its earlier self rather than stacking.
        if event.isFeed, event.key != nil,
           let old = events.firstIndex(where: { Self.replaces($0, with: event) }) {
            let wasSelected = selectedID == events[old].id
            expandedIDs.remove(events[old].id)
            // Logged as gone, so a relaunch restores the replacement only.
            log?.append(.marker(uid: events[old].id, at: Date(), removed: true))
            events.remove(at: old)
            if wasSelected { selectedID = event.id }
        } else if let old = events.firstIndex(where: { Self.groups($0, with: event) }) {
            // Feedback on one PR collapses into one row that keeps each comment.
            let previous = events[old]
            let wasSelected = selectedID == previous.id
            let wasExpanded = expandedIDs.remove(previous.id) != nil
            events.remove(at: old)
            log?.append(.marker(uid: previous.id, at: Date(), removed: true))
            event = Self.merged(previous: previous, incoming: event)
            if wasSelected { selectedID = event.id }
            if wasExpanded { expandedIDs.insert(event.id) }
        }
        events.insert(event, at: 0)
        // Bound per-session first (so a chatty session can't crowd out quiet
        // ones), then apply a hard global ceiling to cap memory/UI growth
        // when many sessions are active in parallel.
        prune()
        // A feed event arrives in the background; taking the selection would
        // make the next ⏎ land on it instead of the prompt being triaged.
        if !event.isFeed || selectedID == nil || !events.contains(where: { $0.id == selectedID }) {
            if selectedID != event.id { selectedID = event.id }
        }
        // After the dedup check, so the log doesn't record a duplicate the
        // panel deliberately dropped. The write itself is async.
        log?.append(EventRecord(at: event.timestamp,
                                agent: event.agent,
                                kind: event.kind.rawValue,
                                title: event.title,
                                message: event.message,
                                project: event.projectPath,
                                session: event.claudeSessionID,
                                source: event.isFeed ? event.source.rawValue : nil,
                                tag: event.tag,
                                url: event.url?.absoluteString,
                                uid: event.isFeed ? event.id.uuidString : nil,
                                severity: event.isFeed ? event.severity.rawValue : nil,
                                repo: event.repo,
                                pr: event.pr,
                                key: event.key,
                                extensionID: event.extensionID))
        onAppend?(event)
        if ProcessInfo.processInfo.environment["STACKNUDGE_PANEL_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "panel: received \(event.agent)/\(event.kind.rawValue): \(event.message)\n".utf8))
        }
    }

    // An extension took back its event with this key. Gone from Events as a
    // dismissal would take it, and logged the same way.
    func retract(key: String, extensionID: String) {
        guard let gone = events.first(where: {
            $0.source == .extension && $0.extensionID == extensionID && $0.key == key
        }) else { return }
        remove(id: gone.id)
    }

    // ⏎ sent its action. The event stays, read, without the action, so a
    // second press can't send it again; the extension replaces or retracts it
    // once it has acted.
    func actionSent(id: NudgeEvent.ID) {
        guard let idx = events.firstIndex(where: { $0.id == id }), events[idx].feedAction != nil else { return }
        events[idx] = events[idx].withoutAction()
        setRead(id: id, true)
    }

    // Its extension can't take the actions any more; the events stay, as
    // ordinary ones.
    func dropActions(extensionID: String) {
        for (idx, event) in events.enumerated()
        where event.extensionID == extensionID && event.feedAction != nil {
            events[idx] = event.withoutAction()
        }
    }

    func remove(id: NudgeEvent.ID) {
        if let gone = events.first(where: { $0.id == id }), gone.isFeed {
            log?.append(.marker(uid: id, at: Date(), removed: true))
        }
        events.removeAll { $0.id == id }
        expandedIDs.remove(id)
        if selectedID == id { selectedID = visibleEvents.first?.id }
    }

    // Same trust boundary as the FIFO path: whatever opens this goes through
    // NSWorkspace, so only web links pass, never file:// or an app scheme.
    static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // MARK: - Feed grouping

    // Review feedback on the same PR from the same source. Keyed events are
    // never comments: a key means "this replaces its earlier self" (GitHub's
    // approved and changes-requested decisions carry one), and folding one into
    // the comment row would hide it there and hand the row its key, so the
    // next decision would replace every comment with it.
    static func groups(_ existing: NudgeEvent, with incoming: NudgeEvent) -> Bool {
        guard existing.isFeed, incoming.isFeed,
              incoming.key == nil, existing.key == nil,
              incoming.tag == "review", existing.tag == "review",
              existing.source == incoming.source,
              let repo = incoming.repo, !repo.isEmpty, existing.repo == repo,
              let pr = incoming.pr, existing.pr == pr
        else { return false }
        return true
    }

    private static func members(of event: NudgeEvent) -> [FeedMember] {
        guard event.members.isEmpty else { return event.members }
        return [FeedMember(title: event.title, message: event.message,
                           url: event.url, at: event.timestamp)]
    }

    static func merged(previous: NudgeEvent, incoming: NudgeEvent) -> NudgeEvent {
        let all = Array((members(of: incoming) + members(of: previous)).prefix(maxMembers))
        let name = incoming.repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? ""
        return .feed(source: incoming.source, tag: incoming.tag,
                     severity: incoming.severity.rank >= previous.severity.rank
                         ? incoming.severity : previous.severity,
                     title: "\(all.count) new comments on \(name)#\(incoming.pr ?? 0)",
                     message: incoming.message, url: incoming.url ?? previous.url,
                     repo: incoming.repo, pr: incoming.pr, key: nil,
                     timestamp: incoming.timestamp, members: all, id: incoming.id)
    }

    // MARK: - Read state

    var unreadCount: Int { events.filter(\.isUnread).count }

    // What the Events tab label counts: prompts and stops are always pending,
    // a feed event only while unread.
    var pendingCount: Int { events.filter { !$0.isFeed || !$0.isRead }.count }

    func unreadCount(forTag tag: String) -> Int {
        events.filter { $0.isUnread && FeedTagFilter.key(for: $0) == tag }.count
    }

    func setRead(id: NudgeEvent.ID, _ read: Bool) {
        guard let idx = events.firstIndex(where: { $0.id == id }),
              events[idx].isFeed, events[idx].isRead != read else { return }
        events[idx] = events[idx].with(isRead: read)
        log?.append(.marker(uid: id, at: Date(), read: read))
    }

    func toggleRead(id: NudgeEvent.ID) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        setRead(id: id, !event.isRead)
    }

    func markAllRead() {
        for event in events where event.isUnread { setRead(id: event.id, true) }
    }

    // Removes every feed event; prompts and stops stay. Returns how many went.
    @discardableResult
    func clearFeed() -> Int {
        let gone = events.filter(\.isFeed)
        for event in gone { log?.append(.marker(uid: event.id, at: Date(), removed: true)) }
        events.removeAll(where: \.isFeed)
        expandedIDs.subtract(gone.map(\.id))
        if !gone.isEmpty { clearedFeed = true }
        if !events.contains(where: { $0.id == selectedID }) { selectedID = visibleEvents.first?.id }
        return gone.count
    }

    func toggleExpanded(id: NudgeEvent.ID) {
        guard events.first(where: { $0.id == id })?.members.isEmpty == false else { return }
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    func setExpanded(id: NudgeEvent.ID, _ expanded: Bool) {
        guard events.first(where: { $0.id == id })?.members.isEmpty == false else { return }
        if expanded { expandedIDs.insert(id) } else { expandedIDs.remove(id) }
    }

    // Brings feed events back from the durable log at launch, with their read
    // state, so unread items survive a relaunch. `records` is newest first as
    // EventLog.load returns it. Grouped rows come back as their newest comment
    // only: members are not persisted. Nothing here fires a banner.
    func restoreFeed(from records: [EventRecord], now: Date = Date()) {
        var counts: [String: Int] = [:]
        var restored: [NudgeEvent] = []
        // Newest first, so the first event seen under a poster's key is the
        // one that replaced the rest. Logs written before replacements were
        // recorded as removals still have the older ones.
        var keys = Set<String>()
        for record in records {
            guard let raw = record.source, let source = EventSource(rawValue: raw), source != .agent,
                  source != .extension || record.extensionID != nil,
                  let uid = record.uid.flatMap(UUID.init(uuidString:)),
                  record.removed != true,
                  now.timeIntervalSince(record.at) <= Self.restoreWindow,
                  !events.contains(where: { $0.id == uid })
            else { continue }
            let event = NudgeEvent.feed(
                source: source, tag: record.tag,
                severity: record.severity.flatMap(EventSeverity.init(rawValue:)) ?? .info,
                title: record.title, message: record.message,
                url: record.url.flatMap { Self.webURL($0) },
                repo: record.repo, pr: record.pr, key: record.key,
                timestamp: record.at, isRead: record.read == true,
                name: source == .extension ? record.agent : nil,
                extensionID: record.extensionID, id: uid)
            let cap = Self.feedKey(event)
            if let key = event.key {
                guard keys.insert("\(cap)|\(key)").inserted,
                      !events.contains(where: { Self.replaces($0, with: event) }) else { continue }
            }
            guard counts[cap, default: 0] < Self.maxEventsPerFeed else { continue }
            counts[cap, default: 0] += 1
            restored.append(event)
        }
        events.append(contentsOf: restored)
        events.sort { $0.timestamp > $1.timestamp }
        prune()
        if selectedID == nil { selectedID = visibleEvents.first?.id }
    }

    // MARK: - Filtering

    // Agent events are never filtered: a hidden permission prompt would leave
    // an agent blocked with nothing on screen to say so.
    var visibleEvents: [NudgeEvent] {
        events.filter { !$0.isFeed || tagFilter.shows(FeedTagFilter.key(for: $0)) }
    }

    // Feed tags in the list, in the order chips show them.
    var presentTags: [String] {
        FeedTagFilter.present(in: events)
    }

    // Replace the event in-place with a new copy that has snoozedUntil set
    // (or cleared with nil). Triggers SwiftUI updates because @Published.
    func setSnoozedUntil(id: NudgeEvent.ID, _ until: Date?) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        events[idx] = events[idx].with(snoozedUntil: until)
    }

    func selectNext() {
        let visible = visibleEvents
        guard !visible.isEmpty else { return }
        let idx = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[min(idx + 1, visible.count - 1)].id
    }

    func selectPrevious() {
        let visible = visibleEvents
        guard !visible.isEmpty else { return }
        let idx = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[max(idx - 1, 0)].id
    }

    // ⌘↑/↓ — jump to the first / last event.
    func selectFirst() { selectedID = visibleEvents.first?.id }
    func selectLast()  { selectedID = visibleEvents.last?.id }

    var selectedEvent: NudgeEvent? {
        events.first { $0.id == selectedID }
    }
}
