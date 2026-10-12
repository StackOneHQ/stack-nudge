import XCTest

@testable import StackNudgePanelCore

// TranscriptTail walks a JSONL file backwards so the readers can find the
// newest usage-bearing line without loading the file. The whole point is that
// it is correct at the boundaries the old whole-file read never had to think
// about: a line straddling a chunk edge, a multi-byte character straddling
// one, a missing trailing newline, and a line longer than the window. Each of
// those silently returns the wrong stats (or none) if it regresses, and none
// of them is visible in normal use, so they are pinned here.
final class TranscriptTailTests: XCTestCase {

    private func write(_ contents: String, name: String = "t.jsonl") -> String {
        let dir = NSTemporaryDirectory() + "tail-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + name
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // Collect every line the scan yields, newest first.
    private func allLines(_ path: String, chunkSize: Int = TranscriptTail.defaultChunkSize,
                          maxBytes: Int = TranscriptTail.defaultMaxBytes) -> [String] {
        var out: [String] = []
        TranscriptTail.scanLinesBackwards(path: path, chunkSize: chunkSize, maxBytes: maxBytes) { line in
            out.append(String(data: line, encoding: .utf8) ?? "<non-utf8>")
            return false
        }
        return out
    }

    func testYieldsLinesNewestFirst() {
        let path = write("a\nb\nc\n")
        XCTAssertEqual(allLines(path), ["c", "b", "a"])
    }

    func testStopsAsSoonAsTheBodyReturnsTrue() {
        let path = write("a\nb\nc\n")
        var seen: [String] = []
        TranscriptTail.scanLinesBackwards(path: path) { line in
            seen.append(String(data: line, encoding: .utf8)!)
            return seen.count == 2
        }
        XCTAssertEqual(seen, ["c", "b"])
    }

    // The last line of a file with no trailing newline is still a whole line.
    // An agent killed mid-write leaves exactly this, and dropping it would mean
    // reporting the turn before last.
    func testReadsAFinalLineWithNoTrailingNewline() {
        let path = write("a\nb\nc")
        XCTAssertEqual(allLines(path), ["c", "b", "a"])
    }

    // Every line boundary falls inside a chunk for some chunk size, so walk a
    // range of sizes over the same file: any off-by-one in the carry handling
    // shows up as a dropped, duplicated or spliced line at one of them.
    func testReassemblesLinesAcrossEveryChunkBoundary() {
        let expected = (1...40).map { "line-\($0)-\(String(repeating: "x", count: $0))" }
        let path = write(expected.joined(separator: "\n") + "\n")
        for chunkSize in 1...64 {
            XCTAssertEqual(allLines(path, chunkSize: chunkSize), expected.reversed(),
                           "chunkSize \(chunkSize) reassembled the file wrongly")
        }
    }

    // Splitting on the 0x0A byte cannot cut a multi-byte character, because a
    // UTF-8 continuation byte is always 0x80–0xBF. This is the trap that
    // decoding each chunk to a String first would fall into: the character
    // straddling the cut decodes to nil and takes its whole line with it.
    func testPreservesMultiByteCharactersStraddlingAChunkBoundary() {
        let expected = ["héllo-ü", "日本語のテキスト", "emoji-🏇-rider"]
        let path = write(expected.joined(separator: "\n") + "\n")
        for chunkSize in 1...48 {
            XCTAssertEqual(allLines(path, chunkSize: chunkSize), expected.reversed(),
                           "chunkSize \(chunkSize) mangled a multi-byte character")
        }
    }

    // A single line longer than one chunk must still be assembled whole rather
    // than emitted in pieces — a fragment would parse as nothing, or worse, as
    // valid JSON with the wrong numbers in it.
    func testAssemblesALineLongerThanTheChunk() {
        let long = String(repeating: "z", count: 5000)
        let path = write("first\n\(long)\nlast\n")
        XCTAssertEqual(allLines(path, chunkSize: 64), ["last", long, "first"])
    }

    func testEmptyAndMissingFilesYieldNothing() {
        XCTAssertEqual(allLines(write("")), [])
        XCTAssertEqual(allLines("/nonexistent/\(UUID().uuidString).jsonl"), [])
    }

    // Blank lines are skipped, matching the omittingEmptySubsequences the
    // whole-file split used, so a transcript with a stray blank line reads the
    // same as one without.
    func testSkipsBlankLines() {
        let path = write("a\n\n\nb\n")
        XCTAssertEqual(allLines(path), ["b", "a"])
    }

    // The budget bounds the work, and a line is only emitted once its leading
    // newline has been read — so the cap withholds the line it stopped inside
    // rather than emitting a fragment. Here the three lines occupy bytes
    // 0–10, 11–21 and 22–32: a 22-byte budget reaches byte 11, which is one
    // short of the newline at byte 10 that would prove the "b" line whole, so
    // the "b" line is held back. One more byte of budget releases it.
    //
    // Handing a truncated line to a JSON parser is the failure this guards:
    // at best it fails, at worst it parses into an object with the wrong
    // numbers in it.
    func testBudgetWithholdsTheLineItStoppedInside() {
        let path = write("aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n")
        XCTAssertEqual(allLines(path, chunkSize: 4, maxBytes: 22), ["cccccccccc"])
        XCTAssertEqual(allLines(path, chunkSize: 4, maxBytes: 23), ["cccccccccc", "bbbbbbbbbb"])
    }

    // A FIFO with no writer blocks in open(2) forever. Reachable because
    // PiTranscriptReader.locate picks transcript paths out of a sessions
    // directory by mtime, and serious because every transcript read shares one
    // serial queue — one such open would wedge stats for every session, with
    // nothing to time it out.
    //
    // The scan runs on another thread and the test waits with a timeout, so a
    // regression FAILS rather than hangs. Measuring elapsed time around a
    // synchronous call cannot do that: if the open blocks, the assertion after
    // it is never reached and the whole suite stops — which is what the first
    // version of this test did, while its comment claimed otherwise.
    func testAFifoIsRefusedRatherThanBlockingOnTheOpen() {
        let dir = NSTemporaryDirectory() + "tail-fifo-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fifo = dir + "pipe.jsonl"
        XCTAssertEqual(mkfifo(fifo, 0o644), 0, "could not create the fifo")

        let done = DispatchSemaphore(value: 0)
        let yielded = Counter()
        var clean: Bool?
        DispatchQueue.global(qos: .userInitiated).async {
            clean = TranscriptTail.scanLinesBackwards(path: fifo) { _ in
                yielded.bump()
                return false
            }
            done.signal()
        }

        // A blocked open never signals, so this is the regression's verdict.
        // The thread is left parked on open(2) in that case — unavoidable, and
        // acceptable in a test process that is about to fail anyway.
        guard done.wait(timeout: .now() + 5) == .success else {
            return XCTFail("the open blocked; O_NONBLOCK or the S_ISREG check is gone")
        }

        XCTAssertEqual(clean, false,
                       "a fifo is not a transcript and must not read as a clean empty one")
        XCTAssertEqual(yielded.value, 0)
    }

    // Minimal thread-safe counter, so the scan's callback does not mutate a
    // captured var from another thread.
    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // The same door rejects the other non-regular paths rather than treating
    // them as transcripts. /dev/null used to read as a clean empty file, which
    // was harmless but meant a nil got memoised against it.
    func testNonRegularPathsAreRefused() {
        let dir = NSTemporaryDirectory() + "tail-nonreg-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertFalse(TranscriptTail.scanLinesBackwards(path: dir) { _ in true },
                       "a directory is not a transcript")
        XCTAssertFalse(TranscriptTail.scanLinesBackwards(path: "/dev/null") { _ in true },
                       "a character device is not a transcript")
    }

    func testRejectsNonPositiveBounds() {
        let path = write("a\nb\n")
        XCTAssertEqual(allLines(path, chunkSize: 0), [])
        XCTAssertEqual(allLines(path, maxBytes: 0), [])
    }
}
