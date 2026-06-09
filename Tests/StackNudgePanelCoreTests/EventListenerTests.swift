import XCTest

@testable import StackNudgePanelCore

// Pure-logic tests for the wire-format parser. The socket I/O itself is
// exercised by the running app; what regresses silently is the
// newline-split + DTO decode pipeline. A malformed line should not take
// down the whole batch; missing optional fields should default cleanly.
final class EventListenerTests: XCTestCase {

    private func payload(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: - Single events

    func test_parseEvents_decodesMinimalEvent() {
        let data = payload(#"""
        {"agent":"claude-code","event":"stop","title":"Done","message":"All set"}
        """#)
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].agent, "claude-code")
        XCTAssertEqual(events[0].kind, .stop)
        XCTAssertEqual(events[0].title, "Done")
        XCTAssertEqual(events[0].message, "All set")
    }

    func test_parseEvents_unknownKindFallsBackToOther() {
        let data = payload(#"""
        {"agent":"claude-code","event":"future_kind","title":"x","message":"y"}
        """#)
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .other)
    }

    func test_parseEvents_populatesOptionalEnrichmentFields() {
        // Must stay on a single line — parseEvents splits on \n before
        // decoding, so any embedded newlines in the JSON payload would
        // shred it into malformed fragments and the test would observe
        // zero events.
        let data = payload(#"{"agent":"claude-code","event":"permission","title":"Allow?","message":"rm -rf","project_path":"/repo","bundle_id":"com.googlecode.iterm2","window_title":"agent: repo","session_id":"w0t0p0","term_program":"iTerm.app","claude_session_id":"abc-123","transcript_path":"/tmp/t.jsonl","sound_name":"Ping","voice_message":"Please review","bypass_mute":true,"has_action_button":true}"#)
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.projectPath, "/repo")
        XCTAssertEqual(e.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(e.windowTitle, "agent: repo")
        XCTAssertEqual(e.sessionID, "w0t0p0")
        XCTAssertEqual(e.termProgram, "iTerm.app")
        XCTAssertEqual(e.claudeSessionID, "abc-123")
        XCTAssertEqual(e.transcriptPath, "/tmp/t.jsonl")
        XCTAssertEqual(e.soundName, "Ping")
        XCTAssertEqual(e.voiceMessage, "Please review")
        XCTAssertTrue(e.bypassMute)
        XCTAssertTrue(e.hasActionButton)
    }

    func test_parseEvents_missingTimestampDefaultsToNow() {
        let before = Date()
        let data = payload(#"""
        {"agent":"a","event":"stop","title":"t","message":"m"}
        """#)
        let events = EventListener.parseEvents(data)
        let after = Date()
        XCTAssertEqual(events.count, 1)
        XCTAssertGreaterThanOrEqual(events[0].timestamp, before)
        XCTAssertLessThanOrEqual(events[0].timestamp, after)
    }

    func test_parseEvents_explicitTimestampPreserved() {
        let data = payload(#"""
        {"agent":"a","event":"stop","title":"t","message":"m","timestamp":1700000000}
        """#)
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].timestamp.timeIntervalSince1970, 1700000000, accuracy: 0.001)
    }

    // MARK: - Batching + recovery

    func test_parseEvents_handlesMultipleLines() {
        let line1 = #"{"agent":"a","event":"stop","title":"t1","message":"m1"}"#
        let line2 = #"{"agent":"b","event":"permission","title":"t2","message":"m2"}"#
        let data = payload("\(line1)\n\(line2)\n")
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].title, "t1")
        XCTAssertEqual(events[1].title, "t2")
    }

    func test_parseEvents_keepsTrailingLineWithoutNewline() {
        let line1 = #"{"agent":"a","event":"stop","title":"first","message":"m"}"#
        let line2 = #"{"agent":"b","event":"stop","title":"second","message":"m"}"#
        // Deliberately no trailing newline on the last line — notify.sh
        // doesn't always terminate.
        let data = payload("\(line1)\n\(line2)")
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].title, "second")
    }

    func test_parseEvents_dropsMalformedLineButKeepsRest() {
        let good1 = #"{"agent":"a","event":"stop","title":"good1","message":"m"}"#
        let bad   = #"{not valid json"#
        let good2 = #"{"agent":"a","event":"stop","title":"good2","message":"m"}"#
        let data = payload("\(good1)\n\(bad)\n\(good2)\n")
        let events = EventListener.parseEvents(data)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.title), ["good1", "good2"])
    }

    func test_parseEvents_returnsEmptyOnAllBlank() {
        XCTAssertEqual(EventListener.parseEvents(Data()).count, 0)
        XCTAssertEqual(EventListener.parseEvents(payload("\n\n\n")).count, 0)
    }
}
