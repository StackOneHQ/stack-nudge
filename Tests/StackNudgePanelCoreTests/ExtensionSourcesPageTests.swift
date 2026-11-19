import AppKit
import XCTest

@testable import StackNudgePanelCore

// Settings → Extensions → Other catalogues: editing the sources setting, what
// each row says about its repository, the sync record behind that, and the
// page's keys.
final class ExtensionSourcesPageTests: XCTestCase {

    private func entry(_ id: String, source: String? = nil) -> ExtensionInstaller.IndexEntry {
        var entry = ExtensionInstaller.IndexEntry(id: id, name: id, version: "1", description: "",
                                                  asset: "extension-\(id)-1.tar.gz", sha256: "ab",
                                                  requires: [], config: [], tier: nil)
        entry.source = source
        return entry
    }

    private let internalSlug = "StackOneHQ/stack-nudge-internal-marketplace"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Editing the setting

    func testAddingAppendsInOrderAndKeepsWhatIsAlreadyThere() {
        let actual = ExtensionSource.adding(" someone/extensions ", to: "\(internalSlug), not a repo")
        XCTAssertEqual(actual, .success("\(internalSlug),not a repo,someone/extensions"))
        XCTAssertEqual(ExtensionSource.adding(internalSlug, to: nil), .success(internalSlug))
    }

    func testAddingRefusesWhatCouldNeverBeRead() {
        XCTAssertEqual(ExtensionSource.adding("StackOneHQ", to: nil), .failure(.notOwnerRepo))
        XCTAssertEqual(ExtensionSource.adding("owner/repo?x=1", to: nil), .failure(.notOwnerRepo))
        XCTAssertEqual(ExtensionSource.adding("stackonehq/STACK-NUDGE", to: nil), .failure(.builtIn))
        XCTAssertEqual(ExtensionSource.adding("stackonehq/stack-nudge-internal-marketplace", to: internalSlug),
                       .failure(.alreadyAdded), "the same repository under any case")
    }

    func testRemovingTakesRepeatsOfTheSameRepositoryAndKeepsTheRest() {
        let value = "\(internalSlug), someone/extensions, stackonehq/stack-nudge-internal-marketplace, bad entry"
        XCTAssertEqual(ExtensionSource.removing(internalSlug, from: value), "someone/extensions,bad entry")
        XCTAssertEqual(ExtensionSource.removing("bad entry", from: value),
                       "\(internalSlug),someone/extensions,stackonehq/stack-nudge-internal-marketplace",
                       "an entry that isn't owner/repo goes by its text")
        XCTAssertNil(ExtensionSource.removing(internalSlug, from: internalSlug), "nothing left removes the key")
    }

    // MARK: - The page's model

    private final class Store {
        var value: String?
        var writes: [String?] = []
        var changes = 0
        init(_ value: String?) { self.value = value }
    }

    private func page(_ value: String?) -> (ExtensionSources, Store) {
        let store = Store(value)
        let model = ExtensionSources(readValue: { store.value },
                                     writeValue: { store.value = $0; store.writes.append($0) },
                                     didChange: { store.changes += 1 })
        model.load()
        return (model, store)
    }

    func testTheAppsOwnRepositoryIsAlwaysFirstAndCannotBeRemoved() {
        let (model, store) = page(internalSlug)
        XCTAssertEqual(model.rows.map(\.entry), [ExtensionSource.builtIn.slug, internalSlug])
        model.selection = 0
        model.removeSelected()
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.changes, 0)
    }

    func testAddingWritesTheSettingSelectsTheNewRowAndSyncs() {
        let (model, store) = page(nil)
        model.draft = internalSlug
        XCTAssertTrue(model.add())
        XCTAssertEqual(store.writes, [internalSlug])
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.selectedRow?.entry, internalSlug)
        XCTAssertEqual(store.changes, 1)
    }

    func testARefusedEntryIsExplainedNotWrittenAndTheExplanationGoesWhenTheFieldChanges() {
        let (model, store) = page(nil)
        model.draft = "not a repo"
        XCTAssertFalse(model.add())
        XCTAssertEqual(model.problem, ExtensionSource.EditProblem.notOwnerRepo.message)
        XCTAssertEqual(model.draft, "not a repo", "kept to be corrected")
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.changes, 0)
        model.draft = "not a rep"
        XCTAssertNil(model.problem)
    }

    // The file is read again before writing, so a change made by hand while
    // the page was open isn't overwritten by the page's older copy.
    func testEditsBuildOnTheFileNotThePagesCopy() {
        let (model, store) = page(nil)
        store.value = "someone/extensions"
        model.draft = internalSlug
        model.add()
        XCTAssertEqual(store.value, "someone/extensions,\(internalSlug)")
    }

    func testRemovingTheLastRowWritesNothingLeftAndSelectsTheRowAbove() {
        let (model, store) = page("\(internalSlug),someone/extensions")
        model.jump(toLast: true)
        model.removeSelected()
        XCTAssertEqual(store.value, internalSlug)
        XCTAssertEqual(model.selectedRow?.entry, internalSlug)
        model.removeSelected()
        XCTAssertEqual(store.writes.last, .some(nil), "the key goes once the list is empty")
        XCTAssertEqual(model.selectedRow?.isBuiltIn, true)
        XCTAssertEqual(store.changes, 2)
    }

    func testSelectionStopsAtTheEnds() {
        let (model, _) = page(internalSlug)
        model.move(by: 1)
        XCTAssertEqual(model.selection, 0, "the first press lands on the first row")
        model.move(by: 5)
        XCTAssertEqual(model.selection, 1)
        model.move(by: -5)
        XCTAssertEqual(model.selection, 0)
    }

    func testARepeatOfAnEarlierRepositoryIsMarked() {
        let rows = ExtensionSources.rows(value: "\(internalSlug),STACKONEHQ/stack-nudge-internal-marketplace")
        XCTAssertEqual(rows.map(\.repeatsEarlier), [false, false, true])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "each row has its own id")
    }

    func testTheSettingsRowCountsRepositories() {
        XCTAssertEqual(ExtensionSources.settingsValue(nil), "None")
        XCTAssertEqual(ExtensionSources.settingsValue(internalSlug), "1 repo")
        XCTAssertEqual(ExtensionSources.settingsValue("\(internalSlug), a/b"), "2 repos")
    }

    // MARK: - What a row says

    private func row(_ value: String, at index: Int = 1) -> ExtensionSources.Row {
        ExtensionSources.rows(value: value)[index]
    }

    func testARowSaysWhenItLastSyncedAndHowMuchItLists() {
        let sync = ExtensionCatalog.SourceSync(attempted: now, synced: now, extensions: 1, failure: nil)
        XCTAssertEqual(ExtensionSources.status(of: row(internalSlug), sync: sync, loading: false, now: now).text,
                       "Synced just now · 1 extension")
        let older = ExtensionCatalog.SourceSync(attempted: now - 600, synced: now - 600, extensions: 3, failure: nil)
        let status = ExtensionSources.status(of: row(internalSlug), sync: older, loading: false, now: now)
        XCTAssertTrue(status.text.hasPrefix("Synced "), status.text)
        XCTAssertFalse(status.text.contains("just now"), status.text)
        XCTAssertTrue(status.text.hasSuffix(" · 3 extensions"), status.text)
        XCTAssertEqual(status.tone, .normal)
    }

    func testAFailedReadSaysWhyAndWhenItLastWorked() {
        let never = ExtensionCatalog.SourceSync(attempted: now, synced: nil, extensions: nil, failure: "nope.")
        let first = ExtensionSources.status(of: row(internalSlug), sync: never, loading: false, now: now)
        XCTAssertEqual(first.text, "Couldn't read it just now: nope.")
        XCTAssertEqual(first.tone, .warning)
        let before = ExtensionCatalog.SourceSync(attempted: now, synced: now - 3600, extensions: 2, failure: "nope.")
        let status = ExtensionSources.status(of: row(internalSlug), sync: before, loading: false, now: now)
        XCTAssertTrue(status.text.contains(" Last synced "), status.text)
        XCTAssertEqual(status.tone, .warning)
    }

    func testARowWithNoRecordSaysWhetherASyncIsUnderWay() {
        XCTAssertEqual(ExtensionSources.status(of: row(internalSlug), sync: nil, loading: true, now: now).text,
                       "Syncing…")
        XCTAssertEqual(ExtensionSources.status(of: row(internalSlug), sync: nil, loading: false, now: now).text,
                       "Not synced yet")
    }

    func testEntriesTheFetchSkipsSayWhy() {
        let bad = ExtensionSources.status(of: row("bad entry"), sync: nil, loading: false, now: now)
        XCTAssertEqual(bad.text, "Not owner/repo, so it's skipped")
        XCTAssertEqual(bad.tone, .warning)
        XCTAssertEqual(ExtensionSources.status(of: row("stackonehq/stack-nudge"), sync: nil, loading: false,
                                               now: now).text,
                       "Always read, so this entry does nothing")
        XCTAssertEqual(ExtensionSources.status(of: row("\(internalSlug),\(internalSlug)", at: 2), sync: nil,
                                               loading: false, now: now).text,
                       "Already listed above, so this entry does nothing")
    }

    // What a repository may grant comes from the list in the app, so a row can
    // only ever say what the binary decided.
    func testTheGrantLineFollowsTheReviewedList() {
        let rows = ExtensionSources.rows(value: "\(internalSlug),someone/extensions,bad entry")
        XCTAssertEqual(rows.map(ExtensionSources.ceilingText), ["Can grant up to trusted", "Can grant up to trusted",
                                                               "View only", nil])
        XCTAssertEqual(ExtensionSources.ceilingText(of: row("StackOneHQ/other-repo")), "View only",
                       "another StackOneHQ repository is not on the list")
    }

    // MARK: - The sync record

    func testAFetchRecordsEverySourceItReadAnEmptyOneIncluded() {
        let catalogue = ExtensionInstaller.Catalogue(
            entries: [entry("derby"), entry("claude-usage", source: internalSlug)],
            listings: [entry("derby"), entry("claude-usage", source: internalSlug),
                       entry("derby", source: internalSlug)],
            unavailable: ["someone/extensions": "nope."],
            read: [internalSlug, "a/empty"])
        let actual = ExtensionCatalog.syncs(after: catalogue, previous: [:], at: now)
        XCTAssertEqual(actual[ExtensionCatalog.syncKey(ExtensionSource.builtIn.slug)],
                       .init(attempted: now, synced: now, extensions: 1, failure: nil))
        XCTAssertEqual(actual[ExtensionCatalog.syncKey(internalSlug)],
                       .init(attempted: now, synced: now, extensions: 2, failure: nil),
                       "a listing whose id was taken still counts")
        XCTAssertEqual(actual["a/empty"], .init(attempted: now, synced: now, extensions: 0, failure: nil))
        XCTAssertEqual(actual["someone/extensions"], .init(attempted: now, synced: nil, extensions: nil,
                                                           failure: "nope."))
    }

    func testAFailedReadKeepsWhenTheSourceLastWorked() {
        let earlier = now - 600
        let previous = ["someone/extensions": ExtensionCatalog.SourceSync(attempted: earlier, synced: earlier,
                                                                          extensions: 4, failure: nil)]
        let catalogue = ExtensionInstaller.Catalogue(entries: [], unavailable: ["someone/extensions": "nope."])
        XCTAssertEqual(ExtensionCatalog.syncs(after: catalogue, previous: previous, at: now)["someone/extensions"],
                       .init(attempted: now, synced: earlier, extensions: 4, failure: "nope."))
    }

    func testTheAppsOwnFailingIsRecordedAgainstItAlone() {
        let actual = ExtensionCatalog.syncs(afterFailure: "down.", previous: [:], at: now)
        XCTAssertEqual(actual, [ExtensionCatalog.syncKey(ExtensionSource.builtIn.slug):
            .init(attempted: now, synced: nil, extensions: nil, failure: "down.")])
    }

    func testMergingNamesTheSourcesItRead() {
        let source = ExtensionSource(slug: internalSlug)!
        let other = ExtensionSource(owner: "someone", repo: "extensions")
        let actual = ExtensionInstaller.merging(builtIn: [], extra: [(source: source, result: .success([])),
                                                                     (source: other, result: .failure(.catalogueUnavailable))])
        XCTAssertEqual(actual.read, [internalSlug])
        XCTAssertEqual(Array(actual.unavailable.keys), ["someone/extensions"])
    }

    // The page changes the setting while a fetch may be running, and that
    // fetch may have read the setting before the change. reload() alone would
    // drop the second request, so the change has to wait its turn instead.
    func testAReloadAskedForMidFetchRunsOnceItLands() {
        var jobs: [() -> Void] = []
        var fetches = 0
        let catalog = ExtensionCatalog(fetchCatalogue: { fetches += 1; return .success([]) },
                                       background: { jobs.append($0) }, toMain: { $0() },
                                       probeRequirement: { _ in .works },
                                       recordedTiers: { [:] }, recordedSources: { [:] })
        catalog.reload()
        catalog.requestReload()
        catalog.requestReload()
        XCTAssertEqual(jobs.count, 1, "nothing starts beside the running fetch")
        jobs.removeFirst()()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(jobs.count, 1, "the asked-for one starts once the first lands")
        guard !jobs.isEmpty else { return }
        jobs.removeFirst()()
        XCTAssertEqual(fetches, 2)
        XCTAssertTrue(jobs.isEmpty, "two asks while loading are one reload")
        catalog.requestReload()
        XCTAssertEqual(jobs.count, 1, "and when idle it simply reloads")
    }

    // MARK: - Keys

    private func key(_ code: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = [],
                     isRepeat: Bool = false) -> PanelController.ExtensionSourcesKeyAction? {
        PanelController.extensionSourcesKeyAction(keyCode: code, characters: characters,
                                                  modifiers: modifiers, isRepeat: isRepeat)
    }

    // Raw key codes, since the panel's names for them are private: ← 123,
    // → 124, ↓ 125, ↑ 126, / 44, ⏎ 36, R 15.
    func testTheKeyTable() {
        XCTAssertEqual(key(123), .back)
        XCTAssertEqual(key(126), .moveSelection(-1))
        XCTAssertEqual(key(125), .moveSelection(1))
        XCTAssertEqual(key(44, "/"), .focusField)
        XCTAssertEqual(key(36, "\r"), .focusField, "⏎ starts an entry, which it then adds")
        XCTAssertEqual(key(15, "r", .command), .sync)
        XCTAssertEqual(key(15, "r"), .appendToDraft("r"), "a plain letter is the start of a name")
    }

    func testKeysThatStartWorkIgnoreAutorepeat() {
        XCTAssertEqual(key(15, "r", .command, isRepeat: true), .swallow)
        XCTAssertEqual(key(36, "\r", isRepeat: true), .swallow)
    }

    func testOtherCommandCombinationsGoToTheAppAndNothingElseReachesEvents() {
        XCTAssertNil(key(12, "q", .command), "⌘Q")
        XCTAssertNil(key(15, "r", .option))
        // An arrow's private-use character is not something to type.
        XCTAssertEqual(key(124, "\u{F703}"), .swallow)
    }
}
