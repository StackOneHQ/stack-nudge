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
    case agent, github, calendar, script

    var label: String {
        switch self {
        case .agent:    return "Agent"
        case .github:   return "GitHub"
        case .calendar: return "Calendar"
        case .script:   return "Script"
        }
    }
}

// How much a feed event asks of you: info is a heads-up, action wants
// something done, alert wants it now. Agent events don't use it; their kind
// already says (a permission prompt is the action).
enum EventSeverity: String, CaseIterable {
    case info, action, alert
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
        self.snoozedUntil = snoozedUntil
    }

    // A feed event: no agent process behind it, so `agent` holds the source's
    // name for the places that display it.
    static func feed(source: EventSource, tag: String?, severity: EventSeverity = .info,
                     title: String, message: String, url: URL? = nil,
                     repo: String? = nil, pr: Int? = nil, key: String? = nil,
                     timestamp: Date = Date()) -> NudgeEvent {
        NudgeEvent(agent: source.label, kind: .other, title: title, message: message,
                   timestamp: timestamp, source: source, tag: tag, severity: severity,
                   url: url, repo: repo, pr: pr, key: key)
    }

    // Whole-struct copy with the snoozedUntil overridden. EventStore uses
    // this when the user snoozes / when the snooze elapses.
    func with(snoozedUntil: Date?) -> NudgeEvent {
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
            snoozedUntil: snoozedUntil,
            id: id  // preserve identity across snooze cycles
        )
    }
}

final class EventStore: ObservableObject {

    @Published private(set) var events: [NudgeEvent] = []
    @Published var selectedID: NudgeEvent.ID?

    var maxEventsPerSession: Int = 5 {
        didSet { if maxEventsPerSession != oldValue { prune() } }
    }
    private let maxEventsTotal = 100
    // Feeds have no sessions; each source gets its own allowance instead, so a
    // busy week of PRs can't push agent prompts out of the queue or vice versa.
    static let maxEventsPerFeed = 20

    private func sessionKey(_ e: NudgeEvent) -> String {
        if e.isFeed { return "feed:\(e.source.rawValue)" }
        return e.claudeSessionID ?? "\(e.agent):\(e.projectPath ?? "")"
    }

    private func prune() {
        var counts: [String: Int] = [:]
        events = events.filter { e in
            let k = sessionKey(e)
            counts[k, default: 0] += 1
            return counts[k]! <= (e.isFeed ? Self.maxEventsPerFeed : maxEventsPerSession)
        }
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
        // identical one landed within the dedup window.
        let dedupWindow: TimeInterval = 2
        if events.contains(where: { existing in
            abs(event.timestamp.timeIntervalSince(existing.timestamp)) < dedupWindow
                && existing.agent == event.agent
                && existing.kind == event.kind
                && existing.message == event.message
                && existing.claudeSessionID == event.claudeSessionID
        }) {
            return
        }
        // A keyed feed event replaces its earlier self rather than stacking.
        if event.isFeed, let key = event.key,
           let old = events.firstIndex(where: { $0.isFeed && $0.key == key }) {
            let wasSelected = selectedID == events[old].id
            events.remove(at: old)
            if wasSelected { selectedID = event.id }
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
                                url: event.url?.absoluteString))
        onAppend?(event)
        if ProcessInfo.processInfo.environment["STACKNUDGE_PANEL_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "panel: received \(event.agent)/\(event.kind.rawValue): \(event.message)\n".utf8))
        }
    }

    func remove(id: NudgeEvent.ID) {
        events.removeAll { $0.id == id }
        if selectedID == id { selectedID = events.first?.id }
    }

    // Replace the event in-place with a new copy that has snoozedUntil set
    // (or cleared with nil). Triggers SwiftUI updates because @Published.
    func setSnoozedUntil(id: NudgeEvent.ID, _ until: Date?) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        events[idx] = events[idx].with(snoozedUntil: until)
    }

    func selectNext() {
        guard !events.isEmpty else { return }
        let idx = events.firstIndex { $0.id == selectedID } ?? 0
        selectedID = events[min(idx + 1, events.count - 1)].id
    }

    func selectPrevious() {
        guard !events.isEmpty else { return }
        let idx = events.firstIndex { $0.id == selectedID } ?? 0
        selectedID = events[max(idx - 1, 0)].id
    }

    // ⌘↑/↓ — jump to the first / last event.
    func selectFirst() { selectedID = events.first?.id }
    func selectLast()  { selectedID = events.last?.id }

    var selectedEvent: NudgeEvent? {
        events.first { $0.id == selectedID }
    }
}
