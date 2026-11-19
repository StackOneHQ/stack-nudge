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

    func testFindsEverySignedInClaudeDashDirInNameOrder() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-work", account: "work")
        try makeDir("\(home)/.claude-org-publisher", account: "org")
        let actual = ClaudeConfigDirs.discover(home: home, setting: nil, defaultAccount: "me")
        XCTAssertEqual(actual, [
            .init(path: "\(home)/.claude-org-publisher", account: "org"),
            .init(path: "\(home)/.claude-work", account: "work"),
        ])
    }

    func testSkipsADirWithNoLogin() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-empty", account: nil)
        try FileManager.default.createDirectory(atPath: "\(home)/.claude-nofile",
                                                withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeConfigDirs.discover(home: home, setting: nil, defaultAccount: nil), [])
    }

    // ~/.claude.json.backup.* and friends sit beside the dirs; only dirs count.
    func testIgnoresFilesThatShareThePrefix() throws {
        let home = try makeHome()
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(home)/.claude-notes.json"))
        XCTAssertEqual(ClaudeConfigDirs.candidates(home: home, setting: nil), [])
    }

    // The default login is probed already; a second dir signed in to the same
    // account would only repeat its numbers. Two dirs on one account likewise.
    func testSkipsADirSignedInToAnAccountAlreadyCounted() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-a", account: "me")
        try makeDir("\(home)/.claude-b", account: "other")
        try makeDir("\(home)/.claude-c", account: "other")
        let actual = ClaudeConfigDirs.discover(home: home, setting: nil, defaultAccount: "me")
        XCTAssertEqual(actual.map(\.path), ["\(home)/.claude-b"])
    }

    // The case that started this: your own plan by default and a team seat in
    // another dir, both signed in as you.
    func testKeepsTheSameAccountSignedInToAnotherOrganization() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude-team", account: "me", organization: "team")
        let actual = ClaudeConfigDirs.discover(home: home, setting: nil, defaultAccount: "me/personal")
        XCTAssertEqual(actual, [.init(path: "\(home)/.claude-team", account: "me/team")])
    }

    func testReadsTheSettingFirstAndOnlyOnce() throws {
        let home = try makeHome()
        let elsewhere = try makeDir("\(home)/accounts/work", account: "work")
        try makeDir("\(home)/.claude-x", account: "x")
        let actual = ClaudeConfigDirs.discover(
            home: home, setting: "~/accounts/work, ~/.claude-x", defaultAccount: nil)
        XCTAssertEqual(actual.map(\.path), [elsewhere, "\(home)/.claude-x"])
    }

    func testNeverProbesTheDefaultDirAsAnotherLogin() throws {
        let home = try makeHome()
        try makeDir("\(home)/.claude", account: "inside")
        XCTAssertEqual(ClaudeConfigDirs.discover(home: home, setting: "~/.claude",
                                                 defaultAccount: nil), [])
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
