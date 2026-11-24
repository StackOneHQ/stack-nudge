import XCTest

@testable import StackNudgePanelCore

final class RecentSessionsTests: XCTestCase {

    private let modified = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testTheNewestSummaryNamesTheSession() {
        let head = [line(["type": "user", "cwd": "/repo/app", "message": ["content": "Fix the build"]])].joined(separator: "\n")
        let tail = [line(["type": "summary", "summary": "Old title"]),
                    line(["type": "ai-title", "aiTitle": "Fix flaky build on CI", "timestamp": "2027-01-01T10:00:00.000Z"])]
            .joined(separator: "\n")
        let session = RecentSessions.parse(id: "s1", head: head, tail: tail, modified: modified)
        XCTAssertEqual(session?.title, "Fix flaky build on CI")
        XCTAssertEqual(session?.project, "app")
    }

    func testWithoutASummaryTheFirstTypedPromptNamesIt() {
        let head = [line(["type": "user", "cwd": "/repo/app", "message": ["content": "<command-name>/clear</command-name>"]]),
                    line(["type": "user", "message": ["content": [["type": "text", "text": "Add   the\\ncompanion"]]]])]
            .joined(separator: "\n")
        XCTAssertEqual(RecentSessions.parse(id: "s1", head: head, tail: head, modified: modified)?.title, "Add the\\ncompanion")
    }

    func testATranscriptWithoutAFolderIsSkipped() {
        XCTAssertNil(RecentSessions.parse(id: "s1", head: line(["type": "user"]), tail: "", modified: modified))
    }

    func testLongTitlesAreClipped() {
        let head = line(["type": "user", "cwd": "/r", "message": ["content": String(repeating: "word ", count: 40)]])
        let title = RecentSessions.parse(id: "s1", head: head, tail: head, modified: modified)?.title ?? ""
        XCTAssertEqual(title.count, RecentSessions.titleLength)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // Running sessions, subagent transcripts and folders that are gone are
    // nothing to resume.
    func testLoadSkipsRunningSubagentAndMissingFolders() throws {
        let root = NSTemporaryDirectory() + "recent-\(UUID().uuidString)"
        let project = root + "/-repo"
        let existing = root + "/cwd"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func write(_ name: String, cwd: String) throws {
            try line(["type": "user", "cwd": cwd, "message": ["content": name]])
                .write(toFile: "\(project)/\(name).jsonl", atomically: true, encoding: .utf8)
        }
        let keep = "0a1b2c3d-0000-4000-8000-000000000001"
        let running = "0a1b2c3d-0000-4000-8000-000000000002"
        try write(keep, cwd: existing)
        try write(running, cwd: existing)
        try write("agent-sub", cwd: existing)
        try write("0a1b2c3d-0000-4000-8000-000000000004", cwd: root + "/deleted")
        let ids = RecentSessions.load(root: root, excluding: [running]).map(\.id)
        XCTAssertEqual(ids, [keep])
    }

    // The id is typed into a shell, so a transcript named anything but the
    // UUID Claude Code writes is not offered.
    func testLoadSkipsATranscriptNotNamedLikeASession() throws {
        let root = NSTemporaryDirectory() + "recent-\(UUID().uuidString)"
        let project = root + "/-repo"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try line(["type": "user", "cwd": root, "message": ["content": "x"]])
            .write(toFile: "\(project)/x$(touch pwned).jsonl", atomically: true, encoding: .utf8)
        XCTAssertEqual(RecentSessions.load(root: root).map(\.id), [])
    }
}

final class SessionLauncherTests: XCTestCase {

    // A folder name with a quote must not break out of the cd.
    func testShellQuoting() {
        XCTAssertEqual(SessionLauncher.shellQuoted("/a/b c"), "'/a/b c'")
        XCTAssertEqual(SessionLauncher.shellQuoted("it's"), "'it'\\''s'")
    }

    // Terminal and iTerm get `cd '<folder>'` typed into the login shell. A
    // quote, a backslash or a control character could end the quoting early
    // in some shells (fish reads \' inside single quotes as an escape), so
    // such a folder is refused there. Ghostty takes the folder as a property.
    func testAFolderThatCantBeTypedSafelyIsRefused() {
        for folder in ["/r/it's", "/r/back\\slash", "/r/new\nline", "/r/bell\u{07}"] {
            XCTAssertNil(SessionLauncher.osascriptArguments(cwd: folder, command: "claude", in: .terminal), folder)
            XCTAssertNil(SessionLauncher.osascriptArguments(cwd: folder, command: "claude", in: .iterm), folder)
            XCTAssertNotNil(SessionLauncher.osascriptArguments(cwd: folder, command: "claude", in: .ghostty), folder)
        }
    }

    // The folder and command reach osascript as arguments after `--`, never
    // spliced into the script's source.
    func testTheFolderAndCommandAreArgumentsNotScript() {
        let folder = "/r/a \"b\" $(c)"
        let terminal = SessionLauncher.osascriptArguments(cwd: folder, command: "claude", in: .terminal)
        XCTAssertEqual(terminal, ["-e", SessionLauncher.terminalScript, "--", "cd '/r/a \"b\" $(c)' && claude"])
        let ghostty = SessionLauncher.osascriptArguments(cwd: folder, command: "claude", in: .ghostty)
        XCTAssertEqual(ghostty, ["-e", SessionLauncher.ghosttyScript, "--", folder, "claude"])
        for script in [SessionLauncher.terminalScript, SessionLauncher.itermScript, SessionLauncher.ghosttyScript] {
            XCTAssertFalse(script.contains(folder))
        }
    }

    func testResumeCommandQuotesTheID() {
        let session = RecentSession(id: "abc-123", cwd: "/r", title: "t", date: Date())
        XCTAssertEqual(SessionLauncher.resumeCommand(session), "claude --resume 'abc-123'")
    }

    func testReposAreGitCheckoutsOnly() throws {
        let root = NSTemporaryDirectory() + "repos-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for dir in ["b-repo/.git", "a-repo/.git", "notes", ".hidden/.git"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        XCTAssertEqual(SessionLauncher.repos(in: root), ["a-repo", "b-repo"])
    }

    func testAConfiguredTerminalWins() {
        XCTAssertEqual(SessionLauncher.terminal(configured: "iTerm"), .iterm)
        XCTAssertEqual(SessionLauncher.terminal(configured: "terminal"), .terminal)
    }
}
