import XCTest

@testable import StackNudgePanelCore

// Regression tests for issue #205: "stack-nudge doesn't restart after update".
//
// The update itself had already succeeded — downloaded, verified, swapped
// into ~/Applications — and the panel then sat on "Restarting stack-nudge…"
// indefinitely. The cause was the restart step shelling out to
// `launchctl kickstart -k` and waiting on it with an unbounded
// `waitUntilExit()`. A kickstart against an agent whose program is missing
// never returns, so the updater thread never reached the lines that relaunch
// the new bundle and quit the old process.
//
// The daemon agent's plist points inside the app bundle that atomicSwap has
// just replaced, so the updater can create that unspawnable job itself.
//
// These exercise Updater.runBounded, which is the guarantee the fix rests on:
// no subprocess on the restart path may outlive its timeout. They use
// ordinary commands rather than launchd, so they are deterministic and leave
// no agents behind.
final class UpdaterRestartTests: XCTestCase {

    // Generous enough not to flake on a loaded CI box, still far below the
    // 30s the child would run for if the timeout did nothing.
    private let slack: TimeInterval = 10

    // MARK: - The bug

    // The one that fails against the pre-fix code: a child that never exits
    // must be abandoned, not waited on forever.
    func test_runBounded_returnsTimedOutWhenTheChildNeverExits() {
        let started = Date()
        let outcome = Updater.runBounded("/bin/sleep", ["30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, slack,
                          "runBounded waited \(elapsed)s on a child it was told to abandon after 1s")
    }

    // Returning .timedOut is only half of it: the child has to actually be
    // gone. A kickstart left running holds the launchd work the timeout was
    // supposed to give up on, and on the restart path we are about to quit.
    func test_runBounded_killsTheChildItAbandons() throws {
        let marker = NSTemporaryDirectory()
            + "stack-nudge-test-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: marker) }

        // Child records its own pid, then sleeps well past the timeout.
        let outcome = Updater.runBounded(
            "/bin/sh", ["-c", "echo $$ > \(marker); exec /bin/sleep 30"], timeout: 2)
        XCTAssertEqual(outcome, .timedOut)

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(recorded), "child never recorded a pid")
        // kill(pid, 0) succeeds only while the process still exists.
        XCTAssertEqual(kill(pid, 0), -1,
                       "child \(pid) survived the timeout that was meant to kill it")
    }

    // MARK: - The paths that must keep working

    func test_runBounded_reportsACleanExit() {
        XCTAssertEqual(Updater.runBounded("/bin/sh", ["-c", "exit 0"], timeout: 5), .exited(0))
    }

    // launchctl exits 113 ("could not find service") when the agent isn't
    // loaded, which is the common case on a shell install and must stay a
    // logged non-event rather than a thrown error.
    func test_runBounded_reportsANonZeroExitRatherThanThrowing() {
        XCTAssertEqual(Updater.runBounded("/bin/sh", ["-c", "exit 113"], timeout: 5), .exited(113))
    }

    func test_runBounded_reportsAnExecutableThatCannotStart() {
        let outcome = Updater.runBounded("/nonexistent/launchctl", ["kickstart"], timeout: 5)
        guard case .failedToStart = outcome else {
            return XCTFail("expected .failedToStart, got \(outcome)")
        }
    }

    // Output goes to /dev/null, not to a Pipe nobody reads. With a pipe, a
    // child writing more than the buffer holds blocks on write() while we
    // block on it — the same hang in a different disguise, and one a quiet
    // `launchctl` would have hidden until something started talking.
    func test_runBounded_doesNotDeadlockOnAChildThatWritesALot() {
        let started = Date()
        let outcome = Updater.runBounded(
            "/bin/sh", ["-c", "yes 'stack-nudge' | head -c 2000000"], timeout: 20)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome, .exited(0))
        XCTAssertLessThan(elapsed, slack, "chatty child took \(elapsed)s — looks like a pipe stall")
    }

    // MARK: - The budget

    // The restart path makes two of these calls back to back, so the ceiling
    // a user can sit through is twice the timeout. Pinned because the cost of
    // raising it is paid on the one screen the user cannot leave.
    func test_kickstartTimeout_keepsTheWorstCaseStallBounded() {
        XCTAssertLessThanOrEqual(Updater.kickstartTimeout * 2, 20)
    }
}
