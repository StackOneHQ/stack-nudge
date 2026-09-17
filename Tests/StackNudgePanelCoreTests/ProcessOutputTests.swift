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

    // MARK: - Children that outlive their parent

    // EOF on the pipe needs *every* holder of the write end to close it, and a
    // child that backgrounds anything hands that end to a grandchild we never
    // see. The read used to block on that forever: a script that printed its
    // output and exited in milliseconds was reported as a full-timeout failure,
    // and the blocked thread was never reclaimed.
    func test_read_withTimeout_returnsPromptlyWhenAGrandchildHoldsStdout() throws {
        let script = try fixture("""
            #!/bin/sh
            sleep 300 &
            echo done
            exit 0
            """)
        let started = Date()
        let completion = ProcessOutput.run("/bin/sh", [script], timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(completion?.output.trimmingCharacters(in: .whitespacesAndNewlines), "done",
                       "the child exited 0 with valid output; that is a success")
        XCTAssertEqual(completion?.status, 0)
        XCTAssertLessThan(elapsed, 5, "must not wait out the full timeout for a child that exited")
    }

    // The leak that starved the shared utility pool. File descriptors are the
    // observable proxy: one pipe per call, never reclaimed.
    func test_run_doesNotLeakDescriptorsAcrossGrandchildHolds() throws {
        let script = try fixture("""
            #!/bin/sh
            sleep 300 &
            echo done
            exit 0
            """)
        _ = ProcessOutput.run("/bin/sh", [script], timeout: 5)  // warm up
        let before = Self.openDescriptorCount()
        for _ in 0..<5 { _ = ProcessOutput.run("/bin/sh", [script], timeout: 5) }
        let after = Self.openDescriptorCount()
        XCTAssertLessThanOrEqual(after - before, 2,
                                 "descriptors must not accumulate per call (was +1 each)")
    }

    // A timeout used to signal only the direct child, so anything it had
    // backgrounded survived every invocation — forever, once on a timer.
    func test_read_withTimeout_killsTheWholeProcessGroup() throws {
        let marker = NSTemporaryDirectory() + "po-pid-\(UUID().uuidString)"
        let script = try fixture("""
            #!/bin/sh
            sleep 300 &
            echo $! > \(marker)
            sleep 300
            """)
        XCTAssertNil(ProcessOutput.read("/bin/sh", [script], timeout: 1))

        guard let raw = try? String(contentsOfFile: marker, encoding: .utf8),
              let orphan = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return XCTFail("fixture never recorded a background pid") }

        // The group gets SIGTERM then SIGKILL; give the kernel a moment to reap.
        var alive = true
        for _ in 0..<50 where alive {
            usleep(20_000)
            alive = kill(orphan, 0) == 0
        }
        XCTAssertFalse(alive, "backgrounded grandchild survived the timeout")
    }

    // MARK: - Truncation

    // The distinction the truncated flag exists for. Here the grandchild is
    // idle: the child printed everything and exited, only EOF is missing, so
    // the output is whole and must be believed.
    func test_run_anIdleGrandchildDoesNotMarkOutputTruncated() throws {
        let script = try fixture("""
            #!/bin/sh
            sleep 300 &
            echo done
            exit 0
            """)
        let completion = ProcessOutput.run("/bin/sh", [script], timeout: 10)
        XCTAssertEqual(completion?.truncated, false)
        XCTAssertEqual(completion?.output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    // A chatty helper does not make the child's own output partial. Once the
    // child has exited, everything *it* wrote is already in the buffer, so a
    // read that reaches EAGAIN has seen all of it — whatever the helper emits
    // afterwards are a different process's bytes, not a missing tail.
    func test_run_aChattyGrandchildDoesNotMakeTheChildsOutputPartial() throws {
        let script = try fixture("""
            #!/bin/sh
            (while true; do echo more; sleep 0.05; done) &
            echo start
            exit 0
            """)
        let completion = ProcessOutput.run("/bin/sh", [script], timeout: 10)
        XCTAssertEqual(completion?.truncated, false)
        XCTAssertTrue(completion?.output.hasPrefix("start") == true,
                      "the child's own line must be there: \(completion?.output ?? "nil")")
    }

    // String callers get nil rather than a partial answer, which is what nil has
    // always meant here — they have no way to tell a short answer from a whole
    // one. This is the shape that would otherwise hand SessionStore a clipped
    // `ps -axo args=` that parses perfectly well as a smaller session list.
    func test_read_returnsNilRatherThanPartialOutput() throws {
        let script = try fixture("""
            #!/bin/sh
            /usr/bin/yes ABCDEFGHIJKLMNOPQRSTUVWXYZ | /usr/bin/head -c 9000000
            exit 0
            """)
        XCTAssertNil(ProcessOutput.read("/bin/sh", [script], timeout: 30))
    }

    // A well-behaved binary is unaffected — this is the path every existing
    // caller takes, and it must stay byte-identical.
    func test_read_ordinaryOutputIsNotTruncated() {
        let completion = ProcessOutput.run("/usr/bin/seq", ["1", "5000"], timeout: 10)
        XCTAssertEqual(completion?.truncated, false)
        XCTAssertEqual(completion?.output.split(separator: "\n").count, 5000)
    }

    // A script that prints far more than we are willing to keep is bounded, and
    // says so. The bytes past the ceiling are read and dropped rather than left
    // in the pipe: abandoning it would block the child on a full buffer and turn
    // its overrun into a timeout instead of a truncation.
    func test_run_stopsStoringAtTheOutputCeilingWithoutWedgingTheChild() throws {
        let script = try fixture("""
            #!/bin/sh
            /usr/bin/yes ABCDEFGHIJKLMNOPQRSTUVWXYZ | /usr/bin/head -c 9000000
            exit 0
            """)
        let completion = ProcessOutput.run("/bin/sh", [script], timeout: 30)
        XCTAssertNotNil(completion, "the child must still be able to exit")
        XCTAssertLessThanOrEqual(completion?.output.utf8.count ?? .max,
                                 ProcessOutput.maxOutputBytes)
        XCTAssertEqual(completion?.truncated, true, "a capped read is by definition partial")
    }

    // MARK: - Signals

    // terminationStatus after a signal is the signal number — not an exit code,
    // and not 128+n. Callers that word it as "exited \(status)" are wrong.
    func test_run_distinguishesASignalFromAnExitCode() throws {
        let script = try fixture("""
            #!/bin/sh
            kill -SEGV $$
            """)
        let completion = ProcessOutput.run("/bin/sh", [script], timeout: 5)
        XCTAssertEqual(completion?.status, SIGSEGV)
        XCTAssertEqual(completion?.signalled, true)
    }

    func test_run_aCleanNonZeroExitIsNotReportedAsASignal() {
        let completion = ProcessOutput.run("/usr/bin/false", [], timeout: 5)
        XCTAssertEqual(completion?.status, 1)
        XCTAssertEqual(completion?.signalled, false)
    }

    // MARK: - Helpers

    private func fixture(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "po-\(UUID().uuidString).sh"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private static func openDescriptorCount() -> Int {
        (0..<512).reduce(into: 0) { total, fd in
            if fcntl(Int32(fd), F_GETFD) != -1 { total += 1 }
        }
    }
}
