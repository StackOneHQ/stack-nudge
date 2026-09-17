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

    private func manifest(_ id: String, version: String) -> ExtensionManifest {
        ExtensionManifest(id: id, name: id.capitalized, version: version, schema: 1,
                          tab: .init(label: id), run: "./run",
                          requires: [], config: [], refresh: .never)
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
}
