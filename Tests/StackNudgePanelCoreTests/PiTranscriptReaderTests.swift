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

    // Mirrors the extension's sessionIdFromFile: the uuid is everything after the
    // first "_" in "<timestamp>_<uuid>.jsonl". The panel correlates events to
    // sessions across these two independent derivations (extension → filename,
    // reader → header `id`), so they must agree on a real filename.
    private func filenameDerivedSessionID(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        guard let underscore = stem.firstIndex(of: "_") else { return stem }
        return String(stem[stem.index(after: underscore)...])
    }

    func test_locate_headerSessionIDMatchesFilenameDerivation() {
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let uuid = "01a06c64-752f-7944-8c47-aebcfcb1cc24"
        let filename = "2026-09-04T12-28-38-063Z_\(uuid).jsonl"
        _ = writeSession([header(cwd: "/Users/x/proj", id: uuid),
                          assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                         dirName: "--Users-x-proj--", name: filename, root: root)

        let ref = PiTranscriptReader.locate(cwd: "/Users/x/proj", root: root)

        XCTAssertEqual(ref?.sessionID, uuid)                                   // reader reads the header id
        XCTAssertEqual(ref?.sessionID, filenameDerivedSessionID(filename))     // == extension's derivation
    }

    func test_locate_headerParsesWhenAMultibyteCharStraddles64KB() {
        // Regression: sessionHeader used to decode the whole 64KB prefix as UTF-8,
        // so a multi-byte char landing on byte 65536 returned nil and left the
        // session permanently unbound — even though line 1 is intact. Place a
        // 3-byte "€" so its first byte is the last byte of the 65536-byte read.
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let headerLine = header(cwd: "/Users/x/proj", id: "straddle") + "\n"
        let padCount = 65535 - headerLine.utf8.count
        let secondLine = String(repeating: "a", count: padCount) + "€ trailing content"
        let dir = "\(root)/--Users-x-proj--"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (headerLine + secondLine + "\n")
            .write(toFile: "\(dir)/2026-09-01T00-00-00-000Z_straddle.jsonl", atomically: true, encoding: .utf8)

        XCTAssertEqual(PiTranscriptReader.locate(cwd: "/Users/x/proj", root: root)?.sessionID, "straddle")
    }

    func test_locate_warmCachePicksUpASessionThatMovedToANewDir() {
        // Regression for the cache: it used to pin to the matched dir and never
        // reconsider, so a newer session for the same cwd in a NEW dir (e.g. a pi
        // upgrade changing the folder wrap) was missed until restart. A new subdir
        // bumps root's mtime, which must invalidate the fast path.
        let root = NSTemporaryDirectory() + "pi-\(UUID().uuidString)"
        let target = "/Users/x/proj"

        let older = writeSession([header(cwd: target, id: "old"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                                 dirName: "--Users-x-proj--", name: "2026-09-01T00-00-00-000Z_old.jsonl", root: root)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older)
        // Pin root old so creating the new subdir below is unambiguously newer.
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: root)

        XCTAssertEqual(PiTranscriptReader.locate(cwd: target, root: root)?.sessionID, "old")  // cold: caches dir + rootMtime

        // Same cwd, a NEW dir — creating the subdir bumps root's mtime to now.
        let newer = writeSession([header(cwd: target, id: "new"), assistantLine(input: 5, cacheRead: 0, cacheWrite: 0)],
                                 dirName: "--Users-x-proj-v2--", name: "2026-09-02T00-00-00-000Z_new.jsonl", root: root)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer)

        XCTAssertEqual(PiTranscriptReader.locate(cwd: target, root: root)?.sessionID, "new")  // warm: root mtime moved → rescan
    }
}
