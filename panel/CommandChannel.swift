import Foundation

// The request/reply form of the panel socket. A connection that sends one JSON
// line carrying a "cmd" key is a command; the reply is one JSON line and then
// the panel closes. Anything without "cmd" is an agent or feed event, exactly as
// before (no agent event has a "cmd" field), so notify.sh and extensions are
// untouched. The socket is chmod 0600 inside ~/.stack-nudge, so only the local
// user reaches it; commands add no new trust.

// A pose the companion should hold until `expiresAt`, set by the `state`
// command. The panel only stores it; the companion reads `PanelNav.poseOverride`
// (or sets `onPoseOverride`) and ignores it once `isActive` is false.
struct PoseOverride: Equatable {
    let pose: String
    let expiresAt: Date

    static let defaultTTL: TimeInterval = 30
    static let ttlRange: ClosedRange<TimeInterval> = 1...3600

    func isActive(at now: Date = Date()) -> Bool { expiresAt > now }
}

struct BusyItem: Equatable {
    let kind: String
    let target: String
    let since: Date?
}

// What is in flight, for deciding whether a relaunch would cut work off. Each
// subsystem registers its own provider by name (agent sessions here, AI runs and
// the poller on the branches that add them), so none edits another's list.
final class BusySources {
    private var providers: [String: () -> [BusyItem]] = [:]

    func register(_ name: String, _ provider: @escaping () -> [BusyItem]) {
        providers[name] = provider
    }

    func items() -> [BusyItem] {
        providers.values.flatMap { $0() }.sorted { ($0.kind, $0.target) < ($1.kind, $1.target) }
    }
}

struct CommandHooks {
    var post: (NudgeEvent) -> Void = { _ in }
    var setFocus: (Bool) -> Void = { _ in }
    var focusStatus: () -> [String: Any] = { [:] }
    // Resolved per request, and nil until the GitHub branch wires a poller. The
    // closure it returns gets how many new events the poll found.
    var poll: () -> ((@escaping (Int) -> Void) -> Void)? = { nil }
    var setPose: (PoseOverride) -> Void = { _ in }
    var busy: () -> [BusyItem] = { [] }
    // Opens the panel on Settings, on `category` when given, and returns the
    // category it is showing.
    var openSettings: (SettingsCategory?) -> SettingsCategory = { $0 ?? .notifications }
    var now: () -> Date = { Date() }
}

final class CommandRouter {
    private let hooks: CommandHooks

    init(hooks: CommandHooks) { self.hooks = hooks }

    // Whether a wire line is a command rather than an event.
    static func isCommand(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return false }
        return object["cmd"] is String
    }

    // Runs on the main thread. `reply` gets the one reply line (no newline), and
    // may be called later than this returns, from any thread.
    func handle(_ line: Data, reply: @escaping (String) -> Void) {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cmd = request["cmd"] as? String
        else { return reply(Self.encode(Self.failure("bad request"))) }

        switch cmd {
        case "ping":
            reply(Self.encode(["ok": true, "pong": true]))
        case "say":
            reply(Self.encode(say(request)))
        case "focus":
            reply(Self.encode(focus(request)))
        case "poll":
            guard let poll = hooks.poll() else { return reply(Self.encode(Self.failure("no poller"))) }
            poll { reply(Self.encode(["ok": true, "newEvents": $0])) }
        case "state":
            reply(Self.encode(state(request)))
        case "busy":
            reply(Self.encode(busy()))
        case "settings":
            reply(Self.encode(settings(request)))
        default:
            reply(Self.encode(Self.failure("unknown command \(cmd)")))
        }
    }

    static func failure(_ message: String) -> [String: Any] {
        ["ok": false, "error": message]
    }

    static func encode(_ reply: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"error":"unencodable reply","ok":false}"# }
        return text
    }

    // MARK: - Commands

    private static let sayFeedSources: Set<String> = ["github", "calendar", "script"]

    // Built as the wire event a script would post and decoded through the same
    // DTO, so the URL scheme check and the rule that a feed is never an agent
    // are the socket's own, not a second copy.
    private func say(_ request: [String: Any]) -> [String: Any] {
        let title = (request["title"] as? String) ?? ""
        guard !title.isEmpty else { return Self.failure("say needs a title") }

        let source = (request["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "script"
        guard Self.sayFeedSources.contains(source) else {
            return Self.failure("unknown source \(source)")
        }
        let severity = (request["severity"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "info"
        guard EventSeverity(rawValue: severity) != nil else {
            return Self.failure("severity must be info, action or alert")
        }

        var wire: [String: Any] = [
            "agent": "script", "event": "other", "title": title,
            "message": (request["body"] as? String) ?? "",
            "source": source, "severity": severity,
            "timestamp": hooks.now().timeIntervalSince1970,
        ]
        for field in ["url", "tag", "key"] {
            if let value = request[field] as? String, !value.isEmpty { wire[field] = value }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: wire),
              let event = EventListener.parseEvents(data).first
        else { return Self.failure("could not build the event") }
        hooks.post(event)
        return ["ok": true]
    }

    private func focus(_ request: [String: Any]) -> [String: Any] {
        switch (request["state"] as? String) ?? "status" {
        case "on":     hooks.setFocus(true)
        case "off":    hooks.setFocus(false)
        case "status": break
        default:       return Self.failure("focus state must be on, off or status")
        }
        var reply = hooks.focusStatus()
        reply["ok"] = true
        return reply
    }

    private func state(_ request: [String: Any]) -> [String: Any] {
        let pose = (request["state"] as? String) ?? ""
        guard !pose.isEmpty, pose.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return Self.failure("state needs a pose name") }
        let raw = (request["ttlSeconds"] as? Double) ?? PoseOverride.defaultTTL
        let ttl = min(max(raw, PoseOverride.ttlRange.lowerBound), PoseOverride.ttlRange.upperBound)
        hooks.setPose(PoseOverride(pose: pose, expiresAt: hooks.now().addingTimeInterval(ttl)))
        return ["ok": true, "state": pose, "ttlSeconds": ttl]
    }

    private func busy() -> [String: Any] {
        let items = hooks.busy()
        let iso = ISO8601DateFormatter()
        return ["ok": true, "busy": !items.isEmpty,
                "items": items.map { ["kind": $0.kind, "target": $0.target,
                                      "since": $0.since.map(iso.string(from:)) ?? ""] }]
    }

    private func settings(_ request: [String: Any]) -> [String: Any] {
        var category: SettingsCategory?
        if let name = request["category"] as? String, !name.isEmpty {
            guard let found = SettingsCategory(key: name) else {
                return Self.failure("unknown category \(name)")
            }
            category = found
        }
        let shown = hooks.openSettings(category)
        return ["ok": true, "current": shown.key,
                "categories": SettingsCategory.allCases.map(\.key)]
    }
}
