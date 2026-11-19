import XCTest

@testable import StackNudgePanelCore

// Which other Claude logins get probed. A dir missed here is an account whose
// usage nothing ever refreshes; a dir wrongly included is a `claude` spawned
// for nothing on every poll, or the default account counted twice.
final class ClaudeConfigDirsTests: XCTestCase {

    private func makeHome() throws -> String {
        let home = NSTemporaryDirectory() + "claude-config-dirs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        return (home as NSString).resolvingSymlinksInPath
    }

    @discardableResult
    private func makeDir(_ path: String, account: String?, organization: String? = nil) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let org = organization.map { #","organizationUuid":"\#($0)""# } ?? ""
        let login = account.map { #","oauthAccount":{"accountUuid":"\#($0)"\#(org)}"# } ?? ""
        try Data(#"{"numStartups":1\#(login)}"#.utf8)
            .write(to: URL(fileURLWithPath: "\(path)/.claude.json"))
        return path
    }

    private func discover(_ home: String, setting: String? = nil,
                          defaultAccount: String?) -> [ClaudeConfigDirs.Dir] {
        ClaudeConfigDirs.discover(home: home, setting: setting,
                                  found: ClaudeConfigDirs.scan(home: home),
                                  defaultAccount: defaultAccount)
    }

    // Named however anyone likes: the .claude.json is what marks one.
    func testFindsEverySignedInDirWhateverItIsCalled() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-org-publisher", account: "org")
        try makeDir("\(home)/work-claude", account: "work")
        try makeDir("\(home)/accounts/side", account: "side")
        let actual = discover(home, defaultAccount: "me")
        XCTAssertEqual(actual, [
            .init(path: "\(home)/.claude-org-publisher", account: "org"),
            .init(path: "\(home)/accounts/side", account: "side"),
            .init(path: "\(home)/work-claude", account: "work"),
        ])
    }

    func testScansTwoLevelsDownAndNoFurther() throws {
        let home = try makeHome()
        try makeDir("\(home)/a/b/c", account: "deep")
        XCTAssertEqual(ClaudeConfigDirs.scan(home: home), [])
    }

    // Looking inside Documents and friends raises a macOS permission prompt.
    func testNeverLooksInsideTheFoldersMacOSGuards() throws {
        let home = try makeHome()
        try makeDir("\(home)/Documents/claude", account: "docs")
        try makeDir("\(home)/Library/claude", account: "lib")
        try makeDir("\(home)/code/node_modules", account: "pkg")
        XCTAssertEqual(ClaudeConfigDirs.scan(home: home), [])
    }

    func testSkipsADirWithNoLogin() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-empty", account: nil)
        try FileManager.default.createDirectory(atPath: "\(home)/.claude-nofile",
                                                withIntermediateDirectories: true)
        XCTAssertEqual(discover(home, defaultAccount: nil), [])
    }

    // The default login is probed already; a second dir signed in to the same
    // account would only repeat its numbers. Two dirs on one account likewise.
    func testSkipsADirSignedInToAnAccountAlreadyCounted() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-a", account: "me")
        try makeDir("\(home)/.claude-b", account: "other")
        try makeDir("\(home)/.claude-c", account: "other")
        XCTAssertEqual(discover(home, defaultAccount: "me").map(\.path), ["\(home)/.claude-b"])
    }

    // The case that started this: your own plan by default and a team seat in
    // another dir, both signed in as you.
    func testKeepsTheSameAccountSignedInToAnotherOrganization() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-team", account: "me", organization: "team")
        let actual = discover(home, defaultAccount: "me/personal")
        XCTAssertEqual(actual, [.init(path: "\(home)/.claude-team", account: "me/team")])
    }

    func testReadsTheSettingFirstAndOnlyOnce() throws {
        let home = try makeHome()
        let elsewhere = try makeDir("\(home)/Documents/work", account: "work")
        try makeDir("\(home)/.claude-x", account: "x")
        let actual = discover(home, setting: "~/Documents/work, ~/.claude-x", defaultAccount: nil)
        XCTAssertEqual(actual.map(\.path), [elsewhere, "\(home)/.claude-x"])
    }

    // Home holds the default login's .claude.json, and ~/.claude is its dir.
    func testNeverProbesTheDefaultLoginAsAnotherOne() throws {
        let home = try makeHome()
        try makeDir(home, account: "me")
        try makeDir("\(home)/.claude", account: "inside")
        XCTAssertEqual(ClaudeConfigDirs.discover(home: home, setting: "~, ~/.claude",
                                                 found: [home, "\(home)/.claude"],
                                                 defaultAccount: nil), [])
    }

    // MARK: - Running and remembered

    func testFindsTheClaudeProcessesAndNothingElse() {
        let ps = """
          101 /Users/me/.local/bin/claude --resume abc
          102 claude
          103 /usr/bin/vim notes.md
          104 /Users/me/.local/bin/claude daemon run
          105 /bin/zsh -c claude-ish
        """
        XCTAssertEqual(ClaudeConfigDirs.claudePids(psOutput: ps), [101, 102])
    }

    // The point of remembering: a dir found only because a session was using it
    // keeps its row after the session ends.
    func testRemembersARunningDirUntilItsDeleted() throws {
        let home = try makeHome()
        let file = "\(home)/remembered"
        let work = try makeDir("\(home)/anywhere/work", account: "work")
        ClaudeConfigDirs.remember([work], path: file)
        ClaudeConfigDirs.remember([], path: file)
        XCTAssertEqual(ClaudeConfigDirs.remembered(path: file), [work])

        try FileManager.default.removeItem(atPath: work)
        ClaudeConfigDirs.remember([], path: file)
        XCTAssertEqual(ClaudeConfigDirs.remembered(path: file), [])
    }

    func testExpandsTildeAndDropsRelativeEntries() {
        XCTAssertEqual(ClaudeConfigDirs.entries(" ~/.claude-work ,relative, /abs/dir,,~", home: "/h"),
                       ["/h/.claude-work", "/abs/dir", "/h"])
        XCTAssertEqual(ClaudeConfigDirs.entries(nil, home: "/h"), [])
    }

    // MARK: - Probing another dir

    func testTheDefaultLoginInheritsTheEnvironmentUnchanged() {
        XCTAssertNil(ClaudeCliQuotaProbe.environment(configDir: nil, inherited: ["PATH": "/bin"]))
    }

    func testAnotherLoginRunsWithItsConfigDirAndKeepsTheRest() {
        let actual = ClaudeCliQuotaProbe.environment(configDir: "/h/.claude-work",
                                                     inherited: ["PATH": "/bin", "HOME": "/h"])
        XCTAssertEqual(actual, ["PATH": "/bin", "HOME": "/h", "CLAUDE_CONFIG_DIR": "/h/.claude-work"])
    }

    func testReadsAnotherLoginsUsageFromItsOwnDir() {
        XCTAssertEqual(ClaudeUsageCache.path(configDir: "/h/.claude-work"), "/h/.claude-work/.claude.json")
        XCTAssertEqual(ClaudeUsageCache.path(configDir: nil), ClaudeUsageCache.path)
    }

    // The probe's own rollout goes to the projects dir of the login it ran as,
    // so the scrub has to look there or every extra-account probe leaves a file.
    func testScrubsAnotherLoginsRolloutFromItsOwnProjectsDir() throws {
        let home = try makeHome()
        let configDir = "\(home)/.claude-work"
        let dir = ClaudeCliQuotaProbe.probeSessionsDir(configDir: configDir)
        XCTAssertTrue(dir.hasPrefix("\(configDir)/projects/"))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let session = "0f0e5c7a-1111-2222-3333-444455556666"
        let file = "\(dir)/\(session).jsonl"
        try Data().write(to: URL(fileURLWithPath: file))

        ClaudeCliQuotaProbe.removeSessionFile(session, configDir: configDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }
}
