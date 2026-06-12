import XCTest

@testable import StackNudgePanelCore

// Real-shape coverage for the Claude transcript reader and, more importantly,
// the parse → ContextTokens.fold pipeline the handoff capture runs on every
// Stop. The Codex reader has its own fixtures (CodexTranscriptReaderTests);
// here we pin the Claude usage-block shape and prove that a transcript whose
// occupancy rises, compacts, then rises again accumulates its real effort
// rather than collapsing to the post-compaction reading.
final class TranscriptReaderTests: XCTestCase {

    private func writeTranscript(_ lines: [String], name: String = "session.jsonl") -> String {
        let dir = NSTemporaryDirectory() + "claude-transcript-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + name
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // A real Claude Code assistant entry whose usage block sums to `occupancy`
    // (input + cache_creation + cache_read), matching what readClaude reads.
    private func claudeLine(_ occupancy: Int, model: String = "claude-opus-4-8") -> String {
        #"{"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":\#(occupancy - 5000),"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000}}}"#
    }

    func test_read_claudeUsage_sumsInputAndCacheTokens() {
        let path = writeTranscript([
            #"{"type":"user","message":{"role":"user"}}"#,
            claudeLine(60_000),
        ])
        let actual = TranscriptReader.read(path: path)
        XCTAssertEqual(actual?.tokens, 60_000)  // 55000 + 2000 + 3000
        XCTAssertEqual(actual?.model, "claude-opus-4-8")
    }

    func test_read_usesLatestAssistantUsage() {
        // Occupancy climbs across turns; the reader reports the newest.
        let path = writeTranscript([
            claudeLine(40_000),
            claudeLine(90_000),
            claudeLine(150_000),
        ])
        XCTAssertEqual(TranscriptReader.read(path: path)?.tokens, 150_000)
    }

    func test_read_returnsNilWhenNoAssistantUsage() {
        let path = writeTranscript([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"system","subtype":"init"}"#,
        ])
        XCTAssertNil(TranscriptReader.read(path: path))
    }

    func test_foldOverRealReadings_accumulatesAcrossCompaction() {
        // Drive the real capture pipeline: at each Stop the transcript has grown
        // (or been compacted), readClaude returns the latest occupancy, and fold
        // banks it. Occupancy goes 50K → 150K → [compaction] 40K → 120K.
        // Effort = 150K peak + (120K − 40K) new-cycle growth = 230K, not the
        // 120K a latest-reading-wins capture would record.
        let occupancyAtEachStop = [50_000, 150_000, 40_000, 120_000]
        var lines: [String] = []
        var state: (total: Int, lastReading: Int)?

        for occupancy in occupancyAtEachStop {
            lines.append(claudeLine(occupancy))
            let path = writeTranscript(lines)
            guard let stats = TranscriptReader.read(path: path) else {
                return XCTFail("reader returned nil for a transcript with usage")
            }
            XCTAssertEqual(stats.tokens, occupancy)  // parsed real shape == expected occupancy
            state = ContextTokens.fold(total: state?.total, lastReading: state?.lastReading,
                                       newReading: stats.tokens)
        }

        XCTAssertEqual(state?.total, 230_000)
        XCTAssertNotEqual(state?.total, 120_000)  // would be the naive latest-reading result
    }
}
