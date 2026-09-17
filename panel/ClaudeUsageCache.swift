import Foundation

// Claude Code's own cache of the /api/oauth/usage response, written to
// ~/.claude.json under `cachedUsageUtilization` whenever it refreshes its usage
// bars. A file read against the 6.4s shell-out it stands in for, and it carries
// more than the rendered text: Opus and Sonnet arrive as numbers even where the
// text omits their lines.
//
// `fetchedAt` is part of the reading because nothing refreshes this file except
// Claude Code, so it is current during a session and arbitrarily old after one.
enum ClaudeUsageCache {

    struct Reading: Equatable {
        let snapshot: QuotaSnapshot
        let fetchedAt: Date
    }

    static var path: String { "\(NSHomeDirectory())/.claude.json" }

    // `maxAge` is the caller's poll interval: within it the cache is no staler
    // than the value a fresh shell-out would have returned.
    static func read(maxAge: TimeInterval, now: Date = Date(),
                     path: String = ClaudeUsageCache.path) -> Reading? {
        // ~/.claude.json runs to hundreds of KB and is never back-dated, so its
        // mtime bounds `fetchedAtMs` from above — a stat rules out a stale cache
        // without parsing, which is the common case when no session is running.
        let url = URL(fileURLWithPath: path)
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              now.timeIntervalSince(mtime) <= maxAge,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let reading = parse(data)
        else { return nil }
        guard now.timeIntervalSince(reading.fetchedAt) <= maxAge else { return nil }
        return reading
    }

    // Split out so tests can push a verbatim fragment through the same decode.
    static func parse(_ data: Data) -> Reading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cached["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let snapshot = QuotaSnapshot(
            fiveHour:       tier(utilization["five_hour"], window: QuotaWindow.fiveHours),
            sevenDay:       tier(utilization["seven_day"], window: QuotaWindow.sevenDays),
            sevenDayOpus:   tier(utilization["seven_day_opus"], window: QuotaWindow.sevenDays),
            sevenDaySonnet: tier(utilization["seven_day_sonnet"], window: QuotaWindow.sevenDays),
            // No plan name here; the probe fills it in from `claude auth status`.
            planType: nil)
        // Every bucket is null on an unused account; an empty snapshot would
        // replace a good one with blanks.
        guard snapshot.hasTier else { return nil }
        return Reading(snapshot: snapshot,
                       fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000))
    }

    // A bucket is `{"utilization": 31, "resets_at": "…"}` or null. The window
    // length isn't in the payload — the key names it, so the caller passes it.
    private static func tier(_ raw: Any?, window: TimeInterval) -> QuotaTier? {
        guard let dict = raw as? [String: Any],
              let used = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseTimestamp)
        return QuotaTier(utilization: used, resetsAt: resetsAt, windowLength: window)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // "2026-09-17T11:20:00.147737+00:00" → Date. Anthropic emits microseconds;
    // ISO8601DateFormatter parses exactly three fractional digits and returns nil
    // for six, so trim before it reaches the formatter. Truncating is fine for a
    // window that resets on the hour; losing the reset time entirely is not.
    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = trimFractionalSeconds(raw)
        return isoWithFraction.date(from: trimmed) ?? isoPlain.date(from: trimmed)
    }

    static func trimFractionalSeconds(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        var kept = 0
        var index = raw.index(after: dot)
        while index < raw.endIndex, raw[index].isNumber, kept < 3 {
            index = raw.index(after: index)
            kept += 1
        }
        // Drop any remaining digits; whatever follows them (the offset) stays.
        var rest = index
        while rest < raw.endIndex, raw[rest].isNumber { rest = raw.index(after: rest) }
        return String(raw[..<index]) + String(raw[rest...])
    }
}
