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
        case ping(id: Int)
        case stop
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
        case .ping(let id):
            object = ["type": "ping", "id": id]
        case .stop:
            object = ["type": "stop"]
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
        // The feed event's object, re-serialised. Kept as bytes because nothing
        // consumes it yet (see ServiceSupervisor), and deciding its shape here
        // would be deciding the feed's.
        case feed(event: Data)
        case pong(id: Int)
    }

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
            guard let event = object["event"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys)
            else { return .invalid("feed without an event object") }
            return .message(.feed(event: data))
        case "pong":
            guard let id = integer(object["id"]) else { return .invalid("pong without an id") }
            return .message(.pong(id: id))
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
