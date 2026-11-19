import XCTest

@testable import StackNudgePanelCore

// Extra catalogues: which repositories count as one, what each may grant, how
// their entries merge with the app's own, and how a private one is read
// without the token going anywhere it shouldn't.
final class ExtensionSourceTests: XCTestCase {

    private func entry(_ id: String, tier: String? = nil, version: String = "1") -> ExtensionInstaller.IndexEntry {
        ExtensionInstaller.IndexEntry(id: id, name: id, version: version, description: "",
                                      asset: "extension-\(id)-\(version).tar.gz", sha256: "ab",
                                      requires: [], config: [], tier: tier)
    }

    private let internalSource = ExtensionSource(owner: "StackOneHQ", repo: "stack-nudge-internal-marketplace")
    private let outsideSource = ExtensionSource(owner: "someone", repo: "extensions")

    // MARK: - Naming a source

    func testASlugIsOwnerAndRepo() {
        XCTAssertEqual(ExtensionSource(slug: " StackOneHQ/stack-nudge-internal-marketplace "),
                       internalSource)
        XCTAssertEqual(ExtensionSource(slug: "a-b/c.d_e")?.repo, "c.d_e")
    }

    // Both halves go into an API path, so anything GitHub wouldn't accept as a
    // name is refused rather than escaped.
    func testASlugThatIsNotOwnerAndRepoIsRefused() {
        for bad in ["", "StackOneHQ", "a/b/c", "/repo", "owner/", "own_er/repo", "-owner/repo",
                    "owner/..", "owner/.", "owner/re po", "owner/repo?x=1", "owner/repo#x"] {
            XCTAssertNil(ExtensionSource(slug: bad), bad)
        }
    }

    func testTheSettingListsExtraSourcesInOrderWithoutRepeats() {
        let config = [ExtensionSource.configKey:
            "StackOneHQ/stack-nudge-internal-marketplace, someone/extensions,stackonehq/STACK-NUDGE-INTERNAL-MARKETPLACE"]
        let actual = ExtensionSource.configured(config)
        XCTAssertEqual(actual.sources, [internalSource, outsideSource])
        XCTAssertEqual(actual.ignored, [])
    }

    // The app's own repository is always the first source, so naming it again,
    // in any case, doesn't add a second copy of it with an extra source's rules.
    func testTheAppsOwnRepositoryIsNeverAnExtraSource() {
        let actual = ExtensionSource.configured([ExtensionSource.configKey: "stackonehq/Stack-Nudge"])
        XCTAssertEqual(actual.sources, [])
    }

    func testAnEntryThatIsNotOwnerAndRepoIsNamedAsIgnored() {
        let actual = ExtensionSource.configured([ExtensionSource.configKey: "nonsense, ,someone/extensions"])
        XCTAssertEqual(actual.sources, [outsideSource])
        XCTAssertEqual(actual.ignored, ["nonsense"])
    }

    func testNoSettingIsNoExtraSources() {
        let actual = ExtensionSource.configured([:])
        XCTAssertEqual(actual.sources, [])
        XCTAssertEqual(actual.ignored, [])
    }

    // MARK: - What a source may grant

    func testOnlyTheReviewedRepositoriesKeepTheirTiers() {
        XCTAssertEqual(ExtensionSource.builtIn.ceiling, .trusted)
        XCTAssertEqual(internalSource.ceiling, .trusted)
        XCTAssertEqual(ExtensionSource(owner: "stackonehq", repo: "STACK-NUDGE-INTERNAL-MARKETPLACE").ceiling,
                       .trusted)
        XCTAssertEqual(outsideSource.ceiling, .view)
        // A lookalike owner is someone else.
        XCTAssertEqual(ExtensionSource(owner: "StackOneHQ-extensions", repo: "x").ceiling, .view)
    }

    // Owning a repository says nothing about who can publish its releases, so
    // the rest of StackOneHQ's repositories are held to view like anyone's.
    func testAnotherStackOneHQRepositoryIsHeldToView() {
        XCTAssertEqual(ExtensionSource(owner: "StackOneHQ", repo: "anything").ceiling, .view)
        let actual = ExtensionInstaller.merging(
            builtIn: [],
            extra: [(source: ExtensionSource(owner: "StackOneHQ", repo: "anything"),
                     result: .success([entry("away", tier: "trusted")]))])
        XCTAssertEqual(actual.entries.first?.reviewedTier, .view)
    }

    // MARK: - Merging

    func testTheAppsOwnEntriesAreUntouched() {
        let own = entry("derby", tier: "service")
        let actual = ExtensionInstaller.merging(builtIn: [own], extra: [])
        XCTAssertEqual(actual.entries, [own])
        XCTAssertEqual(actual.listings, [own])
        XCTAssertTrue(actual.unavailable.isEmpty)
    }

    func testAnExtraEntryIsStampedWithItsSource() {
        let actual = ExtensionInstaller.merging(
            builtIn: [], extra: [(source: internalSource, result: .success([entry("claude-usage")]))])
        XCTAssertEqual(actual.entries.map(\.source), ["StackOneHQ/stack-nudge-internal-marketplace"])
    }

    func testAStackOneHQSourceKeepsTheTierItsReviewersGave() {
        let actual = ExtensionInstaller.merging(
            builtIn: [], extra: [(source: internalSource, result: .success([entry("away", tier: "trusted")]))])
        XCTAssertEqual(actual.entries.first?.reviewedTier, .trusted)
    }

    func testAnyOtherSourceIsHeldToView() {
        let actual = ExtensionInstaller.merging(
            builtIn: [], extra: [(source: outsideSource, result: .success([entry("away", tier: "trusted")]))])
        XCTAssertEqual(actual.entries.first?.tier, "view")
        XCTAssertEqual(actual.entries.first?.reviewedTier, .view)
    }

    // The id is the directory it installs into. An extra source listing one of
    // the app's own ids must not replace it, whatever version it claims.
    func testTheFirstSourceToListAnIdKeepsIt() {
        let own = entry("derby", version: "1")
        let actual = ExtensionInstaller.merging(
            builtIn: [own],
            extra: [(source: internalSource, result: .success([entry("derby", tier: "trusted", version: "9"),
                                                              entry("radar")])),
                    (source: outsideSource, result: .success([entry("radar", version: "9")]))])
        XCTAssertEqual(actual.entries.map(\.id), ["derby", "radar"])
        XCTAssertEqual(actual.entries.first, own)
        XCTAssertEqual(actual.entries.last?.source, internalSource.slug)
    }

    // What a later source lists under a taken id still counts for a copy
    // installed from that source, so it's kept, stamped and capped, in
    // `listings`.
    func testAnEntryAnotherSourceTookIsStillListed() {
        let actual = ExtensionInstaller.merging(
            builtIn: [entry("derby")],
            extra: [(source: outsideSource, result: .success([entry("derby", tier: "trusted")]))])
        XCTAssertEqual(actual.entries.map(\.id), ["derby"])
        XCTAssertEqual(actual.listings.map(\.source), [nil, outsideSource.slug])
        XCTAssertEqual(actual.listings.last?.reviewedTier, .view)
    }

    func testASourceThatFailsIsNamedAndTheRestStillLoad() {
        let actual = ExtensionInstaller.merging(
            builtIn: [entry("derby")],
            extra: [(source: outsideSource, result: .failure(.sourceUnavailable(outsideSource.slug, signedIn: true))),
                    (source: internalSource, result: .success([entry("claude-usage")]))])
        XCTAssertEqual(actual.entries.map(\.id), ["derby", "claude-usage"])
        XCTAssertEqual(Array(actual.unavailable.keys), ["someone/extensions"])
    }

    // The source is the host's to say. An index that writes one in is ignored,
    // so an entry from the app's own release can't pass itself off as another
    // source's, or the other way round.
    func testAnIndexCannotNameItsOwnSource() {
        let json = """
            {"schema":1,"extensions":[{"id":"away","name":"Away","version":"1","description":"",
            "asset":"extension-away-1.tar.gz","sha256":"ab","requires":[],"config":[],
            "source":"StackOneHQ/stack-nudge-internal-marketplace"}]}
            """
        guard case .success(let entries) = ExtensionInstaller.parseIndex(Data(json.utf8)) else {
            return XCTFail("the index didn't parse")
        }
        XCTAssertNil(entries.first?.source)
    }

    // MARK: - Reading a private release

    private func releaseJSON(owner: String = "StackOneHQ", repo: String = "stack-nudge-internal-marketplace",
                             assets: [(name: String, url: String)]) -> Data {
        let list = assets.map { asset in
            "{\"name\":\"\(asset.name)\",\"url\":\"\(asset.url)\","
                + "\"browser_download_url\":\"https://github.com/\(owner)/\(repo)/releases/download/x/\(asset.name)\"}"
        }.joined(separator: ",")
        return Data("{\"tag_name\":\"extensions-1\",\"assets\":[\(list)]}".utf8)
    }

    // A private release's browser link needs a signed-in browser, so an extra
    // source's assets come from their API URL.
    func testAnExtraSourcesAssetsComeFromTheAPI() {
        let url = "https://api.github.com/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42"
        let actual = ExtensionInstaller.assets(fromReleaseJSON: releaseJSON(assets: [("extensions-index.json", url)]),
                                               via: .api(internalSource))
        XCTAssertEqual(actual["extensions-index.json"]?.absoluteString, url)
    }

    // The token goes with every one of these requests, so a URL that isn't
    // this repository's own release asset is dropped rather than fetched.
    func testAnAssetURLOutsideTheSourcesOwnReleaseIsDropped() {
        let bad = [
            "https://api.github.com/repos/someone/extensions/releases/assets/42",
            "https://evil.example/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42",
            "http://api.github.com/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42",
            "https://api.github.com:8443/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42",
            "https://api.github.com/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42?x=1",
            "https://api.github.com/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/",
            "https://api.github.com/repos/StackOneHQ/stack-nudge-internal-marketplace/releases/assets/42/../../../../user",
            "https://api.github.com/user",
        ]
        for url in bad {
            let actual = ExtensionInstaller.assets(fromReleaseJSON: releaseJSON(assets: [("a.tar.gz", url)]),
                                                   via: .api(internalSource))
            XCTAssertTrue(actual.isEmpty, url)
        }
    }

    func testTheAppsOwnReleaseStillUsesTheBrowserLink() {
        let actual = ExtensionInstaller.assets(fromReleaseJSON: releaseJSON(
            assets: [("a.tar.gz", "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/assets/1")]))
        XCTAssertEqual(actual["a.tar.gz"]?.host, "github.com")
    }

    func testEachTokenIsTriedInTurnThenNone() {
        var asked: [String?] = []
        let actual = ExtensionInstaller.sourceReleaseJSON(internalSource, tokens: ["sign-in", "gh"], get: { _, token in
            asked.append(token)
            return token == "gh" ? Data("{}".utf8) : nil
        })
        XCTAssertEqual(asked, ["sign-in", "gh"])
        XCTAssertEqual(actual?.token, "gh")
    }

    func testAPublicSourceIsReadWithNoToken() {
        var asked: [String?] = []
        let actual = ExtensionInstaller.sourceReleaseJSON(outsideSource, tokens: [], get: { _, token in
            asked.append(token)
            return Data("{}".utf8)
        })
        XCTAssertEqual(asked, [nil])
        XCTAssertNotNil(actual)
        XCTAssertNil(actual?.token)
    }

    func testTheTokensAreTheSignInsThenGhsWithoutRepeats() {
        XCTAssertEqual(ExtensionInstaller.githubTokens(signIn: { "a" }, gh: { "b" }), ["a", "b"])
        XCTAssertEqual(ExtensionInstaller.githubTokens(signIn: { "a" }, gh: { "a" }), ["a"])
        XCTAssertEqual(ExtensionInstaller.githubTokens(signIn: { nil }, gh: { "b" }), ["b"])
        XCTAssertEqual(ExtensionInstaller.githubTokens(signIn: { nil }, gh: { nil }), [])
    }

    func testTheTokenIsDroppedWhenARedirectChangesHost() {
        var request = URLRequest(url: URL(string: "https://objects.githubusercontent.com/signed")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let actual = ExtensionInstaller.redirect(
            request, from: URL(string: "https://api.github.com/repos/o/r/releases/assets/1"))
        XCTAssertNotNil(actual)
        XCTAssertNil(actual?.value(forHTTPHeaderField: "Authorization"))
    }

    func testTheTokenIsKeptOnTheSameHost() {
        var request = URLRequest(url: URL(string: "https://api.github.com/repositories/1/releases/assets/1")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let actual = ExtensionInstaller.redirect(
            request, from: URL(string: "https://api.github.com/repos/o/r/releases/assets/1"))
        XCTAssertEqual(actual?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testARedirectOffHTTPSIsRefused() {
        let request = URLRequest(url: URL(string: "http://objects.githubusercontent.com/signed")!)
        XCTAssertNil(ExtensionInstaller.redirect(request, from: URL(string: "https://api.github.com/x")))
    }

    // MARK: - Re-checking tiers against the source an extension came from

    private func listed(_ id: String, tier: String, from source: ExtensionSource?) -> ExtensionInstaller.IndexEntry {
        var listing = entry(id, tier: tier)
        listing.source = source?.slug
        return listing
    }

    // A source that didn't answer leaves its extensions out of the index. That
    // is not the same as withdrawing them, so they keep their tier until it
    // answers.
    func testAnUnreachableSourcesOwnExtensionsKeepTheirTier() {
        let actual = ExtensionTiers.reconciling(
            ["claude-usage": .service, "away": .trusted],
            installedFrom: ["claude-usage": internalSource.slug],
            with: [listed("away", tier: "service", from: nil)],
            unavailable: [internalSource.slug])
        XCTAssertEqual(actual, ["claude-usage": .service, "away": .service])
    }

    // One unreachable source, a mistyped one say, must not stop the app's own
    // catalogue withdrawing an extension.
    func testAnUnreachableSourceDoesNotHoldUpAnotherSourcesWithdrawal() {
        let actual = ExtensionTiers.reconciling(
            ["derby": .service, "radar": .service],
            installedFrom: ["radar": internalSource.slug],
            with: [], unavailable: ["someone/typo"])
        XCTAssertEqual(actual, ["derby": .view, "radar": .view])
    }

    func testOnceItsSourceAnswersAnUnlistedExtensionIsView() {
        let actual = ExtensionTiers.reconciling(["claude-usage": .service],
                                                installedFrom: ["claude-usage": internalSource.slug],
                                                with: [], unavailable: [])
        XCTAssertEqual(actual, ["claude-usage": .view])
    }

    // Another source listing the same id says nothing about the copy on disk:
    // only its own source's listing counts, here the lower one.
    func testOnlyTheSourceItCameFromVouchesForItsTier() {
        let actual = ExtensionTiers.reconciling(
            ["radar": .trusted],
            installedFrom: ["radar": internalSource.slug],
            with: [listed("radar", tier: "trusted", from: nil),
                   listed("radar", tier: "view", from: internalSource)])
        XCTAssertEqual(actual, ["radar": .view])
    }

    // An extension with no recorded source is the app's own, and an extra
    // source's listing of the same id doesn't vouch for it either.
    func testAnotherSourcesListingDoesNotVouchForTheAppsOwnExtension() {
        let actual = ExtensionTiers.reconciling(
            ["derby": .service],
            with: [listed("derby", tier: "service", from: internalSource)])
        XCTAssertEqual(actual, ["derby": .view])
    }

    // GitHub names compare without case, and the setting may have been
    // retyped since the install.
    func testTheRecordedSourceMatchesWithoutCase() {
        let actual = ExtensionTiers.reconciling(
            ["radar": .service],
            installedFrom: ["radar": "stackonehq/STACK-NUDGE-INTERNAL-MARKETPLACE"],
            with: [listed("radar", tier: "service", from: internalSource)])
        XCTAssertEqual(actual, ["radar": .service])
    }

    func testTheSourceIsRecordedAndForgottenBesideTheTier() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiers-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/.tiers.json"
        let sourcesPath = ExtensionTiers.sourcesPath(beside: path)

        ExtensionTiers.record(listed("radar", tier: "service", from: internalSource), path: path)
        ExtensionTiers.record(listed("derby", tier: "service", from: nil), path: path)
        XCTAssertEqual(ExtensionTiers.readSources(path: sourcesPath), ["radar": internalSource.slug])

        // Removing it forgets where it came from.
        ExtensionTiers.forget("radar", path: path)
        XCTAssertEqual(ExtensionTiers.readSources(path: sourcesPath), [:])
        XCTAssertEqual(ExtensionTiers.read(path: path), ["derby": .service])
    }

    // A record that isn't a valid id and owner/repo is dropped, which reads
    // as the app's own and so matches no extra source's listing.
    func testAMalformedSourceRecordIsDropped() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sources-\(UUID().uuidString).json").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        try Data(#"{"radar":"StackOneHQ/stack-nudge-internal-marketplace","../x":"a/b","away":"not a slug","derby":3}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(ExtensionTiers.readSources(path: path), ["radar": internalSource.slug])
    }

    // MARK: - Updating only from the source it came from

    private func manifest(_ id: String, version: String) -> ExtensionManifest {
        ExtensionManifest(id: id, name: id, version: version, schema: 1, tab: .init(label: id), run: "./run",
                          requires: [], config: [], refresh: .never)
    }

    func testACopyIsOnlyUpdatedFromTheSourceItCameFrom() {
        let mine = listed("radar", tier: "view", from: internalSource)
        let theirs = listed("radar", tier: "view", from: outsideSource)
        let sources = ["radar": internalSource.slug]
        XCTAssertFalse(ExtensionTiers.installedFromElsewhere(mine, isInstalled: true, sources: sources))
        XCTAssertTrue(ExtensionTiers.installedFromElsewhere(theirs, isInstalled: true, sources: sources))
        XCTAssertTrue(ExtensionTiers.installedFromElsewhere(theirs, isInstalled: true, sources: [:]),
                      "an extra source's package went over the app's own")
        XCTAssertFalse(ExtensionTiers.installedFromElsewhere(theirs, isInstalled: false, sources: sources),
                       "nothing installed, so nothing to protect")
    }

    // Another source's entry under an installed id is a different extension,
    // not an update: the row is the installed copy, from where it came from,
    // with nothing to update to.
    func testABrowserRowOffersNoUpdateFromAnotherSource() {
        var theirs = entry("radar", version: "9")
        theirs.source = outsideSource.slug
        let actual = ExtensionCatalog.rows(catalogue: [theirs], installed: [manifest("radar", version: "1")],
                                           refused: [], installedFrom: ["radar": internalSource.slug])
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual.first?.source, internalSource.slug)
        XCTAssertNil(actual.first?.availableVersion)
        XCTAssertEqual(actual.first?.updateAvailable, false)
    }

    func testABrowserRowOffersAnUpdateFromItsOwnSource() {
        var mine = entry("radar", version: "2")
        mine.source = internalSource.slug
        let actual = ExtensionCatalog.rows(catalogue: [mine], installed: [manifest("radar", version: "1")],
                                           refused: [], installedFrom: ["radar": internalSource.slug])
        XCTAssertEqual(actual.first?.updateAvailable, true)
    }

    // MARK: - The browser

    func testABrowserRowSaysWhichSourceListsIt() {
        var internalEntry = entry("claude-usage")
        internalEntry.source = internalSource.slug
        let actual = ExtensionCatalog.rows(catalogue: [entry("derby"), internalEntry], installed: [], refused: [])
        XCTAssertEqual(actual.first { $0.id == "claude-usage" }?.source, internalSource.slug)
        XCTAssertNil(actual.first { $0.id == "derby" }?.source)
    }

    func testTheBrowserKnowsWhenASourceDidNotAnswer() {
        let catalogue = ExtensionInstaller.Catalogue(entries: [entry("derby")],
                                                     unavailable: ["someone/extensions": "nope"],
                                                     ignored: ["nonsense"])
        let actual = ExtensionCatalog(fetchCatalogue: { .success(catalogue) },
                                      background: { $0() }, toMain: { $0() }, recordedTiers: { [:] },
                                      recordedSources: { ["radar": "StackOneHQ/stack-nudge-internal-marketplace"] })
        actual.reload()
        XCTAssertEqual(actual.unavailableSources, ["someone/extensions": "nope"])
        XCTAssertEqual(actual.installedFrom, ["radar": "StackOneHQ/stack-nudge-internal-marketplace"])
        XCTAssertEqual(actual.ignoredSources, ["nonsense"])
        XCTAssertEqual(actual.entries.map(\.id), ["derby"])
    }
}
