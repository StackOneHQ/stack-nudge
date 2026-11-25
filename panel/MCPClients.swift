import Foundation

// The MCP clients Settings → MCP → Set up for… can add stack-nudge to, and
// whether each already has it. A client's config is read, never written:
// setting one up copies what to run or paste, so stack-nudge never edits a
// file another app owns. Pure, for tests.
enum MCPClient: CaseIterable, Hashable {
    case claudeCode, claudeDesktop, codex

    var name: String {
        switch self {
        case .claudeCode:    return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex:         return "Codex"
        }
    }

    // The card's second line: what ⏎ copies.
    var summary: String {
        switch self {
        case .claudeCode:    return "Copies the claude mcp add command, for every project"
        case .claudeDesktop: return "Copies the entry for mcpServers in its config file"
        case .codex:         return "Copies the codex mcp add command"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode:    return "terminal.fill"
        case .claudeDesktop: return "macwindow"
        case .codex:         return "chevron.left.forwardslash.chevron.right"
        }
    }

    // What to run or paste, pointing at `binary`, this app's own, so it's
    // right wherever the app is installed. Claude Desktop doesn't expand ~, so
    // its path is always written out in full.
    func setup(binary: String) -> String {
        let quoted = binary.contains(" ") ? "'\(binary)'" : binary
        switch self {
        case .claudeCode:
            return "claude mcp add --scope user stack-nudge -- \(quoted) \(MCPBridge.flag)"
        case .codex:
            return "codex mcp add stack-nudge -- \(quoted) \(MCPBridge.flag)"
        case .claudeDesktop:
            return "\"stack-nudge\": {\"command\": \(Self.jsonString(binary)), \"args\": [\"\(MCPBridge.flag)\"]}"
        }
    }

    // The files a client keeps its servers in. Claude Code and Codex can each
    // run from more than one config dir; the extra ones are the logins the
    // Usage tab already found (ClaudeConfigDirs, CodexHomes).
    func configFiles(home: String, claudeDirs: [String], codexHomes: [String]) -> [String] {
        switch self {
        case .claudeCode:
            return ["\(home)/.claude.json"] + claudeDirs.map { "\($0)/.claude.json" }
        case .claudeDesktop:
            return ["\(home)/Library/Application Support/Claude/claude_desktop_config.json"]
        case .codex:
            return ["\(home)/.codex/config.toml"] + codexHomes.map { "\($0)/config.toml" }
        }
    }

    // The clients with stack-nudge in any of their config files.
    static func configured(home: String = NSHomeDirectory(), claudeDirs: [String] = [], codexHomes: [String] = [],
                           read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> Set<MCPClient> {
        Set(allCases.filter { client in
            client.configFiles(home: home, claudeDirs: claudeDirs, codexHomes: codexHomes)
                .contains { path in read(path).map(client.hasBridge) ?? false }
        })
    }

    // Whether one config file's text has a server running stack-nudge's
    // bridge, whatever it was named.
    func hasBridge(in text: String) -> Bool {
        switch self {
        case .claudeCode, .claudeDesktop: return Self.jsonHasBridge(text)
        case .codex:                      return Self.tomlHasBridge(text)
        }
    }

    // A server is stack-nudge's when it runs the app's binary with --mcp.
    static func isBridge(command: String?, args: [String]) -> Bool {
        guard let command else { return false }
        return (command as NSString).lastPathComponent == "stack-nudge" && args.contains(MCPBridge.flag)
    }

    // mcpServers at the top, as Desktop and Claude Code's user scope keep
    // them, and under each project, as Claude Code's local scope does.
    private static func jsonHasBridge(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        let projects = (root["projects"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        let servers = ([root] + projects).flatMap { ($0["mcpServers"] as? [String: Any] ?? [:]).values }
        return servers.contains { server in
            guard let server = server as? [String: Any] else { return false }
            return isBridge(command: server["command"] as? String, args: server["args"] as? [String] ?? [])
        }
    }

    // Codex's servers are `[mcp_servers.<name>]` tables. Read line by line
    // rather than as TOML: only the table's command and args matter here.
    private static func tomlHasBridge(_ text: String) -> Bool {
        let tables = text.components(separatedBy: "\n").reduce(into: [[String]]()) { tables, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                tables.append(line.hasPrefix("[mcp_servers.") ? [] : ["skip"])
            } else if !tables.isEmpty {
                tables[tables.count - 1].append(line)
            }
        }
        return tables.filter { $0.first != "skip" }.contains { lines in
            let command = lines.first { $0.hasPrefix("command") }.flatMap(quoted)
            let args = lines.drop { !$0.hasPrefix("args") }.joined(separator: " ")
            return isBridge(command: command, args: args.contains("\"\(MCPBridge.flag)\"") ? [MCPBridge.flag] : [])
        }
    }

    // The first double-quoted string on a line.
    private static func quoted(_ line: String) -> String? {
        let parts = line.components(separatedBy: "\"")
        return parts.count >= 3 ? parts[1] : nil
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\(value)\"" }
        return String(array.dropFirst().dropLast())
    }
}
