import XCTest

@testable import StackNudgePanelCore

// The 24h usage graph replays transcripts rather than recording snapshots, so
// these pin the parts that decide whether the plotted shape is truthful: bucket
// alignment, window edges, the mtime prefilter, deduplication, and the token
// arithmetic each agent's schema needs.
final class UsageHistoryTests: XCTestCase {

    // MARK: Fixtures

    private func fixtureDirectory() -> String {
        let dir = NSTemporaryDirectory() + "usage-history-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ lines: [String], to directory: String, name: String, modified: Date? = nil) -> String {
        let path = directory + name
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // A real-shape Claude assistant entry. Mirrors the live schema: timestamp at
    // the top level, usage under .message.usage.
    private func claudeLine(at when: Date,
                            output: Int = 100,
                            input: Int = 10,
                            cacheRead: Int = 1_000,
                            cacheCreate: Int = 500,
                            uuid: String = UUID().uuidString) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(Self.stamp.string(from: when))",\
        "message":{"model":"claude-opus-5","usage":{"input_tokens":\(input),\
        "output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheCreate)}}}
        """
    }

    // A real-shape Codex token_count event. Note input_tokens already contains
    // cached_input_tokens, which is what the reader has to unpick.
    private func codexLine(at when: Date,
                           input: Int = 15_000,
                           cached: Int = 10_000,
                           output: Int = 200,
                           reasoning: Int = 60) -> String {
        """
        {"timestamp":"\(Self.stamp.string(from: when))","type":"event_msg",\
        "payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),\
        "cached_input_tokens":\(cached),"output_tokens":\(output),\
        "reasoning_output_tokens":\(reasoning)}}}}
        """
    }

    // MARK: Bucketing

    func test_bucketsAlignToWallClockBoundaries() {
        let dir = fixtureDirectory()
        // 13:07:41 must land in the 13:05 bucket, not start one at :07.
        let now = Date(timeIntervalSince1970: 1_785_150_000)  // arbitrary fixed instant
        _ = write([claudeLine(at: now.addingTimeInterval(-600))], to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        for bucket in series.buckets {
            let epoch = Int(bucket.start.timeIntervalSince1970)
            XCTAssertEqual(epoch % series.bucketSeconds, 0, "bucket \(bucket.start) is off-boundary")
        }
    }

    func test_windowIsFixedWidth_andZeroFilled() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([claudeLine(at: now.addingTimeInterval(-3_600))], to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        // 24h of 5-minute buckets, every one present so the renderer never has
        // to reason about gaps.
        XCTAssertEqual(series.buckets.count, 288)
        XCTAssertEqual(series.bucketSeconds, 300)
        XCTAssertEqual(series.buckets.filter { $0.turns > 0 }.count, 1)
        XCTAssertEqual(series.buckets.filter { $0.turns == 0 }.count, 287)
    }

    func test_turnsInSameBucket_accumulate() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let when = now.addingTimeInterval(-1_800)
        _ = write([
            claudeLine(at: when, output: 100),
            claudeLine(at: when.addingTimeInterval(30), output: 250),
        ], to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        let active = series.buckets.filter { $0.turns > 0 }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.turns, 2)
        XCTAssertEqual(active.first?.outputTokens, 350)
    }

    func test_entriesOlderThanWindow_areExcluded() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        // Same file holds one in-window and one long-expired entry; the file's
        // mtime is recent, so it passes the prefilter and the entry timestamps
        // have to do the filtering.
        _ = write([
            claudeLine(at: now.addingTimeInterval(-3_600), output: 111),
            claudeLine(at: now.addingTimeInterval(-60 * 60 * 48), output: 999),
        ], to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .outputTokens), 111)
    }

    func test_filesUntouchedSinceWindowStart_areSkipped() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        // An entry that would be in-window by timestamp, but in a file last
        // written two days ago. Skipping it is the optimisation that keeps the
        // scan off ~389 MB of cold transcripts; a real file cannot contain
        // entries newer than its own mtime.
        _ = write([claudeLine(at: now.addingTimeInterval(-3_600), output: 777)],
                  to: dir, name: "cold.jsonl", modified: now.addingTimeInterval(-60 * 60 * 48))

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertFalse(series.hasActivity)
        XCTAssertEqual(series.total(for: .outputTokens), 0)
    }

    func test_duplicateUUIDAcrossFiles_countsOnce() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let when = now.addingTimeInterval(-1_200)
        let shared = "shared-uuid"
        _ = write([claudeLine(at: when, output: 500, uuid: shared)], to: dir, name: "a.jsonl", modified: now)
        _ = write([claudeLine(at: when, output: 500, uuid: shared)], to: dir, name: "b.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .outputTokens), 500)
        XCTAssertEqual(series.total(for: .turns), 1)
    }

    // MARK: Robustness

    func test_malformedAndIncompleteEntries_areSkipped() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([
            "{ not json at all",
            #"{"type":"assistant","timestamp":"nonsense","message":{"usage":{"output_tokens":5}}}"#,
            #"{"type":"assistant","message":{"usage":{"output_tokens":5}}}"#,          // no timestamp
            #"{"type":"user","timestamp":"2026-07-27T12:00:00.000Z","message":{}}"#,   // not an assistant turn
            claudeLine(at: now.addingTimeInterval(-600), output: 42),
        ], to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .outputTokens), 42)
        XCTAssertEqual(series.total(for: .turns), 1)
    }

    func test_emptyDirectory_yieldsZeroFilledSeries() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let series = UsageHistoryReader.claudeSeries(now: now, root: fixtureDirectory())
        XCTAssertEqual(series.buckets.count, 288)
        XCTAssertFalse(series.hasActivity)
        XCTAssertEqual(series.total(for: .turns), 0)
        XCTAssertEqual(series.peakValue(for: .outputTokens), 0)
    }

    func test_missingDirectory_doesNotCrash() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let series = UsageHistoryReader.claudeSeries(now: now, root: "/nonexistent-\(UUID().uuidString)/")
        XCTAssertEqual(series.buckets.count, 288)
        XCTAssertFalse(series.hasActivity)
    }

    func test_timestampWithoutFractionalSeconds_parses() {
        XCTAssertNotNil(UsageHistoryReader.parseTimestamp("2026-07-27T15:04:59Z"))
        XCTAssertNotNil(UsageHistoryReader.parseTimestamp("2026-07-27T15:04:59.572Z"))
        XCTAssertNil(UsageHistoryReader.parseTimestamp("not a timestamp"))
    }

    // MARK: Metrics

    func test_metricsReadIndependentFields() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([claudeLine(at: now.addingTimeInterval(-600),
                              output: 400, input: 20, cacheRead: 9_000, cacheCreate: 1_000)],
                  to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .outputTokens), 400)
        XCTAssertEqual(series.total(for: .inputAndCache), 20 + 9_000 + 1_000)
        XCTAssertEqual(series.total(for: .turns), 1)
        XCTAssertEqual(series.peakValue(for: .outputTokens), 400)
        // Real work: uncached input + cache creation + output. Only the replays
        // are left out.
        XCTAssertEqual(series.total(for: .excludingCacheReads), 20 + 1_000 + 400)
    }

    // The whole point of this metric is which side of the line cache creation
    // falls on: it's fresh content the model processed, so it counts, while cache
    // reads are replays and don't. Getting that backwards is the likely mistake,
    // and with cache reads ~30x cache creation in practice it would be obvious
    // in the plot but silent in the arithmetic.
    func test_excludingCacheReads_keepsCacheCreation_dropsCacheReads() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([claudeLine(at: now.addingTimeInterval(-600),
                              output: 300, input: 50, cacheRead: 500_000, cacheCreate: 20_000)],
                  to: dir, name: "a.jsonl", modified: now)

        let series = UsageHistoryReader.claudeSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .excludingCacheReads), 20_350)
        XCTAssertEqual(series.total(for: .inputAndCache), 520_050)
        // Sanity: dropping the reads has to make a real difference, or the metric
        // is just input+cache under another name.
        XCTAssertLessThan(series.total(for: .excludingCacheReads),
                          series.total(for: .inputAndCache))
    }

    func test_codexExcludingCacheReads_hasNoCacheCreationToAdd() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([codexLine(at: now.addingTimeInterval(-900),
                             input: 15_000, cached: 10_000, output: 200, reasoning: 60)],
                  to: dir, name: "rollout-test.jsonl", modified: now)

        let series = UsageHistoryReader.codexSeries(now: now, root: dir)
        // Codex reports no cache-creation figure, so this collapses to fresh
        // input (15,000 less 10,000 cached) plus 260 output.
        XCTAssertEqual(series.total(for: .excludingCacheReads), 5_260)
    }

    func test_metricCycleOrder_putsOutputFirst() {
        // The graph opens on output tokens; ↑/↓ walk this order.
        XCTAssertEqual(UsageMetric.allCases,
                       [.outputTokens, .excludingCacheReads, .inputAndCache, .turns])
    }

    // MARK: Windows

    func test_narrowerWindow_yieldsFewerBucketsAtSameResolution() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-600))], to: dir, name: "a.jsonl", modified: now)

        // Same 5-minute buckets throughout; only the count changes. This is what
        // buys resolution on a narrow pane.
        XCTAssertEqual(UsageHistoryReader.claudeSeries(now: now, window: .twentyFourHours, root: dir).buckets.count, 288)
        XCTAssertEqual(UsageHistoryReader.claudeSeries(now: now, window: .twelveHours, root: dir).buckets.count, 144)
        XCTAssertEqual(UsageHistoryReader.claudeSeries(now: now, window: .sixHours, root: dir).buckets.count, 72)
    }

    func test_narrowWindow_excludesOlderEntries() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        _ = write([
            claudeLine(at: now.addingTimeInterval(-60 * 60), output: 100),        // 1h ago
            claudeLine(at: now.addingTimeInterval(-60 * 60 * 9), output: 500),    // 9h ago
        ], to: dir, name: "a.jsonl", modified: now)

        XCTAssertEqual(UsageHistoryReader.claudeSeries(now: now, window: .twentyFourHours, root: dir)
                        .total(for: .outputTokens), 600)
        XCTAssertEqual(UsageHistoryReader.claudeSeries(now: now, window: .sixHours, root: dir)
                        .total(for: .outputTokens), 100)
    }

    func test_windowCycleOrder() {
        XCTAssertEqual(UsageWindow.allCases, [.sixHours, .twelveHours, .twentyFourHours])
        XCTAssertEqual(UsageWindow.widest, .twentyFourHours)
        XCTAssertEqual(UsageWindow.sixHours.label, "6h")
    }

    // MARK: Caching

    // The point of the store: a second pass over unchanged files must not re-read
    // them. Full parse of a real 24h window costs ~1050ms against ~94ms for the
    // directory walk alone, so this is the difference that matters.
    func test_secondRefresh_skipsUnchangedFiles() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-600), output: 100)],
                  to: dir, name: "a.jsonl", modified: now)
        let store = UsageHistoryStore()

        store.refresh(source: .claude, root: dir, now: now)
        let first = store.lastRefreshStats
        XCTAssertEqual(first.filesParsed, 1)
        XCTAssertEqual(first.filesSkipped, 0)
        XCTAssertGreaterThan(first.bytesParsed, 0)

        store.refresh(source: .claude, root: dir, now: now)
        let second = store.lastRefreshStats
        XCTAssertEqual(second.filesParsed, 0)
        XCTAssertEqual(second.filesSkipped, 1)
        XCTAssertEqual(second.bytesParsed, 0)

        // Totals survive the skip — the entries came from cache, not a re-read.
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 100)
    }

    // An appended line must be picked up without re-reading what came before.
    func test_appendedLine_parsesOnlyTheNewBytes() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        let path = dir + "a.jsonl"
        let firstLine = claudeLine(at: now.addingTimeInterval(-1_200), output: 100)
        try? (firstLine + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: dir, now: now)
        let firstBytes = store.lastRefreshStats.bytesParsed
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 100)

        let secondLine = claudeLine(at: now.addingTimeInterval(-600), output: 250)
        try? (firstLine + "\n" + secondLine + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        store.refresh(source: .claude, root: dir, now: now)
        let appendBytes = store.lastRefreshStats.bytesParsed
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 350)
        XCTAssertEqual(store.series(now: now).total(for: .turns), 2)

        // Only the appended region was read, not the whole file again. Compare
        // against the file's own size rather than against `firstBytes`: the two
        // fixture lines are near-identical in length, so a first-vs-second
        // comparison would pass or fail on line-length noise instead of on
        // whether the read was incremental.
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        XCTAssertGreaterThan(firstBytes, 0)
        XCTAssertLessThanOrEqual(appendBytes, secondLine.utf8.count + 1)
        XCTAssertLessThan(appendBytes, fileSize)
    }

    // A partial trailing line (a write caught mid-flush) must not be consumed, or
    // its entry would be lost once the newline lands.
    func test_partialTrailingLine_isPickedUpOnceComplete() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        let path = dir + "a.jsonl"
        let complete = claudeLine(at: now.addingTimeInterval(-900), output: 100)
        let pending = claudeLine(at: now.addingTimeInterval(-600), output: 400)

        // Second line written without its terminating newline.
        try? (complete + "\n" + pending).write(toFile: path, atomically: true, encoding: .utf8)
        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: dir, now: now)
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 100)

        try? (complete + "\n" + pending + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        store.refresh(source: .claude, root: dir, now: now)
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 500)
        XCTAssertEqual(store.series(now: now).total(for: .turns), 2)
    }

    // A truncated or replaced file must be re-read from the start rather than
    // resumed at a now-meaningless offset.
    func test_truncatedFile_isReparsedFromStart() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        let path = dir + "a.jsonl"
        let long = [claudeLine(at: now.addingTimeInterval(-1_200), output: 100),
                    claudeLine(at: now.addingTimeInterval(-900), output: 100),
                    claudeLine(at: now.addingTimeInterval(-600), output: 100)]
        try? (long.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: dir, now: now)
        XCTAssertEqual(store.series(now: now).total(for: .turns), 3)

        // Replace with a single, shorter entry.
        let replacement = claudeLine(at: now.addingTimeInterval(-300), output: 7)
        try? (replacement + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        store.refresh(source: .claude, root: dir, now: now)
        XCTAssertEqual(store.series(now: now).total(for: .turns), 1)
        XCTAssertEqual(store.series(now: now).total(for: .outputTokens), 7)
    }

    // Entries that age past the retained window must not accumulate forever.
    func test_agedOutEntries_arePruned() {
        let start = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        _ = write([claudeLine(at: start.addingTimeInterval(-600), output: 100)],
                  to: dir, name: "a.jsonl", modified: start)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: dir, now: start)
        XCTAssertEqual(store.lastRefreshStats.entriesRetained, 1)

        // Same file, but "now" has moved two days on: the file is cold and its
        // entries are out of window, so nothing should be retained.
        store.refresh(source: .claude, root: dir, now: start.addingTimeInterval(60 * 60 * 48))
        XCTAssertEqual(store.lastRefreshStats.entriesRetained, 0)
    }

    // One store serves every client, so its cache has to be partitioned by
    // source. Flattening a single shared map plotted Claude's history under
    // Codex — the graph looked plausible and was simply the wrong agent's data.
    func test_sourcesDoNotLeakIntoEachOther() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let claudeDir = fixtureDirectory()
        let codexDir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-600), output: 1_000)],
                  to: claudeDir, name: "a.jsonl", modified: now)
        _ = write([codexLine(at: now.addingTimeInterval(-600),
                             input: 100, cached: 0, output: 7, reasoning: 0)],
                  to: codexDir, name: "rollout-a.jsonl", modified: now)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: claudeDir, now: now)
        store.refresh(source: .codex, root: codexDir, now: now)

        // Each source sees only its own turns, in either refresh order.
        XCTAssertEqual(store.series(source: .claude, now: now).total(for: .outputTokens), 1_000)
        XCTAssertEqual(store.series(source: .claude, now: now).total(for: .turns), 1)
        XCTAssertEqual(store.series(source: .codex, now: now).total(for: .outputTokens), 7)
        XCTAssertEqual(store.series(source: .codex, now: now).total(for: .turns), 1)
    }

    // The reported symptom: a client with no history of its own must come back
    // empty rather than inheriting whatever was scanned before it.
    func test_sourceWithNoFiles_staysEmptyAfterAnotherSourceWasScanned() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let claudeDir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-600), output: 1_000)],
                  to: claudeDir, name: "a.jsonl", modified: now)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: claudeDir, now: now)
        store.refresh(source: .codex, root: fixtureDirectory(), now: now)

        XCTAssertTrue(store.series(source: .claude, now: now).hasActivity)
        XCTAssertFalse(store.series(source: .codex, now: now).hasActivity)
        XCTAssertEqual(store.series(source: .codex, now: now).total(for: .turns), 0)
    }

    // Refreshing one source must not evict or disturb another's cache.
    func test_refreshingOneSource_leavesTheOtherIntact() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let claudeDir = fixtureDirectory()
        let codexDir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-600), output: 1_000)],
                  to: claudeDir, name: "a.jsonl", modified: now)
        _ = write([codexLine(at: now.addingTimeInterval(-600),
                             input: 100, cached: 0, output: 7, reasoning: 0)],
                  to: codexDir, name: "rollout-a.jsonl", modified: now)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: claudeDir, now: now)
        store.refresh(source: .codex, root: codexDir, now: now)
        // Re-refresh Codex repeatedly; Claude's partition must be untouched.
        store.refresh(source: .codex, root: codexDir, now: now)
        store.refresh(source: .codex, root: codexDir, now: now)

        XCTAssertEqual(store.series(source: .claude, now: now).total(for: .outputTokens), 1_000)
    }

    // Re-bucketing for another window must not touch the disk at all.
    func test_seriesForDifferentWindow_doesNoIO() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        _ = write([claudeLine(at: now.addingTimeInterval(-60 * 60), output: 100),
                   claudeLine(at: now.addingTimeInterval(-60 * 60 * 9), output: 500)],
                  to: dir, name: "a.jsonl", modified: now)

        let store = UsageHistoryStore()
        store.refresh(source: .claude, root: dir, now: now)
        let afterRefresh = store.lastRefreshStats

        XCTAssertEqual(store.series(now: now, window: .twentyFourHours).total(for: .outputTokens), 600)
        XCTAssertEqual(store.series(now: now, window: .sixHours).total(for: .outputTokens), 100)
        // Stats untouched: no refresh happened, so no files were read.
        XCTAssertEqual(store.lastRefreshStats, afterRefresh)
    }

    // MARK: Codex

    func test_codexSeries_splitsCachedInputAndFoldsReasoning() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([codexLine(at: now.addingTimeInterval(-900),
                             input: 15_000, cached: 10_000, output: 200, reasoning: 60)],
                  to: dir, name: "rollout-test.jsonl", modified: now)

        let series = UsageHistoryReader.codexSeries(now: now, root: dir)
        // Reasoning tokens bill as output.
        XCTAssertEqual(series.total(for: .outputTokens), 260)
        // input_tokens already includes the cached portion, so input+cache must
        // come back to 15,000 rather than double-counting to 25,000.
        XCTAssertEqual(series.total(for: .inputAndCache), 15_000)
        XCTAssertEqual(series.total(for: .turns), 1)
    }

    func test_codexNonTokenCountEvents_areIgnored() {
        let dir = fixtureDirectory()
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        _ = write([
            #"{"timestamp":"2026-07-27T12:00:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#,
            codexLine(at: now.addingTimeInterval(-900), output: 200, reasoning: 0),
        ], to: dir, name: "rollout-test.jsonl", modified: now)

        let series = UsageHistoryReader.codexSeries(now: now, root: dir)
        XCTAssertEqual(series.total(for: .turns), 1)
        XCTAssertEqual(series.total(for: .outputTokens), 200)
    }
}
