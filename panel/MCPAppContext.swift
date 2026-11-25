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
            return MCPSessions.list(sessionStore.sessions, events: store?.events ?? []).map(MCPSessions.json)
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
