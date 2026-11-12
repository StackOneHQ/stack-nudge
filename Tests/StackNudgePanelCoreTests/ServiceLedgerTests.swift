import XCTest
@testable import StackNudgePanelCore

final class ServiceLedgerTests: XCTestCase {

    private func ledger() -> ServiceLedger {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-ledger-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        return ServiceLedger(directory: directory)
    }

    private let start = ServiceLedger.ProcessStart(seconds: 1_794_400_000, microseconds: 123_456)
    private let later = ServiceLedger.ProcessStart(seconds: 1_794_400_000, microseconds: 123_457)

    // MARK: - Recording

    func testARunningServiceIsRecordedAndForgottenWhenItGoes() {
        let ledger = ledger()

        ledger.record(id: "away", pid: 4242, group: 4242, startTime: { _ in self.start })
        let recorded = ledger.records()
        ledger.forget(pid: 4242)

        XCTAssertEqual(recorded, [.init(id: "away", pid: 4242, group: 4242, started: start)])
        XCTAssertEqual(ledger.records(), [])
    }

    func testAProcessThatHasAlreadyExitedIsNotRecorded() {
        let ledger = ledger()

        ledger.record(id: "away", pid: 4242, group: 4242, startTime: { _ in nil })

        XCTAssertEqual(ledger.records(), [])
    }

    // MARK: - What counts as left over

    // A pid comes back into use, so the pid alone proves nothing: only the
    // same pid with the same start time is the process that was recorded.
    func testOnlyAProcessWithTheRecordedPidAndStartTimeIsALeftover() {
        let same = ServiceLedger.Record(id: "same", pid: 101, group: 101, started: start)
        let reused = ServiceLedger.Record(id: "reused", pid: 102, group: 102, started: start)
        let gone = ServiceLedger.Record(id: "gone", pid: 103, group: 103, started: start)
        let running: [pid_t: ServiceLedger.ProcessStart] = [101: start, 102: later]

        let actual = ServiceLedger.leftovers([same, reused, gone]) { running[$0] }

        XCTAssertEqual(actual, [same])
    }

    // MARK: - Reaping

    func testReapingStopsOnlyLeftoversAndClearsEveryRecord() {
        let ledger = ledger()
        let running: [pid_t: ServiceLedger.ProcessStart] = [101: start, 102: later]
        for pid: pid_t in [101, 102, 103] {
            ledger.record(id: "ext\(pid)", pid: pid, group: pid, startTime: { _ in self.start })
        }
        var sent: [String] = []

        let actual = ledger.reapLeftovers(startTime: { running[$0] },
                                          signal: { sent.append("\($0.pid) \($1)") },
                                          grace: 0.1, pause: { _ in })

        XCTAssertEqual(actual.map(\.id), ["ext101"])
        XCTAssertEqual(sent, ["101 \(SIGTERM)", "101 \(SIGKILL)"])
        XCTAssertEqual(ledger.records(), [])
    }

    // One that leaves on SIGTERM doesn't wait out the grace, and its group
    // still gets the SIGKILL, for anything it started.
    func testAServiceThatLeavesOnTermStillHasItsGroupKilled() {
        let ledger = ledger()
        ledger.record(id: "away", pid: 101, group: 101, startTime: { _ in self.start })
        var alive = true
        var pauses = 0
        var sent: [Int32] = []

        ledger.reapLeftovers(startTime: { _ in alive ? self.start : nil },
                             signal: { _, signal in sent.append(signal); if signal == SIGTERM { alive = false } },
                             grace: 5, pause: { _ in pauses += 1 })

        XCTAssertEqual(sent, [SIGTERM, SIGKILL])
        XCTAssertEqual(pauses, 1)
    }

    // Without a group of its own, the SIGKILL would go to a bare pid, which
    // may already be someone else's once the recorded process has gone.
    func testABarePidIsOnlyKilledWhileItIsStillTheOneRecorded() {
        let ledger = ledger()
        ledger.record(id: "away", pid: 101, group: -1, startTime: { _ in self.start })
        var alive = true
        var sent: [Int32] = []

        ledger.reapLeftovers(startTime: { _ in alive ? self.start : nil },
                             signal: { _, signal in sent.append(signal); if signal == SIGTERM { alive = false } },
                             grace: 0.1, pause: { _ in })

        XCTAssertEqual(sent, [SIGTERM])
    }

    func testNothingRecordedMeansNothingToStop() {
        var sent: [Int32] = []

        let actual = ledger().reapLeftovers(signal: { _, signal in sent.append(signal) },
                                            pause: { _ in XCTFail("waited with nothing to stop") })

        XCTAssertEqual(actual, [])
        XCTAssertEqual(sent, [])
    }

    // MARK: - With a real service

    // A service that ignores stdin EOF, as one left behind by a crash would,
    // and has started a helper. Reaping stops both, from the record alone.
    func testAStubbornServiceAndItsHelperAreStoppedFromTheRecord() throws {
        let ledger = ledger()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("helper.pid").path
        let run = dir.appendingPathComponent("run")
        try """
            #!/bin/sh
            sleep 300 >/dev/null 2>&1 &
            echo $! > "\(pidFile)"
            while :; do sleep 1; done
            """.write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
        let exited = DispatchSemaphore(value: 0)

        let process = try LiveServiceSpawner(recording: (ledger, "stubborn")).spawn(
            executable: run.path, directory: dir.path, environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { _ in }, onExit: { _ in exited.signal() })
        let recorded = ledger.records()
        let helper = Self.waitForPid(in: pidFile)
        let reaped = ledger.reapLeftovers()

        XCTAssertEqual(recorded.map(\.id), ["stubborn"])
        XCTAssertEqual(reaped.map(\.id), ["stubborn"])
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "the service outlived the reap")
        withExtendedLifetime(process) {}
        XCTAssertTrue(Self.waitUntilGone(helper), "the helper outlived the reap")
        XCTAssertEqual(ledger.records(), [])
    }

    func testAServiceThatExitsByItselfLeavesNoRecord() throws {
        let ledger = ledger()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let run = dir.appendingPathComponent("run")
        try "#!/bin/sh\nread line\nexit 0\n".write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
        let exited = DispatchSemaphore(value: 0)

        let process = try LiveServiceSpawner(recording: (ledger, "polite")).spawn(
            executable: run.path, directory: dir.path, environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { _ in }, onExit: { _ in exited.signal() })
        let whileRunning = ledger.records()
        process.write(Data("bye\n".utf8))

        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "never exited")
        XCTAssertEqual(whileRunning.map(\.id), ["polite"])
        XCTAssertEqual(ledger.records(), [])
    }

    private static func waitForPid(in file: String) -> pid_t {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            usleep(20_000)
        }
        return 0
    }

    // Kills it outright on the way out if it is still there, so a failing
    // test doesn't leave a `sleep` behind.
    private static func waitUntilGone(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        return false
    }
}
