import AppKit

// Starting Claude Code sessions from the Sessions tab: resume a recent one, or
// start a new one in a repo.

// A Claude Code session on disk, as listed in the Resume menu.
struct RecentSession: Equatable, Identifiable {
    let id: String
    let cwd: String
    let title: String
    let date: Date

    var project: String { (cwd as NSString).lastPathComponent }
}

// Titles and working directories come from the head and tail of
// ~/.claude/projects/*/*.jsonl, never the whole file: transcripts run to
// hundreds of megabytes.
enum RecentSessions {
    static let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    static let titleLength = 60
    private static let chunk = 128 * 1024

    // Pure: `head` and `tail` are the start and end of one transcript. Lines
    // cut by the chunk edges fail to parse and are skipped.
    static func parse(id: String, head: String, tail: String, modified: Date) -> RecentSession? {
        let headLines = objects(head), tailLines = objects(tail)
        guard let cwd = (headLines + tailLines).lazy.compactMap({ $0["cwd"] as? String }).first(where: { !$0.isEmpty })
        else { return nil }
        let summary = (tailLines + headLines).reversed().lazy.compactMap(summary(of:)).first
        let title = summary ?? headLines.lazy.compactMap(prompt(of:)).first ?? id
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = tailLines.reversed().lazy.compactMap { ($0["timestamp"] as? String).flatMap(iso.date(from:)) }.first
        return RecentSession(id: id, cwd: cwd, title: clip(title), date: stamp ?? modified)
    }

    private static func objects(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    // Last one wins: titles are rewritten as a session goes on.
    private static func summary(of o: [String: Any]) -> String? {
        let text: String?
        switch o["type"] as? String {
        case "summary":      text = o["summary"] as? String
        case "custom-title": text = o["customTitle"] as? String
        case "ai-title":     text = o["aiTitle"] as? String
        default:             text = nil
        }
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    // A typed prompt; command wrappers and tool results start with `<` or are not text.
    private static func prompt(of o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
              let message = o["message"] as? [String: Any] else { return nil }
        let text: String?
        if let s = message["content"] as? String {
            text = s
        } else {
            text = (message["content"] as? [[String: Any]])?
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return nil }
        return text
    }

    private static func clip(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > titleLength ? String(flat.prefix(titleLength - 1)) + "…" : flat
    }

    // Newest first, up to `limit`, skipping the sessions already running and
    // headless runs' transcripts (subagents are `agent-*.jsonl`).
    static func load(root: String = root, limit: Int = 15, excluding running: Set<String> = []) -> [RecentSession] {
        let fm = FileManager.default
        var files: [(path: String, modified: Date)] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? []
            where name.hasSuffix(".jsonl") && !name.hasPrefix("agent-") {
                let path = "\(root)/\(dir)/\(name)"
                let id = (name as NSString).deletingPathExtension
                guard !running.contains(id),
                      let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { continue }
                files.append((path, modified))
            }
        }
        // Read a few more than shown, since some transcripts have no cwd.
        return files.sorted { $0.modified > $1.modified }.prefix(limit * 2)
            .compactMap { read($0.path, modified: $0.modified) }
            // A transcript whose folder is gone can't be resumed in place.
            .filter { fm.fileExists(atPath: $0.cwd) }
            .prefix(limit).map { $0 }
    }

    private static func read(_ path: String, modified: Date) -> RecentSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: chunk)) ?? Data(), as: UTF8.self)
        var tail = head
        if size > UInt64(chunk) {
            try? handle.seek(toOffset: size - UInt64(chunk))
            tail = String(decoding: (try? handle.read(upToCount: chunk)) ?? Data(), as: UTF8.self)
        }
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return parse(id: id, head: head, tail: tail, modified: modified)
    }
}

enum SessionLauncher {

    // Git checkouts directly under `root`, by name, for the New session menu.
    static func repos(in root: String) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        return names.filter { !$0.hasPrefix(".") && fm.fileExists(atPath: "\(root)/\($0)/.git") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func resumeCommand(_ session: RecentSession) -> String {
        "claude --resume \(shellQuoted(session.id))"
    }

    // Single quotes, with any single quote closed, escaped and reopened.
    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    enum Terminal: String { case ghostty, terminal, iterm }

    // STACKNUDGE_SESSION_TERMINAL, else Ghostty when it is installed, else
    // Terminal.app, which every Mac has.
    static func terminal(configured: String?) -> Terminal {
        if let configured, let choice = Terminal(rawValue: configured.lowercased()) { return choice }
        let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
        return ghostty ? .ghostty : .terminal
    }

    // Opens a new window in `cwd` and types `command` there.
    static func open(cwd: String, command: String, in terminal: Terminal) {
        let script: String
        switch terminal {
        case .ghostty:
            // Ghostty's AppleScript API types the command without the "allow
            // Ghostty to execute" prompt that `open --args -e` raises.
            script = """
                tell application "Ghostty"
                    activate
                    set cfg to new surface configuration from {initial working directory:"\(appleScriptEscaped(cwd))", initial input:"\(appleScriptEscaped(command))" & linefeed}
                    new window with configuration cfg
                end tell
                """
        case .iterm:
            script = """
                tell application "iTerm2"
                    activate
                    set w to (create window with default profile)
                    tell current session of w to write text "\(appleScriptEscaped("cd \(shellQuoted(cwd)) && \(command)"))"
                end tell
                """
        case .terminal:
            script = """
                tell application "Terminal"
                    activate
                    do script "\(appleScriptEscaped("cd \(shellQuoted(cwd)) && \(command)"))"
                end tell
                """
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = ProcessOutput.run("/usr/bin/osascript", ["-e", script], timeout: 15)?.status == 0
            // An older Ghostty without the scripting API: fall back once.
            if !ok, terminal == .ghostty { open(cwd: cwd, command: command, in: .terminal) }
        }
    }
}
