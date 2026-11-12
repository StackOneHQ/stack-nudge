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
    private let appStart = ServiceLedger.ProcessStart(seconds: 1_794_300_000, microseconds: 1)
    private let deadApp: pid_t = 900
    private let liveApp: pid_t = 901

    private func identity(_ pid: pid_t, _ started: ServiceLedger.ProcessStart) -> ServiceLedger.Identity {
        .init(pid: pid, started: started)
    }

    // Writes a record for `pid` as started by `owner`, both at the fixture times.
    private func recordService(_ ledger: ServiceLedger, _ pid: pid_t, group: pid_t? = nil,
                               owner: pid_t? = nil) {
        let owner = owner ?? deadApp
        ledger.record(id: "ext\(pid)", pid: pid, group: group ?? pid, owner: owner,
                      startTime: { $0 == owner ? self.appStart : self.start })
    }

    // MARK: - Recording

    func testARunningServiceIsRecordedWithItsOwnerAndForgottenWhenItGoes() {
        let ledger = ledger()

        let written = ledger.record(id: "away", pid: 4242, group: 4242, owner: deadApp,
                                    startTime: { $0 == self.deadApp ? self.appStart : self.start })
        let recorded = ledger.records()
        written.map(ledger.forget)

        XCTAssertEqual(recorded, [.init(id: "away", process: identity(4242, start), group: 4242,
                                        owner: identity(deadApp, appStart))])
        XCTAssertEqual(ledger.records(), [])
    }

    func testAProcessThatHasAlreadyExitedIsNotRecorded() {
        let ledger = ledger()

        ledger.record(id: "away", pid: 4242, group: 4242, owner: deadApp,
                      startTime: { $0 == self.deadApp ? self.appStart : nil })

        XCTAssertEqual(ledger.records(), [])
    }

    // Forgetting a process that has exited must not take the record of a
    // newer one that was handed the same pid.
    func testForgettingAnOldProcessKeepsANewerOneWithTheSamePid() {
        let ledger = ledger()
        let old = ledger.record(id: "away", pid: 4242, group: 4242, owner: deadApp,
                                startTime: { $0 == self.deadApp ? self.appStart : self.start })
        ledger.record(id: "away", pid: 4242, group: 4242, owner: deadApp,
                      startTime: { $0 == self.deadApp ? self.appStart : self.later })

        old.map(ledger.forget)

        XCTAssertEqual(ledger.records().map(\.process), [identity(4242, later)])
    }

    // MARK: - What counts as left over

    // A pid comes back into use, so the pid alone proves nothing: only the
    // same pid with the same start time is the process that was recorded,
    // and only when the app that started it has gone.
    func testALeftoverIsTheRecordedProcessWhoseOwnerHasGone() {
        func record(_ id: String, _ pid: pid_t, owner: pid_t) -> ServiceLedger.Record {
            .init(id: id, process: identity(pid, start), group: pid, owner: identity(owner, appStart))
        }
        let left = record("left", 101, owner: deadApp)
        let reused = record("reused", 102, owner: deadApp)
        let gone = record("gone", 103, owner: deadApp)
        let anotherCopys = record("another copy's", 104, owner: liveApp)
        let running: [pid_t: ServiceLedger.ProcessStart] = [101: start, 102: later, 104: start,
                                                            liveApp: appStart]

        let actual = ServiceLedger.leftovers([left, reused, gone, anotherCopys]) { running[$0] }

        XCTAssertEqual(actual, [left])
    }

    // MARK: - Reaping

    func testReapingStopsOnlyLeftoversAndClearsTheirRecords() {
        let ledger = ledger()
        for pid: pid_t in [101, 102, 103] { recordService(ledger, pid) }
        var running: [pid_t: ServiceLedger.ProcessStart] = [101: start, 102: later]
        var sent: [String] = []

        let actual = ledger.reapLeftovers(startTime: { running[$0] },
                                          signal: { record, signal in
                                              sent.append("\(record.process.pid) \(signal)")
                                              if signal == SIGKILL { running[record.process.pid] = nil }
                                          },
                                          grace: 0.1, pause: { _ in })

        XCTAssertEqual(actual.map(\.id), ["ext101"])
        XCTAssertEqual(sent, ["101 \(SIGTERM)", "101 \(SIGKILL)"])
        XCTAssertEqual(ledger.records(), [])
    }

    // A dev build launched beside the installed app shares the directory.
    // The installed app's services are live, not left over, and keep their
    // records.
    func testAnotherRunningCopysServicesAreLeftAlone() {
        let ledger = ledger()
        recordService(ledger, 101, owner: liveApp)
        let running: [pid_t: ServiceLedger.ProcessStart] = [101: start, liveApp: appStart]
        var sent: [Int32] = []

        let actual = ledger.reapLeftovers(startTime: { running[$0] },
                                          signal: { _, signal in sent.append(signal) },
                                          grace: 0.1, pause: { _ in })

        XCTAssertEqual(actual, [])
        XCTAssertEqual(sent, [])
        XCTAssertEqual(ledger.records().map(\.process.pid), [101])
    }

    // One that leaves on SIGTERM doesn't wait out the grace, and its group
    // still gets the SIGKILL, for anything it started.
    func testAServiceThatLeavesOnTermStillHasItsGroupKilled() {
        let ledger = ledger()
        recordService(ledger, 101)
        var alive = true
        var pauses = 0
        var sent: [Int32] = []

        ledger.reapLeftovers(startTime: { $0 == 101 && alive ? self.start : nil },
                             signal: { _, signal in sent.append(signal); if signal == SIGTERM { alive = false } },
                             grace: 5, pause: { _ in pauses += 1 })

        XCTAssertEqual(sent, [SIGTERM, SIGKILL])
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(ledger.records(), [])
    }

    // Without a group of its own, the SIGKILL would go to a bare pid, which
    // may already be someone else's once the recorded process has gone.
    func testABarePidIsOnlyKilledWhileItIsStillTheOneRecorded() {
        let ledger = ledger()
        recordService(ledger, 101, group: -1)
        var alive = true
        var sent: [Int32] = []

        ledger.reapLeftovers(startTime: { $0 == 101 && alive ? self.start : nil },
                             signal: { _, signal in sent.append(signal); if signal == SIGTERM { alive = false } },
                             grace: 0.1, pause: { _ in })

        XCTAssertEqual(sent, [SIGTERM])
    }

    // Still there straight after the SIGKILL: kept, so the next launch
    // checks it again rather than forgetting it.
    func testAProcessStillThereAfterTheKillKeepsItsRecord() {
        let ledger = ledger()
        recordService(ledger, 101)

        ledger.reapLeftovers(startTime: { $0 == 101 ? self.start : nil },
                             signal: { _, _ in }, grace: 0.1, pause: { _ in })

        XCTAssertEqual(ledger.records().map(\.process.pid), [101])
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
    // and has started a helper. It was recorded by this test process, which is
    // still running, so it is played here as gone: reaping then stops both,
    // from the record alone.
    func testAStubbornServiceAndItsHelperAreStoppedFromTheRecord() throws {
        let ledger = ledger()
        let (run, pidFile) = try stubbornService()
        let exited = DispatchSemaphore(value: 0)
        let appGone: (pid_t) -> ServiceLedger.ProcessStart? = {
            $0 == getpid() ? nil : ServiceLedger.startTime(of: $0)
        }

        let process = try LiveServiceSpawner(recording: (ledger, "stubborn")).spawn(
            executable: run.path, directory: run.deletingLastPathComponent().path,
            environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { _ in }, onExit: { _ in exited.signal() })
        let recorded = ledger.records()
        let helper = Self.waitForPid(in: pidFile)
        let reaped = ledger.reapLeftovers(startTime: appGone)

        XCTAssertEqual(recorded.map(\.id), ["stubborn"])
        XCTAssertEqual(recorded.map(\.owner.pid), [getpid()])
        XCTAssertEqual(reaped.map(\.id), ["stubborn"])
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "the service outlived the reap")
        withExtendedLifetime(process) {}
        XCTAssertTrue(Self.waitUntilGone(helper), "the helper outlived the reap")
        XCTAssertEqual(ledger.records(), [])
    }

    // The same service while its owner, this test process, is still running,
    // as another copy of the app would see it: left alone.
    func testALiveCopysServiceIsNotReaped() throws {
        let ledger = ledger()
        let (run, pidFile) = try stubbornService()
        let exited = DispatchSemaphore(value: 0)

        let process = try LiveServiceSpawner(recording: (ledger, "stubborn")).spawn(
            executable: run.path, directory: run.deletingLastPathComponent().path,
            environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { _ in }, onExit: { _ in exited.signal() })
        let helper = Self.waitForPid(in: pidFile)
        let reaped = ledger.reapLeftovers()
        let stillRunning = exited.wait(timeout: .now() + 0.5) == .timedOut
        let recordKept = ledger.records().map(\.id)
        process.signal(SIGKILL)

        XCTAssertEqual(reaped, [])
        XCTAssertTrue(stillRunning, "a live copy's service was stopped")
        XCTAssertEqual(recordKept, ["stubborn"])
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "never exited")
        XCTAssertTrue(Self.waitUntilGone(helper), "the helper outlived its service")
    }

    private func stubbornService() throws -> (run: URL, pidFile: String) {
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
        return (run, pidFile)
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
