import XCTest

@testable import StackNudgePanelCore

// The host's side of service extensions: which ones it runs and with what
// grant, where their documents and signals go, and when their processes stop.
// Real supervisors on the fake clock and spawner, driven through load() and the
// fake process, so these go through the same paths the app does.
@MainActor
final class ExtensionHostServiceTests: XCTestCase {

    private var spawner = FakeSpawner()
    private var clock = FakeScheduler()
    private var tiers: [String: ExtensionTier] = [:]
    private var fetches: [String] = []

    private func manifest(_ id: String, mode: String = "service", version: String = "1",
                          capabilities: [String] = [], glance: Bool = false) -> ExtensionManifest {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"\(id)","name":"\(id)","version":"\(version)","schema":2,"mode":"\(mode)",
             "capabilities":[\(list)],"glance":\(glance)}
            """.utf8)) else { fatalError("fixture manifest didn't parse") }
        return m
    }

    private func host(signals: SignalRegistry = SignalRegistry()) -> ExtensionHost {
        ExtensionHost(background: { $0() }, toMain: { $0() },
                      runner: { [unowned self] manifest, _, _ in
                          self.fetches.append(manifest.id)
                          return .transient("stub")
                      },
                      tiers: { [unowned self] in self.tiers },
                      signals: signals,
                      makeSupervisor: { [unowned self] manifest, granted, onEvent in
                          ServiceSupervisor.fake(id: manifest.id, granted: granted,
                                                 spawner: self.spawner, scheduler: self.clock,
                                                 onEvent: onEvent)
                      })
    }

    private func hello(_ process: FakeProcess) -> [String]? {
        process.messages.first?["capabilities"] as? [String]
    }

    // MARK: - Which ones run

    func testAServiceAtServiceTierRunsWithTheGrantItsTierAllows() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["event:idle", "signal:presence"])]))
        XCTAssertEqual(spawner.spawned("away").count, 1)
        XCTAssertEqual(hello(spawner.last), ["event:idle"])
        XCTAssertEqual(host.services["away"], .starting)
        XCTAssertEqual(host.manifests.map(\.id), ["away"])
    }

    // Its `run` was written to stay up, so it can't be run as a view instead.
    func testAServiceAtViewTierIsRefusedWithAReason() {
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        XCTAssertEqual(spawner.spawned.count, 0)
        XCTAssertEqual(host.manifests, [])
        XCTAssertEqual(host.refused.map(\.id), ["away"])
        XCTAssertTrue(host.refused.first?.reason.contains("service tier") == true,
                      host.refused.first?.reason ?? "")
    }

    // View extensions don't get a supervisor, whatever their tier, and still
    // fetch the way they always have.
    func testAViewExtensionIsUntouched() {
        tiers = ["derby": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("derby", mode: "view")]))
        XCTAssertEqual(spawner.spawned.count, 0)
        XCTAssertEqual(host.services, [:])
        host.tabAppeared("derby")
        XCTAssertEqual(fetches, ["derby"])
    }

    // Opening the tab, ⌘R and an action key all spawn `run` for a view. For a
    // service they'd start a second copy, so they do nothing.
    func testAServiceIsNeverRunAsAOneShotFetch() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"document","document":{"schema":1,"actions":[{"id":"go","label":"Go","key":"g"}]}}"#)
        host.tabAppeared("away")
        host.forceRefresh("away")
        XCTAssertFalse(host.handle(key: "g", on: "away"))
        host.tick(visibleTab: "away", now: Date().addingTimeInterval(3600))
        XCTAssertEqual(fetches, [])
        XCTAssertEqual(spawner.spawned.count, 1)
    }

    // MARK: - Documents

    func testADocumentFillsThePaneLikeAFetchDoes() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        XCTAssertEqual(host.pane("away").status, .loading)
        spawner.last.ready()
        spawner.last.document("At desk")
        XCTAssertEqual(host.pane("away").document?.header?.title, "At desk")
        XCTAssertEqual(host.pane("away").status, .idle)
        spawner.last.document("Away")
        XCTAssertEqual(host.pane("away").document?.header?.title, "Away")
    }

    func testAMalformedDocumentBreaksThePaneAsTheExtensionsBug() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"document","document":{"schema":7}}"#)
        guard case .broken = host.pane("away").status else {
            return XCTFail("\(host.pane("away").status)")
        }
    }

    // A crash keeps the last document and marks it stale while it restarts;
    // giving up says so, with the last exit status.
    func testACrashMarksTheDocumentStaleAndGivingUpBreaksThePane() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        spawner.last.ready()
        spawner.last.document("At desk")
        spawner.last.exit(.exited(2))
        XCTAssertEqual(host.pane("away").status, .stale("restarting in 1s"))
        XCTAssertEqual(host.pane("away").document?.header?.title, "At desk")
        for _ in 0..<4 {
            guard case .restarting(let delay) = host.services["away"] else {
                return XCTFail("\(String(describing: host.services["away"]))")
            }
            clock.advance(delay)
            spawner.last.exit(.exited(2))
        }
        XCTAssertEqual(host.services["away"], .broken(.exited(2)))
        guard case .broken(let why) = host.pane("away").status else {
            return XCTFail("\(host.pane("away").status)")
        }
        XCTAssertTrue(why.contains("exited 2"), why)
    }

    // A service sends a document when something changes, so its glance stays
    // fresh for as long as the process is up, not for a couple of intervals.
    func testAServicesGlanceGoesStaleWithItsProcessNotWithTime() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away", glance: true)]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"document","document":{"schema":1,"header":{"title":"Away","badge":{"text":"AWAY","tone":"warning"}}}}"#)
        XCTAssertEqual(host.glances(now: Date().addingTimeInterval(3600)).map(\.stale), [false])
        spawner.last.exit(.exited(1))
        XCTAssertEqual(host.glances(now: Date()).map(\.stale), [true])
    }

    // MARK: - Signals

    func testASignalFromTheHolderReachesTheRegistry() {
        tiers = ["away": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"])]))
        XCTAssertEqual(hello(spawner.last), ["signal:presence"])
        spawner.last.ready()
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        XCTAssertEqual(host.signals.value(.presence), "away")
        XCTAssertEqual(host.signals.holders[.presence], "away")
    }

    // Below trusted, signal:presence isn't granted, so the signal is refused
    // before it gets anywhere near the registry.
    func testASignalWithoutTheGrantChangesNothing() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"])]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        XCTAssertEqual(host.signals.value(.presence), "present")
        XCTAssertNil(host.signals.holders[.presence])
    }

    // With nobody on record, the first by id gets it, whatever order they
    // were found in, and the second isn't told it has it.
    func testWithNoRecordTheSignalGoesToTheFirstByID() {
        tiers = ["away": .trusted, "radar": .trusted]
        for order in [["away", "radar"], ["radar", "away"]] {
            spawner = FakeSpawner()
            let host = host()
            host.load(.init(installed: order.map { manifest($0, capabilities: ["signal:presence"]) }))
            XCTAssertEqual(host.signals.holders[.presence], "away", "\(order)")
            XCTAssertEqual(hello(spawner.spawned("radar")[0]), [])
            XCTAssertEqual(host.signals.refusals["radar"],
                           .heldByAnother(signal: "presence", holder: "away"))
        }
    }

    // On record, the holder keeps it across a relaunch even though another
    // extension would come first by id.
    func testTheRecordedHolderKeepsTheSignal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".signals.json").path
        try #"{"presence":"radar"}"#.write(toFile: path, atomically: true, encoding: .utf8)

        tiers = ["away": .trusted, "radar": .trusted]
        let host = host(signals: SignalRegistry(path: path))
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"]),
                                    manifest("radar", capabilities: ["signal:presence"])]))
        XCTAssertEqual(host.signals.holders[.presence], "radar")
        XCTAssertEqual(hello(spawner.spawned("radar")[0]), ["signal:presence"])
        XCTAssertEqual(hello(spawner.spawned("away")[0]), [])
    }

    // The holder removed: the record goes, and the one that was refused is
    // restarted with the signal it asked for.
    func testRemovingTheHolderHandsTheSignalToTheNextOne() {
        tiers = ["away": .trusted, "radar": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"]),
                                    manifest("radar", capabilities: ["signal:presence"])]))
        spawner.spawned.forEach { $0.ready() }
        host.load(.init(installed: [manifest("radar", capabilities: ["signal:presence"])]))
        XCTAssertNil(host.signals.holders[.presence])
        XCTAssertEqual(spawner.spawned("radar")[0].types.last, "stop")
        spawner.spawned("away")[0].exit(.exited(0))
        spawner.spawned("radar")[0].exit(.exited(0))
        XCTAssertEqual(spawner.spawned("radar").count, 2)
        XCTAssertEqual(hello(spawner.spawned("radar")[1]), ["signal:presence"])
        XCTAssertEqual(host.signals.holders[.presence], "radar")
    }

    func testACrashResetsTheSignalToNeutral() {
        tiers = ["away": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"])]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        spawner.last.exit(.signalled(SIGSEGV))
        XCTAssertEqual(host.signals.value(.presence), "present")
        XCTAssertEqual(host.signals.holders[.presence], "away")
    }

    // MARK: - Stopping

    // Removed: told to stop, and its signal is released at once rather than
    // when the process finally goes.
    func testRemovingAServiceStopsItAndReleasesItsSignal() {
        tiers = ["away": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence"])]))
        let process = spawner.last
        process.ready()
        process.say(#"{"type":"signal","name":"presence","value":"away"}"#)
        host.load(.init(installed: []))
        XCTAssertEqual(process.types.last, "stop")
        XCTAssertEqual(host.signals.value(.presence), "present")
        XCTAssertNil(host.signals.holders[.presence])
        XCTAssertNil(host.services["away"])
        process.exit(.exited(0))
        clock.advance(3600)
        XCTAssertEqual(spawner.spawned.count, 1)
        XCTAssertEqual(process.signals, [])
    }

    // Updated: the new version starts only once the old one has gone, so there
    // is never more than one process for an extension.
    func testAnUpdateStartsTheNewProcessOnlyAfterTheOldOneExits() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away", version: "1")]))
        let old = spawner.last
        old.ready()
        host.load(.init(installed: [manifest("away", version: "2")]))
        XCTAssertEqual(old.types.last, "stop")
        XCTAssertEqual(spawner.spawned.count, 1)
        clock.advance(5)
        XCTAssertEqual(old.signals, [SIGTERM, SIGKILL])
        old.exit(.signalled(SIGKILL))
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(host.services["away"], .starting)
    }

    // An unchanged reload leaves a running service alone.
    func testReloadingWithNothingChangedKeepsItRunning() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        spawner.last.ready()
        host.load(.init(installed: [manifest("away")]))
        XCTAssertEqual(spawner.spawned.count, 1)
        XCTAssertFalse(spawner.last.types.contains("stop"))
    }

    // A demotion takes effect at once: restarted with the smaller grant, or
    // stopped and refused when it no longer has the tier for service mode.
    func testAChangeOfTierRestartsWithTheNewGrant() {
        tiers = ["away": .trusted]
        let host = host()
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence", "event:idle"])]))
        spawner.last.ready()
        tiers = ["away": .service]
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence", "event:idle"])]))
        spawner.last.exit(.exited(0))
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(hello(spawner.last), ["event:idle"])

        spawner.last.ready()
        tiers = [:]
        host.load(.init(installed: [manifest("away", capabilities: ["signal:presence", "event:idle"])]))
        XCTAssertEqual(spawner.last.types.last, "stop")
        spawner.last.exit(.exited(0))
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(host.refused.map(\.id), ["away"])
    }

    // Quitting tells every service to stop and waits, bounded, for them to go;
    // nothing starts again after, even if something reloads. The fakes never
    // exit on their own, so the wait here runs out its (short) timeout.
    func testQuittingStopsEveryServiceAndStartsNothingAfter() {
        tiers = ["away": .service, "radar": .service]
        let host = host()
        host.load(.init(installed: [manifest("away"), manifest("radar")]))
        spawner.spawned.forEach { $0.ready() }
        let processes = spawner.spawned
        let began = Date()
        host.stopServices(waitingUpTo: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        XCTAssertTrue(processes.allSatisfy { $0.types.last == "stop" })
        processes.forEach { $0.exit(.exited(0)) }
        host.load(.init(installed: [manifest("away"), manifest("radar")]))
        XCTAssertEqual(spawner.spawned.count, 2)
        XCTAssertEqual(host.services, [:])
    }

    // MARK: - Tab keys

    func testAServiceTabOffersNoRefreshOrActionsUntilItBreaksThenRetry() {
        XCTAssertEqual(ExtensionHost.tabKeys(mode: .view, state: nil), .view)
        XCTAssertEqual(ExtensionHost.tabKeys(mode: .service, state: .running),
                       .init(refresh: nil, actions: false))
        XCTAssertEqual(ExtensionHost.tabKeys(mode: .service, state: .restarting(after: 4)),
                       .init(refresh: nil, actions: false))
        XCTAssertEqual(ExtensionHost.tabKeys(mode: .service, state: .broken(.exited(1))),
                       .init(refresh: "Retry", actions: false))
    }

    // Retry on a broken service starts a new process with a clean slate: one
    // more crash restarts it rather than counting as the sixth.
    func testRetryingABrokenServiceStartsItAfreshWithANewCrashWindow() {
        tiers = ["away": .service]
        let host = host()
        host.load(.init(installed: [manifest("away")]))
        host.forceRefresh("away")
        XCTAssertEqual(spawner.spawned.count, 1, "⌘R does nothing on a running service")
        for _ in 0..<5 {
            spawner.last.exit(.exited(2))
            if case .restarting(let delay) = host.services["away"] { clock.advance(delay) }
        }
        XCTAssertEqual(host.services["away"], .broken(.exited(2)))
        XCTAssertEqual(host.tabKeys("away").refresh, "Retry")
        host.forceRefresh("away")
        XCTAssertEqual(spawner.spawned.count, 6)
        XCTAssertEqual(host.services["away"], .starting)
        XCTAssertNil(host.tabKeys("away").refresh)
        spawner.last.exit(.exited(2))
        XCTAssertEqual(host.services["away"], .restarting(after: 1))
    }

    // MARK: - Quitting, on real queues

    // Supervisors that run on their own queue, as in the app. Quitting must
    // keep each one alive until its stop has finished: released early, it
    // deinits and SIGKILLs its process instead of sending `stop`. Inline
    // hops, as every other test here uses, can't see that.
    func testQuittingAsksEachServiceToStopEvenWhenSupervisorsRunOnTheirOwnQueue() {
        tiers = ["away": .service, "radar": .service]
        spawner.exitOnStop = true
        let queue = DispatchQueue(label: "host-quit-test")
        let lock = NSLock()
        var mainHops = 0
        let host = ExtensionHost(
            background: { $0() },
            // Never run: main is what's blocked in the wait, and nothing the
            // stop needs may depend on it.
            toMain: { _ in lock.lock(); mainHops += 1; lock.unlock() },
            runner: { _, _, _ in .transient("stub") },
            tiers: { [unowned self] in self.tiers },
            makeSupervisor: { [spawner, clock] manifest, granted, onEvent in
                ServiceSupervisor(id: manifest.id, directory: "/extensions/\(manifest.id)",
                                  granted: granted, environment: [:],
                                  executable: { "/extensions/\(manifest.id)/run" },
                                  spawner: spawner, scheduler: clock,
                                  perform: { queue.async(execute: $0) }, onEvent: onEvent)
            })
        host.load(.init(installed: [manifest("away"), manifest("radar")]))
        queue.sync {}
        let processes = queue.sync { spawner.spawned }
        XCTAssertEqual(processes.count, 2)

        let began = Date()
        host.stopServices(waitingUpTo: 5)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "a stop completion never came")
        queue.sync {}
        for process in processes {
            XCTAssertEqual(process.types, ["hello", "stop"])
            XCTAssertEqual(process.signals, [])
        }
        lock.lock(); XCTAssertGreaterThan(mainHops, 0); lock.unlock()
    }
}
