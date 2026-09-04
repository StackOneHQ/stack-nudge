import Foundation

// A located pi session: its transcript path, session id, and last-write time.
// pi has no per-pid sidecar (Claude) and no live-status RPC (Antigravity), but
// it writes one JSONL per session under a per-cwd directory whose first line is
// a `session` header carrying the id and the absolute cwd. That lets us bind a
// running `pi` process to its transcript from disk alone — no hook event
// required — which is what makes pi sessions show context stats the moment the
// panel opens, the same as Claude's sidecar path.
struct PiSessionRef: Equatable {
    let path: String
    let sessionID: String
    let lastActivityAt: Date?
}

// Reads a pi (@earendil-works/pi-coding-agent) session JSONL and returns the
// same TranscriptStats the Claude/Codex readers produce, so the Sessions and
// Compact views render context usage identically across agents.
//
// pi's transcript differs from Claude Code's in the shape that matters here:
//   • Every entry is wrapped: the assistant turn is `type == "message"` with the
//     model turn under `.message` (role == "assistant"), not a top-level
//     `type == "assistant"`.
//   • Usage keys are camelCase and additive: totalTokens == input + output +
//     cacheRead + cacheWrite + reasoning. `input` does NOT already include the
//     cached portion (unlike Codex), so context-window occupancy is
//     input + cacheRead + cacheWrite — output and reasoning don't persist into
//     the next turn's prompt, mirroring the Claude reader's exclusion of output.
enum PiTranscriptReader {

    private static let sessionsRoot = "\(NSHomeDirectory())/.pi/agent/sessions"

    // Read the whole file and scan newest-first (same approach and tens-of-MB
    // caveat as the Claude reader). First assistant message with a usage block
    // wins. Returns nil for unreadable files or transcripts with no assistant
    // turn yet.
    static func read(path: String) -> TranscriptStats? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "message",
                  let message = obj["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let input      = intValue(usage["input"])
            let cacheRead  = intValue(usage["cacheRead"])
            let cacheWrite = intValue(usage["cacheWrite"])
            let model = message["model"] as? String
            return TranscriptStats(tokens: input + cacheRead + cacheWrite, model: model)
        }
        return nil
    }

    // Locate the active session file for a working directory. pi groups sessions
    // by cwd in a directory named `--<path-with-slashes-as-dashes>--`, but the
    // exact wrap rule has drifted across versions, so we match on the cwd stamped
    // inside each file's `session` header rather than reconstructing the folder
    // name. Newest matching file (by mtime) is the one the running process is
    // appending to. Disk I/O — call off the main thread.
    static func locate(cwd: String, root: String = sessionsRoot) -> PiSessionRef? {
        let fileManager = FileManager.default
        guard let subdirs = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }

        var best: (ref: PiSessionRef, modified: Date)?
        for sub in subdirs {
            let dir = "\(root)/\(sub)"
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let newest = newestTranscript(inDir: dir, fileManager: fileManager) else { continue }
            guard let header = sessionHeader(path: newest.path), header.cwd == cwd else { continue }
            if best == nil || newest.modified > best!.modified {
                best = (PiSessionRef(path: newest.path,
                                     sessionID: header.id,
                                     lastActivityAt: newest.modified),
                        newest.modified)
            }
        }
        return best?.ref
    }

    private static func newestTranscript(inDir dir: String,
                                         fileManager: FileManager) -> (path: String, modified: Date)? {
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: (path: String, modified: Date)?
        for file in files where file.hasSuffix(".jsonl") {
            let path = "\(dir)/\(file)"
            guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (path, modified)
            }
        }
        return newest
    }

    // The first line of every pi session is a `session` header:
    // {"type":"session","version":N,"id":"<uuid>","timestamp":"...","cwd":"..."}.
    // Read only a bounded prefix — the header is tiny and the file can be MB.
    private static func sessionHeader(path: String) -> (id: String, cwd: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let prefix = handle.readData(ofLength: 65536)
        guard let text = String(data: prefix, encoding: .utf8) else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: true).first.map(String.init) ?? text
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session",
              let id = obj["id"] as? String,
              let cwd = obj["cwd"] as? String
        else { return nil }
        return (id, cwd)
    }

    // pi serialises token counts as JSON integers, but decode defensively in
    // case a provider or version emits them as doubles.
    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let double = value as? Double { return Int(double) }
        return 0
    }
}
