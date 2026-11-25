import Foundation

// What the server reads from the app. The real one hops to main and reads nav
// and the stores; tests pass a fake, so the protocol is tested without an app.
protocol MCPContext: AnyObject {
    var serverVersion: String { get }
    func settings() -> [SettingSnapshot]
    func sessions() -> [[String: Any]]
    // Changes a setting, as `caller`, and leaves a line in Events saying so.
    func writeSetting(key: String, value: Any, caller: MCPCaller) -> Result<SettingSnapshot, SettingsRegistry.WriteFailure>
    // Raises a nudge in Events from `caller`.
    func raiseNudge(_ request: MCPNudge.Request, caller: MCPCaller)
    // Mutes for `minutes` (0 resumes), sparing permission prompts. Says what
    // it did.
    func mute(minutes: Int, caller: MCPCaller) -> String
}

// One client's conversation with the server, from the bridge's hello to the
// connection closing. Speaks both 2026-07-28 (server/discover, per-request
// _meta, subscriptions/listen) and the older initialize handshake with
// resources/subscribe, since the clients we target still send the latter.
//
// Thread-safe: requests arrive on the connection's reader, and change
// notifications from the app's observer.
final class MCPSession {

    static let settingsURI = "stacknudge://settings"
    static let sessionsURI = "stacknudge://sessions"
    static let settingsCategoryPrefix = "stacknudge://settings/"

    private let context: MCPContext
    private let events: MCPEventHub
    private let send: ([String: Any]) -> Void
    private let lock = NSLock()
    private(set) var caller: MCPCaller

    // resources/subscribe from an older client: URIs it wants
    // notifications/resources/updated for.
    private var legacySubscriptions: Set<String> = []
    // subscriptions/listen streams, by the request's id.
    private var listeners: [Listener] = []
    // Whether the client speaks 2026-07-28. Such a client hears a notification
    // only on a stream that asked for it; an older one hears list changes
    // unasked, as its revision allows.
    private var modernClient = false

    private struct Listener {
        let id: Any
        let resourceURIs: Set<String>
        let toolsListChanged: Bool
        let resourcesListChanged: Bool
        var eventsListChanged = false
    }

    // events/stream subscriptions, one per request.
    private var streams: [EventStream] = []

    private final class EventStream {
        let id: Any
        let name: String
        let arguments: [String: String]
        let heartbeatMs: Int
        var lastSequence: Int
        var lastSentAt = Date()
        var timer: DispatchSourceTimer?

        init(id: Any, name: String, arguments: [String: String], heartbeatMs: Int, lastSequence: Int) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.heartbeatMs = heartbeatMs
            self.lastSequence = lastSequence
        }
    }

    init(context: MCPContext, events: MCPEventHub = MCPEventHub(), caller: MCPCaller,
         send: @escaping ([String: Any]) -> Void) {
        self.context = context
        self.events = events
        self.caller = caller
        self.send = send
    }

    // The connection closed: stop every stream's heartbeat.
    func close() {
        lock.lock()
        let open = streams
        streams.removeAll()
        listeners.removeAll()
        lock.unlock()
        open.forEach { $0.timer?.cancel() }
    }

    // MARK: - Incoming

    func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }   // a response to nothing we sent
        let id = MCPProtocol.requestID(of: message)
        let params = message["params"] as? [String: Any] ?? [:]
        noteClient(params: params)

        // A notification: never answered.
        guard let id else {
            if method == "notifications/cancelled" { cancel(params["requestId"]) }
            return
        }
        if let version = (params["_meta"] as? [String: Any])?[MCPProtocol.metaProtocolVersion] as? String,
           version != MCPProtocol.currentVersion {
            // Only the revisions that carry _meta: the older ones are reached
            // through initialize, never named per request.
            send(MCPProtocol.error(id: id, code: MCPProtocol.unsupportedProtocolVersion,
                                   message: "Unsupported protocol version \(version)",
                                   data: ["supported": [MCPProtocol.currentVersion]]))
            return
        }
        let modern = (params["_meta"] as? [String: Any])?[MCPProtocol.metaProtocolVersion] != nil
            || method == "server/discover"
        if modern {
            lock.lock()
            modernClient = true
            lock.unlock()
        }
        do {
            switch method {
            case "initialize":                respond(id, initialize(params), modern: false)
            case "server/discover":           respond(id, discover(), modern: true)
            case "ping":                      respond(id, [:], modern: modern)
            case "tools/list":                respond(id, cacheable(["tools": tools()]), modern: modern)
            case "tools/call":                respond(id, try callTool(params), modern: modern)
            case "resources/list":            respond(id, cacheable(["resources": resources()]), modern: modern)
            case "resources/templates/list":  respond(id, cacheable(["resourceTemplates": resourceTemplates()]), modern: modern)
            case "resources/read":            respond(id, cacheable(try readResource(params)), modern: modern)
            case "resources/subscribe":       respond(id, try subscribe(params), modern: modern)
            case "resources/unsubscribe":     respond(id, unsubscribe(params), modern: modern)
            case "subscriptions/listen":      listen(id: id, params: params)
            case "events/list":               respond(id, ["events": events.types.map(\.json)], modern: modern)
            case "events/poll":               respond(id, try poll(params), modern: modern)
            case "events/stream":             try stream(id: id, params: params)
            default:
                send(MCPProtocol.error(id: id, code: MCPProtocol.methodNotFound, message: "Method not found: \(method)"))
            }
        } catch let failure as MCPFailure {
            send(MCPProtocol.error(id: id, code: failure.code, message: failure.message))
        } catch {
            send(MCPProtocol.error(id: id, code: MCPProtocol.internalError, message: "\(error)"))
        }
    }

    // The client names itself in initialize's clientInfo or every request's
    // _meta. Only the name and version are kept, for display.
    private func noteClient(params: [String: Any]) {
        let info = params["clientInfo"] as? [String: Any]
            ?? (params["_meta"] as? [String: Any])?[MCPProtocol.metaClientInfo] as? [String: Any]
        guard let info, let name = info["name"] as? String else { return }
        lock.lock()
        caller.clientName = name
        caller.clientVersion = info["version"] as? String
        lock.unlock()
    }

    // A day: a mute an agent asked for always ends on its own.
    static let maxMuteMinutes = 24 * 60

    private var currentCaller: MCPCaller {
        lock.lock()
        defer { lock.unlock() }
        return caller
    }

    private func respond(_ id: Any, _ result: [String: Any], modern: Bool) {
        var result = result
        result["resultType"] = "complete"
        if modern {
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[MCPProtocol.metaServerInfo] = serverInfo
            result["_meta"] = meta
        }
        send(MCPProtocol.response(id: id, result: result))
    }

    // List and read results say how long they stay fresh (2026-07-28). Short:
    // settings change under the client whenever someone opens Settings.
    private func cacheable(_ result: [String: Any]) -> [String: Any] {
        var result = result
        result["ttlMs"] = 0
        result["cacheScope"] = "private"
        return result
    }

    // MARK: - Handshakes

    private var serverInfo: [String: Any] {
        ["name": "stack-nudge", "version": context.serverVersion]
    }

    static let instructions = """
        stack-nudge is the menu-bar app that tells this person when their coding agents finish or wait \
        on them. Use notify to tell them something here: a long task finished, or you need them, with a \
        link back if you have one. settings_list, settings_get and settings_set read and change its \
        settings; mute quiets it for a while; sessions_list shows which agent sessions are running and \
        which are waiting on the user.
        """

    private var capabilities: [String: Any] {
        ["tools": ["listChanged": true],
         "resources": ["subscribe": true, "listChanged": true],
         "extensions": [MCPEventHub.extensionID: ["listChanged": true]]]
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let asked = params["protocolVersion"] as? String ?? ""
        let version = MCPProtocol.legacyVersions.contains(asked) ? asked : MCPProtocol.legacyVersions[0]
        return ["protocolVersion": version, "capabilities": capabilities,
                "serverInfo": serverInfo, "instructions": Self.instructions]
    }

    private func discover() -> [String: Any] {
        ["supportedVersions": [MCPProtocol.currentVersion], "capabilities": capabilities,
         "instructions": Self.instructions]
    }

    // MARK: - Tools

    struct MCPFailure: Error {
        let code: Int
        let message: String
        static func invalidParams(_ message: String) -> MCPFailure {
            MCPFailure(code: MCPProtocol.invalidParams, message: message)
        }
    }

    // In a fixed order: clients cache the list, and the spec asks for it.
    func tools() -> [[String: Any]] {
        [
            ["name": "settings_list",
             "title": "List stack-nudge settings",
             "description": "Every stack-nudge setting with its current value, the values it takes and whether "
                 + "it can be changed from here. Pass a category to narrow it.",
             "inputSchema": ["type": "object",
                             "properties": ["category": ["type": "string", "enum": SettingsRegistry.categories]],
                             "additionalProperties": false],
             "annotations": ["readOnlyHint": true]],
            ["name": "settings_get",
             "title": "Read one stack-nudge setting",
             "description": "One setting's current value, by its STACKNUDGE_ key.",
             "inputSchema": ["type": "object",
                             "properties": ["key": ["type": "string"]],
                             "required": ["key"], "additionalProperties": false],
             "annotations": ["readOnlyHint": true]],
            ["name": "settings_set",
             "title": "Change a stack-nudge setting",
             "description": "Sets one setting, by its STACKNUDGE_ key, to one of the values settings_list "
                 + "gives for it. Settings that protect permission prompts can't be changed here. Each change "
                 + "is shown to the user in stack-nudge.",
             "inputSchema": ["type": "object",
                             "properties": ["key": ["type": "string"],
                                            "value": ["description": "A boolean, number or string, as the setting takes."]],
                             "required": ["key", "value"], "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]],
            ["name": "notify",
             "title": "Nudge the user",
             "description": "Shows the user a nudge in stack-nudge: a banner and a row in Events. Use it when a "
                 + "long task finishes or you need them. Acting on it takes them to url if you give one, "
                 + "otherwise back to this session's terminal or app.",
             "inputSchema": ["type": "object",
                             "properties": [
                                "title": ["type": "string", "maxLength": MCPNudge.maxTitle],
                                "message": ["type": "string", "maxLength": MCPNudge.maxMessage],
                                "kind": ["type": "string", "enum": MCPNudge.Kind.allCases.map(\.rawValue),
                                         "description": "waiting asks for the user; done and info are heads-ups."],
                                "url": ["type": "string", "description": "An https link to take the user to."],
                                "tag": ["type": "string", "description": "A short label for filtering, like ci."],
                             ],
                             "required": ["title"], "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]],
            ["name": "mute",
             "title": "Mute stack-nudge for a while",
             "description": "Quiets banners, sound and voice for some minutes, up to a day; 0 resumes. Permission "
                 + "prompts still come through.",
             "inputSchema": ["type": "object",
                             "properties": ["minutes": ["type": "integer", "minimum": 0, "maximum": MCPSession.maxMuteMinutes]],
                             "required": ["minutes"], "additionalProperties": false],
             "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true]],
            ["name": "sessions_list",
             "title": "List agent sessions",
             "description": "The coding-agent sessions stack-nudge can see: agent, repo, and state: busy, idle, "
                 + "waiting on the user for a permission prompt, or active when the agent doesn't say.",
             "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
             "annotations": ["readOnlyHint": true]],
        ]
    }

    private func callTool(_ params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else { throw MCPFailure.invalidParams("Missing tool name") }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "settings_list":
            let category = arguments["category"] as? String
            if let category, !SettingsRegistry.categories.contains(category) {
                return MCPProtocol.toolError("No settings category \(category). Categories: "
                                             + SettingsRegistry.categories.joined(separator: ", "))
            }
            let settings = context.settings().filter { category == nil || $0.category == category }
            return MCPProtocol.toolResult(["settings": settings.map(\.json)])
        case "settings_get":
            guard let key = arguments["key"] as? String else { throw MCPFailure.invalidParams("settings_get needs a key") }
            guard let setting = context.settings().first(where: { $0.key == key }) else {
                return MCPProtocol.toolError("No setting \(key). settings_list names them all.")
            }
            return MCPProtocol.toolResult(setting.json)
        case "sessions_list":
            return MCPProtocol.toolResult(["sessions": context.sessions()])
        case "settings_set":
            guard let key = arguments["key"] as? String, let value = arguments["value"] else {
                throw MCPFailure.invalidParams("settings_set needs a key and a value")
            }
            switch context.writeSetting(key: key, value: value, caller: currentCaller) {
            case .success(let setting): return MCPProtocol.toolResult(setting.json)
            case .failure(let failure): return MCPProtocol.toolError(failure.message)
            }
        case "notify":
            switch MCPNudge.request(from: arguments) {
            case .success(let request):
                context.raiseNudge(request, caller: currentCaller)
                return MCPProtocol.toolResult("Shown to the user.")
            case .failure(let refusal):
                return MCPProtocol.toolError(refusal.message)
            }
        case "mute":
            guard let minutes = (arguments["minutes"] as? NSNumber)?.intValue,
                  (0...MCPSession.maxMuteMinutes).contains(minutes)
            else { return MCPProtocol.toolError("minutes is from 0 to \(MCPSession.maxMuteMinutes).") }
            return MCPProtocol.toolResult(context.mute(minutes: minutes, caller: currentCaller))
        default:
            throw MCPFailure.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: - Resources

    func resources() -> [[String: Any]] {
        [
            ["uri": Self.settingsURI, "name": "settings", "title": "stack-nudge settings",
             "description": "Every setting and its current value, as settings_list returns them.",
             "mimeType": "application/json"],
            ["uri": Self.sessionsURI, "name": "sessions", "title": "Agent sessions",
             "description": "The agent sessions stack-nudge sees, as sessions_list returns them.",
             "mimeType": "application/json"],
        ]
    }

    func resourceTemplates() -> [[String: Any]] {
        [["uriTemplate": Self.settingsCategoryPrefix + "{category}", "name": "settings-category",
          "title": "One category of stack-nudge settings", "mimeType": "application/json"]]
    }

    static func isKnownURI(_ uri: String) -> Bool {
        if uri == settingsURI || uri == sessionsURI { return true }
        guard uri.hasPrefix(settingsCategoryPrefix) else { return false }
        return SettingsRegistry.categories.contains(String(uri.dropFirst(settingsCategoryPrefix.count)))
    }

    private func readResource(_ params: [String: Any]) throws -> [String: Any] {
        guard let uri = params["uri"] as? String else { throw MCPFailure.invalidParams("Missing uri") }
        let body: Any
        if uri == Self.settingsURI {
            body = ["settings": context.settings().map(\.json)]
        } else if uri == Self.sessionsURI {
            body = ["sessions": context.sessions()]
        } else if uri.hasPrefix(Self.settingsCategoryPrefix), Self.isKnownURI(uri) {
            let category = String(uri.dropFirst(Self.settingsCategoryPrefix.count))
            body = ["settings": context.settings().filter { $0.category == category }.map(\.json)]
        } else {
            throw MCPFailure.invalidParams("Resource not found: \(uri)")
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["contents": [["uri": uri, "mimeType": "application/json", "text": String(decoding: data, as: UTF8.self)]]]
    }

    private func subscribe(_ params: [String: Any]) throws -> [String: Any] {
        guard let uri = params["uri"] as? String, Self.isKnownURI(uri) else {
            throw MCPFailure.invalidParams("Resource not found: \(params["uri"] ?? "")")
        }
        lock.lock()
        legacySubscriptions.insert(uri)
        lock.unlock()
        return [:]
    }

    private func unsubscribe(_ params: [String: Any]) -> [String: Any] {
        if let uri = params["uri"] as? String {
            lock.lock()
            legacySubscriptions.remove(uri)
            lock.unlock()
        }
        return [:]
    }

    // 2026-07-28: one long-lived request per stream. Acknowledged with what we
    // honour, then left open; its response is the stream's end.
    private func listen(id: Any, params: [String: Any]) {
        let filter = params["notifications"] as? [String: Any] ?? [:]
        let asked = filter["resourceSubscriptions"] as? [String] ?? []
        let uris = Set(asked.filter(Self.isKnownURI))
        var listener = Listener(id: id, resourceURIs: uris,
                                toolsListChanged: filter["toolsListChanged"] as? Bool ?? false,
                                resourcesListChanged: filter["resourcesListChanged"] as? Bool ?? false)
        listener.eventsListChanged = filter["eventsListChanged"] as? Bool ?? false
        var acknowledged: [String: Any] = [:]
        if listener.toolsListChanged { acknowledged["toolsListChanged"] = true }
        if listener.eventsListChanged { acknowledged["eventsListChanged"] = true }
        if listener.resourcesListChanged { acknowledged["resourcesListChanged"] = true }
        if !uris.isEmpty { acknowledged["resourceSubscriptions"] = asked.filter(Self.isKnownURI) }
        lock.lock()
        listeners.append(listener)
        lock.unlock()
        send(MCPProtocol.notification("notifications/subscriptions/acknowledged",
                                      params: ["_meta": [MCPProtocol.metaSubscriptionID: id],
                                               "notifications": acknowledged]))
    }

    private func cancel(_ requestID: Any?) {
        lock.lock()
        listeners.removeAll { MCPProtocol.sameID($0.id, requestID) }
        let cancelled = streams.filter { MCPProtocol.sameID($0.id, requestID) }
        streams.removeAll { MCPProtocol.sameID($0.id, requestID) }
        lock.unlock()
        cancelled.forEach { $0.timer?.cancel() }
    }

    // MARK: - Events

    private func eventType(_ params: [String: Any]) throws -> (MCPEventHub.EventType, [String: String]) {
        guard let name = params["name"] as? String else { throw MCPFailure.invalidParams("Missing event name") }
        guard let type = events.type(named: name) else {
            throw MCPFailure(code: MCPEventHub.notFound, message: "No event type \(name)")
        }
        switch MCPEventHub.arguments(params["arguments"], for: type) {
        case .success(let arguments): return (type, arguments)
        case .failure(let failure):   throw failure
        }
    }

    private func poll(_ params: [String: Any]) throws -> [String: Any] {
        let (type, arguments) = try eventType(params)
        let replay = events.replay(name: type.name, arguments: arguments, cursor: params["cursor"] as? String,
                                   maxAgeMs: (params["maxAgeMs"] as? NSNumber)?.intValue,
                                   maxEvents: (params["maxEvents"] as? NSNumber)?.intValue ?? 100)
        return ["events": replay.events.map { $0.json(cursor: nil) }, "cursor": events.cursor(replay.cursor),
                "truncated": replay.truncated, "hasMore": replay.hasMore, "nextPollMs": MCPEventHub.defaultPollMs]
    }

    // Confirmed with notifications/events/active, then what was missed since
    // the cursor, then live events as they happen, with a heartbeat carrying
    // the cursor whenever a heartbeat interval passes in silence. The request
    // stays open until the client cancels it.
    private func stream(id: Any, params: [String: Any]) throws {
        let (type, arguments) = try eventType(params)
        let suggested = (params["heartbeatMs"] as? NSNumber)?.intValue ?? MCPEventHub.defaultHeartbeatMs
        let heartbeatMs = min(max(suggested, 5000), 300_000)
        lock.lock()
        let replay = events.replay(name: type.name, arguments: arguments, cursor: params["cursor"] as? String,
                                   maxAgeMs: (params["maxAgeMs"] as? NSNumber)?.intValue, maxEvents: MCPEventHub.ringSize)
        let stream = EventStream(id: id, name: type.name, arguments: arguments, heartbeatMs: heartbeatMs,
                                 lastSequence: replay.events.last?.sequence ?? replay.cursor)
        streams.append(stream)
        let tag: [String: Any] = [MCPProtocol.metaSubscriptionID: id]
        send(MCPProtocol.notification("notifications/events/active",
                                      params: ["cursor": events.cursor(replay.cursor), "truncated": replay.truncated,
                                               "heartbeatMs": heartbeatMs, "_meta": tag]))
        for occurrence in replay.events {
            var body = occurrence.json(cursor: events.cursor(occurrence.sequence))
            body["_meta"] = tag
            send(MCPProtocol.notification("notifications/events/event", params: body))
        }
        lock.unlock()
        startHeartbeat(stream)
    }

    private func startHeartbeat(_ stream: EventStream) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = DispatchTimeInterval.milliseconds(stream.heartbeatMs)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self, weak stream] in
            guard let self, let stream else { return }
            self.lock.lock()
            let quiet = Date().timeIntervalSince(stream.lastSentAt) * 1000 >= Double(stream.heartbeatMs) * 0.9
            if quiet {
                stream.lastSentAt = Date()
                self.send(MCPProtocol.notification("notifications/events/heartbeat",
                                                   params: ["cursor": self.events.cursor(self.events.head),
                                                            "_meta": [MCPProtocol.metaSubscriptionID: stream.id]]))
            }
            self.lock.unlock()
        }
        stream.timer = timer
        timer.resume()
    }

    // A new occurrence: each of this client's streams it matches hears it,
    // once.
    func deliver(_ occurrence: MCPEventHub.Occurrence) {
        lock.lock()
        defer { lock.unlock() }
        for stream in streams where occurrence.sequence > stream.lastSequence
            && occurrence.matches(name: stream.name, arguments: stream.arguments) {
            stream.lastSequence = occurrence.sequence
            stream.lastSentAt = Date()
            var body = occurrence.json(cursor: events.cursor(occurrence.sequence))
            body["_meta"] = [MCPProtocol.metaSubscriptionID: stream.id]
            send(MCPProtocol.notification("notifications/events/event", params: body))
        }
    }

    // The event types changed (an extension's came or went): only on a
    // listen stream that asked, as the extension says.
    func eventsListChanged() {
        lock.lock()
        let ids = listeners.filter(\.eventsListChanged).map(\.id)
        lock.unlock()
        for id in ids {
            send(MCPProtocol.notification("notifications/events/list_changed",
                                          params: ["_meta": [MCPProtocol.metaSubscriptionID: id]]))
        }
    }

    // MARK: - Change notifications

    // Called by the app when what a resource says has changed. Each stream or
    // older subscription that asked for one of `uris` hears about it, once.
    func resourcesUpdated(_ uris: Set<String>) {
        lock.lock()
        let legacy = legacySubscriptions.intersection(uris)
        let streams = listeners.map { ($0.id, $0.resourceURIs.intersection(uris)) }.filter { !$0.1.isEmpty }
        lock.unlock()
        for uri in legacy.sorted() {
            send(MCPProtocol.notification("notifications/resources/updated", params: ["uri": uri]))
        }
        for (id, matched) in streams {
            for uri in matched.sorted() {
                send(MCPProtocol.notification("notifications/resources/updated",
                                              params: ["uri": uri, "_meta": [MCPProtocol.metaSubscriptionID: id]]))
            }
        }
    }

    // The tool list changed (an extension's tools came or went). See
    // `modernClient` for who hears it.
    func toolsListChanged() {
        lock.lock()
        let streams = listeners.filter(\.toolsListChanged).map(\.id)
        let modern = modernClient
        lock.unlock()
        if !modern {
            send(MCPProtocol.notification("notifications/tools/list_changed", params: [:]))
        }
        for id in streams {
            send(MCPProtocol.notification("notifications/tools/list_changed",
                                          params: ["_meta": [MCPProtocol.metaSubscriptionID: id]]))
        }
    }

    // The URIs a change to these settings touches: the whole list, and each
    // changed setting's category.
    static func settingsURIs(changed: [SettingSnapshot]) -> Set<String> {
        guard !changed.isEmpty else { return [] }
        return Set([settingsURI] + changed.map { settingsCategoryPrefix + $0.category })
    }
}
