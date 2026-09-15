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
        host.load(manifests)
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
        host.load([])
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
        made.load([manifest("derby")])
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

    func testAnUnboundKeyIsNotHandled() {
        let (host, _, _) = host([manifest("derby")])
        host.finish("derby", .ok(twoRows))
        XCTAssertFalse(host.handle(key: "q", on: "derby"))
    }

    // MARK: - Scheduled refresh

    private func pane(updatedAt: Date?, busy: Bool = false) -> ExtensionHost.Pane {
        var pane = ExtensionHost.Pane()
        pane.updatedAt = updatedAt
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
    func testAPaneThatHasNeverSucceededIsNotDue() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m, pane: pane(updatedAt: nil),
                                              visible: true, now: now))
    }

    func testABusyPaneIsNotDue() {
        let now = Date()
        let m = manifest("derby", refresh: "{\"intervalSeconds\":30}")
        XCTAssertFalse(ExtensionHost.isDue(m,
                                              pane: pane(updatedAt: now.addingTimeInterval(-60),
                                                         busy: true),
                                              visible: true, now: now))
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
}
