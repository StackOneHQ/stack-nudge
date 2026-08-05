import XCTest

@testable import StackNudgePanelCore

// The time-bounded read has one non-obvious requirement: it must drain stdout
// *while* waiting for the child, not after it. Draining afterwards deadlocks
// any command whose output outgrows the ~64KB pipe buffer — the child blocks
// writing, we block waiting, and the timeout fires on a command that was
// working perfectly. `ps -axo args=` is over 250KB on a busy machine, so this
// silently emptied the entire Sessions pane.
final class ProcessOutputTests: XCTestCase {

    // Comfortably past the pipe buffer: ~589KB.
    private let bigOutputLineCount = 100_000

    func test_read_withTimeout_returnsOutputLargerThanThePipeBuffer() {
        let actual = ProcessOutput.read("/usr/bin/seq", ["1", "\(bigOutputLineCount)"], timeout: 10)
        XCTAssertNotNil(actual, "large output must not read as a timeout")
        XCTAssertGreaterThan(actual?.utf8.count ?? 0, 64 * 1024,
                             "test is only meaningful above the pipe buffer")
        XCTAssertEqual(actual?.split(separator: "\n").count, bigOutputLineCount,
                       "output must be complete, not truncated at the buffer")
    }

    func test_read_untimed_returnsOutputLargerThanThePipeBuffer() {
        let actual = ProcessOutput.read("/usr/bin/seq", ["1", "\(bigOutputLineCount)"])
        XCTAssertEqual(actual.split(separator: "\n").count, bigOutputLineCount)
    }

    // The timeout still has to fire for something that genuinely never returns
    // — that's what keeps a hung lsof from freezing the session poll.
    func test_read_withTimeout_returnsNilWhenTheChildOutlivesTheDeadline() {
        let actual = ProcessOutput.read("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertNil(actual)
    }

    func test_read_withTimeout_returnsNilOnSpawnFailure() {
        let actual = ProcessOutput.read("/nonexistent/binary", [], timeout: 1)
        XCTAssertNil(actual, "nil distinguishes 'never ran' from 'ran, printed nothing'")
    }

    func test_read_withTimeout_distinguishesEmptyOutputFromFailure() {
        let actual = ProcessOutput.read("/usr/bin/true", [], timeout: 5)
        XCTAssertEqual(actual, "", "a successful run with no output is an empty string, not nil")
    }
}
