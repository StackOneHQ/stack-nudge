import XCTest

@testable import StackNudgePanelCore

// availableUsageClients decides which clients get a row in the Usage tab. The
// rule used to be "has a non-empty snapshot"; a client that failed simply
// vanished, and the only error the tab could show was Claude's global one. Now a
// client with an error but no snapshot lists itself so the error renders on its
// own detail pane — these pin that, and pin that a Claude error never drops
// Claude just because another client happens to have data.
@MainActor
final class UsageAvailabilityTests: XCTestCase {

    private func claudeSnapshot(five: Double? = 10) -> QuotaSnapshot {
        QuotaSnapshot(fiveHour: five.map { QuotaTier(utilization: $0, resetsAt: nil) },
                      sevenDay: nil, sevenDayOpus: nil, sevenDaySonnet: nil, planType: nil)
    }

    private func codexSnapshot() -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(primary: QuotaTier(utilization: 20, resetsAt: nil),
                           secondary: nil, planType: nil)
    }

    func test_claudeWithTiers_isListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot()
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }

    // The new behaviour: an error with no snapshot to fall back on still lists
    // the client, so the note has a pane to render on instead of falling through
    // to the tab's cold-load empty state.
    func test_claudeWithErrorButNoSnapshot_isListed() {
        let nav = PanelNav()
        nav.quotaErrors[.claude] = "Claude Code didn't report your limits — retrying shortly."
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }

    func test_claudeWithNeitherSnapshotNorError_isNotListed() {
        let nav = PanelNav()
        XCTAssertTrue(nav.availableUsageClients.isEmpty)
    }

    // An all-nil snapshot isn't a usable client, and without an error it stays
    // out of the list — matching the pre-existing "empty snapshot isn't a
    // client" rule.
    func test_emptyClaudeSnapshotWithoutError_isNotListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot(five: nil)
        XCTAssertTrue(nav.availableUsageClients.isEmpty)
    }

    // Regression guard: a Claude error must not drop Claude out of the list just
    // because Codex has data. Both are listed; the failing client keeps its row.
    func test_claudeErrorWithCodexPresent_listsBoth() {
        let nav = PanelNav()
        nav.quotaErrors[.claude] = "Couldn't refresh — run `claude /usage` to check your session."
        nav.codexQuota = codexSnapshot()
        XCTAssertEqual(nav.availableUsageClients, [.claude, .codex])
    }

    // A held-stale Claude snapshot (error present, but the last-good bars are
    // still there) keeps its row too — the error marks it stale rather than
    // removing it.
    func test_claudeHeldStaleSnapshot_staysListed() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot()
        nav.quotaErrors[.claude] = "Couldn't refresh — run `claude /usage` to check your session."
        XCTAssertEqual(nav.availableUsageClients, [.claude])
    }

    // The predicate is uniform: an error lists its client whichever client it
    // is, not only Claude. Antigravity is the one that actually populates an
    // error today (agy running but unparseable); Codex is checked the same way
    // so a future Codex error could display without another wiring change.
    func test_antigravityErrorButNoSnapshot_isListed() {
        let nav = PanelNav()
        nav.quotaErrors[.antigravity] = "Couldn't read Antigravity usage."
        XCTAssertEqual(nav.availableUsageClients, [.antigravity])
    }

    func test_codexErrorButNoSnapshot_isListed() {
        let nav = PanelNav()
        nav.quotaErrors[.codex] = "something failed"
        XCTAssertEqual(nav.availableUsageClients, [.codex])
    }

    // Listing order follows UsageClient.fixedCases (claude, codex, antigravity),
    // so a mix of data and errors stays in a stable order.
    func test_ordering_followsDeclarationOrder() {
        let nav = PanelNav()
        nav.quotaErrors[.antigravity] = "err"
        nav.codexQuota = codexSnapshot()
        nav.quota = claudeSnapshot()
        XCTAssertEqual(nav.availableUsageClients, [.claude, .codex, .antigravity])
    }

    // MARK: - Other Claude logins

    private let team = ClaudeLogin(configDir: "/h/.claude-team", label: "Stackone")
    private let work = ClaudeLogin(configDir: "/h/.claude-work", label: "work")

    // Each login gets its own row, in the order found, straight after the
    // default Claude row and before every other client.
    func test_otherLoginsAreListedAfterTheDefaultClaudeRow() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot()
        nav.codexQuota = codexSnapshot()
        nav.claudeLogins = [team, work]
        nav.claudeLoginQuotas = [team.configDir: claudeSnapshot(), work.configDir: claudeSnapshot()]
        XCTAssertEqual(nav.availableUsageClients,
                       [.claude, .claudeLogin(team), .claudeLogin(work), .codex])
    }

    // Found but not yet probed: no row until there's something or an error to show.
    func test_aLoginWithNothingToShowIsNotListed() {
        let nav = PanelNav()
        nav.claudeLogins = [team]
        XCTAssertEqual(nav.availableUsageClients, [])
        nav.quotaErrors[.claudeLogin(team)] = "failed"
        XCTAssertEqual(nav.availableUsageClients, [.claudeLogin(team)])
    }

    // A login is its config dir: its label changing doesn't make it another row.
    func test_aLoginIsTheSameRowWhateverItsLabel() {
        XCTAssertEqual(UsageClient.claudeLogin(team),
                       .claudeLogin(ClaudeLogin(configDir: team.configDir, label: "Renamed")))
    }

    func test_eachClaudeRowReadsItsOwnSnapshot() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot(five: 10)
        nav.claudeLogins = [team]
        nav.claudeLoginQuotas = [team.configDir: claudeSnapshot(five: 90)]
        XCTAssertEqual(nav.claudeQuota(for: .claude)?.fiveHour?.utilization, 10)
        XCTAssertEqual(nav.claudeQuota(for: .claudeLogin(team))?.fiveHour?.utilization, 90)
        XCTAssertNil(nav.claudeQuota(for: .codex))
    }

    // MARK: - Stress

    // With a Claude row selected, a team seat running hot shows on the mascot
    // even though the pill is showing your own plan.
    func test_stressTakesTheHottestClaudeLoginWhileClaudeIsSelected() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot(five: 10)
        nav.claudeLogins = [team]
        nav.claudeLoginQuotas = [team.configDir: claudeSnapshot(five: 90)]
        nav.usageClientIndex = 0
        XCTAssertEqual(nav.selectedUsageClient, .claude)
        XCTAssertEqual(nav.widgetQuota.peakUtilization, 10)
        XCTAssertEqual(nav.stressPeakUtilization, 90)
    }

    // Another client's logins never count: a hot Claude doesn't stress Codex.
    func test_stressIsTheSelectedClientsOwnOtherwise() {
        let nav = PanelNav()
        nav.quota = claudeSnapshot(five: 95)
        nav.codexQuota = codexSnapshot()
        nav.usageClientIndex = 1
        XCTAssertEqual(nav.selectedUsageClient, .codex)
        XCTAssertEqual(nav.stressPeakUtilization, 20)
    }

    // MARK: - Other Codex logins

    private let codexWork = CodexLogin(codexHome: "/h/.codex-work", label: "work", account: "ws-work",
                                       info: AccountInfo(email: "me@work.example"))

    private func codexSnapshot(primary: Double) -> CodexQuotaSnapshot {
        CodexQuotaSnapshot(primary: QuotaTier(utilization: primary, resetsAt: nil), secondary: nil, planType: "plus")
    }

    func test_otherCodexLoginsAreListedAfterTheDefaultCodexRow() {
        let nav = PanelNav()
        nav.codexQuota = codexSnapshot()
        nav.codexLogins = [codexWork]
        nav.codexLoginQuotas = [codexWork.codexHome: codexSnapshot(primary: 50)]
        nav.quotaErrors[.antigravity] = "err"
        XCTAssertEqual(nav.availableUsageClients, [.codex, .codexLogin(codexWork), .antigravity])
    }

    func test_eachCodexRowReadsItsOwnSnapshotAndAccount() {
        let nav = PanelNav()
        nav.codexQuota = codexSnapshot(primary: 10)
        nav.codexDefaultInfo = AccountInfo(email: "me@home.example")
        nav.codexLogins = [codexWork]
        nav.codexLoginQuotas = [codexWork.codexHome: codexSnapshot(primary: 70)]
        XCTAssertEqual(nav.codexQuota(for: .codex)?.primary?.utilization, 10)
        XCTAssertEqual(nav.codexQuota(for: .codexLogin(codexWork))?.primary?.utilization, 70)
        XCTAssertNil(nav.codexQuota(for: .claude))
        XCTAssertEqual(nav.accountInfo(for: .codex)?.line, "me@home.example")
        XCTAssertEqual(nav.accountInfo(for: .codexLogin(codexWork))?.line, "me@work.example")
        XCTAssertNil(nav.accountInfo(for: .antigravity))
    }

    // The pill follows the selected Codex row's own numbers.
    func test_theWidgetShowsTheSelectedCodexLogin() {
        let nav = PanelNav()
        nav.codexQuota = codexSnapshot(primary: 10)
        nav.codexLogins = [codexWork]
        nav.codexLoginQuotas = [codexWork.codexHome: codexSnapshot(primary: 70)]
        nav.usageClientIndex = 1
        XCTAssertEqual(nav.selectedUsageClient, .codexLogin(codexWork))
        XCTAssertEqual(nav.widgetQuota.client, .codexLogin(codexWork))
        XCTAssertEqual(nav.widgetQuota.shortUtilization, 70)
    }

    func test_stressTakesTheHottestCodexLoginWhileCodexIsSelected() {
        let nav = PanelNav()
        nav.codexQuota = codexSnapshot(primary: 10)
        nav.codexLogins = [codexWork]
        nav.codexLoginQuotas = [codexWork.codexHome: codexSnapshot(primary: 85)]
        nav.usageClientIndex = 0
        XCTAssertEqual(nav.selectedUsageClient, .codex)
        XCTAssertEqual(nav.stressPeakUtilization, 85)
    }

    func test_aCodexLoginIsTheSameRowWhateverItsAccount() {
        XCTAssertEqual(UsageClient.codexLogin(codexWork),
                       .codexLogin(CodexLogin(codexHome: codexWork.codexHome, label: "other", account: "x")))
    }
}
