import Foundation

// Claude Code's own cache of the /api/oauth/usage response. The CLI writes it to
// ~/.claude.json under `cachedUsageUtilization` every time it refreshes its usage
// bars, which is what lets `/usage` answer instantly inside a live session.
//
// Reading it is a file read. The `claude --print /usage` shell-out it stands in
// for measured 6.4s wall clock for 484ms of actual work — nearly all of it CLI
// startup — against a 60s poll. It also carries strictly more than the rendered
// text: the Opus and Sonnet buckets arrive as numbers even where the text omits
// their lines.
//
// The catch, and the reason `fetchedAt` is part of the reading rather than an
// implementation detail: nothing refreshes this file except Claude Code itself.
// It is exactly current while a session runs and arbitrarily old once one stops,
// so the caller serves it only while it is fresher than its own poll interval
// and otherwise spawns the CLI as before. That makes the cache the hot path and
// the shell-out the cold-start path, without ever showing a number we can't date.
enum ClaudeUsageCache {

    struct Reading: Equatable {
        let snapshot: QuotaSnapshot
        let fetchedAt: Date
    }

    static var path: String { "\(NSHomeDirectory())/.claude.json" }

    // nil when the file is absent, older than `maxAge`, or carries no usable
    // bucket. `maxAge` is the caller's poll interval: a cache younger than that
    // is no staler than the value a fresh shell-out would have returned.
    static func read(maxAge: TimeInterval, now: Date = Date(),
                     path: String = ClaudeUsageCache.path) -> Reading? {
        // ~/.claude.json holds every project's state and runs to hundreds of KB.
        // The file is only ever appended to in place, never back-dated, so its
        // mtime bounds `fetchedAtMs` from above — a stat rules out a stale cache
        // without parsing anything, which is the common case for a user who
        // isn't running Claude Code right now.
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

    // Split from read() so tests can push a verbatim ~/.claude.json fragment
    // through the same decode the app uses, with no filesystem involved.
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
            // The cache carries no plan name — the probe fills it in from
            // `claude auth status`, exactly as it does on the text path.
            planType: nil)
        // Every bucket can be null on an account that has used none of them, and
        // a snapshot with nothing in it would replace a good one with blanks.
        guard snapshot.hasTier else { return nil }
        return Reading(snapshot: snapshot,
                       fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000))
    }

    // A bucket is `{"utilization": 31, "resets_at": "…"}` or JSON null. The
    // window length isn't in the payload — the key names it, which is why the
    // caller passes it in rather than this reading one.
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

    // "2026-09-17T11:20:00.147737+00:00" → Date.
    //
    // Anthropic emits microsecond precision. ISO8601DateFormatter parses exactly
    // three fractional digits and returns nil for six, so the fraction is trimmed
    // before it ever reaches the formatter. Sub-second precision is worthless for
    // a window that resets on the hour, so truncating rather than rounding is
    // fine; what isn't fine is silently losing the whole reset time.
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
