import XCTest

@testable import StackNudgePanelCore

final class ClaudeCliQuotaProbeTests: XCTestCase {

    // MARK: - parseTierLine

    func testParseTierLineWithResetsSuffix() {
        let line = "Current session: 2% used · resets Jun 30 at 6:50pm (Europe/London)"
        let parsed = ClaudeCliQuotaProbe.parseTierLine(line)
        XCTAssertEqual(parsed?.name, "session")
        XCTAssertEqual(parsed?.tier.utilization, 2)
        XCTAssertNotNil(parsed?.tier.resetsAt)
    }

    func testParseTierLineWithoutResetsSuffix() {
        // 0% lines omit the "· resets" suffix.
        let line = "Current week (Sonnet only): 0% used"
        let parsed = ClaudeCliQuotaProbe.parseTierLine(line)
        XCTAssertEqual(parsed?.name, "week (Sonnet only)")
        XCTAssertEqual(parsed?.tier.utilization, 0)
        XCTAssertNil(parsed?.tier.resetsAt)
    }

    func testParseTierLineRejectsMalformed() {
        XCTAssertNil(ClaudeCliQuotaProbe.parseTierLine("not a tier line"))
        XCTAssertNil(ClaudeCliQuotaProbe.parseTierLine("Current session: pct used"))
        XCTAssertNil(ClaudeCliQuotaProbe.parseTierLine("Current: 5% used"))
    }

    // MARK: - parseResultText

    func testParseResultTextFullOutput() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 2% used · resets Jun 30 at 6:50pm (Europe/London)
        Current week (all models): 23% used · resets Jul 4 at 3am (Europe/London)
        Current week (Sonnet only): 0% used
        Current week (Opus only): 12% used · resets Jul 4 at 3am (Europe/London)

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine — does not include other devices or claude.ai.

        Last 24h · 1346 requests · 12 sessions
          93% of your usage was at >150k context
        """
        switch ClaudeCliQuotaProbe.parseResultText(text) {
        case .ok(let snap):
            XCTAssertEqual(snap.fiveHour?.utilization, 2)
            XCTAssertEqual(snap.sevenDay?.utilization, 23)
            XCTAssertEqual(snap.sevenDaySonnet?.utilization, 0)
            XCTAssertEqual(snap.sevenDayOpus?.utilization, 12)
            XCTAssertNil(snap.planType, "planType is filled in by fetch(), not parseResultText")
        default:
            XCTFail("Expected .ok")
        }
    }

    func testParseResultTextSoftFailWhenBucketsAbsent() {
        // Rate-limited / cold-cache shape — the "What's contributing" section
        // still renders but the server-fetched Current lines are missing.
        let text = """
        You are currently using your subscription to power your Claude Code usage

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine.

        Last 24h · 1346 requests · 12 sessions
          93% of your usage was at >150k context
        """
        switch ClaudeCliQuotaProbe.parseResultText(text) {
        case .softFail: break
        default: XCTFail("Expected .softFail")
        }
    }

    func testParseResultTextSkipsMalformedLines() {
        // Only the well-formed Sonnet line should land in the snapshot.
        let text = """
        Current session: not a number used
        Current week (Sonnet only): 7% used
        Current: orphaned
        """
        switch ClaudeCliQuotaProbe.parseResultText(text) {
        case .ok(let snap):
            XCTAssertEqual(snap.sevenDaySonnet?.utilization, 7)
            XCTAssertNil(snap.fiveHour)
            XCTAssertNil(snap.sevenDay)
            XCTAssertNil(snap.sevenDayOpus)
        default:
            XCTFail("Expected .ok")
        }
    }

    func testParseResultTextIgnoresUnknownBucketNames() {
        // A new bucket label Anthropic adds in a future release shouldn't crash
        // us — it just gets dropped. Known lines around it must still parse.
        let text = """
        Current month (experimental): 50% used · resets Aug 1 at 12am (UTC)
        Current session: 8% used · resets Jul 1 at 9am (UTC)
        """
        switch ClaudeCliQuotaProbe.parseResultText(text) {
        case .ok(let snap):
            XCTAssertEqual(snap.fiveHour?.utilization, 8)
            XCTAssertNil(snap.sevenDay)
        default:
            XCTFail("Expected .ok")
        }
    }

    // MARK: - parseEnvelope

    func testParseEnvelopeUnwrapsResultField() {
        let raw = #"{"type":"result","result":"Current session: 5% used\n"}"#
        switch ClaudeCliQuotaProbe.parseEnvelope(raw) {
        case .ok(let snap):
            XCTAssertEqual(snap.fiveHour?.utilization, 5)
        default:
            XCTFail("Expected .ok")
        }
    }

    func testParseEnvelopeRejectsNonJson() {
        switch ClaudeCliQuotaProbe.parseEnvelope("not json") {
        case .hardFail: break
        default: XCTFail("Expected .hardFail")
        }
    }

    func testParseEnvelopeRejectsEmpty() {
        switch ClaudeCliQuotaProbe.parseEnvelope("") {
        case .hardFail: break
        default: XCTFail("Expected .hardFail")
        }
        switch ClaudeCliQuotaProbe.parseEnvelope(nil) {
        case .hardFail: break
        default: XCTFail("Expected .hardFail")
        }
    }

    func testParseEnvelopeRejectsMissingResultField() {
        let raw = #"{"type":"result","other":"fields"}"#
        switch ClaudeCliQuotaProbe.parseEnvelope(raw) {
        case .hardFail: break
        default: XCTFail("Expected .hardFail")
        }
    }

    // MARK: - parseResetsAt

    func testParseResetsAtWithTimezone() {
        // 6:50pm in Europe/London on a date in the current year.
        let parsed = ClaudeCliQuotaProbe.parseResetsAt("Jun 30 at 6:50pm (Europe/London)")
        XCTAssertNotNil(parsed)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let comps = cal.dateComponents([.month, .day, .hour, .minute], from: parsed!)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 30)
        XCTAssertEqual(comps.hour, 18)
        XCTAssertEqual(comps.minute, 50)
    }

    func testParseResetsAtBareHour() {
        // "3am" — no minutes — uses the alternate format.
        let parsed = ClaudeCliQuotaProbe.parseResetsAt("Jul 4 at 3am (Europe/London)")
        XCTAssertNotNil(parsed)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let comps = cal.dateComponents([.month, .day, .hour, .minute], from: parsed!)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 3)
        XCTAssertEqual(comps.minute, 0)
    }

    func testParseResetsAtMalformed() {
        XCTAssertNil(ClaudeCliQuotaProbe.parseResetsAt("nonsense"))
        XCTAssertNil(ClaudeCliQuotaProbe.parseResetsAt(""))
    }

    // MARK: - Session cleanup

    func testExtractSessionId() {
        let raw = #"{"type":"result","session_id":"abc-123","result":"x"}"#
        XCTAssertEqual(ClaudeCliQuotaProbe.extractSessionId(raw), "abc-123")
    }

    func testExtractSessionIdMissing() {
        XCTAssertNil(ClaudeCliQuotaProbe.extractSessionId(#"{"type":"result"}"#))
        XCTAssertNil(ClaudeCliQuotaProbe.extractSessionId("garbage"))
        XCTAssertNil(ClaudeCliQuotaProbe.extractSessionId(nil))
    }

    func testProbeSessionsDirEncodesCwd() {
        // "/Users/hiskud/.stack-nudge" → "-Users-hiskud--stack-nudge".
        // Claude replaces BOTH '/' and '.' with '-' (double dash for the
        // dot-prefix). The probe directory must match that encoding exactly,
        // or the cleanup-by-path will silently miss.
        let dir = ClaudeCliQuotaProbe.probeSessionsDir
        let encoded = ClaudeCliQuotaProbe.probeCwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        XCTAssertTrue(dir.hasSuffix("/.claude/projects/\(encoded)"))
        XCTAssertTrue(encoded.contains("--"),
                      "encoding must double-dash the dot-prefix on ~/.stack-nudge")
    }

    func testRemoveSessionFileRejectsPathTraversal() {
        // Defence in depth — a bogus session_id with slashes / .. must NOT
        // resolve to anything outside probeSessionsDir. Easiest assertion is
        // that the canary file we plant survives the call.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stack-nudge-canary-\(UUID().uuidString)")
        try? "canary".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ClaudeCliQuotaProbe.removeSessionFile("../../../../../../\(tmp.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "removeSessionFile must reject anything outside its directory")
    }
}
