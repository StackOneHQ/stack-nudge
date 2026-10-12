import XCTest

@testable import StackNudgePanelCore

// CodexTranscriptReader parses Codex CLI rollout JSONL into the same
// TranscriptStats the Claude reader produces. The schema is fixed against
// Codex's own TokenUsage definition: context occupancy is
// last_token_usage.total_tokens - reasoning_output_tokens, and cached input
// is a subset of input (never summed). Fixtures here encode that contract so
// a Codex schema drift, or a regression to the cached-double-count bug, is
// caught without needing a live Codex session.
final class CodexTranscriptReaderTests: XCTestCase {

    private func writeRollout(_ lines: [String], name: String = "rollout-test.jsonl") -> String {
        let dir = NSTemporaryDirectory() + "codex-rollout-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + name
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // Build a fake ~/.codex/sessions tree with one rollout for `sessionID` under
    // YYYY/MM/DD, returning the root to pass to rolloutPath(forSessionID:root:).
    private func writeSessionsTree(sessionID: String, day: String = "2026/08/10") -> (root: String, path: String) {
        let root = NSTemporaryDirectory() + "codex-sessions-\(UUID().uuidString)"
        let dayDir = "\(root)/\(day)"
        try? FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
        let path = "\(dayDir)/rollout-2026-08-10T12-05-45-\(sessionID).jsonl"
        try? "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
        return (root, path)
    }

    // The stop rule governs how much of a large rollout is read. Tokens sit
    // within 28 KB across all 293 rollouts measured; the model runs to 2.5 MB
    // and on 40 of them is absent entirely, so stopping only when BOTH are
    // found walked the whole 8 MB budget on every read of those. Past the model
    // budget the tokens alone are enough.
    func test_stop_waitsForTokensThenGivesUpOnTheModel() {
        // No tokens yet: keep scanning however deep we are.
        XCTAssertFalse(CodexTranscriptReader.stop(tokens: nil, model: nil, depth: 0))
        XCTAssertFalse(CodexTranscriptReader.stop(tokens: nil, model: "gpt-5-codex", depth: 0))
        XCTAssertFalse(CodexTranscriptReader.stop(tokens: nil, model: nil,
                                                  depth: CodexTranscriptReader.modelSearchBudget * 2),
                       "the token budget is TranscriptTail's, not this rule's")

        // Tokens in hand: stop at once if the model is known.
        XCTAssertTrue(CodexTranscriptReader.stop(tokens: 100, model: "gpt-5-codex", depth: 0))

        // Tokens in hand, model still missing: keep looking, but not forever.
        XCTAssertFalse(CodexTranscriptReader.stop(tokens: 100, model: nil, depth: 0))
        XCTAssertFalse(CodexTranscriptReader.stop(tokens: 100, model: nil,
                                                  depth: CodexTranscriptReader.modelSearchBudget),
                       "the budget is a ceiling to exceed, not to reach")
        XCTAssertTrue(CodexTranscriptReader.stop(tokens: 100, model: nil,
                                                 depth: CodexTranscriptReader.modelSearchBudget + 1))
    }

    // A rollout with no turn_context line anywhere has no model to find —
    // session_meta carries `model_provider`, not `model`. It must still report
    // its tokens rather than resolving to nothing.
    func test_read_resolvesTokensWhenNoLineCarriesAModel() {
        let path = writeRollout([
            #"{"type":"session_meta","payload":{"type":"session_meta","id":"s1","model_provider":"openai"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4096,"reasoning_output_tokens":96}}}}"#,
        ])
        let stats = CodexTranscriptReader.read(path: path)
        XCTAssertEqual(stats?.tokens, 4000)
        XCTAssertNil(stats?.model, "no turn_context means no model, and that is not a failure")
    }

    func test_rolloutPath_findsRolloutBySessionIdSuffix() {
        let sid = "019feb59-9aec-7480-b180-7e8b1cb64117"
        let tree = writeSessionsTree(sessionID: sid)
        XCTAssertEqual(CodexTranscriptReader.rolloutPath(forSessionID: sid, root: tree.root), tree.path)
    }

    func test_rolloutPath_nilWhenNoMatchOrEmptyId() {
        let tree = writeSessionsTree(sessionID: "aaaa")
        XCTAssertNil(CodexTranscriptReader.rolloutPath(forSessionID: "bbbb", root: tree.root))
        XCTAssertNil(CodexTranscriptReader.rolloutPath(forSessionID: "", root: tree.root))
    }

    func test_rolloutPath_walksNewestDayFirst() {
        let sid = "dup"
        let root = NSTemporaryDirectory() + "codex-sessions-\(UUID().uuidString)"
        for day in ["2026/08/09", "2026/08/10"] {
            let dayDir = "\(root)/\(day)"
            try? FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
            try? "{}\n".write(toFile: "\(dayDir)/rollout-x-\(sid).jsonl", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(CodexTranscriptReader.rolloutPath(forSessionID: sid, root: root),
                       "\(root)/2026/08/10/rollout-x-\(sid).jsonl")
    }

    func test_read_usesContextOccupancyFromLatestTokenCount() {
        let path = writeRollout([
            #"{"type":"session_meta","payload":{"id":"s1","model":"gpt-5-codex"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":2000,"output_tokens":500,"reasoning_output_tokens":300,"total_tokens":10800},"last_token_usage":{"input_tokens":10000,"cached_input_tokens":2000,"output_tokens":500,"reasoning_output_tokens":300,"total_tokens":10800},"model_context_window":272000}}}"#,
            #"{"type":"response_item","payload":{"role":"assistant"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60000,"cached_input_tokens":50000,"output_tokens":2000,"reasoning_output_tokens":1000,"total_tokens":63000},"last_token_usage":{"input_tokens":52000,"cached_input_tokens":48000,"output_tokens":1500,"reasoning_output_tokens":1000,"total_tokens":54500},"model_context_window":272000}}}"#,
        ])

        let actual = CodexTranscriptReader.read(path: path)

        // Latest token_count: last_token_usage.total_tokens - reasoning = 54500 - 1000.
        XCTAssertEqual(actual?.tokens, 53500)
        XCTAssertEqual(actual?.model, "gpt-5-codex")
    }

    func test_read_ignoresCumulativeTotalAndCachedSubset() {
        // A single turn where cached == input. If the reader wrongly summed
        // cached into input, or used the cumulative total_token_usage, the
        // number would differ. Occupancy must be last.total - last.reasoning.
        let path = writeRollout([
            #"{"type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000,"cached_input_tokens":0,"output_tokens":40000,"reasoning_output_tokens":12000,"total_tokens":940000},"last_token_usage":{"input_tokens":30000,"cached_input_tokens":30000,"output_tokens":800,"reasoning_output_tokens":200,"total_tokens":30800},"model_context_window":400000}}}"#,
        ])

        let actual = CodexTranscriptReader.read(path: path)

        XCTAssertEqual(actual?.tokens, 30600)  // 30800 - 200, not 940000-ish, not +cached
        XCTAssertEqual(actual?.model, "gpt-5")
    }

    func test_read_returnsNilWhenNoTokenCount() {
        let path = writeRollout([
            #"{"type":"session_meta","payload":{"model":"gpt-5-codex"}}"#,
            #"{"type":"response_item","payload":{"role":"user"}}"#,
        ])

        XCTAssertNil(CodexTranscriptReader.read(path: path))
    }

    func test_read_returnsNilForMissingFile() {
        XCTAssertNil(CodexTranscriptReader.read(path: "/nonexistent/rollout-x.jsonl"))
    }

    func test_dispatch_routesRolloutFilenameToCodexReader() {
        // A Claude-shaped assistant line written into a rollout-* file. If the
        // dispatcher routed by filename to the Codex reader (correct), it finds
        // no token_count and returns nil. If it fell through to the Claude
        // reader, it would parse the usage block and return tokens. nil proves
        // the routing.
        let path = writeRollout([
            #"{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ], name: "rollout-abc.jsonl")

        XCTAssertNil(TranscriptReader.read(path: path))
    }
}
