import XCTest

@testable import StackNudgePanelCore

// PiTranscriptReader parses @earendil-works/pi-coding-agent session JSONL into
// the same TranscriptStats the Claude/Codex readers produce. The schema is
// pinned against pi's own session format: the assistant turn is wrapped in a
// `type == "message"` entry with the model turn under `.message`, usage keys are
// camelCase, and `input` does NOT already include the cached portion (so
// occupancy is input + cacheRead + cacheWrite, never a subtraction). locate()
// binds a running pi process to its transcript by matching the cwd stamped in
// the session header, which is what gives pi sessions stats with no hook event.
final class PiTranscriptReaderTests: XCTestCase {

    private func writeSession(_ lines: [String],
                              dirName: String = "--Users-x-project--",
                              name: String = "2026-09-01T00-00-00-000Z_session.jsonl",
                              root: String) -> String {
        let dir = "\(root)/\(dirName)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name)"
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func header(cwd: String, id: String = "01a05d37-018f-7429-b85d-7d6580040df0") -> String {
        #"{"type":"session","version":1,"id":"\#(id)","timestamp":"2026-09-01T13:44:41.103Z","cwd":"\#(cwd)"}"#
    }

    private func assistantLine(input: Int, cacheRead: Int, cacheWrite: Int,
                               output: Int = 27, reasoning: Int = 0,
                               model: String = "qwen3.8:27b") -> String {
        let total = input + output + cacheRead + cacheWrite + reasoning
        return #"{"type":"message","id":"m1","parentId":"p1","timestamp":"2026-09-01T13:52:20.252Z","message":{"role":"assistant","model":"\#(model)","usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"reasoning":\#(reasoning),"totalTokens":\#(total)},"stopReason":"stop"}}"#
    }

    func test_read_sumsInputAndCacheTokens_excludingOutputAndReasoning() {
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let path = writeSession([
            header(cwd: "/Users/x/project"),
            #"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"hey"}]}}"#,
            assistantLine(input: 55_000, cacheRead: 3_000, cacheWrite: 2_000, output: 400, reasoning: 900),
        ], root: root)

        let actual = PiTranscriptReader.read(path: path)

        XCTAssertEqual(actual?.tokens, 60_000)  // 55000 + 3000 + 2000; output/reasoning excluded
        XCTAssertEqual(actual?.model, "qwen3.8:27b")
    }

    func test_read_usesLatestAssistantMessage() {
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let path = writeSession([
            header(cwd: "/Users/x/project"),
            assistantLine(input: 30_000, cacheRead: 0, cacheWrite: 0),
            assistantLine(input: 90_000, cacheRead: 0, cacheWrite: 0),
        ], root: root)

        XCTAssertEqual(PiTranscriptReader.read(path: path)?.tokens, 90_000)
    }

    func test_read_returnsNilWhenNoAssistantUsage() {
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let path = writeSession([
            header(cwd: "/Users/x/project"),
            #"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"model_change","id":"c1","provider":"ollama","modelId":"qwen3.8:27b"}"#,
        ], root: root)

        XCTAssertNil(PiTranscriptReader.read(path: path))
    }

    func test_read_returnsNilForMissingFile() {
        XCTAssertNil(PiTranscriptReader.read(path: "/nonexistent/pi/session.jsonl"))
    }

    func test_dispatch_routesPiPathToPiReader() {
        // A pi-shaped assistant line under a /.pi/agent/sessions/ path. If the
        // dispatcher fell through to the Claude reader it would find no
        // top-level type=="assistant" and return nil; the pi reader parses the
        // wrapped message and returns tokens. A non-nil result proves routing.
        let root = NSTemporaryDirectory() + "some/.pi/agent/sessions"
        let path = writeSession([
            header(cwd: "/Users/x/project"),
            assistantLine(input: 10, cacheRead: 0, cacheWrite: 0),
        ], root: root)

        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 10)
    }

    func test_locate_matchesByHeaderCwd_newestWins() {
        let root = NSTemporaryDirectory() + "pi-locate-\(UUID().uuidString)"
        let target = "/Users/x/stackone"

        // A session for a different cwd — must be ignored despite being present.
        _ = writeSession([header(cwd: "/Users/x/other"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                         dirName: "--Users-x-other--", root: root)

        // Two sessions for the target cwd, in different dirs; the newer file wins.
        let older = writeSession([header(cwd: target, id: "old"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                                 dirName: "--Users-x-stackone--", name: "old.jsonl", root: root)
        let newer = writeSession([header(cwd: target, id: "new"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                                 dirName: "--Users-x-stackone-branch--", name: "new.jsonl", root: root)
        // Force a deterministic mtime ordering (newer strictly after older).
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: older)
        try? FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: newer)

        let ref = PiTranscriptReader.locate(cwd: target, root: root)

        XCTAssertEqual(ref?.sessionID, "new")
        XCTAssertEqual(ref?.path, newer)
    }

    func test_locate_nilWhenNoCwdMatch() {
        let root = NSTemporaryDirectory() + "pi-locate-\(UUID().uuidString)"
        _ = writeSession([header(cwd: "/Users/x/other"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                         dirName: "--Users-x-other--", root: root)

        XCTAssertNil(PiTranscriptReader.locate(cwd: "/Users/x/absent", root: root))
    }
}
