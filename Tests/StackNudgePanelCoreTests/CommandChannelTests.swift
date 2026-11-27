import XCTest

@testable import StackNudgePanelCore

// The request/reply form of the panel socket: the router on its own, then the
// real listener and the stack-nudge CLI against it.
@MainActor
final class CommandChannelTests: XCTestCase {

    private final class Recorder {
        var posted: [NudgeEvent] = []
        var focus: Bool?
        var pose: PoseOverride?
        var settings: SettingsCategory??
        var busy: [BusyItem] = []
        var poll: ((@escaping (Int) -> Void) -> Void)?
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func router(_ recorder: Recorder) -> CommandRouter {
        var hooks = CommandHooks()
        hooks.post = { recorder.posted.append($0) }
        hooks.setFocus = { recorder.focus = $0 }
        hooks.focusStatus = { ["focus": recorder.focus ?? false, "held": 0] }
        hooks.poll = { recorder.poll }
        hooks.setPose = { recorder.pose = $0 }
        hooks.busy = { recorder.busy }
        hooks.openSettings = { category in
            recorder.settings = .some(category)
            return category ?? .notifications
        }
        hooks.now = { self.now }
        return CommandRouter(hooks: hooks)
    }

    private func run(_ router: CommandRouter, _ json: String) -> [String: Any] {
        var out = ""
        router.handle(Data(json.utf8)) { out = $0 }
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: - Detecting a command

    func test_isCommand_onlyALineWithACmdKey() {
        XCTAssertTrue(CommandRouter.isCommand(Data(#"{"cmd":"ping"}"#.utf8)))
        XCTAssertFalse(CommandRouter.isCommand(Data(#"{"agent":"claude-code","event":"stop","title":"x","message":"y"}"#.utf8)))
        XCTAssertFalse(CommandRouter.isCommand(Data("not json".utf8)))
        XCTAssertFalse(CommandRouter.isCommand(Data(#"{"cmd":5}"#.utf8)))
    }

    // MARK: - Commands

    func test_ping() {
        let reply = run(router(Recorder()), #"{"cmd":"ping"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["pong"] as? Bool, true)
    }

    func test_unknownCommandFails() {
        let reply = run(router(Recorder()), #"{"cmd":"nope"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "unknown command nope")
    }

    func test_say_postsAScriptFeedEvent() {
        let recorder = Recorder()
        let reply = run(router(recorder), #"{"cmd":"say","title":"Deploy done","body":"v2","url":"https://example.com/d","severity":"action","tag":"deploy","key":"deploy:1"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let event = recorder.posted.first
        XCTAssertEqual(recorder.posted.count, 1)
        XCTAssertEqual(event?.title, "Deploy done")
        XCTAssertEqual(event?.message, "v2")
        XCTAssertEqual(event?.source, .script)
        XCTAssertEqual(event?.kind, .other)
        XCTAssertEqual(event?.severity, .action)
        XCTAssertEqual(event?.tag, "deploy")
        XCTAssertEqual(event?.key, "deploy:1")
        XCTAssertEqual(event?.url?.absoluteString, "https://example.com/d")
    }

    func test_say_dropsANonWebLinkAndNeverMakesAnAgentEvent() {
        let recorder = Recorder()
        _ = run(router(recorder), #"{"cmd":"say","title":"x","url":"file:///etc/passwd"}"#)
        XCTAssertNil(recorder.posted.first?.url)
        XCTAssertTrue(recorder.posted.first?.isFeed ?? false)
    }

    func test_say_rejectsBadInput() {
        let recorder = Recorder()
        let r = router(recorder)
        XCTAssertEqual(run(r, #"{"cmd":"say"}"#)["ok"] as? Bool, false)
        XCTAssertEqual(run(r, #"{"cmd":"say","title":"x","severity":"loud"}"#)["ok"] as? Bool, false)
        XCTAssertEqual(run(r, #"{"cmd":"say","title":"x","source":"agent"}"#)["ok"] as? Bool, false)
        XCTAssertTrue(recorder.posted.isEmpty)
    }

    func test_focus_setsAndReadsState() {
        let recorder = Recorder()
        let r = router(recorder)
        XCTAssertEqual(run(r, #"{"cmd":"focus","state":"on"}"#)["ok"] as? Bool, true)
        XCTAssertEqual(recorder.focus, true)
        XCTAssertEqual(run(r, #"{"cmd":"focus","state":"off"}"#)["focus"] as? Bool, false)
        XCTAssertEqual(recorder.focus, false)
        recorder.focus = nil
        XCTAssertEqual(run(r, #"{"cmd":"focus"}"#)["ok"] as? Bool, true)
        XCTAssertNil(recorder.focus, "status must not change the state")
        XCTAssertEqual(run(r, #"{"cmd":"focus","state":"maybe"}"#)["ok"] as? Bool, false)
    }

    func test_poll_saysNoPollerUntilOneIsWired() {
        let recorder = Recorder()
        let r = router(recorder)
        XCTAssertEqual(run(r, #"{"cmd":"poll"}"#)["error"] as? String, "no poller")
        recorder.poll = { $0(3) }
        let reply = run(r, #"{"cmd":"poll"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["newEvents"] as? Int, 3)
    }

    func test_state_storesTheOverrideWithItsExpiry() {
        let recorder = Recorder()
        let reply = run(router(recorder), #"{"cmd":"state","state":"sleeping","ttlSeconds":120}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(recorder.pose, PoseOverride(pose: "sleeping", expiresAt: now.addingTimeInterval(120)))
    }

    func test_state_defaultsAndClampsTheTTL() {
        let recorder = Recorder()
        let r = router(recorder)
        _ = run(r, #"{"cmd":"state","state":"alert"}"#)
        XCTAssertEqual(recorder.pose?.expiresAt, now.addingTimeInterval(30))
        _ = run(r, #"{"cmd":"state","state":"alert","ttlSeconds":99999}"#)
        XCTAssertEqual(recorder.pose?.expiresAt, now.addingTimeInterval(3600))
        _ = run(r, #"{"cmd":"state","state":"alert","ttlSeconds":0}"#)
        XCTAssertEqual(recorder.pose?.expiresAt, now.addingTimeInterval(1))
        XCTAssertEqual(run(r, #"{"cmd":"state","state":"a b"}"#)["ok"] as? Bool, false)
        XCTAssertEqual(run(r, #"{"cmd":"state"}"#)["ok"] as? Bool, false)
    }

    func test_poseOverride_isActiveUntilItExpires() {
        let pose = PoseOverride(pose: "alert", expiresAt: now.addingTimeInterval(10))
        XCTAssertTrue(pose.isActive(at: now))
        XCTAssertFalse(pose.isActive(at: now.addingTimeInterval(10)))
    }

    func test_busy_reportsTheRegisteredSources() {
        let recorder = Recorder()
        let r = router(recorder)
        XCTAssertEqual(run(r, #"{"cmd":"busy"}"#)["busy"] as? Bool, false)
        recorder.busy = [BusyItem(kind: "session", target: "repo", since: nil)]
        let reply = run(r, #"{"cmd":"busy"}"#)
        XCTAssertEqual(reply["busy"] as? Bool, true)
        let items = reply["items"] as? [[String: String]]
        XCTAssertEqual(items?.first?["kind"], "session")
        XCTAssertEqual(items?.first?["target"], "repo")
    }

    func test_busySources_mergeAndSortProviders() {
        let sources = BusySources()
        sources.register("b") { [BusyItem(kind: "run", target: "z", since: nil)] }
        sources.register("a") { [BusyItem(kind: "poll", target: "", since: nil)] }
        XCTAssertEqual(sources.items().map(\.kind), ["poll", "run"])
    }

    func test_settings_opensACategoryAndRejectsAnUnknownOne() {
        let recorder = Recorder()
        let r = router(recorder)
        let reply = run(r, #"{"cmd":"settings","category":"focus"}"#)
        XCTAssertEqual(reply["current"] as? String, "focus")
        XCTAssertEqual(recorder.settings, .some(.focus))
        XCTAssertTrue((reply["categories"] as? [String])?.contains("voice") ?? false)
        _ = run(r, #"{"cmd":"settings"}"#)
        XCTAssertEqual(recorder.settings, .some(nil))
        XCTAssertEqual(run(r, #"{"cmd":"settings","category":"nope"}"#)["ok"] as? Bool, false)
    }

    // MARK: - Real socket

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        private var finished = false
        func finish(_ value: String?) { lock.lock(); stored = value; finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // Runs `work` off the main thread while this one keeps servicing the main
    // queue, which is where the listener hands commands to the router.
    private func offMain(_ work: @escaping @Sendable () -> String?) -> String? {
        let box = Box()
        DispatchQueue.global().async { box.finish(work()) }
        let deadline = Date().addingTimeInterval(10)
        while !box.isFinished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return box.value
    }

    private nonisolated static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { close(fd); return nil }
        return fd
    }

    // Next to this checkout's Tests directory; the no-Xcode runner stages the
    // test files elsewhere, but runs from the repo root.
    private static func cliScript() -> String {
        let beside = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("stack-nudge.sh").path
        if FileManager.default.fileExists(atPath: beside) { return beside }
        return FileManager.default.currentDirectoryPath + "/stack-nudge.sh"
    }

    private func startListener(_ recorder: Recorder) throws -> (EventListener, String, EventStore) {
        let path = "/tmp/sn-\(UUID().uuidString.prefix(8)).sock"
        let store = EventStore()
        let listener = EventListener(store: store, socketPath: path, commands: router(recorder))
        try listener.start()
        return (listener, path, store)
    }

    func test_socket_answersACommandWithoutTheClientClosing() throws {
        let (listener, path, _) = try startListener(Recorder())
        defer { listener.stop() }
        let reply = offMain {
            guard let fd = Self.connect(path) else { return nil }
            defer { close(fd) }
            let line = Array("{\"cmd\":\"ping\"}\n".utf8)
            _ = write(fd, line, line.count)
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(fd, &buf, buf.count)
            return n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : nil
        }
        XCTAssertEqual(reply, "{\"ok\":true,\"pong\":true}\n")
    }

    func test_socket_stillTakesAnEventThatClosesWithoutReading() throws {
        let (listener, path, store) = try startListener(Recorder())
        defer { listener.stop() }
        _ = offMain {
            guard let fd = Self.connect(path) else { return nil }
            let line = Array("{\"agent\":\"claude-code\",\"event\":\"stop\",\"title\":\"Done\",\"message\":\"ok\"}\n".utf8)
            _ = write(fd, line, line.count)
            close(fd)
            return "sent"
        }
        let deadline = Date().addingTimeInterval(5)
        while store.events.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.events.first?.title, "Done")
    }

    func test_cli_sendsCommandsThroughTheSocket() throws {
        let recorder = Recorder()
        let (listener, path, _) = try startListener(recorder)
        defer { listener.stop() }
        let script = Self.cliScript()

        let reply = offMain {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script, "say", "Deploy \"done\"", "--severity", "action", "--tag", "deploy"]
            process.environment = ["STACKNUDGE_SOCK": path, "PATH": "/usr/bin:/bin"]
            try? process.run()
            process.waitUntilExit()
            return String(process.terminationStatus)
        }
        XCTAssertEqual(reply, "0")
        XCTAssertEqual(recorder.posted.first?.title, "Deploy \"done\"")
        XCTAssertEqual(recorder.posted.first?.severity, .action)
        XCTAssertEqual(recorder.posted.first?.tag, "deploy")
    }

    func test_cli_exitsQuietlyForSayWhenThePanelIsDown() {
        let script = Self.cliScript()
        let status = offMain {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script, "focus", "on"]
            process.environment = ["STACKNUDGE_SOCK": "/tmp/sn-missing.sock", "PATH": "/usr/bin:/bin"]
            try? process.run()
            process.waitUntilExit()
            return String(process.terminationStatus)
        }
        XCTAssertEqual(status, "0")
    }
}
