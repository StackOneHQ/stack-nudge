import XCTest

@testable import StackNudgePanelCore

// Events that come from in-app feeds or scripts rather than an agent hook:
// they share the queue with agent events but must never act like one.
@MainActor
final class FeedEventTests: XCTestCase {

    private func prompt() -> NudgeEvent {
        NudgeEvent(agent: "claude-code", kind: .permission, title: "Claude Code", message: "Bash(ls)")
    }

    private func feed(_ message: String = "CI failing", key: String? = "pr:1:ci",
                      source: EventSource = .github) -> NudgeEvent {
        .feed(source: source, tag: "ci", severity: .alert, title: "api#1", message: message,
              url: URL(string: "https://github.com/acme/api/pull/1"),
              repo: "acme/api", pr: 1, key: key)
    }

    func testAFeedEventIsNeverAnAgentEvent() {
        let event = feed()
        XCTAssertTrue(event.isFeed)
        XCTAssertEqual(event.kind, .other, "a feed must stay out of the stop and permission paths")
        XCTAssertEqual(event.agent, "GitHub")
        XCTAssertFalse(prompt().isFeed)
    }

    // The next ⏎ must still land on the prompt the user was triaging.
    func testAFeedEventDoesNotTakeTheSelection() {
        let store = EventStore()
        let waiting = prompt()
        store.append(waiting)
        store.append(feed())
        XCTAssertEqual(store.selectedID, waiting.id)
        XCTAssertEqual(store.events.count, 2)
    }

    func testAFeedEventIsSelectedWhenNothingElseIs() {
        let store = EventStore()
        let event = feed()
        store.append(event)
        XCTAssertEqual(store.selectedID, event.id)
    }

    func testAKeyedFeedEventReplacesItsEarlierSelf() {
        let store = EventStore()
        store.append(feed("CI failing"))
        let recovered = feed("CI passing")
        store.append(recovered)
        XCTAssertEqual(store.events.map(\.message), ["CI passing"])
        XCTAssertEqual(store.selectedID, recovered.id, "the replacement keeps the selection it replaced")
    }

    func testUnkeyedFeedEventsStack() {
        let store = EventStore()
        store.append(feed("one", key: nil))
        store.append(feed("two", key: nil))
        XCTAssertEqual(store.events.count, 2)
    }

    // Feeds have their own allowance, so a busy week of PRs leaves agent
    // prompts in the queue.
    func testFeedsAreCappedPerSourceWithoutEvictingPrompts() {
        let store = EventStore()
        let waiting = prompt()
        store.append(waiting)
        for i in 0..<(EventStore.maxEventsPerFeed + 5) {
            store.append(feed("event \(i)", key: "k\(i)"))
        }
        XCTAssertEqual(store.events.filter(\.isFeed).count, EventStore.maxEventsPerFeed)
        XCTAssertTrue(store.events.contains { $0.id == waiting.id })
    }

    func testSnoozeKeepsTheFeedFields() {
        let event = feed().with(snoozedUntil: Date())
        XCTAssertEqual(event.source, .github)
        XCTAssertEqual(event.tag, "ci")
        XCTAssertEqual(event.severity, .alert)
        XCTAssertEqual(event.url?.host, "github.com")
        XCTAssertEqual(event.pr, 1)
        XCTAssertEqual(event.key, "pr:1:ci")
    }

    func testTheRowChipNamesSourceRepoAndPR() {
        XCTAssertEqual(FeedStyle.chip(for: feed()), "GitHub · api#1")
        let meeting = NudgeEvent.feed(source: .calendar, tag: "calendar", title: "Standup", message: "in 10 minutes")
        XCTAssertEqual(FeedStyle.chip(for: meeting), "Calendar")
    }
}

final class FeedEventDecodingTests: XCTestCase {

    private func decode(_ json: String) -> NudgeEvent? {
        EventListener.parseEvents(Data(json.utf8)).first
    }

    func testAScriptCanPostAFeedEvent() {
        let event = decode(#"{"agent":"deploy-bot","event":"other","title":"Deployed","message":"api to production","source":"script","tag":"deploy","severity":"action","url":"https://example.com/deploys/9","repo":"acme/api","pr":9,"key":"deploy:9"}"#)
        XCTAssertEqual(event?.source, .script)
        XCTAssertEqual(event?.tag, "deploy")
        XCTAssertEqual(event?.severity, .action)
        XCTAssertEqual(event?.url?.absoluteString, "https://example.com/deploys/9")
        XCTAssertEqual(event?.repo, "acme/api")
        XCTAssertEqual(event?.pr, 9)
        XCTAssertEqual(event?.key, "deploy:9")
    }

    // Opening goes through NSWorkspace, so only web links get through.
    func testOnlyWebLinksAreKept() {
        for raw in ["file:///etc/passwd", "x-apple.systempreferences:com.apple.preference", "javascript:alert(1)", "https://"] {
            let event = decode(#"{"agent":"s","event":"other","title":"t","message":"m","source":"script","url":"\#(raw)"}"#)
            XCTAssertNil(event?.url, raw)
        }
    }

    // A script can't make its event an agent prompt with Allow/Deny.
    func testAFeedCannotClaimToBeAPrompt() {
        let event = decode(#"{"agent":"s","event":"permission","title":"t","message":"m","source":"github"}"#)
        XCTAssertEqual(event?.kind, .other)
        let spoof = decode(#"{"agent":"s","event":"other","title":"t","message":"m","source":"agent"}"#)
        XCTAssertEqual(spoof?.source, .agent, "an explicit agent source is just an agent event")
    }

    func testAFeedLosesTheFieldsThatMakeAPromptAnswerable() {
        let event = decode(#"{"agent":"s","event":"permission","title":"t","message":"m","source":"script","has_action_button":true,"hook_pid":1234}"#)
        XCTAssertFalse(event?.hasActionButton ?? true)
        XCTAssertNil(event?.hookPID)
        XCTAssertNil(event?.fifoPath)
    }

    // Hooks send none of the new fields; nothing about them changes.
    func testAnAgentHookEventIsUnchanged() {
        let event = decode(#"{"agent":"claude-code","event":"permission","title":"t","message":"m"}"#)
        XCTAssertEqual(event?.source, .agent)
        XCTAssertEqual(event?.kind, .permission)
        XCTAssertEqual(event?.severity, .info)
        XCTAssertNil(event?.tag)
        XCTAssertNil(event?.key)
    }

    func testAnUnknownSourceOrSeverityFallsBack() {
        let event = decode(#"{"agent":"s","event":"other","title":"t","message":"m","source":"pager","severity":"huge"}"#)
        XCTAssertEqual(event?.source, .agent)
        XCTAssertEqual(event?.severity, .info)
    }
}

final class FeedHistoryTests: XCTestCase {

    // Lines written before the feed fields existed must still load.
    func testOldHistoryLinesStillParse() {
        let old = #"{"at":800000000,"agent":"claude-code","kind":"stop","title":"t","message":"m","project":null,"session":null}"#
        let parsed = EventLog.parse(old)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed.first?.source)
    }

    func testFeedFieldsRoundTripAndAreSearchable() {
        let record = EventRecord(at: Date(timeIntervalSince1970: 1_800_000_000), agent: "GitHub", kind: "other",
                                 title: "api#1", message: "CI failing", project: nil, session: nil,
                                 source: "github", tag: "ci", url: "https://github.com/x/y/pull/1")
        guard let line = EventLog.encode(record) else { return XCTFail("encode failed") }
        XCTAssertEqual(EventLog.parse(line), [record])
        XCTAssertTrue(record.matches("ci"))
        XCTAssertTrue(record.matches("github"))
    }
}
