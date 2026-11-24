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

    // MARK: - Extension feeds

    private func fromExtension(_ id: String, _ title: String = "Reply", key: String? = "draft-1",
                               action: FeedAction? = FeedAction(id: "send", label: "Send")) -> NudgeEvent {
        .feed(source: .extension, tag: "exchange", severity: .action, title: title, message: "body",
              key: key, name: "Direct exchange", extensionID: id, action: action)
    }

    func testAnExtensionsEventIsNamedForTheExtension() {
        let event = fromExtension("exchange")
        XCTAssertEqual(event.agent, "Direct exchange")
        XCTAssertEqual(FeedStyle.chip(for: event), "Direct exchange")
        XCTAssertEqual(event.kind, .other)
    }

    // A key is the poster's own name for its event: another extension, or a
    // script, using the same one adds a row rather than replacing this one.
    func testAKeyOnlyReplacesTheSameExtensionsEvent() {
        let store = EventStore()
        store.append(fromExtension("exchange", "one"))
        store.append(fromExtension("other", "two"))
        store.append(.feed(source: .script, tag: nil, title: "three", message: "", key: "draft-1"))
        XCTAssertEqual(store.events.count, 3)
        store.append(fromExtension("exchange", "four"))
        XCTAssertEqual(store.events.map(\.title).sorted(), ["four", "three", "two"])
    }

    // Each extension has its own cap, so one can't push another's events out.
    func testEachExtensionHasItsOwnCap() {
        let store = EventStore()
        store.append(fromExtension("quiet", "keep", key: nil))
        for n in 0..<(EventStore.maxEventsPerFeed + 5) {
            store.append(fromExtension("chatty", "\(n)", key: nil))
        }
        XCTAssertEqual(store.events.filter { $0.extensionID == "chatty" }.count, EventStore.maxEventsPerFeed)
        XCTAssertEqual(store.events.filter { $0.extensionID == "quiet" }.map(\.title), ["keep"])
    }

    func testARetractRemovesOnlyThatExtensionsEvent() {
        let store = EventStore()
        store.append(fromExtension("exchange"))
        store.append(fromExtension("other"))
        store.retract(key: "draft-1", extensionID: "exchange")
        XCTAssertEqual(store.events.compactMap(\.extensionID), ["other"])
        store.retract(key: "nope", extensionID: "other")
        XCTAssertEqual(store.events.count, 1)
    }

    // Sending marks it read and takes the action off, so a second ⏎ can't
    // send it twice.
    func testSendingAnActionSpendsIt() {
        let store = EventStore()
        let event = fromExtension("exchange")
        store.append(event)
        store.actionSent(id: event.id)
        XCTAssertNil(store.events.first?.feedAction)
        XCTAssertEqual(store.events.first?.isRead, true)
        XCTAssertEqual(store.events.first?.key, "draft-1")
    }

    func testAnExtensionThatStopsLeavesItsEventsWithoutActions() {
        let store = EventStore()
        store.append(fromExtension("exchange"))
        store.append(fromExtension("other"))
        store.dropActions(extensionID: "exchange")
        XCTAssertNil(store.events.first { $0.extensionID == "exchange" }?.feedAction)
        XCTAssertNotNil(store.events.first { $0.extensionID == "other" }?.feedAction)
    }

    // Restored at launch with their extension and name, but never their
    // action: a running extension sends its live ones again.
    func testAnExtensionsEventIsRestoredWithoutItsAction() {
        let posted = fromExtension("exchange")
        let record = EventRecord(at: Date(), agent: posted.agent, kind: "other", title: posted.title,
                                 message: posted.message, project: nil, session: nil,
                                 source: "extension", tag: posted.tag, uid: posted.id.uuidString,
                                 severity: "action", key: posted.key, extensionID: "exchange")
        let store = EventStore()
        store.restoreFeed(from: [record])
        XCTAssertEqual(store.events.first?.extensionID, "exchange")
        XCTAssertEqual(store.events.first?.agent, "Direct exchange")
        XCTAssertNil(store.events.first?.feedAction)
    }

    // Re-posting under a key three times, then relaunching, brings back one
    // row: each replacement is logged as removing the one before.
    func testAReplacedEventStaysGoneAfterARelaunch() {
        let path = NSTemporaryDirectory() + "sn-feed-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = EventLog(path: path)
        let store = EventStore()
        store.log = log
        for title in ["one", "two", "three"] { store.append(fromExtension("exchange", title)) }
        log.flush()

        let relaunched = EventStore()
        relaunched.restoreFeed(from: log.load())
        XCTAssertEqual(relaunched.events.map(\.title), ["three"])
    }

    // A log written before replacements were recorded still restores the
    // newest event per poster and key only.
    func testRestoringKeepsTheNewestEventPerPosterAndKey() {
        func record(_ title: String, _ id: String, ago: TimeInterval) -> EventRecord {
            EventRecord(at: Date().addingTimeInterval(-ago), agent: "Direct exchange", kind: "other",
                        title: title, message: "", project: nil, session: nil, source: "extension",
                        uid: UUID().uuidString, key: "draft-1", extensionID: id)
        }
        let store = EventStore()
        store.restoreFeed(from: [record("newest", "exchange", ago: 10), record("older", "exchange", ago: 20),
                                 record("other's", "other", ago: 30)])
        XCTAssertEqual(store.events.map(\.title), ["newest", "other's"])
    }

    // However many feeds there are, a waiting prompt isn't pushed out by
    // them: past the overall ceiling the oldest feed events go first.
    func testFeedsCantPushAPromptPastTheOverallCeiling() {
        let store = EventStore()
        let waiting = prompt()
        store.append(waiting)
        for ext in 0..<6 {
            for n in 0..<EventStore.maxEventsPerFeed {
                store.append(fromExtension("ext\(ext)", "\(ext)-\(n)", key: nil))
            }
        }
        XCTAssertEqual(store.events.count, 100)
        XCTAssertTrue(store.events.contains { $0.id == waiting.id })
    }

    // An event that gained an action isn't a repeat of the one without it.
    func testGainingAnActionIsNotARepeat() {
        let store = EventStore()
        store.append(fromExtension("exchange", action: nil))
        store.append(fromExtension("exchange"))
        XCTAssertEqual(store.events.first?.feedAction, FeedAction(id: "send", label: "Send"))
    }

    // Only ⏎ sends an extension's action, and only while it can take it.
    // O, or an extension that can't answer, opens the link or is done.
    func testOnlyReturnSendsTheActionAndOnlyWhenItCanBeTaken() {
        let withAction = fromExtension("exchange")
        XCTAssertEqual(PanelController.feedOutcome(withAction, approve: true, canSend: true), .sendAction)
        XCTAssertEqual(PanelController.feedOutcome(withAction, approve: false, canSend: true), .done)
        XCTAssertEqual(PanelController.feedOutcome(withAction, approve: true, canSend: false), .done)
        let linked = NudgeEvent.feed(source: .extension, tag: nil, title: "t", message: "",
                                     url: URL(string: "https://example.com"), key: "k",
                                     name: "x", extensionID: "x", action: FeedAction(id: "send", label: "Send"))
        XCTAssertEqual(PanelController.feedOutcome(linked, approve: false, canSend: true), .open)
        XCTAssertEqual(PanelController.feedOutcome(feed(), approve: true, canSend: true), .open)
    }

    // Whatever tag it uses, an extension's row has the extension's icon and
    // colour, so it can't pass as a GitHub review.
    func testAnExtensionCantBorrowAnotherSourcesLook() {
        let dressedUp = NudgeEvent.feed(source: .extension, tag: "review", title: "t", message: "",
                                        name: "GitHub", extensionID: "x")
        XCTAssertEqual(FeedStyle.symbol(for: dressedUp), FeedStyle.sourceSymbol(.extension))
        XCTAssertEqual(FeedStyle.color(tag: "review", source: .extension), FeedStyle.sourceColor(.extension))
        XCTAssertEqual(FeedStyle.symbol(for: feed()), FeedStyle.symbol(tag: "ci", source: .github))
    }

    // A script can't post as an extension: an extension's event can carry an
    // action that ⏎ sends back to it.
    func testAScriptCannotClaimToBeAnExtension() {
        let event = EventListener.parseEvents(Data(#"{"agent":"x","event":"other","title":"Send","message":"m","source":"extension","key":"draft-1"}"#.utf8)).first
        XCTAssertEqual(event?.source, .script)
        XCTAssertNil(event?.extensionID)
        XCTAssertNil(event?.feedAction)
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
