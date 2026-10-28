import XCTest

@testable import StackNudgePanelCore

final class TodayRowsTests: XCTestCase {

    private let nine = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ id: String, startsIn minutes: Double, lasting: Double = 30) -> Meeting {
        let start = nine.addingTimeInterval(minutes * 60)
        return Meeting(id: id, itemId: id, title: id, start: start, end: start.addingTimeInterval(lasting * 60),
                       location: "", organizer: "", joinUrl: "", calendar: "Work")
    }

    func testPhasesFollowTheClock() {
        XCTAssertEqual(TodayRows.phase(meeting("a", startsIn: -60), now: nine), .past)
        XCTAssertEqual(TodayRows.phase(meeting("b", startsIn: -10), now: nine), .now)
        XCTAssertEqual(TodayRows.phase(meeting("c", startsIn: 30), now: nine), .upcoming)
    }

    // Opening the tab lands on what matters now: the meeting in progress, or
    // the next one, or the day's last when all are over.
    func testTheTabOpensOnTheCurrentOrNextMeeting() {
        let day = [meeting("a", startsIn: -120), meeting("b", startsIn: -10), meeting("c", startsIn: 60)]
        XCTAssertEqual(TodayRows.defaultIndex(day, now: nine), 1)
        XCTAssertEqual(TodayRows.defaultIndex(Array(day.prefix(1)) + [day[2]], now: nine), 1)
        XCTAssertEqual(TodayRows.defaultIndex(Array(day.prefix(2)), now: nine.addingTimeInterval(3600)), 1)
        XCTAssertEqual(TodayRows.defaultIndex([], now: nine), 0)
    }
}
