import XCTest

@testable import StackNudgePanelCore

// The browser's state machine, driven with canned outcomes. Every side effect
// is injected, so an install can be made to fail without a network and the
// resulting pane state asserted directly.
@MainActor
final class ExtensionCatalogTests: XCTestCase {

    private func entry(_ id: String, version: String = "1.0.0")
        -> ExtensionInstaller.IndexEntry {
        .init(id: id, name: id.capitalized, version: version, description: "",
              asset: "\(id)-\(version).tar.gz", sha256: "abc", requires: [], config: [])
    }

    private func catalog(
        fetch: @escaping () -> Result<[ExtensionInstaller.IndexEntry], ExtensionInstaller.Failure>
            = { .success([]) },
        install: @escaping (ExtensionInstaller.IndexEntry) -> Result<String, ExtensionInstaller.Failure>
            = { .success($0.id) },
        remove: @escaping (String) -> Result<String, ExtensionInstaller.Failure>
            = { .success($0) },
        didChange: @escaping () -> Void = {}
    ) -> ExtensionCatalog {
        ExtensionCatalog(fetchCatalogue: fetch, performInstall: install, performRemove: remove,
                         background: { $0() }, toMain: { $0() }, didChange: didChange)
    }

    // The completion must come back through the main hop. Every other test
    // injects `toMain: { $0() }`, so deleting the hop entirely left the suite
    // green — and in production that is @Published mutated from a global queue,
    // which SwiftUI does not forgive. This is the one test that observes the
    // hop rather than stubbing it away.
    func testEveryCompletionIsDeliveredThroughTheMainHop() {
        var hops = 0
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { .success($0.id) },
                                 performRemove: { .success($0) },
                                 background: { $0() },
                                 toMain: { hops += 1; $0() })
        c.install(entry("derby"))
        XCTAssertEqual(hops, 1, "install published without hopping to main")

        c.remove("derby")
        XCTAssertEqual(hops, 2, "remove published without hopping to main")

        c.reload()
        XCTAssertEqual(hops, 3, "reload published without hopping to main")
    }

    // MARK: - The merged row model

    private func manifest(_ id: String, version: String,
                          config: [ExtensionManifest.ConfigKey] = []) -> ExtensionManifest {
        ExtensionManifest(id: id, name: id.capitalized, version: version, schema: 1,
                          tab: .init(label: id), run: "./run",
                          requires: [], config: config, refresh: .never)
    }

    // The form configures the version that actually runs. Taking the index's
    // list instead would offer a field for a key a newer release added and this
    // install ignores.
    func testAnInstalledExtensionsOwnKeysWinOverTheIndexs() {
        var published = entry("derby", version: "2.0.0")
        published = .init(id: published.id, name: published.name, version: published.version,
                          description: published.description, asset: published.asset,
                          sha256: published.sha256, requires: published.requires,
                          config: ["STACKNUDGE_EXT_NEW"])
        let installed = manifest("derby", version: "1.0.0",
                                 config: [.init(key: "STACKNUDGE_EXT_OLD", label: nil,
                                                help: nil, placeholder: nil)])
        let rows = ExtensionCatalog.rows(catalogue: [published],
                                         installed: [installed], refused: [])
        XCTAssertEqual(rows[0].config.map(\.key), ["STACKNUDGE_EXT_OLD"])
    }

    // The index carries key names and no metadata, on purpose: it is a wire
    // format read by binaries of every version. An uninstalled row only shows
    // the "Reads …" line, and isConfigurable requires an install, so a
    // label-less key never reaches a form.
    func testAnUninstalledRowTakesItsKeyNamesFromTheIndex() {
        var published = entry("derby")
        published = .init(id: published.id, name: published.name, version: published.version,
                          description: published.description, asset: published.asset,
                          sha256: published.sha256, requires: published.requires,
                          config: ["STACKNUDGE_EXT_DERBY_ORG"])
        let rows = ExtensionCatalog.rows(catalogue: [published], installed: [], refused: [])
        XCTAssertEqual(rows[0].configKeyList, "STACKNUDGE_EXT_DERBY_ORG")
        XCTAssertFalse(rows[0].isConfigurable)
    }

    // The browser used to render the catalogue, the installed set and the
    // refusals as three independent lists.
    func testACatalogueEntryThatIsAlsoInstalledIsOneRow() {
        let rows = ExtensionCatalog.rows(catalogue: [entry("derby")],
                                         installed: [manifest("derby", version: "1.0.0")],
                                         refused: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].installedVersion, "1.0.0")
        XCTAssertEqual(rows[0].availableVersion, "1.0.0")
        XCTAssertFalse(rows[0].updateAvailable)
    }

    // The flagship refusal case: published, installed, and outgrown by a newer
    // publish. It used to show an orange "Remove" directly above a card
    // offering "Install".
    func testARefusedExtensionThatIsAlsoPublishedIsOneRow() {
        let rows = ExtensionCatalog.rows(
            catalogue: [entry("derby")], installed: [],
            refused: [.init(id: "derby", reason: "needs manifest schema 2")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].refusedReason)
        XCTAssertTrue(rows[0].isInstalled, "a refusal is on disk, so it is removable")
    }

    // Installed but absent from the index — a hand-placed one, or one withdrawn
    // after publication. It appeared in no list at all while Settings counted it.
    func testAnInstalledExtensionMissingFromTheCatalogueIsStillListed() {
        let rows = ExtensionCatalog.rows(catalogue: [],
                                         installed: [manifest("local", version: "0.1")],
                                         refused: [])
        XCTAssertEqual(rows.map(\.id), ["local"])
        XCTAssertTrue(rows[0].isInstalled)
        XCTAssertNil(rows[0].availableVersion, "nothing to update to")
        XCTAssertFalse(rows[0].updateAvailable)
    }

    func testAnUpdateIsOfferedOnlyWhenBothVersionsAreKnownAndDiffer() {
        let rows = ExtensionCatalog.rows(catalogue: [entry("derby", version: "2.0.0")],
                                         installed: [manifest("derby", version: "1.0.0")],
                                         refused: [])
        XCTAssertTrue(rows[0].updateAvailable)
    }

    // Refusals first, then installed, then the rest — a refusal is what
    // somebody opened this page to understand.
    func testRowsAreOrderedRefusedThenInstalledThenAvailable() {
        let rows = ExtensionCatalog.rows(
            catalogue: [entry("available"), entry("installed"), entry("broken")],
            installed: [manifest("installed", version: "1.0.0")],
            refused: [.init(id: "broken", reason: "nope")])
        XCTAssertEqual(rows.map(\.id), ["broken", "installed", "available"])
    }

    func testTheSameIDFromEverySourceCollapsesToOneRow() {
        let rows = ExtensionCatalog.rows(
            catalogue: [entry("derby")],
            installed: [manifest("derby", version: "1.0.0")],
            refused: [.init(id: "derby", reason: "nope")])
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Keyboard

    private var threeRows: [ExtensionRow] {
        ExtensionCatalog.rows(catalogue: [entry("available")],
                              installed: [manifest("installed", version: "1.0.0")],
                              refused: [.init(id: "broken", reason: "nope")])
    }

    func testArrowsWalkTheRowsAndStopAtTheEnds() {
        let c = catalog()
        let rows = threeRows
        XCTAssertEqual(rows.map(\.id), ["broken", "installed", "available"])

        c.moveSelection(among: rows, by: 1)
        XCTAssertEqual(c.selectedID, "broken")
        c.moveSelection(among: rows, by: 1)
        c.moveSelection(among: rows, by: 1)
        XCTAssertEqual(c.selectedID, "available")
        c.moveSelection(among: rows, by: 1)
        XCTAssertEqual(c.selectedID, "available", "stops rather than wrapping")
    }

    func testUpFromNoSelectionTakesTheLastRow() {
        let c = catalog()
        c.moveSelection(among: threeRows, by: -1)
        XCTAssertEqual(c.selectedID, "available")
    }

    // Enter does whatever the row's own button would: install an uninstalled
    // one, remove an installed one.
    func testActivatingAnUninstalledRowInstallsIt() {
        var installed: [String] = []
        // Loaded, because activation resolves the row back to its index entry —
        // a row with nothing published behind it has nothing to install.
        let c = catalog(fetch: { .success([self.entry("available")]) },
                        install: { installed.append($0.id); return .success($0.id) })
        c.reload()
        c.selectedID = "available"
        c.activateSelection(among: threeRows)
        XCTAssertEqual(installed, ["available"])
    }

    // Enter never removes. Removal is on the extension's own page now, reached
    // from Settings → Extensions — Enter on a list where most rows install and
    // one deletes is a keystroke whose meaning depends on where the selection
    // happens to be, and the destructive end of that is the one you hit by
    // accident.
    func testActivatingAnInstalledRowDoesNotRemoveIt() {
        var removed: [String] = []
        let c = catalog(remove: { removed.append($0); return .success($0) })
        c.selectedID = "installed"
        c.activateSelection(among: threeRows)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertNil(c.work["installed"])
    }

    // A failed row is showing a reason, so Enter clears it rather than
    // immediately retrying something the user has not read yet.
    func testActivatingAFailedRowDismissesTheFailureFirst() {
        var attempts = 0
        let c = catalog(fetch: { .success([self.entry("available")]) },
                        install: { _ in attempts += 1; return .failure(.installFailed("no")) })
        c.reload()
        c.selectedID = "available"
        c.activateSelection(among: threeRows)
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(c.failure(for: "available"))

        c.activateSelection(among: threeRows)
        XCTAssertEqual(attempts, 1, "the second press dismissed rather than retried")
        XCTAssertNil(c.failure(for: "available"))
    }

    func testActivatingWithNothingSelectedDoesNothing() {
        var installed: [String] = []
        let c = catalog(install: { installed.append($0.id); return .success($0.id) })
        c.activateSelection(among: threeRows)
        XCTAssertTrue(installed.isEmpty)
    }

    // A selection pointing at a row that has gone would highlight nothing and
    // make Enter a no-op.
    func testTheSelectionIsDroppedWhenItsRowDisappears() {
        let c = catalog()
        c.selectedID = "installed"
        c.reconcileSelection(among: threeRows)
        XCTAssertEqual(c.selectedID, "installed")

        c.reconcileSelection(among: [])
        XCTAssertNil(c.selectedID)
    }

    // MARK: - Loading

    func testLoadingPublishesTheEntries() {
        let c = catalog(fetch: { .success([self.entry("derby"), self.entry("radar")]) })
        c.reload()
        XCTAssertEqual(c.load, .loaded)
        XCTAssertEqual(c.entries.map(\.id), ["derby", "radar"])
    }

    // A release published before extensions existed has no index at all, which
    // is an empty catalogue rather than something being wrong.
    func testAnEmptyCatalogueIsLoadedNotFailed() {
        let c = catalog(fetch: { .success([]) })
        c.reload()
        XCTAssertEqual(c.load, .loaded)
        XCTAssertTrue(c.entries.isEmpty)
    }

    func testAFailedLoadKeepsTheReason() {
        let c = catalog(fetch: { .failure(.downloadFailed("the release list")) })
        c.reload()
        guard case .failed(let why) = c.load else { return XCTFail("expected a failure") }
        XCTAssertTrue(why.contains("couldn't download"), why)
    }

    // loadIfNeeded is what onAppear calls, so it must not re-fetch every time
    // the pane is opened — but it must retry after a failure, or the only way
    // back is to quit.
    func testLoadIfNeededFetchesOnceButRetriesAfterAFailure() {
        var calls = 0
        let c = catalog(fetch: {
            calls += 1
            return calls == 1 ? .failure(.downloadFailed("x")) : .success([])
        })
        c.loadIfNeeded()
        XCTAssertEqual(calls, 1)
        c.loadIfNeeded()
        XCTAssertEqual(calls, 2, "a failed load must be retryable")
        c.loadIfNeeded()
        XCTAssertEqual(calls, 2, "a loaded catalogue must not re-fetch")
    }

    // MARK: - Installing

    // Re-discovery is what republishes the tab strip, so a tab appears without
    // the user restarting.
    func testASuccessfulInstallTriggersRediscovery() {
        var rediscovered = 0
        let c = catalog(didChange: { rediscovered += 1 })
        c.install(entry("derby"))
        XCTAssertNil(c.work["derby"])
        XCTAssertEqual(rediscovered, 1)
    }

    func testAFailedInstallKeepsItsReasonAgainstThatExtension() {
        let c = catalog(install: { _ in .failure(.checksumMismatch(expected: "a", actual: "b")) })
        c.install(entry("derby"))
        guard case .failed(let why) = c.work["derby"] else { return XCTFail("expected a failure") }
        XCTAssertTrue(why.contains("checksum"), why)
    }

    // One failing install must not make the others look broken.
    func testAFailureIsPerExtension() {
        let c = catalog(install: { $0.id == "derby" ? .failure(.installFailed("no")) : .success($0.id) })
        c.install(entry("derby"))
        c.install(entry("radar"))
        XCTAssertNotNil(c.work["derby"])
        XCTAssertNil(c.work["radar"])
    }

    func testAFailureCanBeDismissed() {
        let c = catalog(install: { _ in .failure(.installFailed("no")) })
        c.install(entry("derby"))
        c.dismissFailure(for: "derby")
        XCTAssertNil(c.work["derby"])
    }

    // Dismissing is for a failure, not for an install still running — otherwise
    // a click would hide a spinner that is still doing something.
    func testDismissingDoesNotClearWorkInFlight() {
        var release: (() -> Void)?
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { _ in .success("derby") },
                                 performRemove: { .success($0) },
                                 background: { work in release = work },
                                 toMain: { $0() })
        c.install(entry("derby"))
        XCTAssertEqual(c.work["derby"], .installing)
        c.dismissFailure(for: "derby")
        XCTAssertEqual(c.work["derby"], .installing)
        release?()
    }

    // A second press while one is in flight would race to publish.
    //
    // The previous version of this test asserted nothing: it used
    // `background: { _ in }`, so the runner never executed and `calls == 0`
    // held whether or not the gate existed. The deferred shape below — capture
    // the work, assert, then release it — is what actually observes it, and is
    // the same pattern the dismiss test already used.
    func testASecondInstallWhileOneIsRunningIsIgnored() {
        var calls = 0
        var pending: [() -> Void] = []
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { _ in calls += 1; return .success("derby") },
                                 performRemove: { .success($0) },
                                 background: { pending.append($0) },
                                 toMain: { $0() })
        c.install(entry("derby"))
        c.install(entry("derby"))
        XCTAssertEqual(pending.count, 1, "the second press must not dispatch")

        pending.forEach { $0() }
        XCTAssertEqual(calls, 1)
    }

    func testASecondRemoveWhileOneIsRunningIsIgnored() {
        var calls = 0
        var pending: [() -> Void] = []
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { .success($0.id) },
                                 performRemove: { _ in calls += 1; return .success("derby") },
                                 background: { pending.append($0) },
                                 toMain: { $0() })
        c.remove("derby")
        c.remove("derby")
        XCTAssertEqual(pending.count, 1)
        pending.forEach { $0() }
        XCTAssertEqual(calls, 1)
    }

    // Retrying after a failure has to actually start something. The buttons
    // render enabled in the failed state, so a gate on "has ever failed" made
    // the obvious response to an error a silent no-op.
    func testInstallCanBeRetriedAfterAFailure() {
        var attempts = 0
        let c = catalog(install: { entry in
            attempts += 1
            return attempts == 1 ? .failure(.installFailed("no")) : .success(entry.id)
        })
        c.install(entry("derby"))
        XCTAssertNotNil(c.failure(for: "derby"))

        c.install(entry("derby"))
        XCTAssertEqual(attempts, 2, "a failed row must be retryable without dismissing first")
        XCTAssertNil(c.failure(for: "derby"))
    }

    func testRemoveCanBeRetriedAfterAFailure() {
        var attempts = 0
        let c = catalog(remove: { id in
            attempts += 1
            return attempts == 1 ? .failure(.installFailed("no")) : .success(id)
        })
        c.remove("derby")
        c.remove("derby")
        XCTAssertEqual(attempts, 2)
    }

    // A failed row is idle, not in flight — it is showing a reason, not doing
    // anything, so it must not render a spinner.
    func testAFailedRowIsNotBusy() {
        let c = catalog(install: { _ in .failure(.installFailed("no")) })
        c.install(entry("derby"))
        XCTAssertFalse(c.isBusy("derby"))
        XCTAssertNotNil(c.failure(for: "derby"))
    }

    // Reload is what both the R key and "Try again" call, and each ungated call
    // blocks a pool thread inside the fetch.
    func testReloadIsGatedWhileOneIsInFlight() {
        var calls = 0
        var pending: [() -> Void] = []
        let c = ExtensionCatalog(fetchCatalogue: { calls += 1; return .success([]) },
                                 performInstall: { .success($0.id) },
                                 performRemove: { .success($0) },
                                 background: { pending.append($0) },
                                 toMain: { $0() })
        c.reload()
        c.reload()
        c.reload()
        XCTAssertEqual(pending.count, 1, "three presses, one fetch")
        pending.forEach { $0() }
        XCTAssertEqual(calls, 1)

        c.reload()
        XCTAssertEqual(pending.count, 2, "gated while in flight, not forever")
    }

    // The published state has to be set before the work is dispatched, or a
    // synchronous runner would clear it and leave the row looking idle.
    func testTheRowIsMarkedBusyBeforeTheWorkIsDispatched() {
        var observed: Bool?
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { .success($0.id) },
                                 performRemove: { .success($0) },
                                 background: { _ in },
                                 toMain: { $0() })
        c.install(entry("derby"))
        observed = c.isBusy("derby")
        XCTAssertEqual(observed, true)
    }

    // MARK: - Removing    // MARK: - Removing

    func testRemovingAlsoTriggersRediscovery() {
        var rediscovered = 0
        let c = catalog(didChange: { rediscovered += 1 })
        c.remove("derby")
        XCTAssertNil(c.work["derby"])
        XCTAssertEqual(rediscovered, 1)
    }

    func testAFailedRemovalKeepsItsReason() {
        let c = catalog(remove: { _ in .failure(.installFailed("permission denied")) })
        c.remove("derby")
        guard case .failed = c.work["derby"] else { return XCTFail("expected a failure") }
    }

    // MARK: - Search

    private func row(_ id: String, name: String, description: String = "",
                     installed: Bool = false,
                     config: [ExtensionManifest.ConfigKey] = []) -> ExtensionRow {
        ExtensionRow(id: id, name: name, description: description,
                     installedVersion: installed ? "1.0.0" : nil,
                     availableVersion: "1.0.0", refusedReason: nil,
                     requires: [], config: config)
    }

    private var sample: [ExtensionRow] {
        [row("derby", name: "Token Derby", description: "A horse race."),
         row("system", name: "System", description: "CPU, memory and disk.")]
    }

    func testAnEmptyQueryFiltersNothing() {
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "").count, 2)
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "   ").count, 2)
    }

    func testTheQueryMatchesTheNameCaseInsensitively() {
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "token").map(\.id), ["derby"])
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "TOKEN").map(\.id), ["derby"])
    }

    // The id is what the config keys, the directory and the docs all use.
    // Somebody who knows an extension as "derby" should not have to remember
    // that it is called "Token Derby" to find it.
    func testTheQueryMatchesTheIDAndTheDescription() {
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "derby").map(\.id), ["derby"])
        XCTAssertEqual(ExtensionCatalog.matching(sample, query: "memory").map(\.id), ["system"])
    }

    func testAQueryThatMatchesNothingReturnsNothingRatherThanEverything() {
        XCTAssertTrue(ExtensionCatalog.matching(sample, query: "zzz").isEmpty)
    }

    // Filtering is exactly the case that made reconcileSelection matter: the
    // method existed from the start and nothing but a test ever called it, so a
    // selection could point at a row that is no longer on screen and Enter
    // would silently do nothing.
    func testAQueryThatHidesTheSelectedRowDropsTheSelection() {
        let c = catalog()
        c.selectedID = "derby"
        c.reconcileSelection(among: ExtensionCatalog.matching(sample, query: "system"))
        XCTAssertNil(c.selectedID)
    }

    func testAQueryThatStillShowsTheSelectedRowKeepsIt() {
        let c = catalog()
        c.selectedID = "derby"
        c.reconcileSelection(among: ExtensionCatalog.matching(sample, query: "derby"))
        XCTAssertEqual(c.selectedID, "derby")
    }

    func testMatchingPreservesTheOrderItWasGiven() {
        // The rows arrive already sorted — refusals first, then installed — and
        // a filter that reordered them would move the selection under the user.
        let rows = ExtensionCatalog.matching(sample, query: "e")
        XCTAssertEqual(rows.map(\.id), sample.filter { rows.contains($0) }.map(\.id))
    }

    // MARK: - Configurability

    func testOnlyAnInstalledExtensionThatDeclaredAKeyIsConfigurable() {
        let key = ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_DERBY_ORG",
                                              label: nil, help: nil, placeholder: nil)
        XCTAssertTrue(row("derby", name: "D", installed: true, config: [key]).isConfigurable)
        // Nothing declared: there is no form to render.
        XCTAssertFalse(row("derby", name: "D", installed: true).isConfigurable)
        // Not installed: there is nowhere for the value to take effect.
        XCTAssertFalse(row("derby", name: "D", config: [key]).isConfigurable)
    }

    func testTheCardListsTheKeysRatherThanTheirLabels() {
        // This line is about what the extension can read, and the key is the
        // thing a reviewer recognises from the manifest.
        let keys = [ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_A", label: "Alpha",
                                                help: nil, placeholder: nil),
                    ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_B", label: nil,
                                                help: nil, placeholder: nil)]
        XCTAssertEqual(row("derby", name: "D", config: keys).configKeyList,
                       "STACKNUDGE_EXT_A, STACKNUDGE_EXT_B")
    }
}
