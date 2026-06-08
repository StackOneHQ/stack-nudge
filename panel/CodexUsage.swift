import Foundation

// Codex (ChatGPT-plan) rate limits, mirroring the shape of Claude's quota so
// the Usage tab can render them with the same QuotaTier rows. `primary` is the
// 5-hour rolling window, `secondary` the weekly one. `planType` is the ChatGPT
// tier ("plus", "pro", …) when reported.
struct CodexQuotaSnapshot: Equatable {
    let primary: QuotaTier?
    let secondary: QuotaTier?
    let planType: String?
}

// Reads Codex's account-level rate limits from the newest rollout JSONL under
// ~/.codex/sessions. Codex records them on each `token_count` event at
// `payload.rate_limits` (primary = 5h, secondary = weekly), with `used_percent`
// on a 0–100 scale and a unix `resets_at`. Local-only — no network, no auth.
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

    // Calls completion on the main queue. File IO runs off-main.
    func fetch(completion: @escaping (CodexQuotaSnapshot?) -> Void) {
        let dir = sessionsDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any]
            else { continue }

            return CodexQuotaSnapshot(
                primary: tier(rateLimits["primary"]),
                secondary: tier(rateLimits["secondary"]),
                planType: rateLimits["plan_type"] as? String
            )
        }
        return nil
    }

    // `used_percent` is already on a 0–100 scale; `resets_at` is unix seconds.
    // Both arrive as JSON numbers, so decode via NSNumber to tolerate int/double.
    private static func tier(_ raw: Any?) -> QuotaTier? {
        guard let dict = raw as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resets_at"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return QuotaTier(utilization: used, resetsAt: resetsAt)
    }
}
