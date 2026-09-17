import XCTest

@testable import StackNudgePanelCore

// Pins the ~/.claude.json fragment Claude Code writes to the parser that reads
// it, using the shape the CLI actually emits rather than a hand-built dictionary.
//
// Two things here are easy to get wrong and expensive to get wrong silently.
// The reset timestamps carry microsecond precision, which ISO8601DateFormatter
// rejects outright — a regression there drops every reset time while still
// producing a plausible-looking snapshot. And the freshness gate is the whole
// safety argument for reading this file at all: the cache only advances while
// Claude Code runs, so serving it unconditionally would show a week-old number
// as current.
final class ClaudeUsageCacheTests: XCTestCase {

    // Pinned to the fixture's fetchedAtMs below.
    private let fetchedAt = Date(timeIntervalSince1970: 1_789_642_590.220)

    private func json(fetchedAtMs: Int = 1_789_642_590_220,
                      fiveHour: String = #"{"utilization":31,"resets_at":"2026-09-17T11:20:00.147737+00:00","limit_dollars":null,"locked_reason":null}"#,
                      sevenDay: String = #"{"utilization":51,"resets_at":"2026-09-21T05:00:00.147757+00:00","limit_dollars":null,"locked_reason":null}"#,
                      opus: String = "null",
                      sonnet: String = "null") -> Data {
        Data("""
        {"numStartups":412,"oauthAccount":{"emailAddress":"a@b.c"},\
        "cachedUsageUtilization":{"fetchedAtMs":\(fetchedAtMs),\
        "accountUuid":"1f83e482-708d-4ba5-a85a-46745729aa9a","utilization":{\
        "five_hour":\(fiveHour),"seven_day":\(sevenDay),\
        "seven_day_opus":\(opus),"seven_day_sonnet":\(sonnet),\
        "seven_day_oauth_apps":null,"seven_day_cowork":null,"nimbus_quill":null,\
        "extra_usage":{"is_enabled":false,"utilization":null},\
        "limits":[],"member_dashboard_available":false,"seven_day_breakdown":null}}}
        """.utf8)
    }

    func testParsesBothWindowsWithTheirWindowLengths() {
        guard let reading = ClaudeUsageCache.parse(json()) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(reading.snapshot.fiveHour?.utilization, 31)
        XCTAssertEqual(reading.snapshot.fiveHour?.windowLength, QuotaWindow.fiveHours)
        XCTAssertEqual(reading.snapshot.sevenDay?.utilization, 51)
        XCTAssertEqual(reading.snapshot.sevenDay?.windowLength, QuotaWindow.sevenDays)
        XCTAssertEqual(reading.fetchedAt.timeIntervalSince1970,
                       fetchedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // The microsecond fraction Anthropic emits. Parsed wrong, resetsAt goes nil
    // and the tab loses every countdown while still drawing the bars. The kept
    // precision is milliseconds — the remaining digits are truncated, not
    // rounded, which is why this compares against the three-digit form.
    func testParsesMicrosecondPrecisionResetTimes() {
        let reading = ClaudeUsageCache.parse(json())
        XCTAssertEqual(reading?.snapshot.fiveHour?.resetsAt,
                       ClaudeUsageCache.parseTimestamp("2026-09-17T11:20:00.147+00:00"))
        // Pinned absolutely too, so a formatter change can't move both sides.
        XCTAssertEqual(reading?.snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0,
                       1_789_644_000.147, accuracy: 0.001)
    }

    func testTrimsFractionalSecondsToWhatTheFormatterAccepts() {
        XCTAssertEqual(
            ClaudeUsageCache.trimFractionalSeconds("2026-09-17T11:20:00.147737+00:00"),
            "2026-09-17T11:20:00.147+00:00")
        // Already three digits, and no fraction at all: both pass through.
        XCTAssertEqual(
            ClaudeUsageCache.trimFractionalSeconds("2026-09-17T11:20:00.147+00:00"),
            "2026-09-17T11:20:00.147+00:00")
        XCTAssertEqual(
            ClaudeUsageCache.trimFractionalSeconds("2026-09-17T11:20:00Z"),
            "2026-09-17T11:20:00Z")
    }

    // The model-scoped buckets are null on most plans and present on some, so
    // the parser has to take them when they're there without requiring them.
    func testParsesTheModelScopedWeeklyBucketsWhenPresent() {
        let data = json(opus: #"{"utilization":12,"resets_at":"2026-09-21T05:00:00.1+00:00"}"#)
        let reading = ClaudeUsageCache.parse(data)
        XCTAssertEqual(reading?.snapshot.sevenDayOpus?.utilization, 12)
        XCTAssertEqual(reading?.snapshot.sevenDayOpus?.windowLength, QuotaWindow.sevenDays)
        XCTAssertNil(reading?.snapshot.sevenDaySonnet)
    }

    // The plan name isn't in this payload; the probe supplies it from
    // `claude auth status`. Asserting nil pins that the cache doesn't invent one.
    func testReportsNoPlanType() {
        XCTAssertNil(ClaudeUsageCache.parse(json())?.snapshot.planType)
    }

    // An account that has used nothing this cycle still writes the key with
    // every bucket null. Returning a snapshot there would blank out a good one.
    func testRejectsAPayloadWithNoUsableBucket() {
        XCTAssertNil(ClaudeUsageCache.parse(json(fiveHour: "null", sevenDay: "null")))
    }

    func testRejectsAFileWithoutTheCacheKey() {
        XCTAssertNil(ClaudeUsageCache.parse(Data(#"{"numStartups":412}"#.utf8)))
    }

    // MARK: - Freshness

    private func writeFixture(_ data: Data, mtime: Date? = nil) throws -> String {
        let path = NSTemporaryDirectory() + "claude-usage-cache-\(UUID().uuidString).json"
        try data.write(to: URL(fileURLWithPath: path))
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime],
                                                  ofItemAtPath: path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testServesACacheWrittenWithinTheWindow() throws {
        let path = try writeFixture(json())
        let reading = ClaudeUsageCache.read(
            maxAge: 60, now: fetchedAt.addingTimeInterval(30), path: path)
        XCTAssertEqual(reading?.snapshot.fiveHour?.utilization, 31)
    }

    // The guard that matters: nothing refreshes this file except Claude Code, so
    // a fetchedAtMs older than the poll interval is a number from a session that
    // has since ended. The probe must spawn the CLI instead of showing it.
    func testRejectsACacheOlderThanTheWindow() throws {
        let path = try writeFixture(json())
        XCTAssertNil(ClaudeUsageCache.read(
            maxAge: 60, now: fetchedAt.addingTimeInterval(61), path: path))
    }

    // The stat shortcut: an old file is rejected without parsing hundreds of KB.
    // Written with a stale mtime but a fetchedAtMs that would otherwise pass.
    func testRejectsAStaleFileWithoutParsingIt() throws {
        let now = Date()
        let fresh = json(fetchedAtMs: Int(now.timeIntervalSince1970 * 1000))
        let path = try writeFixture(fresh, mtime: now.addingTimeInterval(-3600))
        XCTAssertNil(ClaudeUsageCache.read(maxAge: 60, now: now, path: path))
    }

    func testReturnsNothingWhenTheFileIsAbsent() {
        XCTAssertNil(ClaudeUsageCache.read(
            maxAge: 60, path: NSTemporaryDirectory() + "definitely-not-here.json"))
    }

    // MARK: - Hard-fail fallback

    private func reading(at seconds: TimeInterval) -> ClaudeUsageCache.Reading {
        ClaudeUsageCache.Reading(
            snapshot: QuotaSnapshot(fiveHour: QuotaTier(utilization: 7, resetsAt: nil),
                                    sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                                    planType: nil),
            fetchedAt: Date(timeIntervalSince1970: seconds))
    }

    // The case this exists for: the CLI is broken or missing on a cold start, so
    // there is nothing held to fall back to. Any disk reading beats an error row
    // over no numbers at all, however old it is.
    func testFallsBackToAnyReadingWhenNothingHasBeenReported() {
        let old = reading(at: 1_000)
        XCTAssertEqual(ClaudeCliQuotaProbe.fallbackReading(old, lastReportedAt: nil), old)
    }

    // The guard that keeps one timed-out tick from doing damage: a file written
    // before the snapshot already on screen must not replace it.
    func testRefusesAReadingOlderThanWhatWasAlreadyReported() {
        XCTAssertNil(ClaudeCliQuotaProbe.fallbackReading(
            reading(at: 1_000), lastReportedAt: Date(timeIntervalSince1970: 2_000)))
    }

    func testAcceptsAReadingNewerThanWhatWasAlreadyReported() {
        let fresh = reading(at: 3_000)
        XCTAssertEqual(
            ClaudeCliQuotaProbe.fallbackReading(
                fresh, lastReportedAt: Date(timeIntervalSince1970: 2_000)),
            fresh)
    }

    // Equal timestamps mean the same reading we already showed — no reason to
    // clear the staleness note for it.
    func testRefusesAReadingTakenAtTheSameInstant() {
        XCTAssertNil(ClaudeCliQuotaProbe.fallbackReading(
            reading(at: 2_000), lastReportedAt: Date(timeIntervalSince1970: 2_000)))
    }

    func testFallsBackToNothingWithNoReadingOnDisk() {
        XCTAssertNil(ClaudeCliQuotaProbe.fallbackReading(nil, lastReportedAt: nil))
    }
}
