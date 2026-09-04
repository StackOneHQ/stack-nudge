import Foundation

// Durable, append-only record of nudges, so "what did the agents do overnight"
// survives a relaunch. EventStore's own list is a live triage queue — capped,
// pruned per session, and gone on quit; this is the history behind it.
//
// Deliberately a slim projection of NudgeEvent rather than the whole struct.
// Most of that struct is runtime plumbing — FIFO paths, PIDs, bundle IDs, IPC
// hooks — that is meaningless once the process it referred to has exited.
// Persisting only the descriptive fields means a replayed record cannot
// masquerade as actionable: it has no FIFO to answer and no PID to focus.
struct EventRecord: Codable, Equatable, Identifiable {
    let at: Date
    let agent: String
    let kind: String
    let title: String
    let message: String
    let project: String?
    let session: String?

    // Stable within a load: the log is append-only and read in order, so the
    // index is enough for SwiftUI identity without persisting a UUID per line.
    var id: String { "\(at.timeIntervalSince1970)-\(agent)-\(message.hashValue)" }

    var projectName: String? {
        guard let project, !project.isEmpty else { return nil }
        return (project as NSString).lastPathComponent
    }

    // Free-text match across the fields a user would search by. Case-folded
    // rather than lowercased so a Turkish locale can't make "I" stop matching.
    func matches(_ needle: String) -> Bool {
        let q = needle.folding(options: [.caseInsensitive, .diacriticInsensitive],
                               locale: nil)
        guard !q.isEmpty else { return true }
        for field in [message, title, agent, projectName ?? ""] {
            if field.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: nil).contains(q) { return true }
        }
        return false
    }
}

// Reads and writes the JSONL log. File I/O is confined to `append` and `load`;
// the parsing and retention rules are static so they can be tested without
// touching disk.
final class EventLog {

    static let defaultPath = ("~/.stack-nudge/events.jsonl" as NSString).expandingTildeInPath

    // Records older than this are dropped at load. A month covers "what
    // happened while I was away" without letting the file grow forever.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    // Hard ceiling regardless of age, so a pathological week of hook spam
    // can't leave a file too big to parse at launch. Newest wins.
    static let maxRecords = 10_000

    private let path: String
    // Appends are serialised off the main thread: EventStore calls this from
    // the hook-delivery path, which must not block on disk.
    private let queue = DispatchQueue(label: "stack-nudge.event-log")

    init(path: String = EventLog.defaultPath) {
        self.path = path
    }

    func append(_ record: EventRecord) {
        queue.async { [path] in
            guard let line = Self.encode(record) else { return }
            let data = Data((line + "\n").utf8)
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
            // Only create when there is genuinely nothing there. createFile
            // unlinks and replaces, and it succeeds whenever the *directory* is
            // writable — so treating "couldn't open for writing" as "must not
            // exist" would discard the whole history the first time the file was
            // root-owned, restored read-only, or chmod'ed by a user who took the
            // README's note about prompt text seriously.
            guard !FileManager.default.fileExists(atPath: path) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 0600: the log carries prompt and tool text, so it should be no
            // more readable than the config beside it.
            FileManager.default.createFile(atPath: path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    // Newest first, already trimmed. Rewrites the file when trimming dropped
    // anything, so retention is enforced once per launch rather than on every
    // append (which would mean rewriting the whole file per nudge).
    func load(now: Date = Date()) -> [EventRecord] {
        // Through the queue: appends write on it, and an unsynchronised read
        // could catch a half-written line. parse() would skip the torn line
        // rather than fail, but silently losing a record is still a bug.
        let contents = queue.sync { try? String(contentsOfFile: path, encoding: .utf8) }
        guard let text = contents else { return [] }
        let all = Self.parse(text)
        let kept = Self.trim(all, now: now)
        if kept.count != all.count { rewrite(kept) }
        return kept.reversed()
    }

    // Block until queued writes have landed. Appends are fire-and-forget on the
    // hook path, so tests (and anything that needs the file settled) need a way
    // to wait for them without sleeping.
    func flush() {
        queue.sync {}
    }

    func clear() {
        queue.async { [path] in
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func rewrite(_ records: [EventRecord]) {
        queue.async { [path] in
            let body = records.compactMap(Self.encode).joined(separator: "\n")
            try? (body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Pure

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        // One record per line — a pretty-printed object would break the format.
        e.outputFormatting = []
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func encode(_ record: EventRecord) -> String? {
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Oldest first, matching file order. A line that doesn't parse is skipped
    // rather than aborting the load: a half-written final line from a crash or
    // a hand-edit must not cost the user their whole history.
    static func parse(_ text: String) -> [EventRecord] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(EventRecord.self, from: data)
        }
    }

    // Age first, then the count ceiling — so a burst inside the window can't
    // push out older records that are still inside it until the cap actually
    // binds. Input and output are both oldest-first.
    static func trim(_ records: [EventRecord], now: Date = Date()) -> [EventRecord] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = records.filter { $0.at >= cutoff }
        guard fresh.count > maxRecords else { return fresh }
        return Array(fresh.suffix(maxRecords))
    }
}
