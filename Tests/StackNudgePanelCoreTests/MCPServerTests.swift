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
        func settings() -> [SettingSnapshot] { settingsList }
        func sessions() -> [[String: Any]] { sessionsList }
    }

    private var sent: [[String: Any]] = []

    private func session(_ caller: MCPCaller = MCPCaller()) -> MCPSession {
        sent = []
        return MCPSession(context: FakeContext(), caller: caller) { [unowned self] in self.sent.append($0) }
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
        XCTAssertEqual(names, ["settings_list", "settings_get", "sessions_list"])
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
