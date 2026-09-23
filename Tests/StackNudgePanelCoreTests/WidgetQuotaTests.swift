import XCTest

@testable import StackNudgePanelCore

final class WidgetQuotaTests: XCTestCase {

    private let soon = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_100_000)

    // windowLength is set here because ClaudeCliQuotaProbe sets it — a fixture
    // without it exercised the unnamed-window path the real probe never takes.
    private func claudeSnapshot(five: Double? = nil, seven: Double? = nil) -> QuotaSnapshot {
        QuotaSnapshot(fiveHour: five.map {
                          QuotaTier(utilization: $0, resetsAt: soon,
                                    windowLength: QuotaWindow.fiveHours)
                      },
                      sevenDay: seven.map {
                          QuotaTier(utilization: $0, resetsAt: later,
                                    windowLength: QuotaWindow.sevenDays)
                      },
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
                      agy: AntigravityQuotaSnapshot? = nil,
                      pi: PiQuotaSnapshot? = nil) -> WidgetQuota {
        WidgetQuota.make(client: client, claude: claude, codex: codex, antigravity: agy, pi: pi)
    }

    private func piSnapshot(today: [Double], week: [Double]) -> PiQuotaSnapshot {
        func models(_ used: [Double], _ duration: TimeInterval) -> [PiModelUsage] {
            used.enumerated().map { index, value in
                PiModelUsage(key: UsageModelKey(provider: "p", model: "m\(index)", isLocal: false),
                             name: "m\(index)", tokens: 1,
                             tier: QuotaTier(utilization: value, resetsAt: Date().addingTimeInterval(duration),
                                             windowLength: duration))
            }
        }
        return PiQuotaSnapshot(today: models(today, 86400), thisWeek: models(week, 7 * 86400), budget: .fallback)
    }

    // MARK: - Per-client ring mapping

    // Like Antigravity: whichever model is closest to its budget takes the ring.
    func test_pi_closestModelTakesEachRing() {
        let q = make(.pi, pi: piSnapshot(today: [12, 62, 4], week: [18, 2]))
        XCTAssertEqual(q.short?.utilization, 62)
        XCTAssertEqual(q.long?.utilization, 18)
        XCTAssertEqual(q.shortLabel, "1d")
        XCTAssertEqual(q.longLabel, "7d")
    }

    func test_pi_weekOnlyUsageLeavesTheInnerRingEmpty() {
        let q = make(.pi, pi: piSnapshot(today: [], week: [9]))
        XCTAssertNil(q.short)
        XCTAssertEqual(q.long?.utilization, 9)
    }

    // A budget is the user's own, so passing it is the point of the row.
    func test_pi_overBudgetIsNotClamped() {
        let q = make(.pi, pi: piSnapshot(today: [140], week: [30]))
        XCTAssertEqual(q.short?.utilization, 140)
    }

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

    // A single dropped loopback tick used to return .empty, flipping the tooltip
    // back to "5h session quota" and losing the "Agy" tag while the Usage tab
    // still read Antigravity. Identity has to survive a missing snapshot, the
    // way the claude/codex branches already do.
    func test_antigravity_keepsItsIdentityWithNoSnapshot() {
        let q = make(.antigravity, agy: nil)
        XCTAssertEqual(q.client, .antigravity)
        XCTAssertEqual(q.shortLabel, "now")
        XCTAssertEqual(q.longLabel, "mo")
        XCTAssertTrue(q.ringDescription.contains("monthly prompt credits"))
        XCTAssertFalse(q.hasData)
    }

    // The same property for every client: a selected client with no snapshot
    // still names itself.
    func test_everyClientKeepsItsIdentityWithNoSnapshot() {
        for client in UsageClient.allCases {
            XCTAssertEqual(make(client).client, client, "\(client) lost its identity")
        }
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

    func test_widgetTag_namesEveryClient() {
        XCTAssertEqual(UsageClient.claude.widgetTag, "Claude")
        XCTAssertEqual(UsageClient.codex.widgetTag, "Codex")
        XCTAssertEqual(UsageClient.antigravity.widgetTag, "Agy")
        for client in UsageClient.allCases {
            XCTAssertFalse(client.widgetTag.isEmpty, "\(client) has no widget tag")
        }
    }
}
