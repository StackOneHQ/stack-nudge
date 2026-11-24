import Foundation

// The line protocol between the host and a service extension: one JSON object
// per line, both ways, each with a `type`. Pure encoding and decoding only, so
// every rule about what a line may say is testable without a process. See
// docs/design/service-extensions.md, "Protocol".
//
// JSONSerialization rather than Codable, unlike the manifest, because a line is
// dispatched on `type` before anything else about it is known, and the protocol
// grows by adding types an older host must skip rather than fail on.
enum ServiceProtocol {

    // Sent in `hello`; the extension's `ready` must name the same number. A bump
    // is for changes that restrict. Additive ones need nothing.
    static let version = 1

    // The document line carries the same ceiling as a view extension's stdout,
    // so a document that fits one mode fits the other. Everything else is a
    // short control message, and 64 KB is generous for any of them.
    static let maxDocumentLineBytes = ProcessOutput.maxOutputBytes
    static let maxLineBytes = 64 * 1024

    // MARK: - Host to extension

    // A scalar in an event payload. Events are the app's own, so their shape is
    // ours to keep flat; a nested value would be a design change, not a field.
    enum Value: Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)

        var json: Any {
            switch self {
            case .string(let s): return s
            case .int(let n):    return n
            case .bool(let b):   return b
            }
        }
    }

    enum HostMessage: Equatable {
        // `capabilities` is what was granted, which may be less than declared.
        case hello(protocol: Int, capabilities: [String])
        case config(values: [String: String])
        case event(name: String, fields: [String: Value])
        // A key the user pressed on its tab, resolved against its latest
        // document the way a view's `run --action` is. `row` is set for a row's
        // own action.
        case action(id: String, row: String?)
        // The action on one of its feed events, pressed from Events. `key` is
        // the event's own key, which is how the extension knows which one.
        case feedAction(id: String, key: String)
        case ping(id: Int)
        case stop
        // An MCP client called one of the extension's tools (ExtensionMCP).
        // `arguments` is the client's JSON object, already checked to be one;
        // `caller` is the client as the bridge saw it, never as a model claims.
        case mcpCall(id: Int, tool: String, arguments: Data, caller: [String: Value])
    }

    // One line, newline included. Keys are sorted so the bytes are stable,
    // which is what lets a test compare them. JSONSerialization escapes any
    // newline inside a string, so a payload can never split the line.
    static func encode(_ message: HostMessage) -> Data {
        var object: [String: Any]
        switch message {
        case .hello(let version, let capabilities):
            object = ["type": "hello", "protocol": version, "capabilities": capabilities]
        case .config(let values):
            object = ["type": "config", "values": values]
        case .event(let name, let fields):
            object = fields.mapValues(\.json)
            // Set after the fields, so a payload key can't rename the event or
            // pass it off as another message type.
            object["type"] = "event"
            object["name"] = name
        case .action(let id, let row):
            object = ["type": "action", "id": id]
            if let row { object["row"] = row }
        case .feedAction(let id, let key):
            object = ["type": "action", "id": id, "feed": key]
        case .ping(let id):
            object = ["type": "ping", "id": id]
        case .stop:
            object = ["type": "stop"]
        case .mcpCall(let id, let tool, let arguments, let caller):
            object = ["type": "mcp.call", "id": id, "tool": tool,
                      "arguments": (try? JSONSerialization.jsonObject(with: arguments)) ?? [String: Any](),
                      "caller": caller.mapValues(\.json)]
        }
        // Every value above is a String, Int, Bool or a collection of them, so
        // serialisation cannot fail; the fallback is for the type checker.
        var data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"type":"stop"}"#.utf8)
        data.append(0x0A)
        return data
    }

    // MARK: - Extension to host

    enum ExtensionMessage: Equatable {
        case ready(protocol: Int)
        case document(ExtensionDocument)
        case signal(name: String, value: String)
        case feed(FeedPost)
        // Takes its feed event with this key out of Events, when whatever it
        // stood for has been dealt with elsewhere.
        case retract(key: String)
        case pong(id: Int)
        // The values a `dynamic` config key may take right now, for its
        // Settings picker. Whether the key is declared, and dynamic, is the
        // host's to check: this only knows the line.
        case choices(key: String, options: [ConfigOption])
        // The answer to an mcp.call: a string or an object, kept as JSON
        // bytes, and whether it's an error the client should see as one.
        case mcpResult(id: Int, result: Data, isError: Bool)
        // An occurrence of one of the extension's declared event types.
        case mcpEvent(name: String, data: Data, eventID: String?)
    }

    // A feed event, as an extension posts one. Text is trimmed to fit, as a
    // document's is, but what names something (the key, the tag, the action)
    // is refused when it's wrong rather than trimmed into another name.
    struct FeedPost: Equatable {
        let title: String
        let message: String
        let tag: String?
        let severity: EventSeverity
        let url: URL?
        // Replaces an earlier event of this extension's with the same key, and
        // is what an action and a retract name.
        let key: String?
        let action: FeedAction?

        static let maxTitle = 256
        static let maxMessage = 4096
        static let maxName = 64

        static func parse(_ object: [String: Any]) -> Result<FeedPost, InvalidLine> {
            guard let rawTitle = object["title"] as? String,
                  case let title = clipped(rawTitle, maxTitle), !title.isEmpty
            else { return .failure(.init("feed event without a title")) }
            let message = clipped((object["message"] as? String) ?? "", maxMessage)
            let tag = object["tag"] as? String
            if let tag, !isName(tag) { return .failure(.init("feed event with a tag that isn't a short name")) }
            let key = object["key"] as? String
            if let key, !isName(key) { return .failure(.init("feed event with a key that isn't a short name")) }
            var severity = EventSeverity.info
            if let raw = object["severity"] {
                guard let name = raw as? String, let parsed = EventSeverity(rawValue: name)
                else { return .failure(.init("feed event with a severity that isn't info, action or alert")) }
                severity = parsed
            }
            var action: FeedAction?
            if let raw = object["action"] {
                guard let entry = raw as? [String: Any],
                      let id = entry["id"] as? String, isName(id),
                      let label = entry["label"] as? String,
                      case let shown = clipped(label, maxName), !shown.isEmpty
                else { return .failure(.init("feed event with an action that needs an id and a label")) }
                // Without a key the extension couldn't tell which event the
                // press was for.
                guard key != nil else { return .failure(.init("feed event with an action but no key")) }
                action = FeedAction(id: id, label: shown)
            }
            return .success(FeedPost(title: title, message: message, tag: tag, severity: severity,
                                     url: EventStore.webURL(object["url"] as? String), key: key,
                                     action: action))
        }

        // Letters, digits and `-_.:`, up to 64. Names go into the event log and
        // come back in an `action` line, so they stay plain.
        static func isName(_ value: String) -> Bool {
            !value.isEmpty && value.count <= maxName && value.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0))
            }
        }

        private static func clipped(_ value: String, _ limit: Int) -> String {
            String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
    }

    struct InvalidLine: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // More than a picker can sensibly step through, or a label longer than a
    // row can show, is refused rather than trimmed: the extension sent
    // something it shouldn't have, and quietly showing part of it would hide
    // that.
    static let maxChoices = ConfigKind.maxOptions

    // What one line turned out to be. `ignored` is an unknown type, which is
    // how the protocol stays additive; `invalid` is a known type that broke its
    // own rules, which is the extension's bug and worth reporting. A document
    // that doesn't parse is kept apart from the rest, because the tab shows it
    // the way it shows a view extension's malformed stdout.
    enum Inbound: Equatable {
        case message(ExtensionMessage)
        case ignored(type: String)
        case invalid(String)
        case invalidDocument(String)
        case oversized(bytes: Int)
    }

    static func decode(_ line: Data) -> Inbound {
        // Only a document may be longer than a control line, and a line that
        // doesn't so much as mention one can't be a document, so it is refused
        // here without parsing up to 8 MB of it first. One that does mention it
        // is parsed, and its real type checked below. (A type spelled with
        // \u escapes would be refused too; nothing prints it that way.)
        if line.count > maxLineBytes, line.range(of: Data(#""document""#.utf8)) == nil {
            return .oversized(bytes: line.count)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return .invalid("not a JSON object") }
        guard let type = object["type"] as? String else { return .invalid("no \"type\"") }
        // The per-type ceiling. The splitter can only enforce the larger one,
        // since a line's type isn't known until the line is whole.
        if line.count > maxLineBytes, type != "document" {
            return .oversized(bytes: line.count)
        }
        switch type {
        case "ready":
            guard let version = integer(object["protocol"]) else {
                return .invalid("ready without a protocol")
            }
            return .message(.ready(protocol: version))
        case "document":
            guard let document = object["document"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: document)
            else { return .invalidDocument("document without a document object") }
            switch ExtensionDocument.parse(data) {
            case .success(let parsed):   return .message(.document(parsed))
            case .failure(let failure):  return .invalidDocument(failure.message)
            }
        case "signal":
            guard let name = object["name"] as? String, let value = object["value"] as? String
            else { return .invalid("signal without a name and value") }
            return .message(.signal(name: name, value: value))
        case "feed":
            guard let event = object["event"] as? [String: Any]
            else { return .invalid("feed without an event object") }
            switch FeedPost.parse(event) {
            case .success(let post):    return .message(.feed(post))
            case .failure(let failure): return .invalid(failure.message)
            }
        case "retract":
            guard let key = object["key"] as? String, FeedPost.isName(key)
            else { return .invalid("retract without a key") }
            return .message(.retract(key: key))
        case "pong":
            guard let id = integer(object["id"]) else { return .invalid("pong without an id") }
            return .message(.pong(id: id))
        case "choices":
            guard let key = object["key"] as? String, ExtensionManifest.isPassableConfigKey(key) else {
                return .invalid("choices without a STACKNUDGE_EXT_ key")
            }
            guard let list = object["options"] as? [[String: Any]] else {
                return .invalid("choices without a list of options")
            }
            guard list.count <= maxChoices else {
                return .invalid("choices with more than \(maxChoices) options")
            }
            var options: [ConfigOption] = []
            for entry in list {
                // The value is written into the config file when picked, so it
                // has to be one the file can hold.
                guard let value = entry["value"] as? String, ConfigKind.isStorable(value),
                      let label = entry["label"] as? String, !label.isEmpty,
                      label.count <= ConfigKind.maxOptionLength,
                      !ConfigFile.containsLineBreak(label),
                      ExtensionConfigValue.problem(with: label) == nil
                else { return .invalid("choices with an option that can't be stored or shown") }
                if !options.contains(where: { $0.value == value }) {
                    options.append(ConfigOption(value: value, label: label))
                }
            }
            return .message(.choices(key: key, options: options))
        case "mcp.result":
            guard let id = integer(object["id"]) else { return .invalid("mcp.result without an id") }
            let result = object["result"] ?? ""
            guard result is String || result is [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys])
            else { return .invalid("mcp.result's result must be a string or an object") }
            let isError = (object["isError"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            return .message(.mcpResult(id: id, result: data, isError: isError))
        case "mcp.event":
            guard let name = object["name"] as? String, ExtensionMCP.isValidName(name) else {
                return .invalid("mcp.event without a valid name")
            }
            guard let payload = object["data"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
            else { return .invalid("mcp.event without a data object") }
            let eventID = (object["eventId"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
            return .message(.mcpEvent(name: name, data: data, eventID: eventID))
        default:
            return .ignored(type: type)
        }
    }

    // JSONSerialization hands back NSNumber for both 1 and true, so a bare
    // `as? Int` would read `"id": true` as 1. Booleans are refused, and so is
    // anything with a fractional part.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return Double(int) == number.doubleValue ? int : nil
    }

    // MARK: - Lines

    // Splits a byte stream into lines, however the reads happen to fall: a line
    // can arrive in many pieces, and one read can carry many lines.
    //
    // Bounded. A line growing past `limit` is dropped as soon as it crosses it,
    // rather than buffered to the end, and everything up to its newline is
    // discarded as it arrives, so an extension that never prints a newline costs
    // at most `limit` bytes of memory.
    struct LineSplitter {
        enum Piece: Equatable {
            case line(Data)
            case oversized(bytes: Int)
        }

        let limit: Int
        private var buffer = Data()
        // Bytes of a line already over the limit, while we wait for its end.
        private var discarding: Int?

        init(limit: Int = ServiceProtocol.maxDocumentLineBytes) {
            self.limit = limit
        }

        mutating func feed(_ data: Data) -> [Piece] {
            var pieces: [Piece] = []
            var rest = data[...]
            while !rest.isEmpty {
                guard let newline = rest.firstIndex(of: 0x0A) else {
                    absorb(rest)
                    break
                }
                absorb(rest[rest.startIndex..<newline])
                rest = rest[rest.index(after: newline)...]
                if let dropped = discarding {
                    discarding = nil
                    pieces.append(.oversized(bytes: dropped))
                } else {
                    var line = buffer
                    buffer = Data()
                    // Tolerate CRLF from an extension written on another
                    // platform's habits; JSON never ends in a bare CR.
                    if line.last == 0x0D { line.removeLast() }
                    if !line.isEmpty { pieces.append(.line(line)) }
                }
            }
            return pieces
        }

        // Adds a fragment with no newline in it to the line being built, or to
        // the count of one being discarded.
        private mutating func absorb(_ fragment: Data.SubSequence) {
            if let dropped = discarding {
                discarding = dropped + fragment.count
            } else if buffer.count + fragment.count > limit {
                discarding = buffer.count + fragment.count
                buffer = Data()
            } else {
                buffer.append(contentsOf: fragment)
            }
        }
    }
}
