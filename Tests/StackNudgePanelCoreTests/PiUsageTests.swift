import XCTest

@testable import StackNudgePanelCore

// Lane sums for asserting which kind a turn was filed under.
private extension Dictionary where Key == UsageModelKey, Value == Int {
    var localTokens: Int { filter { $0.key.isLocal }.values.reduce(0, +) }
    var apiTokens: Int { filter { !$0.key.isLocal }.values.reduce(0, +) }
}

// Pi's row on the Usage tab is a budget the user sets, not a quota a provider
// enforces, so what these pin is that every number under it is derived rather
// than assumed: which turns count as local, how wide the windows really are,
// and that a week's worth of history survives the graph's narrower refresh.
final class PiUsageTests: XCTestCase {

    // MARK: Fixtures

    private func fixtureDirectory() -> String {
        let dir = NSTemporaryDirectory() + "pi-usage-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ lines: [String], to directory: String, name: String, modified: Date) -> String {
        let path = directory + name
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        return path
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // A real-shape pi assistant message. `cost.total` is the only thing that
    // separates a billed API model from a free local one — pi writes the same
    // usage block for both.
    private func piLine(at when: Date,
                        input: Int = 1_000,
                        output: Int = 100,
                        cacheRead: Int = 5_000,
                        cacheWrite: Int = 0,
                        reasoning: Int = 0,
                        cost: Double = 0,
                        model: String = "m",
                        provider: String = "p",
                        id: String = UUID().uuidString) -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"\(Self.stamp.string(from: when))",\
        "message":{"role":"assistant","model":"\(model)","provider":"\(provider)","usage":{"input":\(input),\
        "output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),\
        "reasoning":\(reasoning),"totalTokens":0,"cost":{"total":\(cost)}}}}
        """
    }

    private func totals(_ lines: [String], now: Date, span: TimeInterval = 8 * 86400) -> [UsageModelKey: Int] {
        let dir = fixtureDirectory()
        write(lines, to: dir, name: "session.jsonl", modified: now)
        let store = UsageHistoryStore()
        store.refresh(source: .pi, root: dir, now: now, retaining: span)
        return store.totals(source: .pi, from: now.addingTimeInterval(-span), to: now.addingTimeInterval(60))
    }

    // MARK: Local vs API

    func test_zeroCostTurnCountsAsLocal() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60), cost: 0)], now: now)
        XCTAssertEqual(actual.localTokens, 1_100)
        XCTAssertEqual(actual.apiTokens, 0)
    }

    // pi writes a local turn's cost as the integer 0, a billed one as a
    // fraction. A cast that only accepts one of those shapes silently files
    // every turn in the wrong lane.
    func test_integerCostIsReadAsANumber() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        let line = """
        {"type":"message","id":"a","timestamp":"\(Self.stamp.string(from: now.addingTimeInterval(-60)))",\
        "message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":0,\
        "cacheWrite":0,"reasoning":0,"cost":{"total":2}}}}
        """
        write([line], to: dir, name: "session.jsonl", modified: now)
        let store = UsageHistoryStore()
        store.refresh(source: .pi, root: dir, now: now, retaining: 86400)

        let actual = store.totals(source: .pi, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertEqual(actual.apiTokens, 30)
        XCTAssertEqual(actual.localTokens, 0)
    }

    func test_pricedTurnCountsAsApi() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60), cost: 0.0112)], now: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
        XCTAssertEqual(actual.localTokens, 0)
    }

    // Reasoning is output the model produced; cache reads are a replay of
    // content already paid for and must not burn a budget.
    func test_reasoningCountsAndCacheReadsDoNot() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60),
                                    input: 10, output: 20, cacheRead: 9_000,
                                    cacheWrite: 5, reasoning: 30, cost: 1)],
                            now: now)
        XCTAssertEqual(actual.apiTokens, 65)
    }

    func test_bothLanesInOneWindow() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60), cost: 1),
                             piLine(at: now.addingTimeInterval(-120), cost: 0)],
                            now: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
        XCTAssertEqual(actual.localTokens, 1_100)
    }

    // A resumed session replays earlier turns into a second transcript.
    func test_replayedTurnCountsOnce() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let line = piLine(at: now.addingTimeInterval(-60), cost: 1, id: "repeated")
        let actual = totals([line, line], now: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
    }

    func test_nonAssistantLinesIgnored() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let session = #"{"type":"session","version":3,"id":"s","cwd":"/tmp"}"#
        let user = """
        {"type":"message","id":"u","timestamp":"\(Self.stamp.string(from: now))",\
        "message":{"role":"user","content":[{"type":"text","text":"ask the assistant"}]}}
        """
        let actual = totals([session, user, piLine(at: now.addingTimeInterval(-60), cost: 1)], now: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
    }

    // MARK: Per model

    func test_totalsSplitByModel() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60), cost: 1, model: "gemini-pro", provider: "gemini"),
                             piLine(at: now.addingTimeInterval(-90), cost: 1, model: "gemini-pro", provider: "gemini"),
                             piLine(at: now.addingTimeInterval(-120), cost: 0, model: "qwen", provider: "ollama")],
                            now: now)
        XCTAssertEqual(actual[UsageModelKey(provider: "gemini", model: "gemini-pro", isLocal: false)], 2_200)
        XCTAssertEqual(actual[UsageModelKey(provider: "ollama", model: "qwen", isLocal: true)], 1_100)
    }

    // A failed call is priced at zero and carries no tokens. It must not turn up
    // as an empty local model row.
    func test_zeroTokenTurnAddsNoModel() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-60), input: 0, output: 0,
                                    model: "claude-3-5-haiku-latest", provider: "anthropic")],
                            now: now)
        XCTAssertTrue(actual.isEmpty)
    }

    // MARK: Window arithmetic

    // The span a totals() caller asks for is honoured exactly, rather than being
    // silently truncated to the graph's widest bucket grid.
    func test_totalsSpanAFullWeek() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let actual = totals([piLine(at: now.addingTimeInterval(-6 * 86400), cost: 1),
                             piLine(at: now.addingTimeInterval(-60), cost: 1)],
                            now: now)
        XCTAssertEqual(actual.apiTokens, 2_200)
    }

    func test_entriesOutsideTheSpanAreExcluded() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        write([piLine(at: now.addingTimeInterval(-3 * 86400), cost: 1),
               piLine(at: now.addingTimeInterval(-60), cost: 1)],
              to: dir, name: "session.jsonl", modified: now)
        let store = UsageHistoryStore()
        store.refresh(source: .pi, root: dir, now: now, retaining: 8 * 86400)

        let actual = store.totals(source: .pi, from: now.addingTimeInterval(-86400), to: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
    }

    // The graph refreshes the same source over 24h. Without a retention
    // watermark that narrower call evicts the budget's week between polls.
    func test_narrowRefreshDoesNotEvictTheWeek() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let dir = fixtureDirectory()
        let old = now.addingTimeInterval(-5 * 86400)
        write([piLine(at: old, cost: 1)], to: dir, name: "old.jsonl", modified: old)
        let store = UsageHistoryStore()
        store.refresh(source: .pi, root: dir, now: now, retaining: 8 * 86400)
        store.refresh(source: .pi, root: dir, now: now, retaining: UsageWindow.widest.seconds)

        let actual = store.totals(source: .pi, from: now.addingTimeInterval(-7 * 86400), to: now)
        XCTAssertEqual(actual.apiTokens, 1_100)
    }

    // MARK: Budget

    private func window(_ start: TimeInterval, _ duration: TimeInterval) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), duration: duration)
    }

    private func modelTotals(_ rows: [(model: String, provider: String, isLocal: Bool, tokens: Int)]) -> [UsageModelKey: Int] {
        var totals: [UsageModelKey: Int] = [:]
        for row in rows {
            totals[UsageModelKey(provider: row.provider, model: row.model, isLocal: row.isLocal)] = row.tokens
        }
        return totals
    }

    private func today(_ totals: [UsageModelKey: Int], budget: PiBudget) -> [PiModelUsage] {
        let day = window(1_785_110_400, 86400)
        return PiUsageBudget.snapshot(day: day, dayTotals: totals, week: day, weekTotals: totals,
                                      budget: budget)?.today ?? []
    }

    // The pane lists models by name only, but the kind still picks the budget:
    // a local model against the local allowance, a priced one against the API's.
    func test_eachModelMeasuresAgainstItsKindsBudget() {
        let day = window(1_785_110_400, 86400)
        let totals = modelTotals([("gemini-pro", "gemini", false, 750_000),
                                  ("qwen3.8:27b", "ollama", true, 60_000)])
        let actual = today(totals, budget: PiBudget(apiDaily: 1_500_000, localDaily: 500_000))
        XCTAssertEqual(actual.map(\.name), ["gemini-pro", "qwen3.8:27b"])
        XCTAssertEqual(actual.map(\.tier.utilization), [50, 12])
        XCTAssertEqual(actual.first?.tier.resetsAt, day.end)
        XCTAssertEqual(actual.first?.tier.windowLength, 86400)
    }

    // Closest to its budget first, not most tokens: 400K local is nearer its
    // limit than 750K of API.
    func test_modelsSortClosestToBudgetFirst() {
        let totals = modelTotals([("gemini-pro", "gemini", false, 750_000),
                                  ("qwen3.8:27b", "ollama", true, 400_000)])
        let actual = today(totals, budget: PiBudget(apiDaily: 1_500_000, localDaily: 500_000))
        XCTAssertEqual(actual.map(\.name), ["qwen3.8:27b", "gemini-pro"])
    }

    func test_weekMeasuresAgainstSevenDaysOfAllowance() {
        let day = window(1_785_110_400, 86400)
        let week = window(1_785_110_400, 7 * 86400)
        let totals = modelTotals([("gemini-pro", "gemini", false, 700_000)])
        let snapshot = PiUsageBudget.snapshot(day: day, dayTotals: [:], week: week, weekTotals: totals,
                                              budget: PiBudget(apiDaily: 1_000_000, localDaily: 500_000))
        XCTAssertTrue(snapshot?.today.isEmpty ?? false)
        XCTAssertEqual(snapshot?.thisWeek.first?.tier.utilization, 10)
        XCTAssertEqual(snapshot?.thisWeek.first?.tier.resetsAt, week.end)
    }

    func test_sameModelNameFromTwoProvidersNamesTheProvider() {
        let totals = modelTotals([("qwen3", "qwen", false, 2_000), ("qwen3", "openrouter", false, 1_000)])
        XCTAssertEqual(today(totals, budget: .fallback).map(\.name), ["qwen3 (qwen)", "qwen3 (openrouter)"])
    }

    // A kind budgeted off in Settings takes its models off the page.
    func test_kindBudgetedOffDropsItsModels() {
        let totals = modelTotals([("gemini-pro", "gemini", false, 100_000), ("qwen", "ollama", true, 50_000)])
        XCTAssertEqual(today(totals, budget: PiBudget(apiDaily: 0, localDaily: 500_000)).map(\.name), ["qwen"])
    }

    // Going over is the thing a self-imposed budget exists to report.
    func test_overBudgetIsNotClamped() {
        let totals = modelTotals([("qwen", "ollama", true, 3_000_000)])
        XCTAssertEqual(today(totals, budget: PiBudget(apiDaily: 1_500_000, localDaily: 500_000)).first?.tier.utilization, 600)
    }

    func test_weeklyBudgetIsSevenDays() {
        let budget = PiBudget(apiDaily: 1_000_000, localDaily: 100_000)
        XCTAssertEqual(budget.allowance(isLocal: false, in: .thisWeek), 7_000_000)
        XCTAssertEqual(budget.allowance(isLocal: true, in: .thisWeek), 700_000)
        XCTAssertEqual(budget.allowance(isLocal: true, in: .today), 100_000)
    }

    func test_noUsageProducesNoSnapshot() {
        let day = window(1_785_110_400, 86400)
        XCTAssertNil(PiUsageBudget.snapshot(day: day, dayTotals: [:],
                                            week: day, weekTotals: [:],
                                            budget: .fallback))
    }

    // MARK: Probe

    // End to end: fixtures on disk through the probe to a snapshot, with the
    // day boundary separating what counts today from what only counts this week.
    func test_probeSplitsTodayFromTheWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!
        let dir = fixtureDirectory()
        write([piLine(at: now.addingTimeInterval(-3_600), input: 990, output: 10, cost: 1),
               piLine(at: now.addingTimeInterval(-24 * 3_600), input: 500, output: 0, cost: 1)],
              to: dir, name: "session.jsonl", modified: now)

        let actual = PiUsageProbe.read(store: UsageHistoryStore(),
                                       root: dir,
                                       budget: PiBudget(apiDaily: 1_000_000, localDaily: 500_000),
                                       now: now,
                                       calendar: calendar)

        XCTAssertEqual(actual?.today.map(\.name), ["m"])
        XCTAssertEqual(actual?.today.first?.tier.utilization, 0.1)
        let week = try XCTUnwrap(actual?.thisWeek.first?.tier.utilization)
        XCTAssertEqual(week, 1_500.0 / 7_000_000 * 100, accuracy: 0.000_001)
    }

    // MARK: Calendar windows

    func test_windowsCoverNow() {
        let now = Date(timeIntervalSince1970: 1_785_150_000)
        let windows = PiUsageBudget.windows(now: now)
        XCTAssertEqual(windows?.day.contains(now), true)
        XCTAssertEqual(windows?.week.contains(now), true)
        XCTAssertEqual(windows?.day.duration, 86400)
    }

    // A spring-forward day is 23 hours long. The pane's ahead-of-pace warning
    // divides by this, so measuring the period beats assuming 86400.
    func test_dstDayIsShorterThanTwentyFourHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!

        let windows = PiUsageBudget.windows(now: noon, calendar: calendar)
        XCTAssertEqual(windows?.day.duration, 23 * 3600)
    }

    func test_weekStartsOnTheCalendarsFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2  // Monday
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9))!

        let windows = PiUsageBudget.windows(now: wednesday, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: windows!.week.start), 2)
        XCTAssertEqual(windows?.week.duration, 7 * 86400)
    }
}

// A budget change in Settings has to repaint the Usage tab straight away, not
// on the next poll, and a lane switched off has to take its row with it.
@MainActor
final class PiBudgetSettingsTests: XCTestCase {

    private func snapshot() -> PiQuotaSnapshot {
        let day = DateInterval(start: Date(), duration: 86400)
        let tier = QuotaTier(utilization: 40, resetsAt: day.end, windowLength: day.duration)
        let model = PiModelUsage(key: UsageModelKey(provider: "gemini", model: "gemini-pro", isLocal: false),
                                 name: "gemini-pro", tokens: 600_000, tier: tier)
        return PiQuotaSnapshot(today: [model], thisWeek: [], budget: .fallback)
    }

    func test_budgetChangeRefreshesStraightAway() {
        let nav = PanelNav()
        var refreshes = 0
        nav.refreshPiBudget = { refreshes += 1 }

        nav.setPiBudget(apiDaily: 2_000_000, localDaily: 0)

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(nav.piBudget, PiBudget(apiDaily: 2_000_000, localDaily: 0))
    }

    func test_windowTogglesBetweenTodayAndThisWeek() {
        let nav = PanelNav()
        XCTAssertEqual(nav.piWindow, .today)
        nav.cyclePiWindow()
        XCTAssertEqual(nav.piWindow, .thisWeek)
        nav.cyclePiWindow()
        XCTAssertEqual(nav.piWindow, .today)
    }

    func test_nilSnapshotClearsTheRow() {
        let nav = PanelNav()
        nav.applyPiSnapshot(snapshot())

        nav.applyPiSnapshot(nil)

        XCTAssertNil(nav.piQuota)
        XCTAssertFalse(nav.availableUsageClients.contains(.pi))
    }

    func test_snapshotStampsPiAsUpdated() {
        let nav = PanelNav()

        nav.applyPiSnapshot(snapshot())

        XCTAssertNotNil(nav.quotaUpdatedAt[.pi])
        XCTAssertTrue(nav.availableUsageClients.contains(.pi))
    }
}
