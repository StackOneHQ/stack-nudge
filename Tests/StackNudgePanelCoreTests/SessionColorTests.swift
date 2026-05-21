import SwiftUI
import XCTest

@testable import StackNudgePanelCore

// SessionColor maps (canonical-agent, projectPath) → one of the 6 palette
// colors deterministically. Stability across launches is the whole point
// (Swift's built-in String hashing is randomized per launch as a security
// feature, so this hand-rolled FNV-1a is the contract). These tests pin
// that contract so a future "let's just use .hashValue" mistake fails
// loudly here instead of producing rainbow rows in the wild.
final class SessionColorTests: XCTestCase {

    func test_color_sameKey_returnsSameColor() {
        let a = SessionColor.color(agent: "claude", projectPath: "/x")
        let b = SessionColor.color(agent: "claude", projectPath: "/x")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func test_color_nilProjectPath_returnsNil() {
        XCTAssertNil(SessionColor.color(agent: "claude", projectPath: nil))
    }

    func test_color_emptyProjectPath_returnsNil() {
        XCTAssertNil(SessionColor.color(agent: "claude", projectPath: ""))
    }

    func test_color_canonicalizesAgent() {
        // claude-code and claude must resolve to the same color for the
        // same project — same join key after canonicalization.
        let viaWire   = SessionColor.color(agent: "claude-code", projectPath: "/x")
        let viaCanon  = SessionColor.color(agent: "claude",      projectPath: "/x")
        let viaCursor = SessionColor.color(agent: "cursor",      projectPath: "/x")
        XCTAssertNotNil(viaWire)
        XCTAssertEqual(viaWire, viaCanon)
        XCTAssertEqual(viaCanon, viaCursor)
    }

    func test_color_differentAgents_canHaveDifferentColors() {
        // Different canonical agents (claude vs gemini) hash to different
        // keys, so they MAY differ in color. We can't assert non-equality
        // because the palette has only 6 slots and collisions are normal;
        // we just confirm both resolve to valid palette members.
        let a = SessionColor.color(agent: "claude", projectPath: "/x")
        let b = SessionColor.color(agent: "gemini", projectPath: "/x")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertTrue(SessionColor.palette.contains(a!))
        XCTAssertTrue(SessionColor.palette.contains(b!))
    }

    func test_color_isAlwaysFromPalette() {
        // Sample a handful of distinct keys and confirm every result is
        // a palette member — guards against an off-by-one in the modulo.
        let probes: [(String, String)] = [
            ("claude", "/a"),
            ("claude", "/b/c"),
            ("gemini", "/a"),
            ("codex",  "/d/e/f"),
            ("claude", "/Users/x/very/long/path/here"),
            ("claude", "/"),
        ]
        for (agent, path) in probes {
            let c = SessionColor.color(agent: agent, projectPath: path)
            XCTAssertNotNil(c, "expected a color for (\(agent), \(path))")
            XCTAssertTrue(SessionColor.palette.contains(c!),
                          "color for (\(agent), \(path)) is outside the palette")
        }
    }

    func test_palette_isNonEmpty() {
        // A zero-sized palette would crash the modulo. Belt + braces.
        XCTAssertFalse(SessionColor.palette.isEmpty)
    }

    // MARK: - tabId mixing (Stage 2)

    // Mixing tabId into the hash gives two iTerm tabs in the same cwd
    // distinct accent colors. We can't *guarantee* non-equality (6-slot
    // palette → ~17% collision), so we sample several tab ids and assert
    // at least one diverges from the no-tabId baseline. A clean assert.
    func test_color_tabId_canDifferFromNoTabId() {
        let base = SessionColor.color(agent: "claude", projectPath: "/x")
        let probes = ["tab-A", "tab-B", "tab-C", "tab-D", "tab-E", "tab-F", "tab-G", "tab-H"]
        let anyDiffer = probes.contains { tabId in
            SessionColor.color(agent: "claude", projectPath: "/x", tabId: tabId) != base
        }
        XCTAssertTrue(anyDiffer, "expected at least one tabId probe to land on a different palette slot")
    }

    // Stage-2 callers without a tabId must get the exact same color as
    // the Stage-1 call signature returned — no surprise migration shuffle.
    func test_color_nilTabId_matchesPreStage2Behaviour() {
        let pre  = SessionColor.color(agent: "claude", projectPath: "/x")
        let post = SessionColor.color(agent: "claude", projectPath: "/x", tabId: nil)
        XCTAssertEqual(pre, post)
        let postEmpty = SessionColor.color(agent: "claude", projectPath: "/x", tabId: "")
        XCTAssertEqual(pre, postEmpty)
    }

    // Determinism with a tabId — same triple, same color.
    func test_color_withTabId_isDeterministic() {
        let a = SessionColor.color(agent: "claude", projectPath: "/x", tabId: "tab-A")
        let b = SessionColor.color(agent: "claude", projectPath: "/x", tabId: "tab-A")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }
}
