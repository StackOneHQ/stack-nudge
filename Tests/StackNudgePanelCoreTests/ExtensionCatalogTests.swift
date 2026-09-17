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
    func testASecondInstallWhileOneIsRunningIsIgnored() {
        var calls = 0
        let c = ExtensionCatalog(fetchCatalogue: { .success([]) },
                                 performInstall: { _ in calls += 1; return .success("derby") },
                                 performRemove: { .success($0) },
                                 background: { _ in },   // never completes
                                 toMain: { $0() })
        c.install(entry("derby"))
        c.install(entry("derby"))
        XCTAssertEqual(calls, 0, "the runner never ran; the gate is on the state")
        XCTAssertEqual(c.work["derby"], .installing)
    }

    // MARK: - Removing

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
