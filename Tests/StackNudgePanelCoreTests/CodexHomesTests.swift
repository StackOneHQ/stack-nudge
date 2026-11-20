import XCTest

@testable import StackNudgePanelCore

// Which other Codex logins get probed and which get a row. A home missed here
// is an account whose limits nothing shows; one wrongly included is a `codex`
// started on every refresh that fills a dir that isn't its own with databases,
// or the default account shown twice.
final class CodexHomesTests: XCTestCase {

    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "codex-homes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return (home as NSString).resolvingSymlinksInPath
    }

    // A Codex home as Codex leaves one after a sign-in. The auth.json is empty:
    // only its existence is ever looked at.
    @discardableResult
    private func makeCodexHome(_ path: String, firstRun: Bool = true) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: "\(path)/auth.json"))
        if firstRun { try Data().write(to: URL(fileURLWithPath: "\(path)/installation_id")) }
        return path
    }

    // MARK: - Scan

    func testFindsEveryCodexHomeWhateverItIsCalled() throws {
        let home = try makeHome()
        try makeCodexHome("\(home)/.codex-work")
        try makeCodexHome("\(home)/accounts/side")
        XCTAssertEqual(CodexHomes.scan(home: home).sorted(), ["\(home)/.codex-work", "\(home)/accounts/side"])
    }

    // pi keeps an auth.json in ~/.pi/agent. Probing it would have codex write its
    // databases and logs into pi's dir.
    func testIgnoresAnotherToolsAuthJson() throws {
        let home = try makeHome()
        try makeCodexHome("\(home)/.pi/agent", firstRun: false)
        XCTAssertEqual(CodexHomes.scan(home: home), [])
    }

    func testScansTwoLevelsDownAndNeverInsideTheFoldersMacOSGuards() throws {
        let home = try makeHome()
        try makeCodexHome("\(home)/a/b/c")
        try makeCodexHome("\(home)/Documents/codex")
        try makeCodexHome("\(home)/Library/codex")
        XCTAssertEqual(CodexHomes.scan(home: home), [])
    }

    // MARK: - Candidates

    // ~/.codex is the default login's, probed already.
    func testNeverListsTheDefaultHome() throws {
        let home = try makeHome()
        try makeCodexHome("\(home)/.codex")
        XCTAssertEqual(CodexHomes.candidates(home: home, setting: "~/.codex",
                                             found: CodexHomes.scan(home: home)), [])
    }

    // A dir named in the setting or seen running is Codex's already, so it only
    // needs the auth.json, wherever it lives.
    func testTakesTheSettingFirstAndNeedsOnlyAnAuthJson() throws {
        let home = try makeHome()
        let elsewhere = try makeCodexHome("\(home)/Documents/codex", firstRun: false)
        let scanned = try makeCodexHome("\(home)/.codex-a")
        XCTAssertEqual(CodexHomes.candidates(home: home, setting: "~/Documents/codex, relative",
                                             found: CodexHomes.scan(home: home)),
                       [elsewhere, scanned])
    }

    func testDropsAHomeWithNoAuthJsonAndListsEachOnce() throws {
        let home = try makeHome()
        let work = try makeCodexHome("\(home)/.codex-work")
        try FileManager.default.createDirectory(atPath: "\(home)/.codex-empty", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(home)/work-link", withDestinationPath: work)
        XCTAssertEqual(CodexHomes.candidates(home: home, setting: nil,
                                             found: [work, "\(home)/work-link", "\(home)/.codex-empty"]),
                       [work])
    }

    // MARK: - Logins

    private func account(_ workspace: String?, _ email: String? = "me@example.com") -> CodexAccount {
        CodexAccount(type: "chatgpt", email: email, planType: "plus", chatgptAccountId: workspace)
    }

    func testOneRowPerAccountInTheOrderFound() {
        let actual = CodexHomes.logins(
            candidates: ["/h/.codex-a", "/h/.codex-b", "/h/.codex-c"],
            accounts: ["/h/.codex-a": account("ws-a"), "/h/.codex-b": account("ws-b"),
                       "/h/.codex-c": account("ws-a")],
            defaultAccount: nil)
        XCTAssertEqual(actual.map(\.codexHome), ["/h/.codex-a", "/h/.codex-b"])
        XCTAssertEqual(actual.map(\.account), ["ws-a", "ws-b"])
        XCTAssertEqual(actual.map(\.label), ["a", "b"])
        XCTAssertEqual(actual.first?.info.line, "me@example.com")
    }

    // The same account as the default login would only repeat its numbers.
    func testSkipsAHomeSignedInToTheDefaultAccount() {
        let actual = CodexHomes.logins(candidates: ["/h/.codex-a", "/h/.codex-b"],
                                       accounts: ["/h/.codex-a": account("ws-me"), "/h/.codex-b": account("ws-team")],
                                       defaultAccount: "ws-me")
        XCTAssertEqual(actual.map(\.codexHome), ["/h/.codex-b"])
    }

    // One person in their own plan and a team workspace: same email, separate
    // limits.
    func testKeepsTheSameEmailInAnotherWorkspace() {
        let actual = CodexHomes.logins(candidates: ["/h/.codex-team"],
                                       accounts: ["/h/.codex-team": account("ws-team")],
                                       defaultAccount: "ws-me")
        XCTAssertEqual(actual.map(\.account), ["ws-team"])
    }

    func testFallsBackToTheEmailToDedupe() {
        let actual = CodexHomes.logins(candidates: ["/h/.codex-a"],
                                       accounts: ["/h/.codex-a": account(nil, "me@example.com")],
                                       defaultAccount: "me@example.com")
        XCTAssertEqual(actual, [])
    }

    // Not asked yet, signed out, or API-key auth: nothing to name a row by, and
    // no limits to put in it.
    func testSkipsAHomeWithNoAccountToNameIt() {
        let actual = CodexHomes.logins(candidates: ["/h/.codex-new", "/h/.codex-out", "/h/.codex-key"],
                                       accounts: ["/h/.codex-out": CodexAccount(),
                                                  "/h/.codex-key": CodexAccount(type: "apiKey")],
                                       defaultAccount: nil)
        XCTAssertEqual(actual, [])
    }

    // MARK: - Labels

    func testNamesAHomeByItsDir() {
        XCTAssertEqual(CodexHomes.label(path: "/h/.codex-work"), "work")
        XCTAssertEqual(CodexHomes.label(path: "/h/accounts/side"), "side")
        XCTAssertEqual(CodexHomes.label(path: "/h/clients/acme/.codex"), "acme")
        XCTAssertEqual(CodexHomes.label(path: "/h/.codex-"), ".codex-")
    }

    // MARK: - Running and remembered

    func testFindsTheCodexProcessesAndNothingElse() {
        let ps = """
          201 /Users/me/.local/bin/codex
          202 /opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js
          203 /Users/me/.local/bin/claude
          204 /usr/bin/vim codex.md
        """
        XCTAssertEqual(LoginDirs.pids(psOutput: ps, agent: "codex"), [201, 202])
    }

    func testRemembersARunningHomeUntilItsDeleted() throws {
        let home = try makeHome()
        let file = "\(home)/codex-homes"
        let work = try makeCodexHome("\(home)/anywhere/work")
        CodexHomes.remember([work], path: file)
        CodexHomes.remember([], path: file)
        XCTAssertEqual(CodexHomes.remembered(path: file), [work])

        try FileManager.default.removeItem(atPath: work)
        CodexHomes.remember([], path: file)
        XCTAssertEqual(CodexHomes.remembered(path: file), [])
    }

    // MARK: - Probing another home

    func testTheDefaultLoginInheritsTheEnvironmentUnchanged() {
        XCTAssertNil(CodexAppServer.environment(codexHome: nil, inherited: ["PATH": "/bin"]))
    }

    func testAnotherLoginRunsWithItsHomeAndKeepsTheRest() {
        let actual = CodexAppServer.environment(codexHome: "/h/.codex-work", inherited: ["PATH": "/bin", "HOME": "/h"])
        XCTAssertEqual(actual, ["PATH": "/bin", "HOME": "/h", "CODEX_HOME": "/h/.codex-work"])
    }

    // An extra login's refresh is a whole app-server started, so a reading
    // stands for the refresh interval; the default login's never does.
    func testAnExtraLoginRefreshesAtMostEveryFiveMinutes() {
        let now = Date()
        let reading = CodexQuotaProbe.Reading(measuredAt: now.addingTimeInterval(-120))
        XCTAssertFalse(CodexQuotaProbe.isDue(reading, now: now, minInterval: CodexHomes.refreshInterval))
        XCTAssertTrue(CodexQuotaProbe.isDue(reading, now: now.addingTimeInterval(200),
                                            minInterval: CodexHomes.refreshInterval))
        XCTAssertTrue(CodexQuotaProbe.isDue(nil, now: now, minInterval: CodexHomes.refreshInterval))
        XCTAssertTrue(CodexQuotaProbe.isDue(reading, now: now, minInterval: 0))
        XCTAssertEqual(CodexHomes.refreshInterval, 300)
    }

    // Another login's transcripts are under its own home, and parse as Codex's.
    func testReadsAnotherLoginsHistoryFromItsOwnHome() {
        let login = CodexLogin(codexHome: "/h/.codex-work", label: "work")
        XCTAssertEqual(UsageClient.codexLogin(login).historySource, .codexLogin(codexHome: "/h/.codex-work"))
        XCTAssertEqual(UsageHistoryStore.Source.codexLogin(codexHome: "/h/.codex-work").defaultRoot,
                       "/h/.codex-work/sessions")
        XCTAssertEqual("\(UsageHistoryStore.Source.codexLogin(codexHome: "/h").marker)",
                       "\(UsageHistoryStore.Source.codex.marker)")
    }

    func testAnExtraLoginIsTitledCodexAndTaggedByItsLabel() {
        let login = UsageClient.codexLogin(CodexLogin(codexHome: "/h/.codex-workspace-long", label: "workspace-long"))
        XCTAssertEqual(login.displayName, "Codex")
        XCTAssertEqual(login.widgetTag, "workspace-")
    }
}
