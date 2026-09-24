import XCTest

@testable import StackNudgePanelCore

// Pane state: what survives a refresh, what a failure does to a document that
// was already on screen, and which keypress runs which action.
@MainActor
final class ExtensionHostTests: XCTestCase {

    private func manifest(_ id: String, refresh: String = "{}") -> ExtensionManifest {
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"\(id)","name":"\(id)","version":"1","schema":1,"refresh":\(refresh)}
            """.utf8)) else { fatalError("fixture manifest didn't parse") }
        return m
    }

    private func document(_ json: String) -> ExtensionDocument {
        guard case .success(let d) = ExtensionDocument.parse(Data(json.utf8)) else {
            fatalError("fixture document didn't parse")
        }
        return d
    }

    private var twoRows: ExtensionDocument {
        document("""
            {"schema":1,"rows":[
              {"id":"a","title":"A","actions":[{"id":"open","label":"Open","key":"return"}]},
              {"id":"b","title":"B"}],
             "actions":[{"id":"refresh","label":"Sync","key":"r"}]}
            """)
    }

    // A host wired to a runner that records what it was asked to run and hands
    // back whatever the test queued, so nothing spawns.
    private final class Recorder {
        var calls: [(id: String, action: String?, row: String?)] = []
    }

    private func host(_ manifests: [ExtensionManifest],
                      recorder: Recorder = Recorder(),
                      result: @escaping () -> ExtensionRuntime.Fetch = { .transient("stub") })
        -> (ExtensionHost, Recorder, [ExtensionTab]) {
        var published: [ExtensionTab] = []
        let host = ExtensionHost(onTabsChanged: { published = $0 },
                                 background: { $0() }, toMain: { $0() },
                                 runner: { manifest, action, row in
                                     recorder.calls.append((manifest.id, action, row))
                                     return result()
                                 })
        host.load(.init(installed: manifests))
        return (host, recorder, published)
    }

    // MARK: - Discovery

    func testLoadingPublishesATabPerManifest() {
        let (_, _, tabs) = host([manifest("derby"), manifest("radar")])
        XCTAssertEqual(tabs, [ExtensionTab(id: "derby", label: "derby"),
                              ExtensionTab(id: "radar", label: "radar")])
    }

    // Reinstalling an extension must not bring back the document from its
    // previous life — that one could be describing a completely different
    // version of the script.
    func testUninstallingDropsThePane() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        XCTAssertNotNil(host.pane("derby").document)
        host.load(.init())
        XCTAssertNil(host.pane("derby").document)
    }

    // MARK: - Fetch outcomes

    func testASuccessfulFetchReplacesTheDocumentAndClearsTheStatus() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        XCTAssertEqual(host.pane("derby").document, twoRows)
        XCTAssertEqual(host.pane("derby").status, .idle)
        XCTAssertNotNil(host.pane("derby").updatedAt)
        XCTAssertFalse(host.pane("derby").busy)
    }

    // The whole point of the transient/broken split: a blip must not blank a
    // pane that already had something worth looking at.
    func testATransientFailureKeepsTheLastGoodDocumentAndMarksItStale() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        host.finish("derby", .transient("exited 3"))
        XCTAssertEqual(host.pane("derby").document, twoRows)
        XCTAssertEqual(host.pane("derby").status, .stale("exited 3"))
    }

    // With nothing to show, "stale" would be a claim about an empty pane.
    func testATransientFailureOnAColdPaneIsBrokenNotStale() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .transient("timed out"))
        XCTAssertEqual(host.pane("derby").status, .broken("timed out"))
    }

    func testMalformedAndMissingAreAlwaysBroken() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        host.finish("derby", .malformed("not valid JSON"))
        XCTAssertEqual(host.pane("derby").status, .broken("not valid JSON"))
    }

    // MARK: - Selection

    func testArrowsWalkTheRowsAndStopAtTheEnds() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))

        host.moveSelection(on: "derby", by: 1)
        XCTAssertEqual(host.pane("derby").selectedRow, "a")
        host.moveSelection(on: "derby", by: 1)
        XCTAssertEqual(host.pane("derby").selectedRow, "b")
        host.moveSelection(on: "derby", by: 1)
        XCTAssertEqual(host.pane("derby").selectedRow, "b")
        host.moveSelection(on: "derby", by: -1)
        XCTAssertEqual(host.pane("derby").selectedRow, "a")
        host.moveSelection(on: "derby", by: -1)
        XCTAssertEqual(host.pane("derby").selectedRow, "a")
    }

    // Either arrow is a way in, so ↑ on a fresh pane doesn't look broken.
    func testUpFromNoSelectionTakesTheLastRow() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        host.moveSelection(on: "derby", by: -1)
        XCTAssertEqual(host.pane("derby").selectedRow, "b")
    }

    func testSelectionSurvivesARefreshThatKeepsTheRow() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        host.selectRow("b", on: "derby")
        host.finish("derby", .ok(document("""
            {"schema":1,"rows":[{"id":"b","title":"B moved up"},{"id":"a","title":"A"}]}
            """)))
        XCTAssertEqual(host.pane("derby").selectedRow, "b")
    }

    // A selection pointing at a row that's gone would draw a highlight nowhere
    // and make ⏎ do nothing.
    func testSelectionClearsWhenTheRowDisappears() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        host.selectRow("b", on: "derby")
        host.finish("derby", .ok(document("{\"schema\":1,\"rows\":[{\"id\":\"a\",\"title\":\"A\"}]}")))
        XCTAssertNil(host.pane("derby").selectedRow)
    }

    func testMovingWithNoRowsIsANoOp() {
        let (host, _, _) = host([manifest("derby")])
        host.moveSelection(on: "derby", by: 1)
        XCTAssertNil(host.pane("derby").selectedRow)
    }

    // MARK: - Key resolution

    func testADocumentLevelKey() {
        XCTAssertEqual(ExtensionHost.resolve(key: "r", in: twoRows, selectedRow: nil)?.action,
                       "refresh")
        XCTAssertNil(ExtensionHost.resolve(key: "r", in: twoRows, selectedRow: nil)?.row)
    }

    func testARowLevelKeyCarriesTheRow() {
        let hit = ExtensionHost.resolve(key: "return", in: twoRows, selectedRow: "a")
        XCTAssertEqual(hit?.action, "open")
        XCTAssertEqual(hit?.row, "a")
    }

    // ⏎ with nothing selected has no row to act on, and the document has no
    // return binding of its own — so it does nothing rather than guessing.
    func testReturnWithNoSelectionResolvesToNothing() {
        XCTAssertNil(ExtensionHost.resolve(key: "return", in: twoRows, selectedRow: nil))
    }

    // Row b has no bindings, so its selection must not inherit row a's.
    func testASelectedRowWithNoBindingFallsThroughToTheDocument() {
        XCTAssertNil(ExtensionHost.resolve(key: "return", in: twoRows, selectedRow: "b"))
        XCTAssertEqual(ExtensionHost.resolve(key: "r", in: twoRows, selectedRow: "b")?.action,
                       "refresh")
    }

    // MARK: - One in flight

    // Two concurrent spawns of the same script would race to publish, and the
    // loser's document would overwrite the winner's for no reason anyone could
    // see. The re-entrant runner stands in for the second keypress arriving
    // while the first invocation is still out.
    func testASecondInvocationWhileBusyIsIgnoredRatherThanQueued() {
        let recorder = Recorder()
        var host: ExtensionHost?
        let made = ExtensionHost(background: { $0() }, toMain: { $0() },
                                 runner: { manifest, action, row in
                                     recorder.calls.append((manifest.id, action, row))
                                     // Re-entrant: this is the press that lands
                                     // while the pane is still busy.
                                     host?.perform(action: "second", row: nil, on: manifest.id)
                                     return .ok(ExtensionDocument(schema: 1, state: .ok,
                                                                  message: nil, header: nil,
                                                                  rows: [], actions: []))
                                 })
        host = made
        made.load(.init(installed: [manifest("derby")]))
        made.perform(action: "first", row: nil, on: "derby")

        XCTAssertEqual(recorder.calls.map(\.action), ["first"])
        XCTAssertFalse(made.pane("derby").busy)
    }

    // Once it has returned, the next press goes through — the gate is "one in
    // flight", not "one ever".
    func testThePaneAcceptsWorkAgainOnceTheInvocationReturns() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby")], recorder: recorder,
                                result: { .transient("stub") })
        host.perform(action: "first", row: nil, on: "derby")
        host.perform(action: "second", row: nil, on: "derby")
        XCTAssertEqual(recorder.calls.map(\.action), ["first", "second"])
    }

    func testAKeyIsNotHandledWhileTheresNoDocument() {
        let (host, recorder, _) = host([manifest("derby")])
        host.selectRow("a", on: "derby")
        XCTAssertFalse(host.handle(key: "r", on: "derby"))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // The case a user actually hits: holding a key while a slow spawn is out.
    // Covered only for the no-document half of the same guard until now.
    func testAKeyIsNotHandledWhileAnInvocationIsInFlight() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby")], recorder: recorder)
        host.finish("derby", .ok(twoRows))
        host.selectRow("a", on: "derby")

        var pane = host.pane("derby")
        pane.busy = true
        host.replacePaneForTesting(pane, on: "derby")

        XCTAssertFalse(host.handle(key: "return", on: "derby"))
        XCTAssertTrue(recorder.calls.isEmpty, "a keypress must not queue a second spawn")
    }

    // MARK: - The scheduled tick

    // isDue is tested as a predicate; this is the wiring that consults it.
    func testTickRefreshesOnlyTheExtensionsThatAreDue() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("due", refresh: "{\"intervalSeconds\":30}"),
                                 manifest("fresh", refresh: "{\"intervalSeconds\":30}"),
                                 manifest("nointerval")],
                                recorder: recorder)
        let now = Date()
        for (id, age) in [("due", -600.0), ("fresh", -1.0), ("nointerval", -600.0)] {
            var pane = host.pane(id)
            pane.attemptedAt = now.addingTimeInterval(age)
            pane.updatedAt = pane.attemptedAt
            host.replacePaneForTesting(pane, on: id)
        }
        host.tick(visibleTab: "due", now: now)
        XCTAssertEqual(recorder.calls.map(\.id), ["due"])
    }

    // whileFocusedOnly defaults on, so an extension whose tab isn't the visible
    // one must not be spawned by the tick at all.
    func testTickSkipsAFocusedOnlyExtensionThatIsNotTheVisibleTab() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby", refresh: "{\"intervalSeconds\":30}")],
                                recorder: recorder)
        let now = Date()
        var pane = host.pane("derby")
        pane.attemptedAt = now.addingTimeInterval(-600)
        host.replacePaneForTesting(pane, on: "derby")

        host.tick(visibleTab: nil, now: now)
        XCTAssertTrue(recorder.calls.isEmpty)

        host.tick(visibleTab: "derby", now: now)
        XCTAssertEqual(recorder.calls.map(\.id), ["derby"])
    }

    func testAnUnboundKeyIsNotHandled() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        XCTAssertFalse(host.handle(key: "q", on: "derby"))
    }

    // MARK: - Scheduled refresh

    // `attemptedAt` is what scheduling reads; `updatedAt` defaults to matching
    // it so the common "last fetch succeeded" case stays readable at call sites.
    private func pane(updatedAt: Date?, attemptedAt: Date?? = nil,
                      busy: Bool = false) -> ExtensionHost.Pane {
        var pane = ExtensionHost.Pane()
        pane.updatedAt = updatedAt
        pane.attemptedAt = attemptedAt ?? updatedAt
        pane.busy = busy
        return pane
    }

    func testNoIntervalMeansNoScheduledRefresh() {
        let now = Date()
        XCTAssertFalse(ExtensionHost.isDue(manifest("derby"),
                                              pane: pane(updatedAt: now.addingTimeInterval(-3600)),
                                              visible: true, now: now))
    }

    func testAnExtensionIsDueOnceItsIntervalHasPassed() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m, pane: pane(updatedAt: now.addingTimeInterval(-29)),
                                              visible: true, now: now))
        XCTAssertTrue(ExtensionHost.isDue(m, pane: pane(updatedAt: now.addingTimeInterval(-31)),
                                             visible: true, now: now))
    }

    // Polling a remote service to update a view nobody can see spends battery
    // and rate limit for nothing.
    func testAFocusedOnlyExtensionIsNotDueWhileItsTabIsOutOfSight() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m, pane: pane(updatedAt: now.addingTimeInterval(-60)),
                                              visible: false, now: now))
    }

    func testAnExtensionThatOptedOutOfFocusGatingPollsEitherWay() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30,\"whileFocusedOnly\":false}")
        XCTAssertTrue(ExtensionHost.isDue(m, pane: pane(updatedAt: now.addingTimeInterval(-60)),
                                             visible: false, now: now))
    }

    // The first fetch belongs to onOpen or to the user; the interval measures
    // the age of a document, and a pane with none has nothing to age.
    // The bug this split exists for: scheduling off updatedAt alone left a
    // failing extension permanently overdue, so its interval collapsed to the
    // ticker's 5s cadence and stayed there — measured at 18 spawns in 120s for a
    // 30s interval. A failed attempt has to restart the clock like a successful
    // one.
    func testAFailedFetchStillRestartsTheInterval() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        var pane = ExtensionHost.Pane()
        pane.updatedAt = now.addingTimeInterval(-3600)   // last success, long ago
        pane.attemptedAt = now.addingTimeInterval(-5)    // just failed
        XCTAssertFalse(ExtensionHost.isDue(m, pane: pane, visible: true, now: now),
                       "a just-failed extension must wait out its interval, not retry every tick")

        pane.attemptedAt = now.addingTimeInterval(-31)
        XCTAssertTrue(ExtensionHost.isDue(m, pane: pane, visible: true, now: now))
    }

    // Driven through the real path rather than the predicate, so the wiring in
    // finish() is what's under test.
    func testFinishRecordsAnAttemptWhateverTheOutcome() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .transient("exited 3"))
        XCTAssertNotNil(host.pane("derby").attemptedAt, "a failure is still an attempt")
        XCTAssertNil(host.pane("derby").updatedAt, "but it is not a success")
    }

    func testAPaneThatHasNeverSucceededIsNotDue() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m, pane: pane(updatedAt: nil),
                                              visible: true, now: now))
    }

    // A manifest is floored at parse time, but isDue is a pure static that has
    // to hold on its own — a zero interval makes `now - attemptedAt >= 0`
    // unconditionally true, so the extension re-spawns on every single tick.
    func testANonPositiveIntervalNeverBecomesDue() {
        let now = Date()
        for interval in [0, -5] {
            let m = ExtensionManifest(
                id: "derby", name: "D", version: "1", schema: 1,
                tab: .init(label: "D"), run: "./run", requires: [], config: [],
                refresh: .init(onOpen: true, intervalSeconds: interval, whileFocusedOnly: false))
            XCTAssertFalse(ExtensionHost.isDue(m,
                                               pane: pane(updatedAt: now.addingTimeInterval(-600)),
                                               visible: true, now: now),
                           "interval \(interval) must never schedule")
        }
    }

    func testABusyPaneIsNotDue() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m,
                                              pane: pane(updatedAt: now.addingTimeInterval(-60),
                                                         busy: true),
                                              visible: true, now: now))
    }

    // A click on a footer hint has to send what the keypress would. resolve()
    // reads a row action as belonging to the selected row and a document action
    // as belonging to none, so the pairing the footer renders must agree — a
    // document action sent with a row id would spawn `--action refresh --row x`
    // for a row the action was never about.
    func testADocumentActionCarriesNoRowAndARowActionCarriesItsOwn() {
        let json = """
            {"schema":1,
             "rows":[{"id":"h1","title":"A","actions":[{"id":"open","label":"Open","key":"o"}]}],
             "actions":[{"id":"refresh","label":"Sync now","key":"r"}]}
            """
        guard case .success(let document) = ExtensionDocument.parse(Data(json.utf8)) else {
            return XCTFail("fixture didn't parse")
        }
        XCTAssertEqual(ExtensionHost.resolve(key: "r", in: document, selectedRow: "h1")?.row, nil)
        XCTAssertEqual(ExtensionHost.resolve(key: "o", in: document, selectedRow: "h1")?.row, "h1")
        // With nothing selected a row action isn't reachable at all.
        XCTAssertNil(ExtensionHost.resolve(key: "o", in: document, selectedRow: nil))
    }

    // MARK: - Opening a tab

    func testOpeningATabRefreshesItUnlessTheManifestOptedOut() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby"),
                                 manifest("radar", refresh: "{\"onOpen\":false}")],
                                recorder: recorder)
        host.tabAppeared("derby")
        host.tabAppeared("radar")
        XCTAssertEqual(recorder.calls.map(\.id), ["derby"])
    }

    // The panel is an NSPanel that is ordered out, not torn down, so its SwiftUI
    // tree survives being hidden and `onAppear` — the only thing that calls
    // tabAppeared — does not fire again when it comes back. Reopening onto a tab
    // you were already on is therefore not an "open" as far as the host is
    // concerned, and the pane shows whatever it last fetched.
    //
    // This asks whether the scheduled refresh covers that gap on its own.
    // Switching to a tab is someone asking for that extension, so it refetches
    // every time. It had no floor before the panel-visible path existed and
    // must not acquire one now: the tab-switch-away-and-back escape hatch is
    // the only manual refresh an extension that declares no action has.
    func testSwitchingToATabAlwaysRefetches() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby", refresh: "{\"intervalSeconds\":600}")],
                                recorder: recorder)
        host.tabAppeared("derby")
        host.finish("derby", .transient("stub"))
        host.tabAppeared("derby")
        XCTAssertEqual(recorder.calls.count, 2, "an explicit switch is never suppressed")
    }

    // The panel reappearing over the tab someone happened to leave it on is not
    // a request for that extension, so it respects the cadence the manifest
    // asked for.
    //
    // The floor used to be ExtensionManifest.minimumIntervalSeconds, which is a
    // different number: that is the fastest any extension is *permitted* to
    // poll, not what this one chose. An extension asking for 600s against a
    // rate-limited API was spawned every 5s by someone toggling the panel.
    func testShowingThePanelRespectsTheManifestsOwnInterval() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby", refresh: "{\"intervalSeconds\":600}")],
                                recorder: recorder)
        let now = Date()
        host.tabAppeared("derby")
        host.finish("derby", .transient("stub"))
        XCTAssertEqual(recorder.calls.count, 1)

        // Well past the schema minimum, nowhere near what the extension asked
        // for: the old floor would have spawned here.
        host.panelBecameVisible("derby", now: now.addingTimeInterval(30))
        XCTAssertEqual(recorder.calls.count, 1)

        host.panelBecameVisible("derby", now: now.addingTimeInterval(601))
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testTheReopenFloorIsTheManifestsInterval() {
        XCTAssertEqual(ExtensionHost.reopenFloor(manifest("a", refresh: "{\"intervalSeconds\":600}")),
                       600)
        // No interval to read, so the schema minimum is the only sensible value.
        XCTAssertEqual(ExtensionHost.reopenFloor(manifest("b", refresh: "{\"onOpen\":true}")),
                       ExtensionManifest.minimumIntervalSeconds)
        // A declared interval below the minimum is clamped at parse time, so it
        // can never produce a floor under it.
        XCTAssertEqual(ExtensionHost.reopenFloor(manifest("c", refresh: "{\"intervalSeconds\":1}")),
                       ExtensionManifest.minimumIntervalSeconds)
    }

    // An extension that asks only for onOpen has no schedule to fall back on,
    // so showing the panel onto its tab is the only thing that can refresh it.
    func testATabWithNoScheduleStillRefreshesWhenThePanelComesBack() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby", refresh: "{\"onOpen\":true}")],
                                recorder: recorder)
        let now = Date()
        host.tabAppeared("derby")
        host.finish("derby", .transient("stub"))
        XCTAssertEqual(recorder.calls.count, 1)

        // Hidden for ten minutes. No interval, so no tick will ever help.
        var later = now
        for _ in 0..<120 {
            later = later.addingTimeInterval(5)
            host.tick(visibleTab: nil, now: later)
        }
        XCTAssertEqual(recorder.calls.count, 1)

        host.panelBecameVisible("derby", now: later)
        XCTAssertEqual(recorder.calls.count, 2,
                       "showing the panel is the only refresh this extension gets")
    }

    // The reported bug, end to end. An earlier version of this test drove only
    // `tick` and so passed identically without the fix — it was exercising the
    // pre-existing schedule, not the new path.
    func testReopeningOntoATabYouWereAlreadyOnRefetchesWithoutAKeypress() {
        let recorder = Recorder()
        let (host, _, _) = host([manifest("derby", refresh: "{\"intervalSeconds\":30}")],
                                recorder: recorder)
        host.tabAppeared("derby")
        host.finish("derby", .transient("stub"))
        XCTAssertEqual(recorder.calls.count, 1)

        // Hidden for five minutes: whileFocusedOnly means no polling, by design.
        var now = Date()
        for _ in 0..<60 {
            now = now.addingTimeInterval(5)
            host.tick(visibleTab: nil, now: now)
        }
        XCTAssertEqual(recorder.calls.count, 1, "a hidden pane must not poll")

        // The panel comes back. onAppear does not fire — the view never left
        // the tree — so this call is the only thing standing between the user
        // and stale numbers.
        host.panelBecameVisible("derby", now: now.addingTimeInterval(5))
        XCTAssertEqual(recorder.calls.count, 2)
    }
}
