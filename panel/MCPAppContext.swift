import Combine
import Foundation

// The MCP server's view of the running app. Requests arrive on connection
// threads, and nav and the stores are main-thread objects, so every read hops
// to main.
final class MCPAppContext: MCPContext {

    private weak var nav: PanelNav?
    private weak var store: EventStore?
    private weak var sessionStore: SessionStore?

    init(nav: PanelNav, store: EventStore, sessions: SessionStore) {
        self.nav = nav
        self.store = store
        self.sessionStore = sessions
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
            return MCPSessions.snapshot(sessionStore.sessions, events: store?.events ?? [],
                                        allowTabTitle: nav?.tabTitleNames ?? false)
        }
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

// The sessions as a client sees them. Pure, for tests.
enum MCPSessions {

    static func snapshot(_ sessions: [Session], events: [NudgeEvent], allowTabTitle: Bool) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        return sessions.filter { $0.status == .active }.map { session in
            var entry: [String: Any] = [
                "pid": session.pid,
                "agent": session.agent,
                "name": SessionLabel.displayName(for: session, fallback: session.agent, allowTabTitle: allowTabTitle),
                "busy": session.liveStatus == "busy",
                "waitingOnUser": isWaiting(session, events: events),
            ]
            if let project = session.projectName { entry["project"] = project }
            if let path = session.projectPath { entry["path"] = path }
            if let terminal = session.terminalApp { entry["terminal"] = terminal }
            if let id = session.claudeSessionID { entry["claudeSessionId"] = id }
            if let at = session.lastActivityAt { entry["lastActivity"] = iso.string(from: at) }
            return entry
        }
    }

    // A permission prompt from this session is still in Events: answered and
    // dead prompts leave the queue, so one that's there is waiting.
    static func isWaiting(_ session: Session, events: [NudgeEvent]) -> Bool {
        events.contains { event in
            guard event.kind == .permission, !event.isFeed else { return false }
            if let id = session.claudeSessionID, let eventID = event.claudeSessionID { return id == eventID }
            if let pid = event.agentPID { return pid == session.pid }
            return false
        }
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
    private var lastSessions = ""
    private var cancellables = Set<AnyCancellable>()

    init(server: MCPServer, nav: PanelNav, store: EventStore, sessions: SessionStore) {
        self.server = server
        self.nav = nav
        self.store = store
        self.sessionStore = sessions
        lastSettings = Self.values(SettingsRegistry.snapshot(nav))
        lastSessions = sessionsSignature()
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
        lastSettings = Self.values(snapshot)
        var uris = MCPSession.settingsURIs(changed: changed)
        let sessions = sessionsSignature()
        if sessions != lastSessions {
            lastSessions = sessions
            uris.insert(MCPSession.sessionsURI)
        }
        server.resourcesUpdated(uris)
    }

    private static func values(_ snapshot: [SettingSnapshot]) -> [String: SettingValue] {
        Dictionary(snapshot.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func sessionsSignature() -> String {
        guard let sessionStore else { return "" }
        let entries = MCPSessions.snapshot(sessionStore.sessions, events: store?.events ?? [],
                                           allowTabTitle: nav?.tabTitleNames ?? false)
            // lastActivity moves on every tick of a busy session; a client
            // subscribing to the list wants to hear about sessions coming,
            // going, and starting or stopping waiting.
            .map { $0.filter { $0.key != "lastActivity" } }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
