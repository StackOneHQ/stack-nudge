import XCTest

@testable import StackNudgePanelCore

// classify is the not-in-use / broken / ok split the Usage tab keys its error
// state on: agy not running stays silent, but agy answering with a body we can't
// read surfaces an error, the same way Claude tells a missing CLI apart from a
// failed one.
final class AntigravityUsageTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // A minimal GetUserStatus body with one model quota — enough for parse to
    // build a snapshot.
    private let validBody = """
    {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
    {"label":"Claude Opus 4.6","quotaInfo":{"remainingFraction":0.6}}
    ]}}}
    """

    func test_nilData_isUnreachable() {
        XCTAssertEqual(AntigravityUsageProbe.classify(nil), .unreachable)
    }

    // agy answered, but the shape isn't what we expect — a real break, not
    // "not in use".
    func test_respondedButUnparseable_isUnparseable() {
        XCTAssertEqual(AntigravityUsageProbe.classify(data("{\"unexpected\":true}")), .unparseable)
        XCTAssertEqual(AntigravityUsageProbe.classify(data("not json")), .unparseable)
    }

    // A body with the envelope but no models parses to nothing, which is still
    // "responded but nothing usable" — unparseable, not unreachable.
    func test_respondedWithNoModels_isUnparseable() {
        let empty = "{\"userStatus\":{\"cascadeModelConfigData\":{\"clientModelConfigs\":[]}}}"
        XCTAssertEqual(AntigravityUsageProbe.classify(data(empty)), .unparseable)
    }

    func test_validBody_isOk() {
        guard case .ok(let snapshot) = AntigravityUsageProbe.classify(data(validBody)) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertEqual(snapshot.models.first?.label, "Claude Opus 4.6")
        XCTAssertEqual(snapshot.models.first?.tier.utilization, 40)  // (1 - 0.6) * 100
    }
}
