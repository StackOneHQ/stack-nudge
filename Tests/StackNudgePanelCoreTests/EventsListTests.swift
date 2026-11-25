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

    func testApplyTogglesOrShowsOnlyAndAllNoneIgnoresOnly() {
        let present = ["ci", "review", "ready"]
        var filter = FeedTagFilter()
        filter.apply(.tag("ci"), only: false, among: present)
        XCTAssertEqual(present.filter(filter.shows), ["review", "ready"])
        filter.apply(.tag("ci"), only: false, among: present)
        XCTAssertTrue(filter.allShown(among: present))
        filter.apply(.tag("review"), only: true, among: present)
        XCTAssertEqual(present.filter(filter.shows), ["review"])
        filter.apply(.all, only: true, among: present)
        XCTAssertTrue(filter.allShown(among: present), "a partial selection goes to All")
        filter.apply(.all, only: false, among: present)
        XCTAssertTrue(filter.noneShown(among: present))
    }

    // MARK: Chip row focus

    func testChipRowStartsWithAllAndFocusReturnsToTheLastChip() {
        let present = ["ci", "review"]
        XCTAssertEqual(FeedChip.row(among: present), [.all, .tag("ci"), .tag("review")])
        XCTAssertEqual(FeedChip.focusTarget(last: nil, among: present), .all)
        XCTAssertEqual(FeedChip.focusTarget(last: .tag("review"), among: present), .tag("review"))
        XCTAssertEqual(FeedChip.focusTarget(last: .tag("gone"), among: present), .all)
    }

    func testChipMoveStopsAtTheEnds() {
        let present = ["ci", "review"]
        XCTAssertEqual(FeedChip.all.moved(by: -1, among: present), .all)
        XCTAssertEqual(FeedChip.all.moved(by: 1, among: present), .tag("ci"))
        XCTAssertEqual(FeedChip.tag("ci").moved(by: 1, among: present), .tag("review"))
        XCTAssertEqual(FeedChip.tag("review").moved(by: 1, among: present), .tag("review"))
        XCTAssertEqual(FeedChip.tag("gone").moved(by: 1, among: present), .tag("ci"))
    }

    // Raw virtual key codes, since the panel's KeyCode table is private.
    func testChipKeyRouting() {
        func action(_ code: UInt16, shifted: Bool = false) -> FeedChipKeyAction {
            PanelController.chipKeyAction(keyCode: code, shifted: shifted)
        }
        XCTAssertEqual(action(123), .move(-1))
        XCTAssertEqual(action(124), .move(1))
        XCTAssertEqual(action(36), .toggle)
        XCTAssertEqual(action(76), .toggle)
        XCTAssertEqual(action(49), .toggle)
        XCTAssertEqual(action(36, shifted: true), .only)
        for back: UInt16 in [125, 3] {
            XCTAssertEqual(action(back), .back, "Down and F leave the chips")
        }
        // Esc never reaches the chips: the panel hides on it everywhere.
        // up, U, A, C, R, O, delete, forward delete, H, M, S
        for key: UInt16 in [53, 126, 32, 0, 8, 15, 31, 51, 117, 4, 46, 1] {
            XCTAssertEqual(action(key), .swallow)
        }
    }

    func testTagColoursAreSharedByRowsAndChips() {
        XCTAssertEqual(FeedStyle.color(tag: "ci", source: .github), .orange)
        XCTAssertEqual(FeedStyle.color(tag: " ci ", source: .github), .orange)
        XCTAssertEqual(FeedStyle.color(tag: "mystery", source: .calendar), FeedStyle.sourceColor(.calendar))
        XCTAssertEqual(FeedStyle.color(tag: nil, source: .script), FeedStyle.sourceColor(.script))
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

    // GitHub's approved and changes-requested decisions are keyed review events.
    // Folded into the comment row they vanished there and gave it their key,
    // so the next decision replaced every comment.
    func testAKeyedReviewEventStaysOutOfTheCommentGroup() {
        let store = EventStore()
        store.append(feed("first", tag: "review", repo: "o/r", pr: 7))
        store.append(feed("second", tag: "review", repo: "o/r", pr: 7))
        store.append(feed("approved", tag: "review", key: "decision:o/r#7", repo: "o/r", pr: 7))
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first { $0.key == nil }?.members.count, 2)

        store.append(feed("changes requested", tag: "review", key: "decision:o/r#7", repo: "o/r", pr: 7))
        XCTAssertEqual(store.events.count, 2, "the decision replaces only itself")
        XCTAssertEqual(store.events.first { $0.key == nil }?.members.count, 2, "the comments survive it")
        XCTAssertEqual(store.events.first { $0.key != nil }?.message, "changes requested")
    }

    // MARK: Clear all

    // A held C autorepeats, and the first repeat used to be read as the
    // confirmation, clearing the feed without ever asking.
    func testAHeldCDoesNotConfirmClearAll() {
        // KeyCode is private to Panel.swift: C is 8 and ⌫ is 51.
        let c: UInt16 = 8
        XCTAssertEqual(PanelController.clearConfirmKeyAction(keyCode: c, shifted: false, isRepeat: true), .ignoreRepeat)
        XCTAssertEqual(PanelController.clearConfirmKeyAction(keyCode: c, shifted: false, isRepeat: false), .clear)
        XCTAssertEqual(PanelController.clearConfirmKeyAction(keyCode: c, shifted: true, isRepeat: false), .cancel)
        XCTAssertEqual(PanelController.clearConfirmKeyAction(keyCode: 51, shifted: false, isRepeat: false),
                       .cancel)
    }

    func testLeavingEventsDisarmsClearAll() {
        let nav = PanelNav()
        nav.mode = .events
        nav.confirmingClear = true
        nav.mode = .sessions
        nav.mode = .events
        XCTAssertFalse(nav.confirmingClear)
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

    // MARK: Timestamps

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

    func testFullDateIsNotEmptyAndStableAcrossCalls() {
        let first = EventTime.fullDate(date(10, 9, 30), calendar: calendar)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(EventTime.fullDate(date(10, 9, 30), calendar: calendar), first)
    }

    // MARK: Footer

    func testFeedHintsAppearOnlyWithAFeedAndShedFirst() {
        func hints(_ feed: FeedFooterState) -> [FooterHintSpec] {
            PanelContentView.eventsFooterHints(
                pane: .live, filterFocused: false, liveQueueEmpty: false,
                primaryAction: "Open", dismissLabel: "Dismiss", snoozeEnabled: false,
                muted: false, feed: feed)
        }
        XCTAssertFalse(hints(FeedFooterState()).contains { $0.keys == ["F"] })
        XCTAssertEqual(hints(FeedFooterState(feedCount: 2)).first { $0.keys == ["F"] }?.label, "Filters")
        let withFeed = hints(FeedFooterState(unread: 1, feedCount: 2, selectedIsFeed: true))
        XCTAssertEqual(withFeed.filter { $0.shedOrder.map { $0 < 0 } == true }.map(\.keys),
                       [["F"], ["U"], ["A"], ["C"]])
        let confirm = hints(FeedFooterState(feedCount: 2, confirmingClear: true))
        XCTAssertEqual(confirm.map(\.keys), [["C"]])
    }

    func testChipKeysReplaceTheNormalHintsWhileFocused() {
        let focused = PanelContentView.eventsFooterHints(
            pane: .live, filterFocused: false, liveQueueEmpty: false,
            primaryAction: "Open", dismissLabel: "Dismiss", snoozeEnabled: false,
            muted: false, feed: FeedFooterState(feedCount: 2, chipsFocused: true))
        XCTAssertEqual(focused.map(\.label), ["Move", "Toggle", "Only", "List"])
        XCTAssertEqual(focused.map(\.keys), [["←→"], ["⏎"], ["⇧⏎"], ["F"]])
    }

    func testChipLabelsKeepAcronymsInCapitals() {
        XCTAssertEqual(FeedTagFilter.label("ci"), "CI")
        XCTAssertEqual(FeedTagFilter.label("pr-closed"), "PR closed")
        XCTAssertEqual(FeedTagFilter.label("review-request"), "Review request")
        XCTAssertEqual(FeedTagFilter.label("mcp"), "MCP")
    }
}
