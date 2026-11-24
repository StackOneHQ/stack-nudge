import Foundation

// What a service extension offers MCP clients through stack-nudge's server:
// tools a client can call, routed to the extension as `mcp.call`, and event
// types it emits as `mcp.event`. Declared in the manifest's `mcp` block,
// checked at install like the rest of the manifest, and offered only while the
// extension holds the `mcp` capability. Names are namespaced by the
// extension's id, so `pylon` declaring `sla_breach` offers `pylon.sla_breach`
// (docs/design/local-mcp.md, "Extensions").
struct ExtensionMCP: Equatable {

    struct Tool: Equatable {
        let name: String
        let description: String
        // A JSON Schema object, kept as its JSON so the manifest stays
        // Equatable.
        let inputSchema: Data
    }

    struct Event: Equatable {
        let name: String
        let description: String
        // Subscription arguments: each narrows to occurrences whose data has
        // that string field equal to the argument.
        let filters: [String: String]
        let payloadSchema: Data
    }

    var tools: [Tool] = []
    var events: [Event] = []

    var isEmpty: Bool { tools.isEmpty && events.isEmpty }

    static let maxEach = 16
    static let maxDescription = 500

    // A name inside the extension's namespace: lowercase, a letter first.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase, name.count <= 40 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    // The manifest's `mcp` value, or why it isn't one. Absent is empty.
    static func parse(_ raw: Any?) -> Result<ExtensionMCP, ExtensionManifest.ParseFailure> {
        guard let raw else { return .success(ExtensionMCP()) }
        guard let object = raw as? [String: Any] else { return .failure(.invalidMCP("mcp must be an object")) }
        var parsed = ExtensionMCP()
        let tools = object["tools"] as? [[String: Any]] ?? []
        let events = object["events"] as? [[String: Any]] ?? []
        guard tools.count <= maxEach, events.count <= maxEach else {
            return .failure(.invalidMCP("at most \(maxEach) tools and \(maxEach) events"))
        }
        for entry in tools {
            guard let name = entry["name"] as? String, isValidName(name) else {
                return .failure(.invalidMCP("a tool name must be lowercase letters, digits and _, starting with a letter"))
            }
            guard let description = describe(entry["description"]) else {
                return .failure(.invalidMCP("tool \(name) needs a description of up to \(maxDescription) characters"))
            }
            guard let schema = objectSchema(entry["inputSchema"] ?? ["type": "object"]) else {
                return .failure(.invalidMCP("tool \(name)'s inputSchema must be an object schema"))
            }
            guard !parsed.tools.contains(where: { $0.name == name }) else {
                return .failure(.invalidMCP("tool \(name) is declared twice"))
            }
            parsed.tools.append(Tool(name: name, description: description, inputSchema: schema))
        }
        for entry in events {
            guard let name = entry["name"] as? String, isValidName(name) else {
                return .failure(.invalidMCP("an event name must be lowercase letters, digits and _, starting with a letter"))
            }
            guard let description = describe(entry["description"]) else {
                return .failure(.invalidMCP("event \(name) needs a description of up to \(maxDescription) characters"))
            }
            guard let schema = objectSchema(entry["payloadSchema"] ?? ["type": "object"]) else {
                return .failure(.invalidMCP("event \(name)'s payloadSchema must be an object schema"))
            }
            let filters = entry["filters"] as? [String: String] ?? [:]
            guard (entry["filters"] == nil || entry["filters"] is [String: String]),
                  filters.keys.allSatisfy(isValidName)
            else { return .failure(.invalidMCP("event \(name)'s filters map argument names to descriptions")) }
            guard !parsed.events.contains(where: { $0.name == name }) else {
                return .failure(.invalidMCP("event \(name) is declared twice"))
            }
            parsed.events.append(Event(name: name, description: description, filters: filters, payloadSchema: schema))
        }
        return .success(parsed)
    }

    private static func describe(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= maxDescription else { return nil }
        return text
    }

    private static func objectSchema(_ raw: Any) -> Data? {
        guard let schema = raw as? [String: Any], (schema["type"] as? String) == "object",
              JSONSerialization.isValidJSONObject(schema)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }

    // MARK: - As the server offers them

    static func toolName(_ id: String, _ tool: String) -> String { "\(id).\(tool)" }

    func toolsJSON(owner id: String, name: String) -> [[String: Any]] {
        tools.map { tool in
            ["name": Self.toolName(id, tool.name),
             "title": "\(name): \(tool.name)",
             "description": "From the \(name) extension. \(tool.description)",
             "inputSchema": (try? JSONSerialization.jsonObject(with: tool.inputSchema)) ?? ["type": "object"],
             "_meta": ["stack-nudge/extension": id]]
        }
    }

    func eventTypes(owner id: String) -> [MCPEventHub.EventType] {
        events.map { event in
            MCPEventHub.EventType(name: Self.toolName(id, event.name),
                                  description: event.description, filters: event.filters,
                                  payloadSchema: ((try? JSONSerialization.jsonObject(with: event.payloadSchema))
                                                  as? [String: Any]) ?? ["type": "object"],
                                  owner: id)
        }
    }
}
