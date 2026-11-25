import XCTest

@testable import StackNudgePanelCore

// The local MCP server: the protocol core against a fake app, the bridge's
// pure parts, the settings registry, and one real round trip over a socket.
final class MCPSessionTests: XCTestCase {

    final class FakeContext: MCPContext {
        var serverVersion = "9.9.9"
        var settingsList: [SettingSnapshot] = [
            SettingSnapshot(key: "STACKNUDGE_VOICE", label: "Voice notifications", category: "voice",
                            value: .bool(true), kindJSON: ["type": "boolean"], readOnlyReason: nil),
            SettingSnapshot(key: "STACKNUDGE_BANNER", label: "Banner notifications", category: "notifications",
                            value: .bool(true), kindJSON: ["type": "boolean"],
                            readOnlyReason: SettingsRegistry.protectsPrompts),
        ]
        var sessionsList: [[String: Any]] = [["pid": 42, "agent": "claude", "waitingOnUser": true]]
        var written: [(String, Any, MCPCaller)] = []
        var nudges: [(MCPNudge.Request, MCPCaller)] = []
        var mutes: [Int] = []
        func settings() -> [SettingSnapshot] { settingsList }
        func sessions() -> [[String: Any]] { sessionsList }
        func writeSetting(key: String, value: Any, caller: MCPCaller) -> Result<SettingSnapshot, SettingsRegistry.WriteFailure> {
            written.append((key, value, caller))
            guard let setting = settingsList.first(where: { $0.key == key }) else { return .failure(.unknownKey(key)) }
            if let reason = setting.readOnlyReason { return .failure(.readOnly(reason)) }
            return .success(setting)
        }
        func raiseNudge(_ request: MCPNudge.Request, caller: MCPCaller) { nudges.append((request, caller)) }
        func mute(minutes: Int, caller: MCPCaller) -> String { mutes.append(minutes); return "ok" }
    }

    private var sent: [[String: Any]] = []
    private var context = FakeContext()

    private func session(_ caller: MCPCaller = MCPCaller()) -> MCPSession {
        sent = []
        context = FakeContext()
        return MCPSession(context: context, caller: caller) { [unowned self] in self.sent.append($0) }
    }

    private func request(_ id: Any, _ method: String, _ params: [String: Any] = [:], modern: Bool = false) -> [String: Any] {
        var params = params
        if modern {
            params["_meta"] = [MCPProtocol.metaProtocolVersion: MCPProtocol.currentVersion,
                               MCPProtocol.metaClientInfo: ["name": "claude-code", "version": "2.1"]]
        }
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private var lastResult: [String: Any]? { sent.last?["result"] as? [String: Any] }
    private var lastError: [String: Any]? { sent.last?["error"] as? [String: Any] }

    // MARK: Handshakes

    func testAnOlderClientGetsTheVersionItAskedForWhenWeSpeakIt() {
        let session = session()
        session.receive(request(1, "initialize", ["protocolVersion": "2025-06-18",
                                                  "clientInfo": ["name": "codex", "version": "0.9"]]))
        XCTAssertEqual(lastResult?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((lastResult?["serverInfo"] as? [String: Any])?["version"] as? String, "9.9.9")
        XCTAssertNotNil(lastResult?["capabilities"])
        XCTAssertEqual(session.caller.clientName, "codex")

        session.receive(request(2, "initialize", ["protocolVersion": "1999-01-01"]))
        XCTAssertEqual(lastResult?["protocolVersion"] as? String, MCPProtocol.legacyVersions[0])
    }

    func testDiscoverAnswersWithTheCurrentRevision() {
        let session = session()
        session.receive(request("d", "server/discover", modern: true))
        XCTAssertEqual(lastResult?["supportedVersions"] as? [String], [MCPProtocol.currentVersion])
        XCTAssertEqual(lastResult?["resultType"] as? String, "complete")
        let meta = lastResult?["_meta"] as? [String: Any]
        XCTAssertEqual((meta?[MCPProtocol.metaServerInfo] as? [String: Any])?["name"] as? String, "stack-nudge")
        XCTAssertEqual(session.caller.clientName, "claude-code")
    }

    func testAnUnknownRevisionIsRefusedWithWhatWeSpeak() {
        let session = session()
        session.receive(["jsonrpc": "2.0", "id": 3, "method": "tools/list",
                         "params": ["_meta": [MCPProtocol.metaProtocolVersion: "2030-01-01"]]])
        XCTAssertEqual(lastError?["code"] as? Int, MCPProtocol.unsupportedProtocolVersion)
    }

    func testAnOlderRevisionNamedPerRequestIsRefusedWithOnlyTheCurrentOne() {
        let session = session()
        session.receive(["jsonrpc": "2.0", "id": 3, "method": "tools/list",
                         "params": ["_meta": [MCPProtocol.metaProtocolVersion: MCPProtocol.legacyVersions[0]]]])
        XCTAssertEqual(lastError?["code"] as? Int, MCPProtocol.unsupportedProtocolVersion)
        XCTAssertEqual((lastError?["data"] as? [String: Any])?["supported"] as? [String], [MCPProtocol.currentVersion])
    }

    func testNotificationsAreNeverAnswered() {
        let session = session()
        session.receive(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertTrue(sent.isEmpty)
    }

    func testAnUnknownMethodIsMethodNotFound() {
        let session = session()
        session.receive(request(4, "prompts/list"))
        XCTAssertEqual(lastError?["code"] as? Int, MCPProtocol.methodNotFound)
    }

    // MARK: Tools

    func testToolsAreListedInAFixedOrder() {
        let session = session()
        session.receive(request(5, "tools/list"))
        let names = (lastResult?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["settings_list", "settings_get", "settings_set", "notify", "mute", "sessions_list"])
    }

    private func call(_ session: MCPSession, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any]? {
        session.receive(request(6, "tools/call", ["name": name, "arguments": arguments]))
        return lastResult
    }

    func testSettingsListSaysWhatCanBeChanged() {
        let session = session()
        let result = call(session, "settings_list")
        let settings = (result?["structuredContent"] as? [String: Any])?["settings"] as? [[String: Any]]
        XCTAssertEqual(settings?.count, 2)
        let banner = settings?.first { $0["key"] as? String == "STACKNUDGE_BANNER" }
        XCTAssertEqual(banner?["writable"] as? Bool, false)
        XCTAssertNotNil(banner?["readOnlyReason"])
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertNotNil((result?["content"] as? [[String: Any]])?.first?["text"], "text for clients that only read content")
    }

    func testSettingsListNarrowsByCategoryAndRejectsAnUnknownOne() {
        let session = session()
        let voice = (call(session, "settings_list", ["category": "voice"])?["structuredContent"] as? [String: Any])?["settings"]
        XCTAssertEqual((voice as? [[String: Any]])?.count, 1)
        XCTAssertEqual(call(session, "settings_list", ["category": "nope"])?["isError"] as? Bool, true)
    }

    func testSettingsGetNamesAMissingKey() {
        let session = session()
        XCTAssertEqual((call(session, "settings_get", ["key": "STACKNUDGE_VOICE"])?["structuredContent"]
                        as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual(call(session, "settings_get", ["key": "STACKNUDGE_NOPE"])?["isError"] as? Bool, true)
        session.receive(request(7, "tools/call", ["name": "settings_get", "arguments": [:] as [String: Any]]))
        XCTAssertEqual(lastError?["code"] as? Int, MCPProtocol.invalidParams)
    }

    func testSessionsListIsTheAppsList() {
        let session = session()
        let sessions = (call(session, "sessions_list")?["structuredContent"] as? [String: Any])?["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.first?["waitingOnUser"] as? Bool, true)
    }

    // MARK: Writing, nudging and muting

    func testSettingsSetWritesAsTheBridgesCallerAndReportsARefusal() {
        let session = session(MCPCaller(claudeSessionID: "s-1"))
        let ok = call(session, "settings_set", ["key": "STACKNUDGE_VOICE", "value": false])
        XCTAssertEqual(ok?["isError"] as? Bool, false)
        XCTAssertEqual(context.written.first?.0, "STACKNUDGE_VOICE")
        XCTAssertEqual(context.written.first?.2.claudeSessionID, "s-1", "the caller is the bridge's, not the model's")

        let refused = call(session, "settings_set", ["key": "STACKNUDGE_BANNER", "value": false])
        XCTAssertEqual(refused?["isError"] as? Bool, true)
    }

    func testNotifyRaisesANudgeAndRefusesABadOne() {
        let session = session()
        XCTAssertEqual(call(session, "notify", ["title": "Build done", "kind": "done"])?["isError"] as? Bool, false)
        XCTAssertEqual(context.nudges.first?.0.title, "Build done")
        XCTAssertEqual(call(session, "notify", ["title": "x", "url": "http://example.com"])?["isError"] as? Bool, true)
        XCTAssertEqual(context.nudges.count, 1)
    }

    func testMuteIsBoundedToADay() {
        let session = session()
        XCTAssertEqual(call(session, "mute", ["minutes": 30])?["isError"] as? Bool, false)
        XCTAssertEqual(call(session, "mute", ["minutes": MCPSession.maxMuteMinutes + 1])?["isError"] as? Bool, true)
        XCTAssertEqual(context.mutes, [30])
    }

    // MARK: Resources

    func testResourcesReadAsJSONAndAnUnknownURIIsInvalidParams() throws {
        let session = session()
        session.receive(request(8, "resources/read", ["uri": "stacknudge://settings/voice"]))
        let text = ((lastResult?["contents"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((body["settings"] as? [[String: Any]])?.count, 1)

        session.receive(request(9, "resources/read", ["uri": "stacknudge://nope"]))
        XCTAssertEqual(lastError?["code"] as? Int, MCPProtocol.invalidParams)
    }

    func testAnOlderClientHearsOnlyTheURIsItSubscribedTo() {
        let session = session()
        session.receive(request(10, "resources/subscribe", ["uri": MCPSession.settingsURI]))
        sent = []
        session.resourcesUpdated([MCPSession.sessionsURI])
        XCTAssertTrue(sent.isEmpty)
        session.resourcesUpdated([MCPSession.settingsURI, MCPSession.sessionsURI])
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/resources/updated")
        XCTAssertEqual((sent.first?["params"] as? [String: Any])?["uri"] as? String, MCPSession.settingsURI)
    }

    // 2026-07-28: acknowledged first, every notification tagged with the
    // listen request's id, and nothing after it's cancelled.
    func testAListenStreamIsAcknowledgedTaggedAndCancellable() {
        let session = session()
        session.receive(request(11, "subscriptions/listen",
                                ["notifications": ["resourceSubscriptions": [MCPSession.sessionsURI, "stacknudge://nope"],
                                                   "toolsListChanged": true]],
                                modern: true))
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/subscriptions/acknowledged")
        let ack = sent.first?["params"] as? [String: Any]
        XCTAssertEqual((ack?["_meta"] as? [String: Any])?[MCPProtocol.metaSubscriptionID] as? Int, 11)
        XCTAssertEqual((ack?["notifications"] as? [String: Any])?["resourceSubscriptions"] as? [String],
                       [MCPSession.sessionsURI], "an unknown URI isn't acknowledged")
        XCTAssertNil(sent.first?["id"], "the listen request stays open")

        sent = []
        session.resourcesUpdated([MCPSession.sessionsURI])
        XCTAssertEqual(((sent.first?["params"] as? [String: Any])?["_meta"] as? [String: Any])?[MCPProtocol.metaSubscriptionID] as? Int, 11)

        session.receive(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 11]])
        sent = []
        session.resourcesUpdated([MCPSession.sessionsURI])
        XCTAssertTrue(sent.isEmpty)
    }

    func testANewerClientHearsListChangesOnlyOnAStreamThatAsked() {
        let older = session()
        older.receive(request(1, "initialize", ["protocolVersion": "2025-11-25"]))
        sent = []
        older.toolsListChanged()
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/tools/list_changed")

        let newer = session()
        newer.receive(request(1, "server/discover", modern: true))
        sent = []
        newer.toolsListChanged()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTheURIsASettingsChangeTouches() {
        let changed = FakeContext().settingsList.filter { $0.category == "voice" }
        XCTAssertEqual(MCPSession.settingsURIs(changed: changed),
                       [MCPSession.settingsURI, "stacknudge://settings/voice"])
        XCTAssertEqual(MCPSession.settingsURIs(changed: []), [])
    }

    // MARK: The caller

    func testTheCallerComesFromTheBridgesHello() {
        let caller = MCPCaller.fromHello(["type": "hello", "claudeSessionId": "abc", "parentPid": 77, "parentApp": ""])
        XCTAssertEqual(caller.claudeSessionID, "abc")
        XCTAssertEqual(caller.parentPID, 77)
        XCTAssertNil(caller.parentApp)
        XCTAssertEqual(caller.displayName, "Claude Code")
        XCTAssertEqual(MCPCaller(clientName: "codex").displayName, "Codex")
        XCTAssertEqual(MCPCaller(parentApp: "Claude").displayName, "Claude")
    }
}

final class MCPBridgeTests: XCTestCase {

    func testTheHelloCarriesTheClaudeSessionAndParent() {
        let hello = MCPBridge.hello(environment: ["CLAUDE_CODE_SESSION_ID": "s-1"], parentPID: getpid())
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["claudeSessionId"] as? String, "s-1")
        XCTAssertEqual(hello["parentPid"] as? Int, Int(getpid()))
        XCTAssertNil(MCPBridge.hello(environment: [:], parentPID: getpid())["claudeSessionId"])
    }

    func testAnAppIsNamedFromItsBundlePath() {
        XCTAssertEqual(MCPBridge.appName(fromExecutablePath: "/Applications/Claude.app/Contents/MacOS/Claude"), "Claude")
        XCTAssertNil(MCPBridge.appName(fromExecutablePath: "/Users/me/.local/bin/claude"))
    }

    // The app isn't running: the client's startup still succeeds, with no
    // tools and a reason.
    func testWithTheAppDownTheClientStillStarts() {
        let initialize = MCPBridge.notRunningReply(to: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                        "params": ["protocolVersion": "2025-11-25"]])
        let result = initialize?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual(result?["instructions"] as? String, MCPBridge.notRunning)
        let tools = MCPBridge.notRunningReply(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        XCTAssertEqual(((tools?["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        XCTAssertNil(MCPBridge.notRunningReply(to: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let call = MCPBridge.notRunningReply(to: ["jsonrpc": "2.0", "id": 3, "method": "tools/call"])
        XCTAssertEqual((call?["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.methodNotFound)
    }
}

@MainActor
final class SettingsRegistryTests: XCTestCase {

    func testEveryKeyIsListedOnceUnderASettingsCategory() {
        let keys = SettingsRegistry.specs.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        let sidebar = Set(SettingsCategory.allCases.map { $0.label.lowercased() })
        for category in SettingsRegistry.categories {
            XCTAssertTrue(sidebar.contains(category), "\(category) isn't a Settings category")
        }
    }

    // An agent changing these could hide a prompt from you or widen what it
    // can do; they stay Settings-only.
    func testWhatProtectsPromptsIsNeverWritable() {
        for key in ["STACKNUDGE_BANNER", "STACKNUDGE_MUTE_WHEN_FOCUSED", "STACKNUDGE_REMIND_MIN",
                    "STACKNUDGE_AWAY_LOCK", "STACKNUDGE_PANEL_HOTKEY"] {
            XCTAssertNotNil(SettingsRegistry.spec(key)?.readOnlyReason, key)
        }
    }

    func testNoSecretIsListed() {
        for key in ["STACKNUDGE_SLACK_BOT_TOKEN", "STACKNUDGE_SLACK_MEMBER_ID", "STACKNUDGE_GITHUB_CLIENT_ID"] {
            XCTAssertNil(SettingsRegistry.spec(key), key)
        }
    }

    func testTheSnapshotReadsNav() {
        let nav = PanelNav()
        nav.voiceEnabled = true
        nav.quotaAlertThreshold = 90
        let snapshot = SettingsRegistry.snapshot(nav)
        XCTAssertEqual(snapshot.count, SettingsRegistry.specs.count)
        XCTAssertEqual(snapshot.first { $0.key == "STACKNUDGE_VOICE" }?.value, .bool(true))
        XCTAssertEqual(snapshot.first { $0.key == "STACKNUDGE_QUOTA_THRESHOLD" }?.value, .int(90))
    }
}

final class MCPSessionsTests: XCTestCase {

    private func session(_ pid: Int, claude: String, status: SessionStatus = .active) -> Session {
        var session = Session(id: pid, pid: pid, agent: "claude", projectPath: "/r", projectName: "r",
                              terminalPID: nil, terminalApp: nil, elapsed: nil, customName: nil, status: status)
        session.claudeSessionID = claude
        return session
    }

    func testASessionIsWaitingWhileItsPromptIsStillBlocking() {
        let prompt = NudgeEvent(agent: "claude", kind: .permission, title: "Claude Code", message: "Bash(ls)",
                                claudeSessionID: "s-9")
        let entries = MCPSessions.list([session(9, claude: "s-9"), session(1, claude: "s-1")], events: [prompt],
                                       isBlocking: { _ in true }).map(MCPSessions.json)
        XCTAssertEqual(entries.map { $0["state"] as? String }, ["waiting", "active"])
        XCTAssertEqual(entries.first?["claudeSessionId"] as? String, "s-9")
        XCTAssertEqual(entries.first?["repo"] as? String, "r")
        XCTAssertNil(entries.first?["path"], "no paths, as event:session")
    }

    func testAnEndedSessionIsLeftOut() {
        let entries = MCPSessions.list([session(9, claude: "s-9", status: .finished(at: Date()))], events: [])
        XCTAssertTrue(entries.isEmpty)
    }
}

// One real round trip: the bridge's hello, a request and the push of a change,
// over the socket the app listens on.
final class MCPServerSocketTests: XCTestCase {

    func testARoundTripAndAPushOverTheSocket() throws {
        // sun_path is 104 bytes, and NSTemporaryDirectory is long on macOS.
        let path = "/tmp/sn-mcp-\(UUID().uuidString.prefix(8)).sock"
        let server = MCPServer(socketPath: path, context: MCPSessionTests.FakeContext())
        try server.start()
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBytes { src in _ = memcpy(dst.baseAddress, src.baseAddress, src.count) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        defer { close(fd) }

        func send(_ object: [String: Any]) {
            let data = MCPProtocol.encode(object)!
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
        }
        var reader = MCPLineReader(fd: fd)
        func next() -> [String: Any]? { reader.next().flatMap(MCPProtocol.parse) }

        send(["type": "hello", "claudeSessionId": "s-1", "parentPid": 1])
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
        XCTAssertEqual((next()?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")

        send(["jsonrpc": "2.0", "id": 2, "method": "resources/subscribe", "params": ["uri": MCPSession.settingsURI]])
        XCTAssertEqual(next()?["id"] as? Int, 2)
        XCTAssertEqual(server.sessions.first?.caller.claudeSessionID, "s-1")

        server.resourcesUpdated([MCPSession.settingsURI])
        XCTAssertEqual(next()?["method"] as? String, "notifications/resources/updated")
    }
}

final class MCPNudgeTests: XCTestCase {

    private func session(pid: Int, claude: String? = nil, active: Bool = true) -> Session {
        var session = Session(id: pid, pid: pid, agent: "claude", projectPath: "/r", projectName: "r",
                              terminalPID: nil, terminalApp: "iTerm2", elapsed: nil, customName: nil,
                              status: active ? .active : .finished(at: Date()))
        session.claudeSessionID = claude
        return session
    }

    func testARequestIsChecked() {
        XCTAssertEqual(try MCPNudge.request(from: ["title": "  Done  "]).get().kind, .info)
        XCTAssertEqual(try MCPNudge.request(from: ["title": "Done"]).get().title, "Done")
        XCTAssertThrowsError(try MCPNudge.request(from: ["message": "no title"]).get())
        XCTAssertThrowsError(try MCPNudge.request(from: ["title": "x", "kind": "urgent"]).get())
        XCTAssertThrowsError(try MCPNudge.request(from: ["title": "x", "url": "http://example.com"]).get(),
                             "only https")
        XCTAssertThrowsError(try MCPNudge.request(from: ["title": "x", "url": "file:///etc/passwd"]).get())
        XCTAssertThrowsError(try MCPNudge.request(from: ["title": "x", "tag": "has space"]).get())
        XCTAssertEqual(try MCPNudge.request(from: ["title": "x", "url": "https://claude.ai/chat/1"]).get().url?.host,
                       "claude.ai")
        XCTAssertEqual(try MCPNudge.request(from: ["title": String(repeating: "a", count: 500)]).get().title.count,
                       MCPNudge.maxTitle)
    }

    // By the Claude session id the bridge saw, else by the agent process that
    // launched the bridge.
    func testTheCallersSessionIsFound() {
        let sessions = [session(pid: 10, claude: "s-10"), session(pid: 20), session(pid: 30, claude: "s-30", active: false)]
        XCTAssertEqual(MCPNudge.session(for: MCPCaller(claudeSessionID: "s-10", parentPID: 20), in: sessions)?.pid, 10)
        XCTAssertEqual(MCPNudge.session(for: MCPCaller(parentPID: 20), in: sessions)?.pid, 20)
        XCTAssertNil(MCPNudge.session(for: MCPCaller(claudeSessionID: "s-30"), in: sessions), "a finished session")
        XCTAssertNil(MCPNudge.session(for: MCPCaller(parentApp: "Claude", parentBundleID: "com.anthropic.claudefordesktop"),
                                      in: sessions))
    }

    func testTheNudgeCarriesItsWayBack() {
        let request = try! MCPNudge.request(from: ["title": "Waiting", "kind": "waiting"]).get()
        let fromCode = MCPNudge.event(request, caller: MCPCaller(clientName: "claude-code", claudeSessionID: "s-10"),
                                      session: session(pid: 10, claude: "s-10"))
        XCTAssertEqual(fromCode.source, .mcp)
        XCTAssertTrue(fromCode.isFeed, "never a permission prompt")
        XCTAssertNil(fromCode.fifoPath)
        XCTAssertEqual(fromCode.agentPID, 10)
        XCTAssertEqual(fromCode.severity, .action)
        XCTAssertEqual(fromCode.agent, "Claude Code")
        XCTAssertEqual(MCPNudge.liveSession(for: fromCode, in: [session(pid: 10, claude: "s-10")])?.pid, 10)

        let fromDesktop = MCPNudge.event(request, caller: MCPCaller(parentApp: "Claude",
                                                                    parentBundleID: "com.anthropic.claudefordesktop"),
                                         session: nil)
        XCTAssertEqual(fromDesktop.bundleID, "com.anthropic.claudefordesktop")
        XCTAssertNil(MCPNudge.liveSession(for: fromDesktop, in: [session(pid: 10, claude: "s-10")]))
    }

    // The hook socket may not claim to be MCP: an MCP nudge can take you to a
    // terminal or app, so only the server makes them.
    func testAScriptCantClaimToBeMCP() {
        let line = #"{"agent":"s","event":"other","title":"t","message":"m","source":"mcp"}"#
        XCTAssertEqual(EventListener.parseEvents(Data(line.utf8)).first?.source, .script)
    }

    func testTheBridgeNamesTheLaunchingAppsBundle() {
        XCTAssertEqual(MCPBridge.bundleID(fromExecutablePath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator"),
                       "com.apple.calculator")
        XCTAssertNil(MCPBridge.bundleID(fromExecutablePath: "/usr/local/bin/codex"))
    }
}

@MainActor
final class MCPWriteTests: XCTestCase {

    // Every failure returns before anything is written: these never touch
    // the real config file.
    func testRefusalsComeBeforeAnyWrite() {
        let nav = PanelNav()
        XCTAssertEqual(SettingsRegistry.write(key: "STACKNUDGE_NOPE", raw: true, nav: nav).failure,
                       .unknownKey("STACKNUDGE_NOPE"))
        XCTAssertEqual(SettingsRegistry.write(key: "STACKNUDGE_BANNER", raw: false, nav: nav).failure,
                       .readOnly(SettingsRegistry.protectsPrompts))
        XCTAssertNotNil(SettingsRegistry.write(key: "STACKNUDGE_MCP_WRITES", raw: false, nav: nav).failure,
                        "a client can't turn its own writes on or off")
        nav.mcpWritesEnabled = false
        XCTAssertEqual(SettingsRegistry.write(key: "STACKNUDGE_VOICE", raw: false, nav: nav).failure, .writesOff)
        nav.mcpWritesEnabled = true
        if case .invalidValue = SettingsRegistry.write(key: "STACKNUDGE_VOICE", raw: "loud", nav: nav).failure {} else {
            XCTFail("a toggle takes a boolean")
        }
        if case .invalidValue = SettingsRegistry.write(key: "STACKNUDGE_QUOTA_THRESHOLD", raw: 33, nav: nav).failure {} else {
            XCTFail("a list setting takes one of its values")
        }
    }

    func testValuesAreCoercedToWhatTheSettingTakes() {
        let nav = PanelNav()
        XCTAssertEqual(SettingsRegistry.coerce(true, to: .toggle, key: "k", nav: nav).value, .bool(true))
        XCTAssertEqual(SettingsRegistry.coerce("off", to: .toggle, key: "k", nav: nav).value, .bool(false))
        XCTAssertNil(SettingsRegistry.coerce(1, to: .toggle, key: "k", nav: nav).value, "1 isn't a boolean")
        XCTAssertEqual(SettingsRegistry.coerce(90, to: .integer([80, 90]), key: "k", nav: nav).value, .int(90))
        XCTAssertNil(SettingsRegistry.coerce(true, to: .integer([0, 1]), key: "k", nav: nav).value)
        XCTAssertEqual(SettingsRegistry.coerce(1.23, to: .number(min: 0.6, max: 1.6, step: 0.05), key: "k", nav: nav).value,
                       .double(1.25))
        XCTAssertNil(SettingsRegistry.coerce(2.0, to: .number(min: 0.6, max: 1.6, step: 0.05), key: "k", nav: nav).value)
    }

    // A mute an MCP client asked for spares permission prompts.
    func testAnMCPMuteSparesPrompts() {
        let nav = PanelNav()
        let prompt = NudgeEvent(agent: "claude", kind: .permission, title: "Claude Code", message: "Bash(ls)")
        let stop = NudgeEvent(agent: "claude", kind: .stop, title: "Claude Code", message: "Done")
        nav.muteUntil = Date().addingTimeInterval(600)
        XCTAssertTrue(nav.mutes(prompt))
        nav.muteSparesPrompts = true
        XCTAssertFalse(nav.mutes(prompt))
        XCTAssertTrue(nav.mutes(stop))
        nav.muteUntil = nil
        XCTAssertFalse(nav.mutes(stop))
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let failure) = self { return failure }; return nil }
    var value: Success? { if case .success(let value) = self { return value }; return nil }
}
