import XCTest

@testable import StackNudgePanelCore

// Pins the `account/rateLimits/read` response to the parser that reads it, using
// a verbatim capture from `codex app-server` rather than a hand-built dictionary.
//
// Also pins the request strings. They're assembled by concatenation to keep the
// JSON readable inline, which makes a stray brace or a dropped comma a runtime
// no-op that fails silently: the server would reject the frame, the exchange
// would time out, and the probe would quietly fall back to the stale rollout
// forever. Parsing them back is the cheapest guard against that.
final class CodexAppServerTests: XCTestCase {

    private let fiveHourReset: TimeInterval = 1_789_661_002
    private let weeklyReset: TimeInterval = 1_789_805_796

    private func result(_ json: String) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dict = object as? [String: Any] else {
            XCTFail("fixture is not a JSON object")
            return [:]
        }
        return dict
    }

    // Verbatim from a live `account/rateLimits/read` on a ChatGPT Plus account.
    private var plusAccount: [String: Any] {
        result("""
        {"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","limitName":null,\
        "normalModelSlug":null,\
        "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":\(Int(fiveHourReset))},\
        "secondary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":\(Int(weeklyReset))},\
        "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},\
        "individualLimit":null,"spendControlReached":false,"planType":"plus",\
        "rateLimitReachedType":null},\
        "rateLimitsByLimitId":{"codex":{"limitId":"codex",\
        "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":\(Int(fiveHourReset))},\
        "secondary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":\(Int(weeklyReset))},\
        "planType":"plus"}},\
        "rateLimitResetCredits":{"availableCount":3,"credits":null},\
        "accountId":"fd1b74f4-628a-4218-a3e5-9ce036a1cc3a","rateLimitUpsell":null}
        """)
    }

    func testMapsBothWindowsOntoTheSharedSnapshot() {
        guard let snapshot = CodexAppServer.snapshot(fromResult: plusAccount) else {
            return XCTFail("expected a snapshot")
        }
        XCTAssertEqual(snapshot.primary?.utilization, 0)
        XCTAssertEqual(snapshot.primary?.windowLength, 300 * 60)
        XCTAssertEqual(snapshot.primary?.resetsAt,
                       Date(timeIntervalSince1970: fiveHourReset))
        XCTAssertEqual(snapshot.secondary?.utilization, 36)
        XCTAssertEqual(snapshot.secondary?.windowLength, 10080 * 60)
        XCTAssertEqual(snapshot.planType, "plus")
    }

    // The deliberate divergence from the rollout reader. There a passed reset
    // means the file went stale and the window must be dropped; here the server
    // just told us, so dropping it would blank a live row over clock skew.
    func testKeepsAWindowWhoseResetHasPassed() {
        let snapshot = CodexAppServer.snapshot(fromResult: result("""
        {"rateLimits":{"limitId":"codex","planType":"pro",\
        "primary":{"usedPercent":88,"windowDurationMins":10080,"resetsAt":1},\
        "secondary":null}}
        """))
        XCTAssertEqual(snapshot?.primary?.utilization, 88)
        XCTAssertEqual(snapshot?.primary?.resetsAt, Date(timeIntervalSince1970: 1))
    }

    // Same plan shape the rollout tests pin: one weekly window in the primary
    // slot, no secondary. The window length is what tells them apart, not the slot.
    func testHandlesAWeeklyOnlyAccount() {
        let snapshot = CodexAppServer.snapshot(fromResult: result("""
        {"rateLimits":{"limitId":"codex","planType":"pro",\
        "primary":{"usedPercent":13,"windowDurationMins":10080,"resetsAt":\(Int(weeklyReset))},\
        "secondary":null}}
        """))
        XCTAssertEqual(snapshot?.primary?.windowLength, 10080 * 60)
        XCTAssertNil(snapshot?.secondary)
    }

    // API-key auth reports no windows. A snapshot of two nils would take the
    // Codex row from "nothing to show" to an empty set of bars.
    func testRejectsAResponseWithNoWindows() {
        XCTAssertNil(CodexAppServer.snapshot(fromResult: result("""
        {"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex",\
        "primary":null,"secondary":null,"planType":null}}
        """)))
    }

    func testRejectsAResponseWithoutRateLimits() {
        XCTAssertNil(CodexAppServer.snapshot(
            fromResult: result(#"{"ordinaryUsageAllowed":true}"#)))
    }

    // MARK: - Request frames

    private func decode(_ frame: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any]
    }

    func testInitializeFrameIsWellFormed() {
        guard let frame = decode(CodexAppServer.initializeRequest(version: "1.34.1")) else {
            return XCTFail("initialize is not valid JSON")
        }
        XCTAssertEqual(frame["method"] as? String, "initialize")
        XCTAssertEqual((frame["id"] as? NSNumber)?.intValue, 1)
        let clientInfo = (frame["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "stack-nudge")
        XCTAssertEqual(clientInfo?["version"] as? String, "1.34.1")
    }

    func testInitializedFrameIsANotification() {
        guard let frame = decode(CodexAppServer.initializedNotification) else {
            return XCTFail("initialized is not valid JSON")
        }
        XCTAssertEqual(frame["method"] as? String, "initialized")
        // A notification carries no id; sending one would leave us waiting for a
        // reply that never comes, until the watchdog kills the exchange.
        XCTAssertNil(frame["id"])
    }

    // Both params are load-bearing. supportsLunaReserve must stay false for a
    // passive reader — true records experiment exposure we have no business
    // triggering — and excludeResetCreditDetails skips a backend lookup we
    // never render, which is what the Codex TUI sets on its own periodic polls.
    func testRateLimitsFrameOptsOutOfSideEffects() {
        guard let frame = decode(CodexAppServer.rateLimitsRequest) else {
            return XCTFail("rateLimits request is not valid JSON")
        }
        XCTAssertEqual(frame["method"] as? String, "account/rateLimits/read")
        XCTAssertEqual((frame["id"] as? NSNumber)?.intValue, 2)
        let params = frame["params"] as? [String: Any]
        XCTAssertEqual(params?["supportsLunaReserve"] as? Bool, false)
        XCTAssertEqual(params?["excludeResetCreditDetails"] as? Bool, true)
    }
}
