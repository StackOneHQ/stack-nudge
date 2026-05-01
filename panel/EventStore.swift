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
    // FIFO that the source notify.sh hook is blocking on. Writing
    // "allow" or "deny" to it lets stack-nudge return a PermissionRequest
    // decision to Claude Code without touching the terminal UI.
    let fifoPath: String?

    init(agent: String, kind: NudgeKind, title: String, message: String,
         projectPath: String? = nil, bundleID: String? = nil,
         windowTitle: String? = nil, ipcHook: String? = nil,
         hasActionButton: Bool = false, timestamp: Date = Date(),
         agentPID: Int? = nil, shellPID: Int? = nil,
         terminalPID: Int? = nil, terminalApp: String? = nil,
         termProgram: String? = nil, sessionID: String? = nil,
         fifoPath: String? = nil,
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
        self.fifoPath = fifoPath
        self.snoozedUntil = snoozedUntil
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
            fifoPath: fifoPath, snoozedUntil: snoozedUntil,
            id: id  // preserve identity across snooze cycles
        )
    }
}

final class EventStore: ObservableObject {

    @Published private(set) var events: [NudgeEvent] = []
    @Published var selectedID: NudgeEvent.ID?

    private let maxEvents = 5

    /// Called on main queue after each new event is inserted.
    var onAppend: ((NudgeEvent) -> Void)?

    func append(_ event: NudgeEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        if selectedID != event.id { selectedID = event.id }
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

    var selectedEvent: NudgeEvent? {
        events.first { $0.id == selectedID }
    }
}
