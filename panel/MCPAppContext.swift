import Combine
import Foundation

// The MCP server's view of the running app. Requests arrive on connection
// threads, and nav and the stores are main-thread objects, so every read hops
// to main.
final class MCPAppContext: MCPContext {

    private weak var nav: PanelNav?
    private weak var store: EventStore?
    private weak var sessionStore: SessionStore?
    // The controller's mute, which owns the timer and the menu-bar badge.
    private let muteFor: (Int, Bool) -> Void
    private let resume: () -> Void
    // Set once the server exists: writes credit their client through it.
    weak var server: MCPServer?

    init(nav: PanelNav, store: EventStore, sessions: SessionStore,
         muteFor: @escaping (Int, Bool) -> Void, resume: @escaping () -> Void) {
        self.nav = nav
        self.store = store
        self.sessionStore = sessions
        self.muteFor = muteFor
        self.resume = resume
    }

    var serverVersion: String {
        BuildVersion.current()?.string ?? "unknown"
    }

    func settings() -> [SettingSnapshot] {
        onMain { nav.map(SettingsRegistry.snapshot) ?? [] }
    }

    func sessions() -> [[String: Any]] {
        onMain {
            guard let sessionStore else { return [] }
            return MCPSessions.list(sessionStore.sessions, events: store?.events ?? []).map(MCPSessions.json)
        }
    }

    func writeSetting(key: String, value: Any, caller: MCPCaller) -> Result<SettingSnapshot, SettingsRegistry.WriteFailure> {
        onMain {
            guard let nav else { return .failure(.unknownKey(key)) }
            let before = SettingsRegistry.snapshot(nav).first { $0.key == key }?.value
            server?.attribution.note(key, by: caller.displayName)
            let result = SettingsRegistry.write(key: key, raw: value, nav: nav)
            // Every change shows in Events, so one you didn't ask for is seen.
            if case .success(let setting) = result, setting.value != before {
                store?.append(MCPNudge.auditEvent(caller: caller, setting: setting))
            }
            return result
        }
    }

    func raiseNudge(_ request: MCPNudge.Request, caller: MCPCaller) {
        onMain {
            let session = MCPNudge.session(for: caller, in: sessionStore?.sessions ?? [])
            store?.append(MCPNudge.event(request, caller: caller, session: session))
        }
    }

    func mute(minutes: Int, caller: MCPCaller) -> String {
        onMain {
            guard minutes > 0 else {
                resume()
                return "Notifications resumed."
            }
            muteFor(minutes, true)
            store?.append(NudgeEvent.feed(source: .mcp, tag: "settings", severity: .info,
                                          title: "\(caller.displayName) muted notifications for \(minutes) min",
                                          message: "Permission prompts still come through."))
            return "Muted for \(minutes) \(minutes == 1 ? "minute" : "minutes"). Permission prompts still come through."
        }
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

// The sessions as a client sees them: the shape `event:session` sends, so the
// two agree on what waiting means, without the ones that have ended. Pure, for
// tests.
enum MCPSessions {

    static func list(_ sessions: [Session], events: [NudgeEvent],
                     isBlocking: (NudgeEvent) -> Bool = { $0.isStillBlocking }) -> [SessionSnapshot] {
        SessionSnapshot.list(sessions: sessions, events: events, isBlocking: isBlocking).filter { $0.state != .ended }
    }

    static func json(_ snapshot: SessionSnapshot) -> [String: Any] {
        var entry: [String: Any] = ["session": snapshot.handle, "pid": snapshot.pid, "agent": snapshot.agent,
                                    "state": snapshot.state.rawValue]
        if let repo = snapshot.repo { entry["repo"] = repo }
        if let name = snapshot.name { entry["name"] = name }
        if let id = snapshot.claudeSessionID { entry["claudeSessionId"] = id }
        return entry
    }
}

// Watches the app for changes the server's resources describe and tells every
// connected client: a setting's value, and the sessions list. Debounced, and
// compared against what was last sent, so a burst of @Published changes that
// leaves the values as they were sends nothing.
final class MCPChangeWatcher {

    private let server: MCPServer
    private weak var nav: PanelNav?
    private weak var store: EventStore?
    private weak var sessionStore: SessionStore?
    private var lastSettings: [String: SettingValue] = [:]
    private var lastSessions: [SessionSnapshot] = []
    private var cancellables = Set<AnyCancellable>()

    init(server: MCPServer, nav: PanelNav, store: EventStore, sessions: SessionStore) {
        self.server = server
        self.nav = nav
        self.store = store
        self.sessionStore = sessions
        lastSettings = Self.values(SettingsRegistry.snapshot(nav))
        lastSessions = currentSessions()
        Publishers.Merge3(nav.objectWillChange.map { _ in () },
                          store.objectWillChange.map { _ in () },
                          sessions.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.publish() }
            .store(in: &cancellables)
    }

    private func publish() {
        guard let nav else { return }
        let snapshot = SettingsRegistry.snapshot(nav)
        let changed = snapshot.filter { lastSettings[$0.key] != $0.value }
        for setting in changed {
            var data: [String: Any] = ["key": setting.key, "label": setting.label,
                                       "value": SettingsRegistry.describe(setting.value),
                                       "by": server.attribution.take(setting.key) ?? "stack-nudge"]
            if let previous = lastSettings[setting.key] { data["previous"] = SettingsRegistry.describe(previous) }
            server.emit("settings.changed", data: data)
        }
        lastSettings = Self.values(snapshot)
        var uris = MCPSession.settingsURIs(changed: changed)
        let sessions = currentSessions()
        if sessions != lastSessions {
            lastSessions = sessions
            uris.insert(MCPSession.sessionsURI)
        }
        server.resourcesUpdated(uris)
    }

    private static func values(_ snapshot: [SettingSnapshot]) -> [String: SettingValue] {
        Dictionary(snapshot.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func currentSessions() -> [SessionSnapshot] {
        guard let sessionStore else { return [] }
        return MCPSessions.list(sessionStore.sessions, events: store?.events ?? [])
    }
}

// What stack-nudge tells MCP event subscribers about, built from what the app
// already has. Minimal by design: no prompt text, tool input or message body
// (docs/design/local-mcp.md, "Events"). Pure, for tests.
enum MCPAppEvents {

    static func project(_ path: String?) -> String? {
        path.map { ($0 as NSString).lastPathComponent }
    }

    // An event arriving in Events: a prompt is a session waiting, a finished
    // turn a session stopping, and anything else a nudge.
    static func occurrence(for event: NudgeEvent) -> (name: String, data: [String: Any])? {
        if event.isFeed {
            var data: [String: Any] = ["source": event.source.rawValue, "client": event.agent, "title": event.title]
            if let tag = event.tag { data["tag"] = tag }
            if let url = event.url { data["url"] = url.absoluteString }
            return ("nudge.raised", data)
        }
        var data: [String: Any] = ["agent": event.agent]
        if let path = event.projectPath { data["path"] = path; data["project"] = project(path) }
        if let id = event.claudeSessionID { data["claudeSessionId"] = id }
        switch event.kind {
        case .permission:
            if let pid = event.agentPID { data["sessionPid"] = pid }
            data["since"] = MCPEventHub.iso.string(from: event.timestamp)
            return ("session.waiting", data)
        case .stop:
            return ("session.stopped", data)
        case .other:
            return nil
        }
    }

    static func stalled(_ session: Session, quietMinutes: Int) -> [String: Any] {
        var data: [String: Any] = ["agent": session.agent, "sessionPid": session.pid, "quietMinutes": quietMinutes]
        if let path = session.projectPath { data["path"] = path }
        if let project = session.projectName ?? project(session.projectPath) { data["project"] = project }
        return data
    }

    static func quota(label: String, percent: Int, resetsAt: Date?) -> [String: Any] {
        var data: [String: Any] = ["label": label, "percent": percent]
        if let resetsAt { data["resetsAt"] = MCPEventHub.iso.string(from: resetsAt) }
        return data
    }
}
