import Foundation

// Codex (ChatGPT-plan) rate limits, mirroring the shape of Claude's quota so
// the Usage tab can render them with the same QuotaTier rows. Which window each
// slot carries varies between payloads — read `windowLength`, not the slot name.
// `planType` is the ChatGPT tier ("plus", "pro", …) when reported.
struct CodexQuotaSnapshot: Equatable {
    let primary: QuotaTier?
    let secondary: QuotaTier?
    let planType: String?

    // See QuotaSnapshot.hasTier. Reachable here too: `tier` drops a window whose
    // reset has already passed, so a rollout left over from last week parses into
    // a snapshot with both windows nil.
    var hasTier: Bool { primary != nil || secondary != nil }
}

// Reads Codex's account-level rate limits from the newest rollout JSONL under
// ~/.codex/sessions. Codex records them on each `token_count` event at
// `payload.rate_limits`, with `used_percent` on a 0–100 scale, a unix
// `resets_at` and a `window_minutes`. Local-only — no network, no auth.
//
// The limits are account-wide (not per-session), so the most-recently-written
// rollout holds the freshest values. Returns nil for API-key auth (no
// rate_limits emitted) or when no rollout exists, which the Usage tab treats as
// "no Codex usage to show".
final class CodexQuotaProbe {

    private let sessionsDir = "\(NSHomeDirectory())/.codex/sessions"

    // Skip re-parsing a rollout we've already read at this path+size+mtime —
    // the probe runs on the same 60s/5min cadence as the Claude one, and most
    // ticks hit an unchanged file.
    private var cacheKey: String?
    private var cached: CodexQuotaSnapshot?

    // Serialises read() so overlapping polls — the 60s/5min timer firing while a
    // prior fetch is still doing disk I/O on a large ~/.codex/sessions tree —
    // can't race on cacheKey/cached. These are only ever touched on this queue.
    private let probeQueue = DispatchQueue(label: "stack-nudge.codex-quota")

    // Calls completion on the main queue. File IO runs off-main.
    func fetch(completion: @escaping (CodexQuotaSnapshot?) -> Void) {
        let dir = sessionsDir
        probeQueue.async { [weak self] in
            let result = self?.read(dir: dir) ?? nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func read(dir: String) -> CodexQuotaSnapshot? {
        guard let newest = Self.newestRollout(in: dir) else { return nil }
        let key = "\(newest.path)|\(newest.size)|\(newest.mtime)"
        if key == cacheKey { return cached }
        let snapshot = Self.parseLatestRateLimits(path: newest.path)
        cacheKey = key
        cached = snapshot
        return snapshot
    }

    // Newest rollout-*.jsonl by modification date anywhere under the sessions
    // tree (it's nested YYYY/MM/DD). Enumeration is stat-only and runs at most
    // once per poll tick.
    private static func newestRollout(in dir: String) -> (path: String, size: Int, mtime: TimeInterval)? {
        let base = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (path: String, size: Int, mtime: TimeInterval)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            if best == nil || mtime > best!.mtime {
                best = (url.path, size, mtime)
            }
        }
        return best
    }

    // Scan newest-line-first for the latest token_count event carrying
    // rate_limits, and map it to the snapshot.
    private static func parseLatestRateLimits(path: String) -> CodexQuotaSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("rate_limits"),
                  let snapshot = snapshot(fromLine: String(line)) else { continue }
            return snapshot
        }
        return nil
    }

    // Split out so tests can push a verbatim rollout line through the same
    // decode the app uses, pinning payload shape and parser together.
    static func snapshot(fromLine line: String, now: Date = Date()) -> CodexQuotaSnapshot? {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        return CodexQuotaSnapshot(
            primary: tier(rateLimits["primary"], now: now),
            secondary: tier(rateLimits["secondary"], now: now),
            planType: rateLimits["plan_type"] as? String
        )
    }

    // `used_percent` is already on a 0–100 scale; `resets_at` is unix seconds.
    // Both arrive as JSON numbers, so decode via NSNumber to tolerate int/double.
    //
    // `window_minutes` (300 or 10080) is the only reliable way to tell the two
    // windows apart. The slot carries no fixed meaning: `primary` is usually the
    // weekly window with `secondary` absent, but the same `limit_id` also emits
    // the 5h/weekly pair, so neither the slot nor the id can stand in for it.
    static func tier(_ raw: Any?, now: Date = Date()) -> QuotaTier? {
        guard let dict = raw as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let windowLength = (dict["window_minutes"] as? NSNumber)
            .map { $0.doubleValue * 60 }
        // A window whose reset time has already passed has since rolled over;
        // the captured used_percent is stale and no longer reflects the current
        // window. Drop it so the Usage tab doesn't show old numbers with a
        // "resets N days ago" (happens when Codex hasn't run recently and the
        // newest rollout is older than its own rate-limit window).
        if let resetsAt, resetsAt < now { return nil }
        return QuotaTier(utilization: used, resetsAt: resetsAt, windowLength: windowLength)
    }
}
