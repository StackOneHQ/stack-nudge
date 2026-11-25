import XCTest

@testable import StackNudgePanelCore

// MCP Events: the ring, cursors and replay, and push and poll through the
// protocol core.
final class MCPEventHubTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func hub() -> MCPEventHub {
        MCPEventHub(epoch: "e1", now: { [unowned self] in self.clock })
    }

    func testANullCursorStartsFromNow() {
        let hub = hub()
        hub.emit("session.stopped", data: ["agent": "claude"])
        let replay = hub.replay(name: "session.stopped", arguments: [:], cursor: nil, maxAgeMs: nil)
        XCTAssertTrue(replay.events.isEmpty)
        XCTAssertEqual(hub.cursor(replay.cursor), "e1.1")
        XCTAssertFalse(replay.truncated)
    }

    func testACursorReplaysWhatWasMissedThatMatches() {
        let hub = hub()
        hub.emit("session.stopped", data: ["agent": "claude"])
        hub.emit("session.stopped", data: ["agent": "codex"])
        hub.emit("nudge.raised", data: ["source": "mcp", "title": "x"])
        hub.emit("session.stopped", data: ["agent": "claude"])
        let replay = hub.replay(name: "session.stopped", arguments: ["agent": "claude"], cursor: "e1.1", maxAgeMs: nil)
        XCTAssertEqual(replay.events.map(\.sequence), [4])
        XCTAssertEqual(replay.cursor, 4)
        XCTAssertFalse(replay.truncated)
    }

    // Another launch's cursor, one older than the ring, or one behind the
    // maxAgeMs floor is a gap, never an error.
    func testAGapIsTruncatedNotAnError() {
        let hub = hub()
        hub.emit("session.stopped", data: ["agent": "claude"])
        XCTAssertTrue(hub.replay(name: "session.stopped", arguments: [:], cursor: "old.3", maxAgeMs: nil).truncated)
        XCTAssertTrue(hub.replay(name: "session.stopped", arguments: [:], cursor: "nonsense", maxAgeMs: nil).truncated)
        for _ in 0..<(MCPEventHub.ringSize + 5) { hub.emit("session.stopped", data: ["agent": "claude"]) }
        XCTAssertTrue(hub.replay(name: "session.stopped", arguments: [:], cursor: "e1.1", maxAgeMs: nil).truncated)

        let aged = self.hub()
        aged.emit("session.stopped", data: ["agent": "claude"])
        clock = clock.addingTimeInterval(600)
        aged.emit("session.stopped", data: ["agent": "claude"])
        let replay = aged.replay(name: "session.stopped", arguments: [:], cursor: "e1.0", maxAgeMs: 60_000)
        XCTAssertEqual(replay.events.map(\.sequence), [2])
        XCTAssertTrue(replay.truncated)
    }

    func testABacklogComesInBatches() {
        let hub = hub()
        for _ in 0..<5 { hub.emit("session.stopped", data: ["agent": "claude"]) }
        let first = hub.replay(name: "session.stopped", arguments: [:], cursor: "e1.0", maxAgeMs: nil, maxEvents: 2)
        XCTAssertEqual(first.events.map(\.sequence), [1, 2])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.cursor, 2)
    }

    func testArgumentsAreTheTypesFilters() {
        let stopped = MCPEventHub.appTypes.first { $0.name == "session.stopped" }!
        XCTAssertEqual(try MCPEventHub.arguments(["agent": "claude"], for: stopped).get(), ["agent": "claude"])
        XCTAssertThrowsError(try MCPEventHub.arguments(["colour": "red"], for: stopped).get())
        XCTAssertThrowsError(try MCPEventHub.arguments(["agent": 3], for: stopped).get())
        XCTAssertEqual(try MCPEventHub.arguments(nil, for: stopped).get(), [:])
    }

    func testAnExtensionsTypesComeAndGo() {
        let hub = hub()
        let type = MCPEventHub.EventType(name: "pylon.sla", description: "d", filters: [:], payloadSchema: [:])
        XCTAssertTrue(hub.setExtensionTypes([type], for: "pylon"))
        XCTAssertFalse(hub.setExtensionTypes([type], for: "pylon"), "the same list again is no change")
        XCTAssertEqual(hub.type(named: "pylon.sla")?.owner, "pylon")
        XCTAssertTrue(hub.setExtensionTypes([], for: "pylon"))
        XCTAssertNil(hub.type(named: "pylon.sla"))
    }
}

final class MCPEventsSessionTests: XCTestCase {

    private var sent: [[String: Any]] = []
    private var hub = MCPEventHub(epoch: "e1")

    private func session() -> MCPSession {
        sent = []
        hub = MCPEventHub(epoch: "e1")
        return MCPSession(context: MCPSessionTests.FakeContext(), events: hub, caller: MCPCaller()) { [unowned self] in
            self.sent.append($0)
        }
    }

    private func request(_ id: Any, _ method: String, _ params: [String: Any]) -> [String: Any] {
        var params = params
        params["_meta"] = [MCPProtocol.metaProtocolVersion: MCPProtocol.currentVersion]
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private func params(_ message: [String: Any]?) -> [String: Any]? { message?["params"] as? [String: Any] }
    private func subscription(_ message: [String: Any]?) -> Int? {
        (params(message)?["_meta"] as? [String: Any])?[MCPProtocol.metaSubscriptionID] as? Int
    }

    func testTheExtensionIsAdvertisedAndItsTypesListed() {
        let session = session()
        session.receive(request("d", "server/discover", [:]))
        let capabilities = (sent.last?["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil((capabilities?["extensions"] as? [String: Any])?[MCPEventHub.extensionID])

        session.receive(request(1, "events/list", [:]))
        let types = (sent.last?["result"] as? [String: Any])?["events"] as? [[String: Any]]
        XCTAssertEqual(types?.count, MCPEventHub.appTypes.count)
        XCTAssertEqual(types?.first?["delivery"] as? [String], ["push", "poll"])
    }

    func testAPollStartsFromNowThenGetsWhatHappened() {
        let session = session()
        session.receive(request(1, "events/poll", ["name": "session.waiting", "cursor": NSNull()]))
        let start = sent.last?["result"] as? [String: Any]
        XCTAssertEqual((start?["events"] as? [Any])?.count, 0)
        let cursor = start?["cursor"] as? String
        hub.emit("session.waiting", data: ["agent": "claude"])
        session.receive(request(2, "events/poll", ["name": "session.waiting", "cursor": cursor as Any]))
        let next = sent.last?["result"] as? [String: Any]
        XCTAssertEqual(((next?["events"] as? [[String: Any]])?.first?["data"] as? [String: Any])?["agent"] as? String, "claude")
        XCTAssertEqual(next?["nextPollMs"] as? Int, MCPEventHub.defaultPollMs)
    }

    func testAnUnknownTypeIsNotFound() {
        let session = session()
        session.receive(request(1, "events/poll", ["name": "nope"]))
        XCTAssertEqual((sent.last?["error"] as? [String: Any])?["code"] as? Int, MCPEventHub.notFound)
        session.receive(request(2, "events/stream", ["name": "session.waiting", "arguments": ["colour": "red"]]))
        XCTAssertEqual((sent.last?["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidParams)
    }

    // Active first, with the granted heartbeat; then the backlog; then live
    // events that match, each tagged with the stream; nothing after cancel.
    func testAStreamIsActiveThenReplaysThenGoesLive() {
        let session = session()
        hub.emit("session.stopped", data: ["agent": "claude"])
        hub.emit("session.stopped", data: ["agent": "claude"])
        session.receive(request(7, "events/stream", ["name": "session.stopped", "arguments": ["agent": "claude"],
                                                      "cursor": "e1.1", "heartbeatMs": 10]))
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/events/active")
        XCTAssertEqual(params(sent.first)?["heartbeatMs"] as? Int, 5000, "clamped to the server's floor")
        XCTAssertEqual(subscription(sent.first), 7)
        XCTAssertEqual(sent.count, 2, "the one event since e1.1")
        XCTAssertEqual(params(sent.last)?["cursor"] as? String, "e1.2")

        sent = []
        session.deliver(hub.emit("session.stopped", data: ["agent": "codex"]))
        XCTAssertTrue(sent.isEmpty, "filtered out")
        session.deliver(hub.emit("session.stopped", data: ["agent": "claude"]))
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/events/event")
        XCTAssertEqual(subscription(sent.first), 7)

        session.receive(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]])
        sent = []
        session.deliver(hub.emit("session.stopped", data: ["agent": "claude"]))
        XCTAssertTrue(sent.isEmpty)
    }

    func testTheListChangesOnlyOnAStreamThatAskedForIt() {
        let session = session()
        session.eventsListChanged()
        XCTAssertTrue(sent.isEmpty)
        session.receive(request(3, "subscriptions/listen", ["notifications": ["eventsListChanged": true]]))
        XCTAssertEqual((params(sent.first)?["notifications"] as? [String: Any])?["eventsListChanged"] as? Bool, true)
        sent = []
        session.eventsListChanged()
        XCTAssertEqual(sent.first?["method"] as? String, "notifications/events/list_changed")
        XCTAssertEqual(subscription(sent.first), 3)
    }
}

final class MCPAppEventsTests: XCTestCase {

    // No prompt text, tool input or message body: a prompt says who's
    // waiting, not what it asks.
    func testAPromptBecomesSessionWaitingWithoutItsText() {
        let prompt = NudgeEvent(agent: "claude", kind: .permission, title: "Claude Code", message: "Bash(rm -rf /tmp/x)",
                                projectPath: "/Users/me/api", agentPID: 42, claudeSessionID: "s-1")
        let (name, data) = MCPAppEvents.occurrence(for: prompt)!
        XCTAssertEqual(name, "session.waiting")
        XCTAssertEqual(data["repo"] as? String, "api")
        XCTAssertNil(data["path"], "the repo's name, never its path")
        XCTAssertEqual(data["sessionPid"] as? Int, 42)
        XCTAssertFalse(data.values.contains { ($0 as? String)?.contains("rm -rf") == true })
    }

    func testStopsAndFeedEventsMapToTheirTypes() {
        let stop = NudgeEvent(agent: "codex", kind: .stop, title: "Codex", message: "Done")
        XCTAssertEqual(MCPAppEvents.occurrence(for: stop)?.name, "session.stopped")
        let feed = NudgeEvent.feed(source: .github, tag: "ci", title: "CI failed", message: "api#9",
                                   url: URL(string: "https://github.com/o/r/pull/9"))
        let (name, data) = MCPAppEvents.occurrence(for: feed)!
        XCTAssertEqual(name, "nudge.raised")
        XCTAssertEqual(data["source"] as? String, "github")
        XCTAssertEqual(data["url"] as? String, "https://github.com/o/r/pull/9")
        XCTAssertNil(MCPAppEvents.occurrence(for: NudgeEvent(agent: "claude", kind: .other, title: "t", message: "m")))
    }

    func testAWriteIsCreditedOnlyBriefly() {
        let attribution = MCPAttribution()
        let at = Date()
        attribution.note("STACKNUDGE_VOICE", by: "Claude Code", at: at)
        XCTAssertEqual(attribution.take("STACKNUDGE_VOICE", now: at.addingTimeInterval(1)), "Claude Code")
        XCTAssertNil(attribution.take("STACKNUDGE_VOICE", now: at.addingTimeInterval(1)), "taken once")
        attribution.note("STACKNUDGE_VOICE", by: "Claude Code", at: at)
        XCTAssertNil(attribution.take("STACKNUDGE_VOICE", now: at.addingTimeInterval(10)))
    }
}
