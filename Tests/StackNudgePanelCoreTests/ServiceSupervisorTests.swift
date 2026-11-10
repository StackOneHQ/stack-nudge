import XCTest

@testable import StackNudgePanelCore

// The supervisor's lifecycle, driven on a fake clock and a fake child: the
// handshake, liveness, restarts and when they stop, the stop sequence, and the
// message limits. One test at the end runs a real script through the real
// spawner, because the fakes can't show that pipes and process groups behave.
final class ServiceSupervisorTests: XCTestCase {

    private var spawner = FakeSpawner()
    private var clock = FakeScheduler()
    private var events: [ServiceSupervisor.Event] = []
    // Held for the length of the test. The fakes only keep it weakly, as the
    // real process does, so a test that dropped it would be talking to nobody.
    private var current: ServiceSupervisor?

    private func supervisor(granted: [ExtensionCapability] = [],
                            config: [String: String] = [:],
                            executable: String? = nil) -> ServiceSupervisor {
        let s = ServiceSupervisor.fake(granted: granted, config: config, spawner: spawner,
                                       scheduler: clock, executable: executable,
                                       onEvent: { [unowned self] in self.events.append($0) })
        current = s
        return s
    }

    // Started, and `ready` answered.
    private func running(granted: [ExtensionCapability] = []) -> ServiceSupervisor {
        let s = supervisor(granted: granted)
        s.start()
        spawner.last.ready()
        XCTAssertEqual(s.state, .running)
        return s
    }

    private var documents: [String] {
        events.compactMap { if case .document(let d) = $0 { return d.header?.title } else { return nil } }
    }

    private var degradations: [String] {
        events.compactMap { if case .degraded(let why) = $0 { return why } else { return nil } }
    }

    // MARK: - Handshake

    func testStartingSendsHelloWithOnlyTheGrantedCapabilities() {
        let s = supervisor(granted: [.eventIdle, .feed])
        s.start()
        XCTAssertEqual(spawner.spawned.count, 1)
        XCTAssertEqual(s.state, .starting)
        let hello = spawner.last.messages.first
        XCTAssertEqual(hello?["type"] as? String, "hello")
        XCTAssertEqual(hello?["protocol"] as? Int, ServiceProtocol.version)
        XCTAssertEqual(hello?["capabilities"] as? [String], ["event:idle", "feed"])
    }

    func testReadyMakesItRunningAndSendsTheConfig() {
        let s = supervisor(config: ["STACKNUDGE_EXT_AWAY_WAIT": "30"])
        s.start()
        spawner.last.ready()
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(spawner.last.types, ["hello", "config"])
        XCTAssertEqual(spawner.last.messages.last?["values"] as? [String: String],
                       ["STACKNUDGE_EXT_AWAY_WAIT": "30"])
    }

    // A change in Settings reaches a running service as a `config` message,
    // without a restart, and is what a later restart starts with.
    func testReconfiguringARunningServiceSendsTheNewConfig() {
        let s = supervisor(config: ["STACKNUDGE_EXT_AWAY_PHONE": "Pixel"])
        s.start()
        spawner.last.ready()
        s.reconfigure(environment: ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"],
                      config: ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])
        XCTAssertEqual(spawner.spawned.count, 1, "no restart")
        XCTAssertEqual(spawner.last.types, ["hello", "config", "config"])
        XCTAssertEqual(spawner.last.messages.last?["values"] as? [String: String],
                       ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])

        // The same values again say nothing new.
        s.reconfigure(environment: ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"],
                      config: ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])
        XCTAssertEqual(spawner.last.types.filter { $0 == "config" }.count, 2)

        spawner.last.exit()
        clock.advance(1)
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(spawner.last.environment["STACKNUDGE_EXT_AWAY_PHONE"], "Galaxy")
        spawner.last.ready()
        XCTAssertEqual(spawner.last.messages.last?["values"] as? [String: String],
                       ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])
    }

    // Before `ready` the config isn't sent early; `ready` sends the new one.
    func testReconfiguringBeforeReadyWaitsForReady() {
        let s = supervisor(config: ["STACKNUDGE_EXT_AWAY_PHONE": "Pixel"])
        s.start()
        s.reconfigure(environment: [:], config: ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])
        XCTAssertEqual(spawner.last.types, ["hello"])
        spawner.last.ready()
        XCTAssertEqual(spawner.last.messages.last?["values"] as? [String: String],
                       ["STACKNUDGE_EXT_AWAY_PHONE": "Galaxy"])
    }

    // Nothing counts before `ready`: a document printed first is dropped.
    func testNothingIsDeliveredBeforeReady() {
        let s = supervisor()
        s.start()
        spawner.last.document("early")
        XCTAssertEqual(documents, [])
        spawner.last.ready()
        spawner.last.document("on time")
        XCTAssertEqual(documents, ["on time"])
        XCTAssertEqual(s.state, .running)
    }

    func testNoReadyWithinTheHandshakeIsKilledAndRestarted() {
        let s = supervisor()
        s.start()
        clock.advance(9.9)
        XCTAssertEqual(spawner.last.signals, [])
        clock.advance(0.1)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
        spawner.last.exit(.signalled(SIGKILL))
        XCTAssertEqual(s.state, .restarting(after: 1))
        clock.advance(1)
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(s.state, .starting)
    }

    // Killed for not answering `hello`, five times over: still counted as
    // crashes, with the same backoff, but broken says why rather than
    // "killed by signal 9", which was only the host's own SIGKILL.
    func testRepeatedHandshakeTimeoutsBreakItSayingWhy() {
        let s = supervisor()
        s.start()
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            clock.advance(10)
            XCTAssertEqual(spawner.last.signals, [SIGKILL])
            spawner.last.exit(.signalled(SIGKILL))
            if case .restarting(let delay) = s.state {
                delays.append(delay)
                clock.advance(delay)
            }
        }
        XCTAssertEqual(delays, [1, 2, 4, 8])
        XCTAssertEqual(s.state, .broken(.unresponsive("didn't answer hello within 10 s")))
        XCTAssertEqual(ExtensionHost.brokenMessage(.unresponsive("didn't answer hello within 10 s")),
                       "stopped restarting after repeated crashes; the last one didn't answer hello within 10 s")
    }

    // The reason belongs to the process that was killed. One that then dies
    // on its own is reported as itself.
    func testAKillForSilenceDoesNotOutliveItsProcess() {
        let s = supervisor()
        s.start()
        for _ in 0..<4 {
            clock.advance(10)
            spawner.last.exit(.signalled(SIGKILL))
            guard case .restarting(let delay) = s.state else { return XCTFail("\(s.state)") }
            clock.advance(delay)
        }
        spawner.last.ready()
        spawner.last.exit(.exited(3))
        XCTAssertEqual(s.state, .broken(.exited(3)))
    }

    // A protocol this host doesn't speak won't be fixed by restarting.
    func testAnIncompatibleProtocolIsBrokenStraightAway() {
        let s = supervisor()
        s.start()
        spawner.last.say(#"{"type":"ready","protocol":2}"#)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
        spawner.last.exit(.signalled(SIGKILL))
        XCTAssertEqual(s.state, .broken(.incompatible(protocol: 2)))
        clock.advance(1000)
        XCTAssertEqual(spawner.spawned.count, 1)
    }

    func testAMissingExecutableIsBrokenWithoutSpawning() {
        let s = supervisor(executable: "")
        s.start()
        XCTAssertEqual(spawner.spawned.count, 0)
        guard case .broken(.failedToStart) = s.state else { return XCTFail("\(s.state)") }
    }

    func testASpawnFailureIsBrokenRatherThanRetried() {
        spawner.refuse = true
        let s = supervisor()
        s.start()
        guard case .broken(.failedToStart) = s.state else { return XCTFail("\(s.state)") }
        clock.advance(1000)
        guard case .broken = s.state else { return XCTFail("\(s.state)") }
    }

    // MARK: - Crashes and backoff

    func testBackoffDoublesFromOneSecondAndCapsAtFiveMinutes() {
        XCTAssertEqual((1...11).map { ServiceSupervisor.backoff(after: $0) },
                       [1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        XCTAssertEqual(ServiceSupervisor.backoff(after: 10_000), 300)
    }

    // Each restart waits twice as long as the last, and the fifth crash inside
    // ten minutes gives up, keeping the last exit status to show.
    func testFiveCrashesInTenMinutesIsBroken() {
        let s = running()
        var delays: [TimeInterval] = []
        for status in Int32(1)...4 {
            spawner.last.exit(.exited(status))
            guard case .restarting(let delay) = s.state else { return XCTFail("\(s.state)") }
            delays.append(delay)
            clock.advance(delay)
            spawner.last.ready()
        }
        XCTAssertEqual(delays, [1, 2, 4, 8])
        spawner.last.exit(.exited(5))
        XCTAssertEqual(s.state, .broken(.exited(5)))
        clock.advance(3600)
        XCTAssertEqual(spawner.spawned.count, 5)
    }

    // Spread out, the same crashes never add up to five in the window, so it
    // keeps restarting, and the backoff keeps growing because it never stays
    // up long enough to count as recovered.
    func testCrashesSpreadOverMoreThanTenMinutesKeepRestartingWithGrowingBackoff() {
        let s = running()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            clock.advance(200)
            spawner.last.exit(.exited(1))
            guard case .restarting(let delay) = s.state else { return XCTFail("\(s.state)") }
            delays.append(delay)
            clock.advance(delay)
            spawner.last.ready()
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 64, 128])
        XCTAssertEqual(s.state, .running)
    }

    // A process that stayed up for a whole window has recovered, so its next
    // crash starts the backoff again from one second.
    func testBackoffResetsAfterAWholeWindowUp() {
        let s = running()
        for _ in 0..<3 {
            spawner.last.exit(.exited(1))
            guard case .restarting(let delay) = s.state else { return XCTFail("\(s.state)") }
            clock.advance(delay)
            spawner.last.ready()
        }
        // Answering pings throughout, so it isn't killed as a hang.
        for _ in 0..<21 {
            clock.advance(30)
            spawner.last.pongLastPing()
        }
        spawner.last.exit(.exited(1))
        XCTAssertEqual(s.state, .restarting(after: 1))
    }

    // MARK: - Liveness

    func testAPingUnansweredWithinTenSecondsIsAHang() {
        let s = running()
        clock.advance(30)
        XCTAssertEqual(spawner.last.types.last, "ping")
        clock.advance(9.9)
        XCTAssertEqual(spawner.last.signals, [])
        clock.advance(0.1)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
        spawner.last.exit(.signalled(SIGKILL))
        XCTAssertEqual(s.state, .restarting(after: 1))
        clock.advance(1)
        XCTAssertEqual(spawner.spawned.count, 2)
    }

    func testRepeatedPongTimeoutsBreakItSayingWhy() {
        let s = running()
        for _ in 0..<5 {
            clock.advance(30 + 10)
            XCTAssertEqual(spawner.last.signals, [SIGKILL])
            spawner.last.exit(.signalled(SIGKILL))
            if case .restarting(let delay) = s.state {
                clock.advance(delay)
                spawner.last.ready()
            }
        }
        XCTAssertEqual(s.state, .broken(.unresponsive("stopped answering pings (no pong within 10 s)")))
    }

    func testAnsweredPingsKeepItRunning() {
        let s = running()
        for _ in 0..<5 {
            clock.advance(30)
            spawner.last.pongLastPing()
        }
        clock.advance(29)
        XCTAssertEqual(spawner.last.signals, [])
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(spawner.last.types.filter { $0 == "ping" }.count, 5)
    }

    // A pong for a ping that isn't the outstanding one doesn't count.
    func testAPongWithTheWrongIDDoesNotCount() {
        _ = running()
        clock.advance(30)
        spawner.last.say(#"{"type":"pong","id":999}"#)
        clock.advance(10)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
    }

    // The Mac slept between the ping and its timeout, so the timeout fires
    // late. That one is forgiven with a fresh ping; the next one isn't.
    func testAMissedPongAcrossASleepIsForgivenOnce() {
        _ = running()
        clock.advance(30)
        clock.sleep(3600)
        clock.advance(0)
        XCTAssertEqual(spawner.last.signals, [])
        XCTAssertEqual(spawner.last.types.filter { $0 == "ping" }.count, 2)
        clock.advance(10)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
    }

    // MARK: - Stopping

    func testStopAsksThenTerminatesThenKills() {
        let s = running()
        var stopped = false
        s.stop { stopped = true }
        XCTAssertEqual(s.state, .stopping)
        XCTAssertEqual(spawner.last.types.last, "stop")
        clock.advance(2.9)
        XCTAssertEqual(spawner.last.signals, [])
        clock.advance(0.1)
        XCTAssertEqual(spawner.last.signals, [SIGTERM])
        clock.advance(2)
        XCTAssertEqual(spawner.last.signals, [SIGTERM, SIGKILL])
        XCTAssertFalse(stopped)
        spawner.last.exit(.signalled(SIGKILL))
        XCTAssertTrue(stopped)
        XCTAssertEqual(s.state, .stopped)
        clock.advance(3600)
        XCTAssertEqual(spawner.spawned.count, 1)
    }

    // The usual case: it reads `stop` and exits. Nothing is signalled after,
    // and the exit isn't taken for a crash.
    func testAnExitDuringStopFinishesItWithoutSignalsOrARestart() {
        let s = running()
        var stopped = 0
        s.stop { stopped += 1 }
        spawner.last.exit(.exited(0))
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(s.state, .stopped)
        clock.advance(3600)
        XCTAssertEqual(spawner.last.signals, [])
        XCTAssertEqual(spawner.spawned.count, 1)
    }

    func testStopWhileRestartingCancelsTheRestart() {
        let s = running()
        spawner.last.exit(.exited(1))
        var stopped = false
        s.stop { stopped = true }
        XCTAssertTrue(stopped)
        XCTAssertEqual(s.state, .stopped)
        clock.advance(3600)
        XCTAssertEqual(spawner.spawned.count, 1)
    }

    func testStopAskedTwiceCompletesBoth() {
        let s = running()
        var stopped = 0
        s.stop { stopped += 1 }
        s.stop { stopped += 1 }
        spawner.last.exit(.exited(0))
        XCTAssertEqual(stopped, 2)
        XCTAssertEqual(spawner.last.types.filter { $0 == "stop" }.count, 1)
    }

    // A process that has already been replaced can't speak for its successor:
    // its late exit doesn't start another restart, and its output is ignored.
    func testALateExitFromAReplacedProcessIsIgnored() {
        let s = running()
        let first = spawner.last
        first.exit(.exited(1))
        clock.advance(1)
        spawner.last.ready()
        first.exit(.exited(1))
        first.document("ghost")
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(documents, [])
    }

    // A supervisor released while its stop is still waiting on the process
    // kills it, and completes the stop rather than dropping it, so a caller
    // waiting on that completion isn't left hanging.
    func testASupervisorReleasedMidStopKillsAndStillCompletes() {
        var s: ServiceSupervisor? = supervisor()
        s?.start()
        spawner.last.ready()
        var completions = 0
        s?.stop { completions += 1 }
        XCTAssertEqual(completions, 0)
        current = nil
        s = nil
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(spawner.last.signals, [SIGKILL])
    }

    // MARK: - Messages

    func testDocumentsAndGrantedSignalsAndFeedAreDelivered() {
        _ = running(granted: [.signalPresence, .feed])
        spawner.last.document("hello")
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        spawner.last.say(#"{"type":"feed","event":{"title":"Left"}}"#)
        XCTAssertEqual(documents, ["hello"])
        XCTAssertTrue(events.contains(.signal(name: "presence", value: "away")))
        XCTAssertTrue(events.contains { if case .feed = $0 { return true } else { return false } })
    }

    func testSignalsAndFeedWithoutTheirGrantAreRefused() {
        _ = running()
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        spawner.last.say(#"{"type":"feed","event":{"title":"Left"}}"#)
        XCTAssertFalse(events.contains { if case .signal = $0 { return true } else { return false } })
        XCTAssertFalse(events.contains { if case .feed = $0 { return true } else { return false } })
        XCTAssertEqual(events.filter { if case .problem = $0 { return true } else { return false } }.count, 2)
    }

    func testAnEventReachesOnlyARunningExtensionThatWasGrantedIt() {
        let s = supervisor(granted: [.eventIdle])
        s.start()
        s.send(event: "idle", fields: ["seconds": .int(42)])
        XCTAssertEqual(spawner.last.types, ["hello"])
        spawner.last.ready()
        s.send(event: "idle", fields: ["seconds": .int(42)])
        s.send(event: "panel", fields: ["open": .bool(true)])
        let sent = spawner.last.messages.filter { $0["type"] as? String == "event" }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["name"] as? String, "idle")
        XCTAssertEqual(sent.first?["seconds"] as? Int, 42)
    }

    func testAMalformedDocumentIsReportedAsTheExtensionsBug() {
        _ = running()
        spawner.last.say(#"{"type":"document","document":{"schema":9}}"#)
        XCTAssertTrue(events.contains { if case .malformedDocument = $0 { return true } else { return false } })
    }

    // 20 a second on average: a burst of 20 is fine, the rest of a flood is
    // dropped, the drop is reported once, and the allowance comes back.
    func testMessagesPastTheRateLimitAreDroppedAndMarkTheExtensionDegraded() {
        let s = running()
        // `ready` spent one of the burst.
        let flood = (0..<30).map { #"{"type":"document","document":{"schema":1,"header":{"title":"\#($0)"}}}"# }
        spawner.last.output(Data((flood.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(documents.count, 19)
        XCTAssertEqual(degradations.count, 1)
        XCTAssertTrue(s.degraded)
        XCTAssertEqual(s.state, .running)
        clock.advance(1)
        spawner.last.output(Data((flood.prefix(5).joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(documents.count, 24)
        XCTAssertEqual(degradations.count, 1)
    }

    // A pong is never charged: a service flooding the host loses messages,
    // but answering a ping in the middle of the flood still keeps it alive.
    func testAPongInAFloodStillCountsSoTheFloodIsNotTakenForAHang() {
        let s = running()
        clock.advance(30)
        let ping = spawner.last.messages.last { $0["type"] as? String == "ping" }
        let id = ping?["id"] as? Int ?? -1
        var lines = (0..<40).map { #"{"type":"document","document":{"schema":1,"header":{"title":"\#($0)"}}}"# }
        lines.append(#"{"type":"pong","id":\#(id)}"#)
        spawner.last.output(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertTrue(s.degraded)
        clock.advance(10)
        XCTAssertEqual(spawner.last.signals, [])
        XCTAssertEqual(s.state, .running)
    }

    func testAnOversizedControlLineIsDroppedAndMarksItDegraded() {
        let s = running(granted: [.signalPresence])
        let padding = String(repeating: "x", count: ServiceProtocol.maxLineBytes)
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away","pad":"\#(padding)"}"#)
        XCTAssertFalse(events.contains { if case .signal = $0 { return true } else { return false } })
        XCTAssertEqual(degradations.count, 1)
        XCTAssertTrue(s.degraded)
    }

    // MARK: - A real process

    // The one test that spawns: a shell script through the real spawner, real
    // pipes and real time. It checks what the fakes stand in for: that `hello`
    // reaches stdin, a document comes back on stdout, the environment says
    // service mode, `stop` ends it, and a child it left running dies with it.
    func testARealScriptHandshakesSendsADocumentAndStops() throws {
        let shell = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid").path
        let run = dir.appendingPathComponent("run")
        try """
            #!/bin/sh
            sleep 300 >/dev/null 2>&1 &
            echo $! > "\(pidFile)"
            read hello
            case "$hello" in *'"hello"'*) ;; *) exit 3 ;; esac
            echo '{"type":"ready","protocol":1}'
            echo '{"type":"document","document":{"schema":1,"header":{"title":"'"$STACKNUDGE_EXT_MODE"'"}}}'
            while read line; do
              case "$line" in *'"stop"'*) exit 0 ;; esac
            done
            """.write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)

        guard case .success(let manifest) = ExtensionManifest.parse(Data("""
            {"id":"probe","name":"Probe","version":"1","schema":2,"mode":"service"}
            """.utf8)) else { return XCTFail("fixture manifest didn't parse") }

        let lock = NSLock()
        var seen: [ServiceSupervisor.Event] = []
        let gotDocument = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "service-test")
        let supervisor = ServiceSupervisor(
            id: "probe", directory: dir.path, granted: [],
            environment: ExtensionRuntime.serviceEnvironment(for: manifest, config: [:]),
            executable: { ExtensionRuntime.resolveExecutable(manifest, in: dir.path) },
            spawner: LiveServiceSpawner(),
            scheduler: DispatchServiceScheduler(queue: queue),
            perform: { queue.async(execute: $0) },
            onEvent: { event in
                lock.lock(); seen.append(event); lock.unlock()
                if case .document = event { gotDocument.signal() }
            })

        supervisor.start()
        XCTAssertEqual(gotDocument.wait(timeout: .now() + 10), .success, "no document")
        lock.lock()
        let title = seen.compactMap { event -> String? in
            if case .document(let d) = event { return d.header?.title } else { return nil }
        }.first
        lock.unlock()
        XCTAssertEqual(title, "service")

        let stopped = DispatchSemaphore(value: 0)
        let began = Date()
        supervisor.stop { stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 10), .success, "never stopped")
        // It read `stop` and left by itself, well inside the 3 s grace.
        XCTAssertLessThan(Date().timeIntervalSince(began), 2.5)
        lock.lock()
        let states = seen.compactMap { event -> ServiceSupervisor.State? in
            if case .state(let s) = event { return s } else { return nil }
        }
        lock.unlock()
        XCTAssertEqual(states, [.starting, .running, .stopping, .stopped])

        // The backgrounded `sleep` was in its group, so it went too.
        let child = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        XCTAssertGreaterThan(child, 0)
        var alive = child > 0
        let deadline = Date().addingTimeInterval(3)
        while alive, Date() < deadline {
            alive = kill(child, 0) == 0
            if alive { usleep(20_000) }
        }
        if alive { kill(child, SIGKILL) }
        XCTAssertFalse(alive, "the extension's child outlived it")
    }

    // A real `run` that reads `hello` and never answers. The host kills it
    // when the handshake runs out, and the broken reason names the handshake,
    // not the signal the host sent.
    func testARealProbeThatNeverSendsReadyIsBrokenForTheHandshake() throws {
        let shell = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let run = dir.appendingPathComponent("run")
        try """
            #!/bin/sh
            read hello
            while read line; do :; done
            """.write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)

        var timing = ServiceSupervisor.Timing()
        timing.handshake = 0.3
        timing.crashLimit = 1
        let lock = NSLock()
        var broken: ServiceSupervisor.Termination?
        let gaveUp = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "service-test")
        let supervisor = ServiceSupervisor(
            id: "probe", directory: dir.path, granted: [],
            environment: ["PATH": "/usr/bin:/bin"], timing: timing,
            executable: { run.path },
            spawner: LiveServiceSpawner(),
            scheduler: DispatchServiceScheduler(queue: queue),
            perform: { queue.async(execute: $0) },
            onEvent: { event in
                guard case .state(.broken(let why)) = event else { return }
                lock.lock(); broken = why; lock.unlock()
                gaveUp.signal()
            })
        supervisor.start()
        XCTAssertEqual(gaveUp.wait(timeout: .now() + 10), .success, "never gave up")
        lock.lock()
        XCTAssertEqual(broken, .unresponsive("didn't answer hello within 0.3 s"))
        lock.unlock()
    }

    // A `run` that backgrounds a helper and dies at once. The exit can beat
    // the spawner to recording the process group, and the group has to be
    // cleaned up regardless, or the helper runs on with nobody to stop it.
    func testAHelperLeftByAServiceThatExitsAtOnceIsKilled() throws {
        let shell = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("child.pid").path
        let run = dir.appendingPathComponent("run")
        try """
            #!/bin/sh
            sleep 300 >/dev/null 2>&1 &
            echo $! > "\(pidFile)"
            exit 1
            """.write(to: run, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)

        let exited = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var termination: ServiceSupervisor.Termination?
        let process = try LiveServiceSpawner().spawn(
            executable: run.path, directory: dir.path, environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { _ in },
            onExit: { t in lock.lock(); termination = t; lock.unlock(); exited.signal() })
        XCTAssertEqual(exited.wait(timeout: .now() + 10), .success, "never exited")
        withExtendedLifetime(process) {}
        lock.lock(); XCTAssertEqual(termination, .exited(1)); lock.unlock()

        let child = Self.pid(in: pidFile)
        XCTAssertGreaterThan(child, 0)
        XCTAssertTrue(Self.waitUntilGone(child), "the helper outlived the service")
    }

    private static func pid(in file: String) -> pid_t {
        pid_t((try? String(contentsOfFile: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    // Polls, since an orphan killed by signal is reaped by launchd a moment
    // later. Kills it outright on the way out if it is still there, so a
    // failing test doesn't leave a `sleep` behind either.
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
