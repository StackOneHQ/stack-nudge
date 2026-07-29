import XCTest

@testable import StackNudgePanelCore

// RefreshGate rate-limits the Tickets tab's two refreshes. The contract that
// matters: a request inside the window is deferred rather than dropped (so the
// caller never has to know whether its data made the cut), repeated requests
// inside one window collapse into a single run, and force bypasses entirely.
// Driven by an injected clock so nothing here waits on a real timer.
final class RefreshGateTests: XCTestCase {

    // Captures scheduled work instead of dispatching it, so a test can fire it
    // at the point it chooses.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        var scheduled: [(delay: TimeInterval, block: () -> Void)] = []

        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }

        // Run the pending block as if its delay had elapsed.
        func fire() {
            guard let next = scheduled.first else { return XCTFail("nothing scheduled") }
            scheduled.removeFirst()
            advance(next.delay)
            next.block()
        }
    }

    private func gate(interval: TimeInterval = 60) -> (RefreshGate, Clock, () -> Int) {
        let clock = Clock()
        var runs = 0
        let gate = RefreshGate(
            interval: interval,
            now: { clock.now },
            after: { delay, block in clock.scheduled.append((delay, block)) },
            work: { runs += 1 })
        return (gate, clock, { runs })
    }

    func test_coldGate_runsImmediately() {
        let (gate, clock, runs) = self.gate()
        gate.request()
        XCTAssertEqual(runs(), 1)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    func test_requestAfterWindowElapsed_runsImmediately() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        clock.advance(60)
        gate.request()
        XCTAssertEqual(runs(), 2)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    // The point of the gate: a second visit to the tab inside the window doesn't
    // re-pay the fetch.
    func test_requestInsideWindow_doesNotRunYet() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        clock.advance(10)
        gate.request()
        XCTAssertEqual(runs(), 1)
        XCTAssertEqual(clock.scheduled.count, 1)
    }

    // Deferred, not dropped: the request is still served when the window closes.
    func test_deferredRequest_runsWhenWindowCloses() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        clock.advance(10)
        gate.request()
        XCTAssertEqual(clock.scheduled.first?.delay, 50)  // remainder of the window
        clock.fire()
        XCTAssertEqual(runs(), 2)
    }

    // A burst (several Stops, or flipping tabs repeatedly) costs one extra run.
    func test_manyRequestsInsideWindow_collapseToOneRun() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        for _ in 0..<20 {
            clock.advance(1)
            gate.request()
        }
        XCTAssertEqual(runs(), 1)
        XCTAssertEqual(clock.scheduled.count, 1)
        clock.fire()
        XCTAssertEqual(runs(), 2)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    // After a deferred run completes, the gate is armed again rather than stuck.
    func test_gateRearmsAfterDeferredRun() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        clock.advance(10)
        gate.request()
        clock.fire()
        XCTAssertEqual(runs(), 2)
        clock.advance(5)
        gate.request()
        XCTAssertEqual(runs(), 2)              // still inside the new window
        XCTAssertEqual(clock.scheduled.count, 1)
        clock.fire()
        XCTAssertEqual(runs(), 3)
    }

    func test_force_bypassesTheWindow() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.request()
        clock.advance(1)
        gate.force()
        XCTAssertEqual(runs(), 2)
        XCTAssertTrue(clock.scheduled.isEmpty)
    }

    // force also restarts the window, so it can't be used to defeat the limit by
    // alternating with request().
    func test_force_restartsTheWindow() {
        let (gate, clock, runs) = self.gate(interval: 60)
        gate.force()
        clock.advance(10)
        gate.request()
        XCTAssertEqual(runs(), 1)
        XCTAssertEqual(clock.scheduled.count, 1)
    }
}
