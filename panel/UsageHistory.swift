import Foundation

// MARK: - Series model

// One time bucket of a usage series. Token fields are sums over every agent
// turn that landed in the bucket; `turns` counts the turns themselves.
struct UsageBucket: Equatable {
    let start: Date
    var inputTokens:       Int = 0
    var outputTokens:      Int = 0
    var cacheReadTokens:   Int = 0
    var cacheCreateTokens: Int = 0
    var turns:             Int = 0
}

// What the graph plots, in ↑/↓ cycle order. Output tokens is the default because
// input+cache is dominated by cache reads — over a real 24h it ran ~190x the
// output total, so sharing one linear axis would flatten output into the
// baseline.
//
// `excludingCacheReads` is the "real work" view: everything the model actually
// processed, minus the cheap replays. Cache *creation* counts because that is
// fresh content genuinely run through the model and merely stored for reuse;
// cache *reads* are excluded because they dominate everything else and flatten
// the shape. Measured over a real 24h: 25.9M against 3.7M output and 699M cache
// reads, so it lands ~7x the output-only series and reads as a distinct curve.
//
// Excluding cache creation as well would leave uncached input + output, which
// measured just 0.8% above output-only — a near-duplicate series, not worth a
// position in the cycle.
enum UsageMetric: CaseIterable {
    case outputTokens
    case excludingCacheReads
    case inputAndCache
    case turns

    var label: String {
        switch self {
        case .outputTokens:        return "Output tokens"
        case .excludingCacheReads: return "Tokens (no cache reads)"
        case .inputAndCache:       return "Input + cache"
        case .turns:               return "Turns"
        }
    }
}

extension UsageBucket {
    func value(for metric: UsageMetric) -> Int {
        switch metric {
        case .outputTokens: return outputTokens
        // Everything but the replays. `inputTokens` is already the uncached
        // portion for both agents — Claude reports cache reads and cache
        // creation as separate fields, and the Codex reader subtracts its cached
        // count out of `input_tokens` — so only cacheReadTokens is left out here.
        case .excludingCacheReads: return inputTokens + cacheCreateTokens + outputTokens
        case .inputAndCache:       return inputTokens + cacheReadTokens + cacheCreateTokens
        case .turns:               return turns
        }
    }
}

// Window the graph covers. Shorter windows exist mainly for resolution: at 5
// minute buckets a 24h window packs 288 buckets into the ~465pt the pane gets
// (1.6pt each, sparkline territory), where 6h gives 72 buckets at ~6.5pt each
// and reads as distinct bars.
enum UsageWindow: CaseIterable {
    case sixHours
    case twelveHours
    case twentyFourHours

    var hours: Int {
        switch self {
        case .sixHours:        return 6
        case .twelveHours:     return 12
        case .twentyFourHours: return 24
        }
    }

    var label: String { "\(hours)h" }

    // The widest window, and therefore how much history the store retains. Every
    // shorter window is bucketed from the same cached entries, so switching
    // scope costs no I/O at all.
    static var widest: UsageWindow { .twentyFourHours }
}

// A trailing-window series. Every bucket is present and zero-filled rather than
// only the active ones: over a real 24h only ~22% of 5-minute buckets had any
// activity, and a line drawn across genuine holes reads as broken data instead
// of as idle time. Buckets are aligned to wall-clock multiples of
// `bucketSeconds`, and the last one is the in-progress bucket.
struct UsageSeries: Equatable {
    let buckets: [UsageBucket]
    let bucketSeconds: Int

    var windowStart: Date { buckets.first?.start ?? Date(timeIntervalSince1970: 0) }
    var windowEnd: Date {
        guard let last = buckets.last else { return Date(timeIntervalSince1970: 0) }
        return last.start.addingTimeInterval(Double(bucketSeconds))
    }

    var hasActivity: Bool { buckets.contains { $0.turns > 0 } }

    func total(for metric: UsageMetric) -> Int {
        buckets.reduce(0) { $0 + $1.value(for: metric) }
    }

    func peakValue(for metric: UsageMetric) -> Int {
        buckets.reduce(0) { max($0, $1.value(for: metric)) }
    }

    func peakBucket(for metric: UsageMetric) -> UsageBucket? {
        buckets.max { $0.value(for: metric) < $1.value(for: metric) }
    }
}

// MARK: - Parsed entry

// One agent turn, kept in the store so re-bucketing for a different window — or
// a refresh where nothing changed — never re-reads or re-parses anything.
struct UsageEntry: Equatable {
    let when: Date
    // Stable per-turn id where the agent provides one (Claude's `uuid`), used to
    // drop turns replayed into a second transcript by a resumed or forked
    // session. nil for agents with no such id.
    let identity: String?
    let inputTokens:       Int
    let outputTokens:      Int
    let cacheReadTokens:   Int
    let cacheCreateTokens: Int
}

// MARK: - Store

// Caches parsed transcript entries so repeat reads are cheap.
//
// Measured on a real 24h window (~88 MB across 47 warm transcripts): a full
// uncached pass costs ~1050 ms, of which the directory walk and stat is ~94 ms,
// raw I/O plus line splitting is ~208 ms, and JSON plus timestamp parsing is
// ~749 ms — 71% of the total. Caching parsed entries therefore removes the
// dominant cost, taking a no-change refresh down to roughly the ~94 ms walk.
//
// Transcripts are append-only, so a file whose size and mtime are unchanged is
// skipped outright, and a file that grew is parsed only from the byte offset
// where the last complete line ended.
final class UsageHistoryStore {

    enum Source {
        case claude
        case codex

        var defaultRoot: String {
            switch self {
            case .claude: return "\(NSHomeDirectory())/.claude/projects"
            case .codex:  return "\(NSHomeDirectory())/.codex/sessions"
            }
        }

        // Byte pattern every interesting line must contain, applied before any
        // JSON parsing.
        var marker: StaticString {
            switch self {
            case .claude: return "\"assistant\""
            case .codex:  return "token_count"
            }
        }
    }

    // What a refresh actually did. Exposed so the cache's behaviour is
    // assertable rather than assumed.
    struct RefreshStats: Equatable {
        var filesParsed     = 0
        var filesSkipped    = 0
        var bytesParsed     = 0
        var entriesRetained = 0
    }

    private struct CachedFile {
        var size: Int
        var modified: Date
        // Offset just past the last complete line consumed. A trailing partial
        // line (a write caught mid-flush) is deliberately left unconsumed and
        // picked up once its newline lands.
        var parsedUpTo: Int
        var entries: [UsageEntry]
    }

    // Partitioned by source, not a flat path map: the same store serves every
    // client, and a series must never merge another agent's entries. Flattening
    // one shared map here silently showed Claude's history under Codex.
    private var cache: [Source: [String: CachedFile]] = [:]
    private var stats = RefreshStats()
    // Guards `cache` and `stats` only. File I/O and parsing happen outside it, so
    // a background refresh never blocks a main-thread re-bucket for a scope
    // change.
    private let lock = NSLock()

    var lastRefreshStats: RefreshStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: Refresh

    // Bring the cache up to date for `source`, retaining `retaining` hours of
    // history. Safe to call repeatedly; the cost of a call that finds nothing
    // changed is the directory walk plus a stat per file.
    func refresh(source: Source,
                 root: String? = nil,
                 now: Date = Date(),
                 retaining: UsageWindow = .widest) {
        let directory = root ?? source.defaultRoot
        let cutoff = now.addingTimeInterval(-Double(retaining.hours * 3600))
        var fresh = RefreshStats()

        for candidate in Self.transcriptFiles(under: directory, modifiedAfter: cutoff) {
            lock.lock()
            let cached = cache[source]?[candidate.path]
            lock.unlock()

            // Unchanged since the last pass — the append-only guarantee means
            // there is nothing new to read.
            if let cached, cached.size == candidate.size, cached.modified == candidate.modified {
                fresh.filesSkipped += 1
                continue
            }

            // Shrunk means truncated or replaced, so the cached entries can't be
            // trusted; anything else is treated as an append and resumes from the
            // last complete line. A whole-file rewrite that happened to grow
            // would be mis-resumed, which is why identity-based deduplication
            // stays in the merge step below rather than being dropped as
            // redundant.
            let resumeFrom = (cached.map { candidate.size < $0.size ? 0 : $0.parsedUpTo }) ?? 0
            var entries = resumeFrom == 0 ? [] : (cached?.entries ?? [])

            let consumed = Self.forEachLine(of: candidate.path,
                                            from: resumeFrom,
                                            containing: source.marker) { line in
                if let entry = Self.parse(line: line, source: source) { entries.append(entry) }
            }

            fresh.filesParsed += 1
            fresh.bytesParsed += max(0, consumed - resumeFrom)

            // Drop anything that has aged out so memory tracks the window rather
            // than the session.
            entries.removeAll { $0.when < cutoff }

            lock.lock()
            cache[source, default: [:]][candidate.path] = CachedFile(size: candidate.size,
                                                                     modified: candidate.modified,
                                                                     parsedUpTo: consumed,
                                                                     entries: entries)
            lock.unlock()
        }

        lock.lock()
        // Evict files that have gone cold. A file last written before the cutoff
        // cannot hold an in-window entry, which is the same argument the scan
        // prefilter rests on. Only this source's partition is touched — another
        // client's cache is none of this refresh's business.
        let surviving = (cache[source] ?? [:]).filter { $0.value.modified > cutoff }
        cache[source] = surviving
        fresh.entriesRetained = surviving.values.reduce(0) { $0 + $1.entries.count }
        stats = fresh
        lock.unlock()
    }

    // MARK: Bucketing

    // Bucket one source's cached entries into a series. Pure computation over
    // entries already in memory — no I/O — so a scope change is effectively free.
    // `source` is required rather than defaulted: getting it wrong silently plots
    // the wrong agent's history.
    func series(source: Source,
                now: Date = Date(),
                window: UsageWindow = .widest,
                bucketSeconds: Int = UsageHistoryStore.defaultBucketSeconds) -> UsageSeries {
        lock.lock()
        let all = (cache[source] ?? [:]).values.flatMap { $0.entries }
        lock.unlock()

        var accumulator = Accumulator(now: now, windowHours: window.hours, bucketSeconds: bucketSeconds)
        for entry in all { accumulator.add(entry) }
        return accumulator.series()
    }

    // Refresh then bucket, for callers that want both in one step.
    func refreshedSeries(source: Source,
                         root: String? = nil,
                         now: Date = Date(),
                         window: UsageWindow = .widest,
                         bucketSeconds: Int = UsageHistoryStore.defaultBucketSeconds) -> UsageSeries {
        // Always retain the widest window so narrower ones are a re-bucket of the
        // same cached entries rather than another scan.
        refresh(source: source, root: root, now: now, retaining: .widest)
        return series(source: source, now: now, window: window, bucketSeconds: bucketSeconds)
    }

    static let defaultBucketSeconds = 300

    // MARK: Accumulator

    // Folds entries into wall-clock-aligned buckets, then zero-fills.
    private struct Accumulator {
        let firstBucketStart: Date
        let bucketSeconds: Int
        let bucketCount: Int

        private var totals: [Int: UsageBucket] = [:]
        private var seenIdentities: Set<String> = []

        init(now: Date, windowHours: Int, bucketSeconds: Int) {
            self.bucketSeconds = bucketSeconds
            self.bucketCount = max(1, (windowHours * 3600) / bucketSeconds)
            // Align the newest bucket down to a wall-clock boundary so buckets
            // land on :00/:05/:10 rather than drifting with launch time, then
            // count backwards for a fixed bucket count. The effective window is
            // therefore up to one bucket short of `windowHours`, which keeps the
            // series a stable width for the renderer.
            let alignedNow = floor(now.timeIntervalSince1970 / Double(bucketSeconds)) * Double(bucketSeconds)
            let firstEpoch = alignedNow - Double((bucketCount - 1) * bucketSeconds)
            self.firstBucketStart = Date(timeIntervalSince1970: firstEpoch)
        }

        mutating func add(_ entry: UsageEntry) {
            // Resumed or forked sessions can replay earlier turns into a second
            // transcript. Measured duplication over a real 24h was zero, but this
            // also covers a file being re-read after a rewrite, so it earns its
            // keep beyond the replay case.
            if let identity = entry.identity, !seenIdentities.insert(identity).inserted { return }

            let offset = entry.when.timeIntervalSince(firstBucketStart)
            guard offset >= 0 else { return }
            let index = Int(offset) / bucketSeconds
            guard index < bucketCount else { return }

            let start = firstBucketStart.addingTimeInterval(Double(index * bucketSeconds))
            var bucket = totals[index] ?? UsageBucket(start: start)
            bucket.inputTokens       += entry.inputTokens
            bucket.outputTokens      += entry.outputTokens
            bucket.cacheReadTokens   += entry.cacheReadTokens
            bucket.cacheCreateTokens += entry.cacheCreateTokens
            bucket.turns             += 1
            totals[index] = bucket
        }

        func series() -> UsageSeries {
            let buckets = (0..<bucketCount).map { index in
                totals[index] ?? UsageBucket(
                    start: firstBucketStart.addingTimeInterval(Double(index * bucketSeconds))
                )
            }
            return UsageSeries(buckets: buckets, bucketSeconds: bucketSeconds)
        }
    }

    // MARK: Line parsing

    private static func parse(line: Data, source: Source) -> UsageEntry? {
        switch source {
        case .claude: return parseClaude(line: line)
        case .codex:  return parseCodex(line: line)
        }
    }

    private static func parseClaude(line: Data) -> UsageEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (object["type"] as? String) == "assistant",
              let rawTimestamp = object["timestamp"] as? String,
              let when = parseTimestamp(rawTimestamp),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        return UsageEntry(
            when: when,
            identity: object["uuid"] as? String,
            inputTokens:       usage["input_tokens"]               as? Int ?? 0,
            outputTokens:      usage["output_tokens"]              as? Int ?? 0,
            cacheReadTokens:   usage["cache_read_input_tokens"]     as? Int ?? 0,
            cacheCreateTokens: usage["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    private static func parseCodex(line: Data) -> UsageEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let rawTimestamp = object["timestamp"] as? String,
              let when = parseTimestamp(rawTimestamp),
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return nil }
        // Codex's `input_tokens` already includes `cached_input_tokens`, so the
        // cached portion is split out rather than added — otherwise "input +
        // cache" would double-count it. Reasoning tokens are billed as output, so
        // they fold into the output total. There is no cache-creation figure.
        let rawInput  = last["input_tokens"]            as? Int ?? 0
        let cached    = last["cached_input_tokens"]     as? Int ?? 0
        let output    = last["output_tokens"]           as? Int ?? 0
        let reasoning = last["reasoning_output_tokens"] as? Int ?? 0
        return UsageEntry(
            when: when,
            // Rollout events carry no stable id, so replays can't be detected for
            // Codex. Its rollouts are append-only in practice.
            identity: nil,
            inputTokens:       max(0, rawInput - cached),
            outputTokens:      output + reasoning,
            cacheReadTokens:   cached,
            cacheCreateTokens: 0
        )
    }

    // MARK: File plumbing

    private struct Candidate {
        let path: String
        let size: Int
        let modified: Date
    }

    // Transcript files that could hold an in-window entry. A file last written
    // before the window cannot contain entries inside it, because entries are
    // appended as they happen — that prefilter narrows a ~389 MB transcript tree
    // to the ~47 warm sessions, and the walk itself costs ~94 ms.
    private static func transcriptFiles(under directory: String, modifiedAfter cutoff: Date) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [Candidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > cutoff
            else { continue }
            candidates.append(Candidate(path: url.path,
                                        size: values.fileSize ?? 0,
                                        modified: modified))
        }
        return candidates
    }

    // Walks a JSONL file from `offset`, invoking `body` for each complete line
    // containing `marker`, and returns the offset just past the last complete
    // line — the resume point for the next pass.
    //
    // Deliberately avoids decoding the file into a String and splitting it: that
    // route measured 4.09s against a real 24h window versus 0.99s for this one.
    // Swift's String is Unicode-correct, which makes a whole-file decode plus
    // per-line `contains` the dominant cost. memchr/memmem do the newline split
    // and marker search in C, and only surviving lines are copied into a Data.
    @discardableResult
    private static func forEachLine(of path: String,
                                    from offset: Int,
                                    containing marker: StaticString,
                                    _ body: (Data) -> Void) -> Int {
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        else { return offset }

        var consumed = offset
        fileData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, offset < raw.count else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let total = raw.count
            let markerStart = marker.utf8Start
            let markerLength = marker.utf8CodeUnitCount

            var cursor = offset
            while cursor < total {
                let remaining = total - cursor
                let lineStart = bytes + cursor
                // No newline left means a partial trailing line; leave it
                // unconsumed so it is read once complete.
                guard let newline = memchr(lineStart, 0x0A, remaining) else { break }
                let lineLength = UnsafeRawPointer(newline) - UnsafeRawPointer(lineStart)

                if lineLength >= markerLength,
                   memmem(lineStart, lineLength, markerStart, markerLength) != nil {
                    body(Data(bytes: lineStart, count: lineLength))
                }
                cursor += lineLength + 1
                consumed = cursor
            }
        }
        return consumed
    }

    // Both formatters are built once — instantiating one per line dominates the
    // parse otherwise. Claude stamps fractional seconds; the plain variant is
    // the fallback for any writer that doesn't.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}

// MARK: - Uncached convenience

// One-shot reads with no cache, for tests and any caller that wants a clean
// pass. The app goes through a long-lived UsageHistoryStore instead so repeat
// reads stay cheap; keeping these separate means tests share no state.
enum UsageHistoryReader {

    static func claudeSeries(now: Date = Date(),
                             window: UsageWindow = .widest,
                             bucketSeconds: Int = UsageHistoryStore.defaultBucketSeconds,
                             root: String? = nil) -> UsageSeries {
        UsageHistoryStore().refreshedSeries(source: .claude, root: root, now: now,
                                            window: window, bucketSeconds: bucketSeconds)
    }

    static func codexSeries(now: Date = Date(),
                            window: UsageWindow = .widest,
                            bucketSeconds: Int = UsageHistoryStore.defaultBucketSeconds,
                            root: String? = nil) -> UsageSeries {
        UsageHistoryStore().refreshedSeries(source: .codex, root: root, now: now,
                                            window: window, bucketSeconds: bucketSeconds)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        UsageHistoryStore.parseTimestamp(raw)
    }
}
