import Foundation

// MCP Events (io.modelcontextprotocol/events, SEP-3415) for the local server:
// the event types stack-nudge offers, a ring of recent occurrences, and the
// cursors that let a client resume. Push (events/stream) and poll
// (events/poll) are offered; webhook needs an authenticated principal and an
// https callback, and is the relay's to add (docs/design/local-mcp.md,
// "Events").
//
// Cursors are "<epoch>.<sequence>". The epoch changes with every launch, so a
// cursor from a previous run reads as a gap rather than a position in this
// one's ring. Replay is bounded by the ring; anything older is a gap too.
final class MCPEventHub {

    static let extensionID = "io.modelcontextprotocol/events"
    static let notFound = -32023
    static let unsupported = -32026
    static let ringSize = 500
    static let defaultPollMs = 5000
    static let defaultHeartbeatMs = 30000

    struct EventType {
        let name: String
        let description: String
        // Subscription arguments: each one narrows to occurrences whose data
        // has that field equal to the argument.
        let filters: [String: String]
        let payloadSchema: [String: Any]
        // An extension's, by its id; nil for the app's own.
        var owner: String? = nil

        var json: [String: Any] {
            var properties: [String: Any] = [:]
            for (name, description) in filters {
                properties[name] = ["type": "string", "description": description]
            }
            var entry: [String: Any] = [
                "name": name, "description": description, "delivery": ["push", "poll"],
                "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false],
                "payloadSchema": payloadSchema,
            ]
            if let owner { entry["_meta"] = ["stack-nudge/extension": owner] }
            return entry
        }
    }

    struct Occurrence {
        let sequence: Int
        let eventID: String
        let name: String
        let timestamp: Date
        let data: [String: Any]

        func json(cursor: String?) -> [String: Any] {
            var entry: [String: Any] = ["eventId": eventID, "name": name,
                                        "timestamp": MCPEventHub.iso.string(from: timestamp), "data": data]
            if let cursor { entry["cursor"] = cursor }
            return entry
        }

        func matches(name: String, arguments: [String: String]) -> Bool {
            guard self.name == name else { return false }
            return arguments.allSatisfy { key, value in (data[key] as? String) == value }
        }
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let lock = NSLock()
    let epoch: String
    private var ring: [Occurrence] = []
    private var sequence = 0
    private var extensionTypes: [EventType] = []
    private let now: () -> Date

    init(epoch: String = String(UUID().uuidString.prefix(8)).lowercased(), now: @escaping () -> Date = Date.init) {
        self.epoch = epoch
        self.now = now
    }

    // MARK: Types

    var types: [EventType] {
        lock.lock()
        defer { lock.unlock() }
        return Self.appTypes + extensionTypes
    }

    func type(named name: String) -> EventType? {
        types.first { $0.name == name }
    }

    // An extension's event types replace whatever it offered before. Returns
    // whether the list changed, so the server can say so.
    @discardableResult
    func setExtensionTypes(_ types: [EventType], for owner: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = extensionTypes.filter { $0.owner == owner }.map(\.name)
        extensionTypes.removeAll { $0.owner == owner }
        extensionTypes += types.map { var type = $0; type.owner = owner; return type }
        return before != types.map(\.name)
    }

    private static let sessionFilters = ["agent": "Only this agent: claude, codex, gemini, agy or pi.",
                                         "project": "Only sessions in the project with this folder name."]

    private static func object(_ fields: [String: String], required: [String]) -> [String: Any] {
        ["type": "object", "required": required,
         "properties": fields.mapValues { type -> [String: Any] in ["type": type] }]
    }

    static let appTypes: [EventType] = [
        EventType(name: "session.waiting",
                  description: "An agent session is blocked on the user: a permission prompt or a question.",
                  filters: sessionFilters,
                  payloadSchema: object(["agent": "string", "project": "string", "path": "string",
                                         "sessionPid": "integer", "claudeSessionId": "string", "since": "string"],
                                        required: ["agent"])),
        EventType(name: "session.stopped",
                  description: "An agent session finished its turn.",
                  filters: sessionFilters,
                  payloadSchema: object(["agent": "string", "project": "string", "path": "string",
                                         "claudeSessionId": "string"], required: ["agent"])),
        EventType(name: "session.stalled",
                  description: "A session the agent still reports as busy has produced nothing for the stall window.",
                  filters: sessionFilters,
                  payloadSchema: object(["agent": "string", "project": "string", "path": "string",
                                         "sessionPid": "integer", "quietMinutes": "integer"], required: ["agent"])),
        EventType(name: "nudge.raised",
                  description: "A nudge that isn't an agent's own arrived in Events: GitHub, a script, an extension, "
                      + "or an MCP client's notify.",
                  filters: ["source": "Only nudges from this source: github, calendar, script, mcp.",
                            "tag": "Only nudges with this tag."],
                  payloadSchema: object(["source": "string", "client": "string", "title": "string",
                                         "tag": "string", "url": "string"], required: ["source", "title"])),
        EventType(name: "quota.threshold",
                  description: "A usage window crossed the quota alert threshold.",
                  filters: [:],
                  payloadSchema: object(["label": "string", "percent": "integer", "resetsAt": "string"],
                                        required: ["label", "percent"])),
        EventType(name: "settings.changed",
                  description: "A stack-nudge setting changed, from Settings, the config file or an MCP client.",
                  filters: ["key": "Only this STACKNUDGE_ key."],
                  payloadSchema: object(["key": "string", "label": "string", "value": "string",
                                         "previous": "string", "by": "string"], required: ["key", "value"])),
    ]

    // MARK: Emitting

    // Records an occurrence and returns it for live delivery. Payloads are
    // kept minimal by the callers: no prompt text or tool input.
    @discardableResult
    func emit(_ name: String, data: [String: Any], eventID: String? = nil) -> Occurrence {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let occurrence = Occurrence(sequence: sequence, eventID: eventID ?? "\(epoch)-\(sequence)",
                                    name: name, timestamp: now(), data: data)
        ring.append(occurrence)
        if ring.count > Self.ringSize { ring.removeFirst(ring.count - Self.ringSize) }
        return occurrence
    }

    func cursor(_ sequence: Int) -> String { "\(epoch).\(sequence)" }

    var head: Int {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    // MARK: Replay

    struct Replay {
        let events: [Occurrence]
        let cursor: Int
        let truncated: Bool
        let hasMore: Bool
    }

    // What a subscription missed since `cursor`: none for a null cursor (start
    // from now), and a gap when the cursor is from another launch, older than
    // the ring, or behind the maxAgeMs floor.
    func replay(name: String, arguments: [String: String], cursor: String?,
                maxAgeMs: Int?, maxEvents: Int = 100) -> Replay {
        lock.lock()
        defer { lock.unlock() }
        guard let cursor else { return Replay(events: [], cursor: sequence, truncated: false, hasMore: false) }
        let parts = cursor.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == epoch, let from = Int(parts[1]), from <= sequence else {
            return Replay(events: [], cursor: sequence, truncated: true, hasMore: false)
        }
        let oldest = ring.first?.sequence ?? sequence + 1
        var truncated = from + 1 < oldest
        var pending = ring.filter { $0.sequence > from }
        if let maxAgeMs {
            let floor = now().addingTimeInterval(-Double(maxAgeMs) / 1000)
            let kept = pending.filter { $0.timestamp >= floor }
            if kept.count < pending.count { truncated = true }
            pending = kept
        }
        let matching = pending.filter { $0.matches(name: name, arguments: arguments) }
        let batch = Array(matching.prefix(max(1, maxEvents)))
        let hasMore = matching.count > batch.count
        return Replay(events: batch, cursor: hasMore ? batch.last!.sequence : sequence,
                      truncated: truncated, hasMore: hasMore)
    }

    // A subscription's arguments, checked against its type: only declared
    // filters, each a string.
    static func arguments(_ raw: Any?, for type: EventType) -> Result<[String: String], MCPSession.MCPFailure> {
        guard let raw else { return .success([:]) }
        guard let object = raw as? [String: Any] else { return .failure(.invalidParams("arguments must be an object")) }
        var arguments: [String: String] = [:]
        for (key, value) in object {
            guard type.filters[key] != nil else {
                return .failure(.invalidParams("\(type.name) has no argument \(key)"))
            }
            guard let string = value as? String else { return .failure(.invalidParams("\(key) must be a string")) }
            arguments[key] = string
        }
        return .success(arguments)
    }
}
