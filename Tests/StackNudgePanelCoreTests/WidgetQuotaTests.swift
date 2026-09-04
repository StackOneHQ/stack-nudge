import XCTest

@testable import StackNudgePanelCore

final class WidgetQuotaTests: XCTestCase {

    private let soon = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_100_000)

    private func claudeSnapshot(five: Double? = nil, seven: Double? = nil) -> QuotaSnapshot {
        QuotaSnapshot(fiveHour: five.map { QuotaTier(utilization: $0, resetsAt: soon) },
                      sevenDay: seven.map { QuotaTier(utilization: $0, resetsAt: later) },
                      sevenDayOpus: nil, sevenDaySonnet: nil, planType: "max")
    }

    private func agySnapshot(models: [(String, Double)],
                             credits: (available: Int, monthly: Int)? = nil)
    -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            planType: "pro",
            models: models.map {
                .init(label: $0.0, tier: QuotaTier(utilization: $0.1, resetsAt: soon))
            },
            promptCredits: credits.map { .init(available: $0.available, monthly: $0.monthly) },
            flowCredits: nil)
    }

    private func make(_ client: UsageClient?,
                      claude: QuotaSnapshot? = nil,
                      codex: CodexQuotaSnapshot? = nil,
                      agy: AntigravityQuotaSnapshot? = nil) -> WidgetQuota {
        WidgetQuota.make(client: client, claude: claude, codex: codex, antigravity: agy)
    }

    // MARK: - Per-client ring mapping

    func test_claude_mapsFiveHourAndSevenDay() {
        let q = make(.claude, claude: claudeSnapshot(five: 40, seven: 12))
        XCTAssertEqual(q.short?.utilization, 40)
        XCTAssertEqual(q.long?.utilization, 12)
        XCTAssertEqual(q.shortLabel, "5h")
        XCTAssertEqual(q.longLabel, "7d")
    }

    func test_codex_mapsPrimaryAndSecondary() {
        let codex = CodexQuotaSnapshot(primary: QuotaTier(utilization: 82, resetsAt: soon),
                                       secondary: QuotaTier(utilization: 30, resetsAt: later),
                                       planType: "plus")
        let q = make(.codex, codex: codex)
        XCTAssertEqual(q.client, .codex)
        XCTAssertEqual(q.short?.utilization, 82)
        XCTAssertEqual(q.long?.utilization, 30)
    }

    // agy has no 5h/weekly pair, so the inner ring shows whichever model is
    // closest to blocking you — not the first one the RPC happened to list.
    func test_antigravity_innerRingIsTheWorstModel() {
        let q = make(.antigravity, agy: agySnapshot(models: [("Sonnet", 10),
                                                             ("Opus", 91),
                                                             ("Gemini", 44)]))
        XCTAssertEqual(q.short?.utilization, 91)
        XCTAssertEqual(q.shortLabel, "now")
        XCTAssertEqual(q.longLabel, "mo")
    }

    // Credits arrive as "available of monthly" — the inverse of every other
    // tier's utilization, so a wrong sign here would read 25% as 75%.
    func test_antigravity_creditsInvertToUtilization() {
        let q = make(.antigravity, agy: agySnapshot(models: [("Opus", 5)],
                                                    credits: (available: 250, monthly: 1000)))
        XCTAssertEqual(q.long?.utilization, 75)
        XCTAssertNil(q.long?.resetsAt)
    }

    func test_antigravity_noCredits_leavesOuterRingEmpty() {
        let q = make(.antigravity, agy: agySnapshot(models: [("Opus", 5)]))
        XCTAssertNil(q.long)
    }

    func test_antigravity_zeroMonthlyCredits_doesNotDivideByZero() {
        let q = make(.antigravity, agy: agySnapshot(models: [("Opus", 5)],
                                                    credits: (available: 0, monthly: 0)))
        XCTAssertNil(q.long)
    }

    // MARK: - Empty states

    func test_noClientSelected_isEmpty() {
        XCTAssertEqual(make(nil, claude: claudeSnapshot(five: 40)), .empty)
        XCTAssertFalse(WidgetQuota.empty.hasData)
    }

    // The selection is an index into availableUsageClients, which is rebuilt
    // from live probe state — a client can be selected on the tick its snapshot
    // goes away.
    func test_selectedClientWithNoSnapshot_hasNoData() {
        let q = make(.codex, claude: claudeSnapshot(five: 40))
        XCTAssertFalse(q.hasData)
        XCTAssertEqual(q.shortUtilization, 0)
    }

    func test_hasData_trueWhenOnlyOneRingPresent() {
        XCTAssertTrue(make(.claude, claude: claudeSnapshot(seven: 12)).hasData)
    }

    // MARK: - Derived signals

    // Border, pulse and refresh cadence read the short window alone; this
    // preserves the pre-multi-client behaviour, where they read fiveHour.
    func test_shortUtilization_ignoresTheLongWindow() {
        let q = make(.claude, claude: claudeSnapshot(five: 10, seven: 99))
        XCTAssertEqual(q.shortUtilization, 10)
    }

    // The mascot's stress signal keys off whichever window is tighter.
    func test_peakUtilization_takesTheWorseWindow() {
        XCTAssertEqual(make(.claude, claude: claudeSnapshot(five: 10, seven: 99)).peakUtilization, 99)
        XCTAssertEqual(make(.claude, claude: claudeSnapshot(five: 88, seven: 4)).peakUtilization, 88)
    }

    func test_countdownTargetIsTheShortWindowReset() {
        let q = make(.claude, claude: claudeSnapshot(five: 40, seven: 12))
        XCTAssertEqual(q.countdownTarget, soon)
    }

    func test_countdownNilWhenShortWindowMissing() {
        XCTAssertNil(make(.claude, claude: claudeSnapshot(seven: 12)).countdownTarget)
    }

    // MARK: - Labelling

    func test_ringDescription_isClientSpecific() {
        XCTAssertTrue(make(.claude, claude: claudeSnapshot(five: 1)).ringDescription.contains("5h session"))
        XCTAssertTrue(make(.antigravity, agy: agySnapshot(models: [("Opus", 1)]))
            .ringDescription.contains("monthly prompt credits"))
    }

    // Claude is the default selection, so tagging it would put a name line on
    // every pill belonging to someone who never switches client.
    func test_widgetTag_absentForClaudeOnly() {
        XCTAssertNil(UsageClient.claude.widgetTag)
        XCTAssertEqual(UsageClient.codex.widgetTag, "Codex")
        XCTAssertEqual(UsageClient.antigravity.widgetTag, "Agy")
    }
}
