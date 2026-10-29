import XCTest

@testable import StackNudgePanelCore

@MainActor
final class EventsListTests: XCTestCase {

    private func feed(_ message: String, tag: String? = "ci", key: String? = nil,
                      repo: String? = nil, pr: Int? = nil, at: Date = Date(),
                      severity: EventSeverity = .info) -> NudgeEvent {
        .feed(source: .github, tag: tag, severity: severity, title: "t", message: message,
              url: URL(string: "https://example.com/\(message)"), repo: repo, pr: pr, key: key,
              timestamp: at)
    }

    private func prompt() -> NudgeEvent {
        NudgeEvent(agent: "claude-code", kind: .permission, title: "Claude Code", message: "Bash(ls)")
    }

    // MARK: Tag filter

    func testFilterStartsShowingEverythingAndChipsToggle() {
        var filter = FeedTagFilter()
        XCTAssertTrue(filter.shows("ci"))
        filter.toggle("ci")
        XCTAssertFalse(filter.shows("ci"))
        XCTAssertTrue(filter.shows("review"))
    }

    func testShowOnlyAndAllNone() {
        let present = ["ci", "review", "ready"]
        var filter = FeedTagFilter()
        filter.showOnly("review", among: present)
        XCTAssertEqual(present.filter(filter.shows), ["review"])
        filter.toggleAll(among: present)
        XCTAssertEqual(present.filter(filter.shows), present, "a partial selection goes to All")
        filter.toggleAll(among: present)
        XCTAssertTrue(filter.noneShown(among: present))
    }

    func testCycleWalksEachTagThenWrapsToAll() {
        let present = ["a", "b", "c"]
        var filter = FeedTagFilter()
        var seen: [[String]] = []
        for _ in 0..<4 {
            filter.cycle(among: present, forward: true)
            seen.append(present.filter(filter.shows))
        }
        XCTAssertEqual(seen, [["a"], ["b"], ["c"], ["a", "b", "c"]])
        filter.cycle(among: present, forward: false)
        XCTAssertEqual(present.filter(filter.shows), ["c"])
    }

    func testStoreSelectionSkipsHiddenRowsAndNeverHidesPrompts() {
        let store = EventStore()
        let waiting = prompt()
        let ci = feed("ci", tag: "ci", key: "1")
        let review = feed("rev", tag: "review", key: "2")
        [waiting, ci, review].forEach(store.append)
        store.tagFilter.showOnly("review", among: store.presentTags)
        let visible = store.visibleEvents.map(\.id)
        XCTAssertTrue(visible.contains(waiting.id))
        XCTAssertFalse(visible.contains(ci.id))
        store.selectFirst()
        store.selectNext()
        store.selectNext()
        XCTAssertEqual(store.selectedID, visible.last)
    }

    // MARK: Read state

    func testFeedStartsUnreadAndPromptsAreNotPartOfIt() {
        let store = EventStore()
        store.append(prompt())
        store.append(feed("a", key: "a"))
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.pendingCount, 2)
        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.pendingCount, 1, "the prompt is still pending")
        let id = store.events.first { $0.isFeed }!.id
        store.toggleRead(id: id)
        XCTAssertEqual(store.unreadCount, 1)
        store.setRead(id: store.events.first { !$0.isFeed }!.id, true)
        XCTAssertEqual(store.pendingCount, 2, "marking a prompt read does nothing")
    }

    func testClearFeedKeepsPromptsAndSaysCaughtUp() {
        let store = EventStore()
        let waiting = prompt()
        store.append(waiting)
        store.append(feed("a", key: "a"))
        store.append(feed("b", key: "b"))
        XCTAssertEqual(store.clearFeed(), 2)
        XCTAssertEqual(store.events.map(\.id), [waiting.id])
        XCTAssertTrue(store.clearedFeed)
        store.append(feed("c", key: "c"))
        XCTAssertFalse(store.clearedFeed)
    }

    func testReadStateSurvivesInTheLogAndOldLinesStillDecode() {
        let old = #"{"at":1,"agent":"a","kind":"stop","title":"t","message":"m"}"#
        XCTAssertEqual(EventLog.parse(old).count, 1)

        let event = feed("a", key: "a")
        let record = EventRecord(at: event.timestamp, agent: "GitHub", kind: "other", title: "t",
                                 message: "a", project: nil, session: nil, source: "github",
                                 tag: "ci", uid: event.id.uuidString)
        let lines = [record, .marker(uid: event.id, at: Date(), read: true)]
            .compactMap(EventLog.encode).joined(separator: "\n")
        let loaded = EventLog.resolve(EventLog.parse(lines))
        XCTAssertEqual(loaded.count, 1, "the marker is not a record of its own")
        XCTAssertEqual(loaded.first?.read, true)

        let unread = EventLog.resolve(EventLog.parse(
            [record, .marker(uid: event.id, at: Date(), read: true),
             .marker(uid: event.id, at: Date(), read: false)]
                .compactMap(EventLog.encode).joined(separator: "\n")))
        XCTAssertEqual(unread.first?.read, false, "the later marker wins")
    }

    func testRestoreBringsBackUnremovedFeedWithItsReadState() {
        let kept = feed("kept", key: "k")
        let gone = feed("gone", key: "g")
        func record(_ e: NudgeEvent, read: Bool?, removed: Bool?) -> EventRecord {
            EventRecord(at: e.timestamp, agent: "GitHub", kind: "other", title: "t", message: e.message,
                        project: nil, session: nil, source: "github", tag: "ci",
                        url: e.url?.absoluteString, uid: e.id.uuidString, key: e.key,
                        read: read, removed: removed)
        }
        let store = EventStore()
        store.restoreFeed(from: [record(kept, read: true, removed: nil),
                                 record(gone, read: nil, removed: true)])
        XCTAssertEqual(store.events.map(\.message), ["kept"])
        XCTAssertTrue(store.events[0].isRead)
        XCTAssertEqual(store.events[0].url?.host, "example.com")
    }

    func testRestoreSkipsOldRecords() {
        let stale = feed("stale", at: Date().addingTimeInterval(-EventStore.restoreWindow - 60))
        let store = EventStore()
        store.restoreFeed(from: [EventRecord(at: stale.timestamp, agent: "GitHub", kind: "other",
                                             title: "t", message: "stale", project: nil, session: nil,
                                             source: "github", uid: stale.id.uuidString)])
        XCTAssertTrue(store.events.isEmpty)
    }

    // MARK: Grouping

    func testFeedbackOnOnePRCollapsesAndKeepsEachComment() {
        let store = EventStore()
        let t = Date()
        store.append(feed("first", tag: "review", repo: "o/r", pr: 7, at: t.addingTimeInterval(-10), severity: .info))
        store.append(feed("second", tag: "review", repo: "o/r", pr: 7, at: t, severity: .action))
        XCTAssertEqual(store.events.count, 1)
        let group = store.events[0]
        XCTAssertEqual(group.members.map(\.message), ["second", "first"])
        XCTAssertEqual(group.title, "2 new comments on r#7")
        XCTAssertEqual(group.severity, .action)
        XCTAssertTrue(group.isUnread)
        store.append(feed("third", tag: "review", repo: "o/r", pr: 7))
        XCTAssertEqual(store.events[0].members.count, 3)
    }

    func testGroupingIgnoresOtherPRsAndTags() {
        let store = EventStore()
        store.append(feed("a", tag: "review", repo: "o/r", pr: 7))
        store.append(feed("b", tag: "review", repo: "o/r", pr: 8))
        store.append(feed("c", tag: "ci", repo: "o/r", pr: 7))
        XCTAssertEqual(store.events.count, 3)
    }

    func testMembersAreBoundedAndExpansionOnlyForGroups() {
        let store = EventStore()
        for i in 0..<(EventStore.maxMembers + 10) {
            store.append(feed("c\(i)", tag: "review", repo: "o/r", pr: 1))
        }
        XCTAssertEqual(store.events[0].members.count, EventStore.maxMembers)
        let id = store.events[0].id
        store.toggleExpanded(id: id)
        XCTAssertTrue(store.expandedIDs.contains(id))
        store.append(feed("lone", key: "x"))
        let lone = store.events.first { $0.message == "lone" }!
        store.toggleExpanded(id: lone.id)
        XCTAssertFalse(store.expandedIDs.contains(lone.id))
    }

    func testWireMembersAreParsedBoundedAndNeverOnAgentEvents() {
        let line = #"{"agent":"x","event":"stop","title":"t","message":"m","source":"github","members":[{"message":"one","url":"https://a.b/c"},{"message":"two","url":"file:///etc"}]}"#
        let event = EventListener.parseEvents(Data(line.utf8))[0]
        XCTAssertEqual(event.members.map(\.message), ["one", "two"])
        XCTAssertNotNil(event.members[0].url)
        XCTAssertNil(event.members[1].url)
        let agent = EventListener.parseEvents(Data(#"{"agent":"x","event":"stop","title":"t","message":"m","members":[{"message":"one"}]}"#.utf8))[0]
        XCTAssertTrue(agent.members.isEmpty)
    }

    // MARK: Timestamps and day headings

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    func testRelativeAndListTime() {
        let now = date(29, 12)
        XCTAssertEqual(EventTime.relative(now.addingTimeInterval(-30), now: now, calendar: calendar), "now")
        XCTAssertEqual(EventTime.relative(date(29, 11, 30), now: now, calendar: calendar), "30m")
        XCTAssertEqual(EventTime.relative(date(29, 9), now: now, calendar: calendar), "3h")
        XCTAssertEqual(EventTime.relative(date(28, 20), now: now, calendar: calendar), "Yesterday")
        XCTAssertTrue(EventTime.listTime(date(28, 18, 5), now: now, calendar: calendar).hasPrefix("Yesterday "))
    }

    func testDayTitles() {
        let now = date(29, 12)
        XCTAssertEqual(EventTime.dayTitle(date(29, 1), now: now, calendar: calendar), "Today")
        XCTAssertEqual(EventTime.dayTitle(date(28, 23), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(EventTime.dayTitle(date(26, 9), now: now, calendar: calendar), "Monday")
        XCTAssertTrue(EventTime.dayTitle(date(10, 9), now: now, calendar: calendar).contains("10"))
        XCTAssertFalse(EventTime.fullDate(date(10, 9, 30), calendar: calendar).isEmpty)
    }

    func testDayHeadingsOnlyAppearWithFeedEvents() {
        let now = date(29, 12)
        let agentOnly = EventListItem.items([prompt()], now: now, calendar: calendar)
        XCTAssertEqual(agentOnly.count, 1)

        let items = EventListItem.items([feed("a", at: date(29, 9)), feed("b", at: date(29, 8)),
                                         feed("c", at: date(28, 9))], now: now, calendar: calendar)
        let headings = items.compactMap { item -> String? in
            if case .day(let title) = item { return title } else { return nil }
        }
        XCTAssertEqual(headings, ["Today", "Yesterday"])
        XCTAssertEqual(items.count, 5)
    }

    // MARK: Footer

    func testFeedHintsAppearOnlyWithAFeedAndShedFirst() {
        func hints(_ feed: FeedFooterState) -> [FooterHintSpec] {
            PanelContentView.eventsFooterHints(
                pane: .live, filterFocused: false, filterQuery: "", liveQueueEmpty: false,
                primaryAction: "Open", dismissLabel: "Dismiss", snoozeEnabled: false,
                muted: false, feed: feed)
        }
        XCTAssertFalse(hints(FeedFooterState()).contains { $0.keys == ["F"] })
        let withFeed = hints(FeedFooterState(unread: 1, feedCount: 2, selectedIsFeed: true))
        XCTAssertEqual(withFeed.filter { $0.shedOrder.map { $0 < 0 } == true }.map(\.keys),
                       [["F"], ["U"], ["A"], ["C"]])
        let confirm = hints(FeedFooterState(feedCount: 2, confirmingClear: true))
        XCTAssertEqual(confirm.map(\.keys), [["C"], ["Esc"]])
    }
}
