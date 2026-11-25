import Foundation

// A nudge an MCP client raised with the notify tool, and where acting on it
// takes you. Pure, for tests (docs/design/local-mcp.md, "Knowing who's
// calling").
enum MCPNudge {

    enum Kind: String, CaseIterable {
        case done, waiting, info

        var severity: EventSeverity {
            switch self {
            case .waiting:      return .action
            case .done, .info:  return .info
            }
        }
    }

    struct Request: Equatable {
        let title: String
        let message: String
        let kind: Kind
        let url: URL?
        let tag: String?
    }

    // Why a notify call was refused, as the tool result says it.
    struct Refusal: Error, Equatable {
        let message: String
    }

    static let maxTitle = 200
    static let maxMessage = 2000

    // The notify tool's arguments, checked. A link must be https, as the hook
    // socket's are (EventStore.webURL); a tag is short and plain, since tags
    // become chips and filter keys.
    static func request(from arguments: [String: Any]) -> Result<Request, Refusal> {
        guard let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return .failure(Refusal(message: "notify needs a title.")) }
        let message = (arguments["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Kind
        if let raw = arguments["kind"] as? String {
            guard let parsed = Kind(rawValue: raw) else {
                let kinds = Kind.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure(Refusal(message: "kind is one of: \(kinds)."))
            }
            kind = parsed
        } else {
            kind = .info
        }
        var url: URL?
        if let raw = arguments["url"] as? String, !raw.isEmpty {
            guard let parsed = EventStore.webURL(raw), parsed.scheme?.lowercased() == "https" else {
                return .failure(Refusal(message: "url must be an https link."))
            }
            url = parsed
        }
        var tag: String?
        if let raw = arguments["tag"] as? String, !raw.isEmpty {
            guard raw.count <= 32, raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return .failure(Refusal(message: "tag is up to 32 letters, digits, - or _.")) }
            tag = raw.lowercased()
        }
        return .success(Request(title: String(title.prefix(maxTitle)),
                                message: String(message.prefix(maxMessage)),
                                kind: kind, url: url, tag: tag))
    }

    // The session a caller is running in: by the Claude Code session id its
    // bridge saw, else by the process that launched the bridge (an agent CLI
    // runs its MCP servers as children).
    static func session(for caller: MCPCaller, in sessions: [Session]) -> Session? {
        let live = sessions.filter { $0.status == .active }
        if let id = caller.claudeSessionID, let match = live.first(where: { $0.claudeSessionID == id }) {
            return match
        }
        if let pid = caller.parentPID, let match = live.first(where: { $0.pid == pid }) {
            return match
        }
        return nil
    }

    // The feed event: source mcp, so it can never be a permission prompt and
    // has its own cap in the queue. It carries what acting on it needs to take
    // you back: the session's pid and Claude session id, or the launching
    // app's bundle id. And what to say, since a client asked for the user's
    // attention: with banners off, voice may be the only way they hear it.
    // `sound` is the user's own, for when voice is off.
    static func event(_ request: Request, caller: MCPCaller, session: Session?, sound: String? = nil) -> NudgeEvent {
        NudgeEvent(agent: caller.displayName, kind: .other, title: request.title, message: request.message,
                   projectPath: session?.projectPath,
                   bundleID: session == nil ? caller.parentBundleID : nil,
                   agentPID: session?.pid,
                   terminalApp: session?.terminalApp,
                   voiceMessage: "\(caller.displayName): \(request.title)", soundName: sound,
                   claudeSessionID: session?.claudeSessionID ?? caller.claudeSessionID,
                   source: .mcp, tag: request.tag ?? "mcp", severity: request.kind.severity,
                   url: request.url)
    }

    // Where acting on the nudge goes, while it's still there to go to.
    static func liveSession(for event: NudgeEvent, in sessions: [Session]) -> Session? {
        let live = sessions.filter { $0.status == .active }
        if let id = event.claudeSessionID, let match = live.first(where: { $0.claudeSessionID == id }) {
            return match
        }
        if let pid = event.agentPID, let match = live.first(where: { $0.pid == pid }) {
            return match
        }
        return nil
    }

    // The audit line a settings change leaves in Events.
    static func auditEvent(caller: MCPCaller, setting: SettingSnapshot) -> NudgeEvent {
        NudgeEvent.feed(source: .mcp, tag: "settings", severity: .info,
                        title: "\(caller.displayName) set \(setting.label) to \(SettingsRegistry.describe(setting.value))",
                        message: "Changed over MCP. Settings has the switch for this.")
    }
}
