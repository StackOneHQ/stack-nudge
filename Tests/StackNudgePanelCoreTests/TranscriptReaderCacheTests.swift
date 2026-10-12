import XCTest

@testable import StackNudgePanelCore

// TranscriptReader.read memoises on (size, mtime) because the refresh poll
// re-reads every active session's transcript on a cadence while a transcript
// only changes when its agent writes a turn. Two properties matter and are
// easy to break in opposite directions: an unchanged file must not be re-read,
// and a changed one must not serve a stale answer.
final class TranscriptReaderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TranscriptReader.resetCache()
    }

    override func tearDown() {
        TranscriptReader.resetCache()
        super.tearDown()
    }

    private func assistant(tokens: Int, model: String = "claude-opus-5") -> String {
        """
        {"type":"assistant","message":{"model":"\(model)","usage":{"input_tokens":\(tokens),\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func write(_ lines: [String]) -> String {
        let dir = NSTemporaryDirectory() + "transcript-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "session.jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func rewrite(_ path: String, _ lines: [String]) {
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // A whole-second instant, stamped on the file both before the first read
    // and after the rewrite. Restoring a captured mtime does not work: the
    // filesystem keeps sub-second precision that setAttributes truncates, so
    // the "restored" mtime differs from the original and the fingerprint
    // misses. Stamping the same exact value twice is what makes them equal.
    private let frozenMtime = Date(timeIntervalSince1970: 1_700_000_000)

    private func freezeMtime(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: frozenMtime],
                                               ofItemAtPath: path)
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                       frozenMtime, "mtime did not round-trip; the test cannot hold the fingerprint still")
    }

    // Replace the file's contents while holding (size, mtime) exactly where
    // they were — padding to the original byte length, then re-freezing the
    // mtime. The fingerprint is then identical and the content is not, so the
    // only thing that can tell the two apart is the memoisation. Deleting the
    // file would not do: an unstattable path deliberately falls through to the
    // parse rather than serve a hit, so a nil there proves nothing.
    private func rewritePreservingFingerprint(_ path: String, _ line: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0

        // Trailing whitespace before the newline is legal JSON and is carried
        // through to the parser verbatim, so it pads without changing meaning.
        var body = line
        XCTAssertLessThanOrEqual(body.utf8.count + 1, size, "cannot pad up to \(size) bytes")
        while body.utf8.count + 1 < size { body += " " }
        try? (body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        freezeMtime(path)

        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size)
    }

    // The tail scan must look past trailing non-assistant lines — a transcript
    // almost always ends on a user or tool entry, so a reader that only
    // inspected the final line would report nothing.
    func testSkipsTrailingNonAssistantLines() {
        let path = write([assistant(tokens: 77),
                          #"{"type":"user","message":{"role":"user"}}"#,
                          #"{"type":"system","subtype":"hook"}"#])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 77)
    }

    // An unchanged file serves the memoised answer rather than re-reading.
    // Proven by swapping the content underneath a frozen fingerprint: a reader
    // that went to disk would return the new number, so the old number can
    // only have come from the cache.
    func testUnchangedFileIsNotReRead() {
        let path = write([assistant(tokens: 410)])
        freezeMtime(path)
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 410)

        rewritePreservingFingerprint(path, assistant(tokens: 999))
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 410,
                       "same size and mtime must serve the cached answer, not re-read")
    }

    // The other direction, and the one that would ship wrong numbers silently:
    // a transcript that grew must be re-read. Size alone catches this even when
    // mtime granularity would not.
    func testChangedFileIsReRead() {
        let path = write([assistant(tokens: 100)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 100)

        rewrite(path, [assistant(tokens: 100), assistant(tokens: 900)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 900)
    }

    // A same-size rewrite is the case size cannot catch, so mtime has to. The
    // sleep is the point rather than incidental: it puts the two writes in
    // different mtime ticks, which is what the fingerprint relies on.
    func testSameSizeRewriteIsReReadOnMtime() {
        let path = write([assistant(tokens: 111)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 111)

        Thread.sleep(forTimeInterval: 1.1)
        rewrite(path, [assistant(tokens: 222)])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 222)
    }

    // A nil is memoised too — a transcript with no assistant turn yet is the
    // one most likely to be polled repeatedly to no effect. Same proof: a real
    // re-read under a frozen fingerprint would find the assistant line.
    func testNilResultIsMemoised() {
        let path = write([#"{"type":"user","note":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#])
        freezeMtime(path)
        XCTAssertNil(TranscriptReader.read(path: path))

        rewritePreservingFingerprint(path, assistant(tokens: 500))
        XCTAssertNil(TranscriptReader.read(path: path),
                     "an unchanged fingerprint must keep serving the memoised nil")
    }

    // An unstattable path must not serve another path's answer, and must not
    // crash. It falls through to the parse, which fails the same way.
    func testMissingFileReturnsNil() {
        XCTAssertNil(TranscriptReader.read(path: "/nonexistent/\(UUID().uuidString).jsonl"))
    }
}
