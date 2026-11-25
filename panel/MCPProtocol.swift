import Foundation

// JSON-RPC 2.0 as MCP's stdio transport frames it: one object per line. Kept
// as [String: Any] rather than Codable types: the surface is small, ids are a
// number or a string, and params pass through to tools as free-form JSON.
// See docs/design/local-mcp.md.
enum MCPProtocol {

    // The revision that drops the initialize handshake for server/discover and
    // per-request _meta. Older clients still send initialize, and get one of
    // `legacyVersions` back.
    static let currentVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let unsupportedProtocolVersion = -32022

    // _meta keys from 2026-07-28.
    static let metaProtocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"
    static let metaSubscriptionID = "io.modelcontextprotocol/subscriptionId"

    // Lines are capped like the hook socket's payloads: well past any real
    // request, and short of letting a client make the app buffer without end.
    static let maxLineBytes = 1 << 20

    static func parse(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    static func encode(_ message: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    static func response(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var body: [String: Any] = ["code": code, "message": message]
        if let data { body["data"] = data }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": body]
    }

    static func notification(_ method: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "params": params]
    }

    // A tool's answer: the structured value, and the same as text for clients
    // that only read content.
    static func toolResult(_ value: Any, isError: Bool = false) -> [String: Any] {
        let text: String
        if let string = value as? String {
            text = string
        } else if JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "\(value)"
        }
        var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if value is [String: Any] { result["structuredContent"] = value }
        return result
    }

    static func toolError(_ message: String) -> [String: Any] {
        toolResult(message, isError: true)
    }

    // A JSON-RPC id is a number or a string; anything else is no id.
    static func requestID(of message: [String: Any]) -> Any? {
        switch message["id"] {
        case let number as NSNumber: return number
        case let string as String:   return string
        default:                     return nil
        }
    }

    static func sameID(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (l as String, r as String):     return l == r
        case let (l as NSNumber, r as NSNumber): return l == r
        default:                                 return false
        }
    }
}

// Who is on the other end of a bridge connection, as the bridge saw it from
// its own process, never as a model says it is (docs/design/local-mcp.md,
// "Knowing who's calling").
struct MCPCaller: Equatable {
    // From the client's handshake: initialize's clientInfo, or _meta clientInfo.
    var clientName: String? = nil
    var clientVersion: String? = nil
    // CLAUDE_CODE_SESSION_ID in the bridge's environment: Claude Code sets it
    // for every process it starts.
    var claudeSessionID: String? = nil
    // The process that launched the bridge: the agent CLI, or an app such as
    // Claude Desktop.
    var parentPID: Int? = nil
    var parentApp: String? = nil
    // The launching app's bundle id, so acting on its nudge can bring it back.
    var parentBundleID: String? = nil

    // The bridge's first line on the socket.
    static func fromHello(_ hello: [String: Any]) -> MCPCaller {
        MCPCaller(clientName: nil, clientVersion: nil,
                  claudeSessionID: (hello["claudeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  parentPID: (hello["parentPid"] as? NSNumber)?.intValue,
                  parentApp: (hello["parentApp"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  parentBundleID: (hello["parentBundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // How a feed row and an audit line name the client.
    var displayName: String {
        if let name = clientName, !name.isEmpty { return Self.friendlyName(name) }
        if let app = parentApp, !app.isEmpty { return app }
        return claudeSessionID != nil ? "Claude Code" : "An MCP client"
    }

    // Clients name themselves in code form ("claude-code"); a row reads better
    // with the product name.
    static func friendlyName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude-code", "claude code":                 return "Claude Code"
        case "claude-ai", "claude", "claude-desktop":      return "Claude"
        case "codex", "codex-mcp-client", "codex_cli_rs": return "Codex"
        default:                                           return raw
        }
    }
}
