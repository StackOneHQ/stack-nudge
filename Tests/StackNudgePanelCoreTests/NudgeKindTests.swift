import XCTest

@testable import StackNudgePanelCore

final class NudgeKindTests: XCTestCase {

    func test_rawWireValue_recognisedCases() {
        XCTAssertEqual(NudgeKind(rawWireValue: "stop"), .stop)
        XCTAssertEqual(NudgeKind(rawWireValue: "permission"), .permission)
    }

    func test_rawWireValue_unknownFallsBackToOther() {
        XCTAssertEqual(NudgeKind(rawWireValue: "garbage"), .other)
        XCTAssertEqual(NudgeKind(rawWireValue: ""), .other)
        // Case-sensitive — wire format is lowercase.
        XCTAssertEqual(NudgeKind(rawWireValue: "Stop"), .other)
    }

    func test_rawValue_matchesWireFormat() {
        XCTAssertEqual(NudgeKind.stop.rawValue, "stop")
        XCTAssertEqual(NudgeKind.permission.rawValue, "permission")
        XCTAssertEqual(NudgeKind.other.rawValue, "other")
    }
}
