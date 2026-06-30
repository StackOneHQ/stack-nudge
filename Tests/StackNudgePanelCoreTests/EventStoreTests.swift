import XCTest

@testable import StackNudgePanelCore

@MainActor
final class EventStoreTests: XCTestCase {

    private func makeEvent(message: String = "x") -> NudgeEvent {
        NudgeEvent(agent: "claude-code", kind: .stop,
                   title: "Claude Code", message: message)
    }

    func test_append_insertsAtFront() {
        let store = EventStore()
        let first  = makeEvent(message: "first")
        let second = makeEvent(message: "second")
        store.append(first)
        store.append(second)
        XCTAssertEqual(store.events.map(\.message), ["second", "first"])
    }

    func test_append_setsSelectionToNewest() {
        let store = EventStore()
        let event = makeEvent()
        store.append(event)
        XCTAssertEqual(store.selectedID, event.id)
    }

    func test_selectFirstAndLast_jumpToEnds() {
        let store = EventStore()
        let oldest = makeEvent(message: "oldest")
        let newest = makeEvent(message: "newest")
        store.append(oldest)
        store.append(newest)   // newest-first: events == [newest, oldest]
        store.selectLast()
        XCTAssertEqual(store.selectedID, oldest.id)   // bottom row
        store.selectFirst()
        XCTAssertEqual(store.selectedID, newest.id)   // top row
    }

    func test_selectFirst_onEmptyStore_clearsSelection() {
        let store = EventStore()
        store.selectFirst()
        XCTAssertNil(store.selectedID)
    }

    func test_append_truncatesPastMaxEvents() {
        // maxEvents is 5; we send 7.
        let store = EventStore()
        let events = (0..<7).map { makeEvent(message: "m\($0)") }
        events.forEach(store.append)
        XCTAssertEqual(store.events.count, 5)
        // Newest 5 retained, oldest 2 evicted.
        XCTAssertEqual(store.events.map(\.message), ["m6", "m5", "m4", "m3", "m2"])
    }

    func test_remove_dropsByIDAndReselects() {
        let store = EventStore()
        let a = makeEvent(message: "a")
        let b = makeEvent(message: "b")
        store.append(a)
        store.append(b)
        // selectedID is now b.
        store.remove(id: b.id)
        XCTAssertEqual(store.events.map(\.message), ["a"])
        XCTAssertEqual(store.selectedID, a.id, "selection moves to remaining event")
    }

    func test_remove_nonSelectedLeavesSelectionAlone() {
        let store = EventStore()
        let a = makeEvent(message: "a")
        let b = makeEvent(message: "b")
        store.append(a)
        store.append(b)
        // selectedID is b. Remove a.
        store.remove(id: a.id)
        XCTAssertEqual(store.events.map(\.message), ["b"])
        XCTAssertEqual(store.selectedID, b.id)
    }

    func test_remove_lastEventClearsSelection() {
        let store = EventStore()
        let event = makeEvent()
        store.append(event)
        store.remove(id: event.id)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertNil(store.selectedID)
    }

    func test_selectNext_movesDownThenClampsAtBottom() {
        let store = EventStore()
        // Append in order so events == [c, b, a] (newest first).
        let a = makeEvent(message: "a")
        let b = makeEvent(message: "b")
        let c = makeEvent(message: "c")
        [a, b, c].forEach(store.append)
        store.selectedID = c.id
        store.selectNext()
        XCTAssertEqual(store.selectedID, b.id)
        store.selectNext()
        XCTAssertEqual(store.selectedID, a.id)
        store.selectNext()
        XCTAssertEqual(store.selectedID, a.id, "clamps at last event")
    }

    func test_selectPrevious_movesUpThenClampsAtTop() {
        let store = EventStore()
        let a = makeEvent(message: "a")
        let b = makeEvent(message: "b")
        let c = makeEvent(message: "c")
        [a, b, c].forEach(store.append)
        store.selectedID = a.id
        store.selectPrevious()
        XCTAssertEqual(store.selectedID, b.id)
        store.selectPrevious()
        XCTAssertEqual(store.selectedID, c.id)
        store.selectPrevious()
        XCTAssertEqual(store.selectedID, c.id, "clamps at first event")
    }

    func test_selectNextAndPrevious_noOpOnEmptyStore() {
        let store = EventStore()
        store.selectNext()
        store.selectPrevious()
        XCTAssertNil(store.selectedID)
    }

    func test_selectedEvent_matchesSelectedID() {
        let store = EventStore()
        let event = makeEvent(message: "selected")
        store.append(event)
        XCTAssertEqual(store.selectedEvent?.id, event.id)
        XCTAssertEqual(store.selectedEvent?.message, "selected")
    }
}
