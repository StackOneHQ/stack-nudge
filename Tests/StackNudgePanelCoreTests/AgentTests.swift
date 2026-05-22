import XCTest

@testable import StackNudgePanelCore

// Agent.canonical bridges the names emitted on the notify.sh wire
// ("claude-code", "cursor", "gemini", "codex") to the names the process
// scanner sees ("claude", "gemini", "codex"). The whole event ↔ session
// link rides on this — a regression here would silently break the
// events-tab session label and the per-session color accent.
final class AgentTests: XCTestCase {

    func test_canonical_claudeCodeMapsToClaude() {
        XCTAssertEqual(Agent.canonical("claude-code"), "claude")
    }

    func test_canonical_cursorMapsToClaude() {
        // Cursor wraps Claude Code under the hood; the process scanner
        // observes a "claude" binary, so the canonical form must match.
        XCTAssertEqual(Agent.canonical("cursor"), "claude")
    }

    func test_canonical_claudeUnchanged() {
        XCTAssertEqual(Agent.canonical("claude"), "claude")
    }

    func test_canonical_geminiUnchanged() {
        XCTAssertEqual(Agent.canonical("gemini"), "gemini")
    }

    func test_canonical_codexUnchanged() {
        XCTAssertEqual(Agent.canonical("codex"), "codex")
    }

    func test_canonical_antigravityMapsToAgy() {
        // Antigravity ships the `agy` CLI; the hook may report
        // "antigravity" or "antigravity-cli" depending on which
        // integration fires it. All three should collapse to "agy"
        // so renames + colors apply consistently.
        XCTAssertEqual(Agent.canonical("antigravity"),     "agy")
        XCTAssertEqual(Agent.canonical("antigravity-cli"), "agy")
        XCTAssertEqual(Agent.canonical("agy"),             "agy")
    }

    func test_canonical_unknownAgentPassesThrough() {
        XCTAssertEqual(Agent.canonical("some-future-agent"), "some-future-agent")
    }

    func test_canonical_emptyStringPassesThrough() {
        XCTAssertEqual(Agent.canonical(""), "")
    }
}
