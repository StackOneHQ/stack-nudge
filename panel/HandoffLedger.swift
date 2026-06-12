import Foundation

// Durable, bounded per-session ledger at ~/.stack-nudge/handoffs.jsonl. Records
// are upserted by session id (one row per session, last-write-wins) and pruned
// by age + count. JSONL keeps it dependency-free and matches the repo's
// swiftc-only build (no SQLite). Access is main-thread only — the Stop capture
// and the dashboard both run on main — and the file is small (≤ maxCount rows),
// so the synchronous atomic write is negligible.
final class HandoffLedger {

    static let shared = HandoffLedger()

    private let url: URL
    private let maxAge: TimeInterval
    private let maxCount: Int
    private var byID: [String: HandoffRecord]

    init(path: URL? = nil, maxAgeDays: Double = 90, maxCount: Int = 1000) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".stack-nudge", isDirectory: true)
        self.url = path ?? dir.appendingPathComponent("handoffs.jsonl", isDirectory: false)
        self.maxAge = maxAgeDays * 86_400
        self.maxCount = maxCount
        self.byID = Self.load(url)
        // Prune on launch too — retention otherwise only runs on the next
        // upsert, so an idle ledger would keep stale rows indefinitely.
        let before = byID.count
        prune()
        if byID.count != before { persist() }
    }

    // Create on first sight of a session id, or merge into the existing record.
    // The `merge` closure lets the caller set only the fields it knows this
    // tick (e.g. usage) without clobbering an earlier-derived ticket. `id` and
    // `agent` are fixed; `createdAt` is preserved; `updatedAt` is stamped here.
    func upsert(id: String, agent: String, _ merge: (inout HandoffRecord) -> Void) {
        let now = Date()
        var record = byID[id] ?? HandoffRecord(
            id: id, agent: agent,
            repoRoot: nil, branch: nil, ticket: nil, model: nil, contextTokens: nil,
            headCommit: nil, filesChanged: nil, insertions: nil, deletions: nil,
            createdAt: now, updatedAt: now)
        merge(&record)
        record.updatedAt = now
        byID[id] = record
        prune()
        persist()
    }

    // Key by session *and* branch so a session that moves across branches keeps
    // a row per branch — capturing all the effort spent on each — instead of
    // overwriting as it switches. A resume on the same branch still merges.
    func upsert(sessionID: String, branch: String?, agent: String,
                _ merge: (inout HandoffRecord) -> Void) {
        upsert(id: Self.key(sessionID: sessionID, branch: branch), agent: agent, merge)
    }

    static func key(sessionID: String, branch: String?) -> String {
        "\(sessionID)\n\(branch ?? "")"
    }

    // Drop records by session id (manual dismiss from the Tickets tab).
    func remove(ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { byID.removeValue(forKey: id) }
        persist()
    }

    // Newest-first.
    func all() -> [HandoffRecord] {
        byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Persistence

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func load(_ url: URL) -> [String: HandoffRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let decoder = decoder()
        var result: [String: HandoffRecord] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(HandoffRecord.self, from: lineData)
            else { continue }
            result[record.id] = record
        }
        return result
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        var kept = byID.values.filter { $0.updatedAt >= cutoff }
        if kept.count > maxCount {
            kept = Array(kept.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxCount))
        }
        byID = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }

    private func persist() {
        let encoder = Self.encoder()
        let lines = all()
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        let blob = Data((lines.joined(separator: "\n") + "\n").utf8)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? blob.write(to: url, options: .atomic)
    }
}
