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
        // kill(pid, 0) succeeds only while the process still exists. Check
        // errno too: if the pid were recycled by a process of ANOTHER uid,
        // kill returns -1 with EPERM and a bare `== -1` would pass against a
        // live process. ESRCH is the one that means "gone".
        //
        // This samples immediately and deliberately: it is what pins the
        // post-terminate wait, i.e. that we return with the child reaped
        // rather than a zombie. Polling here would lose that coverage.
        XCTAssertEqual(kill(pid, 0), -1,
                       "child \(pid) survived the timeout that was meant to kill it")
        XCTAssertEqual(errno, ESRCH, "child \(pid) is not gone; errno \(errno)")
    }

    // The case above `exec`s /bin/sleep, which dies on SIGTERM — so it never
    // reaches the SIGKILL escalation, and deleting that escalation outright
    // leaves it green. This one traps SIGTERM, so it can only be stopped by
    // the arm the other test cannot reach. That arm exists for exactly this:
    // a child wedged badly enough to ignore a polite ask.
    func test_runBounded_escalatesToSIGKILLWhenTheChildIgnoresSIGTERM() throws {
        let marker = NSTemporaryDirectory()
            + "stack-nudge-test-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let outcome = Updater.runBounded(
            "/bin/sh",
            ["-c", "trap '' TERM; echo $$ > \(marker); while :; do /bin/sleep 0.2; done"],
            timeout: 2)
        XCTAssertEqual(outcome, .timedOut)

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(recorded), "child never recorded a pid")
        // This child cannot be stopped by SIGTERM, so when this test fails it
        // fails by leaving one behind — which a CI runner would accumulate
        // per run. Clean up after ourselves rather than relying on the code
        // under test, which is the thing in question.
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        XCTAssertEqual(kill(pid, 0), -1,
                       "SIGTERM-proof child \(pid) outlived runBounded — SIGKILL never landed")
        XCTAssertEqual(errno, ESRCH, "child \(pid) is not gone; errno \(errno)")
    }

    // MARK: - The paths that must keep working

    func test_runBounded_reportsACleanExit() {
        XCTAssertEqual(Updater.runBounded("/bin/sh", ["-c", "exit 0"], timeout: slack), .exited(0))
    }

    // launchctl exits 113 ("could not find service") when the agent isn't
    // loaded, which is the common case on a shell install and must stay a
    // logged non-event rather than a thrown error.
    func test_runBounded_reportsANonZeroExitRatherThanThrowing() {
        XCTAssertEqual(Updater.runBounded("/bin/sh", ["-c", "exit 113"], timeout: slack), .exited(113))
    }

    func test_runBounded_reportsAnExecutableThatCannotStart() {
        let outcome = Updater.runBounded("/nonexistent/launchctl", ["kickstart"], timeout: 5)
        guard case .failedToStart(let message) = outcome else {
            return XCTFail("expected .failedToStart, got \(outcome)")
        }
        // The message is what reaches appendLog, i.e. the only diagnostic a
        // user ever sends back. `catch { .failedToStart("") }` would satisfy
        // the case match alone.
        XCTAssertFalse(message.isEmpty, "failedToStart carried no reason")
    }

    // Output goes to /dev/null, not to a Pipe nobody reads. With a pipe, a
    // child writing more than the buffer holds blocks on write() while we
    // block on it — the same hang in a different disguise, and one a quiet
    // `launchctl` would have hidden until something started talking.
    //
    // Fills BOTH descriptors deliberately. Filling only stdout left the
    // stderr default untested, and stderr is the one that matters: launchctl
    // writes its diagnostics there, so in production it is the likelier fd
    // to carry the bytes that would stall us.
    func test_runBounded_doesNotDeadlockOnAChildThatWritesALot() {
        let started = Date()
        let outcome = Updater.runBounded(
            "/bin/sh",
            ["-c", "yes 'stack-nudge' | head -c 2000000; "
                 + "yes 'stack-nudge' | head -c 2000000 >&2"],
            timeout: 20)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome, .exited(0))
        XCTAssertLessThan(elapsed, slack, "chatty child took \(elapsed)s — looks like a pipe stall")
    }

    // MARK: - stderr capture

    // extractTarball needs tar's stderr for its error message, and used to
    // read it from a Pipe *after* waitUntilExit() — the ordering that
    // deadlocks once the child outruns the buffer. It now writes to a file,
    // so check the text actually survives the round trip, including past the
    // 64KiB a pipe would have stalled on.
    func test_runBounded_capturesStderrToAFileWithoutStalling() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stack-nudge-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)

        let started = Date()
        let outcome = Updater.runBounded(
            "/bin/sh",
            ["-c", "yes 'tar: this is a warning' | head -c 200000 1>&2; exit 1"],
            timeout: 20,
            standardError: handle)
        let elapsed = Date().timeIntervalSince(started)
        try? handle.close()

        XCTAssertEqual(outcome, .exited(1))
        XCTAssertLessThan(elapsed, slack, "stderr capture took \(elapsed)s — looks like a stall")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 100_000, "stderr was truncated")
        XCTAssertTrue(text.hasPrefix("tar: this is a warning"))
    }

    // MARK: - The budget

    // The restart path makes two bounded calls back to back, so what a user
    // can sit through is twice the WORST case of one call — and the worst
    // case is not the timeout. A child that ignores SIGTERM also costs both
    // grace periods, so the real figure is timeout + 2 × grace. Asserting
    // against `kickstartTimeout * 2` passed at exactly 20 while the true
    // ceiling was 28: a budget test measuring the wrong number.
    //
    // A wedged `launchctl` dies on SIGTERM immediately (measured), so the
    // realistic cost is the timeout alone — but the ceiling is what a budget
    // has to be written against, not the common case.
    func test_boundedCallCeiling_accountsForTheSignalGraces() {
        XCTAssertEqual(Updater.boundedCallCeiling,
                       Updater.kickstartTimeout + Updater.terminateGrace * 2)
        XCTAssertGreaterThan(Updater.boundedCallCeiling, Updater.kickstartTimeout,
                             "ceiling must exceed the timeout, or it is not the ceiling")
    }

    // MARK: - The bug itself

    // Everything above proves the *helper* is bounded. This is the only test
    // that encodes #205: the restart must happen whatever the kickstarts do.
    // A refactor that gates the relaunch on a clean exit, or routes a
    // timeout through fail(), reproduces the original bug exactly — and
    // every other test in this file would stay green.
    func test_restartSequence_relaunchesAndQuitsEvenWhenBothKickstartsHang() {
        var relaunched = false
        var quit = false
        var kicked: [String] = []

        var announced = false
        Updater.restartSequence(
            announce: { announced = true },
            kickstart: { label in kicked.append(label); return .timedOut },
            relaunch: { relaunched = true },
            quit: { quit = true })
        XCTAssertTrue(announced, "the restart was never announced to the UI")

        XCTAssertTrue(relaunched, "a hung kickstart stopped the new version from launching")
        XCTAssertTrue(quit, "a hung kickstart stopped the old process from quitting")
        XCTAssertEqual(kicked.count, 2, "both launchd labels should still be kicked")
    }

    // Same guarantee for the other failure shapes, since .timedOut is only
    // one of the ways a kickstart can come back unhappy.
    func test_restartSequence_relaunchesAndQuitsOnEveryKickstartOutcome() {
        for outcome: Updater.LaunchctlOutcome in [.exited(0), .exited(113),
                                                  .killedBySignal(9), .timedOut,
                                                  .failedToStart("boom")] {
            var relaunched = false
            var quit = false
            Updater.restartSequence(announce: {},
                                    kickstart: { _ in outcome },
                                    relaunch: { relaunched = true },
                                    quit: { quit = true })
            XCTAssertTrue(relaunched, "no relaunch after \(outcome)")
            XCTAssertTrue(quit, "no quit after \(outcome)")
        }
    }

    // MARK: - Reporting

    // terminationStatus carries the SIGNAL number when the child was killed,
    // so reporting it as an exit code would log a SIGKILLed launchctl as
    // "exited 9" in the one log a user ever sees.
    func test_runBounded_distinguishesASignalFromAnExitCode() {
        let outcome = Updater.runBounded("/bin/sh", ["-c", "kill -9 $$"], timeout: 10)
        XCTAssertEqual(outcome, .killedBySignal(SIGKILL))
    }

    // What the user actually waits through, named in one place.
    func test_restartStall_staysWithinItsBudget() {
        let twoKickstarts = Updater.boundedCallCeiling * 2
        XCTAssertLessThanOrEqual(twoKickstarts, 15,
                                 "worst-case restart stall is \(twoKickstarts)s")
    }
}
