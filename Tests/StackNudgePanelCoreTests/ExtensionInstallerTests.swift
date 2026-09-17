import XCTest

@testable import StackNudgePanelCore

// The parts of installing that take no I/O: the index, the checksum, and the
// archive guard. They are static and pure precisely so the hostile shapes can be
// tested without a network or an archive — which is the thing Updater got wrong,
// where the same logic is unreachable behind a weak nav.
final class ExtensionInstallerTests: XCTestCase {

    // MARK: - The index

    private func index(_ json: String) -> Result<[ExtensionInstaller.IndexEntry],
                                                ExtensionInstaller.Failure> {
        ExtensionInstaller.parseIndex(Data(json.utf8))
    }

    private let oneEntry = """
        {"schema":1,"extensions":[
          {"id":"derby","name":"Token Derby","version":"1.2.0","description":"A race",
           "asset":"derby-1.2.0.tar.gz","sha256":"abc","requires":["python3"],
           "config":["STACKNUDGE_EXT_DERBY_ORG"]}]}
        """

    func testAWellFormedIndex() {
        guard case .success(let entries) = index(oneEntry) else { return XCTFail("expected entries") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "derby")
        XCTAssertEqual(entries[0].asset, "derby-1.2.0.tar.gz")
        XCTAssertEqual(entries[0].requires, ["python3"])
    }

    // An index with nothing in it is what a release ships before the first
    // extension exists, so it must be ordinary rather than an error.
    func testAnEmptyIndexIsNotAFailure() {
        guard case .success(let entries) = index(#"{"schema":1,"extensions":[]}"#) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries, [])
    }

    func testAnIndexFromANewerHostIsRefused() {
        XCTAssertEqual(index(#"{"schema":2,"extensions":[]}"#),
                       .failure(.unsupportedIndexSchema(2)))
    }

    func testAMalformedIndex() {
        guard case .failure(.malformedIndex) = index("{{{") else {
            return XCTFail("expected malformed")
        }
    }

    // The index arrives over the network. "Ours" is a claim about provenance,
    // not about the bytes that turned up, so an id that would become a directory
    // name is validated here too.
    func testAnIndexIDThatWouldEscapeIsRefused() {
        for id in ["../../evil", "/etc", "Derby", "", "a b"] {
            let json = """
                {"schema":1,"extensions":[
                  {"id":"\(id)","name":"X","version":"1","description":"",
                   "asset":"x.tar.gz","sha256":"abc","requires":[],"config":[]}]}
                """
            guard case .failure(.invalidEntry) = index(json) else {
                return XCTFail("accepted id \(id)")
            }
        }
    }

    // The asset name is appended to a URL and used as a filename.
    func testAnIndexAssetNameThatCarriesAPathIsRefused() {
        for asset in ["../../evil.tar.gz", "sub/dir.tar.gz", "", "derby.zip"] {
            let json = """
                {"schema":1,"extensions":[
                  {"id":"derby","name":"X","version":"1","description":"",
                   "asset":"\(asset)","sha256":"abc","requires":[],"config":[]}]}
                """
            guard case .failure(.invalidEntry) = index(json) else {
                return XCTFail("accepted asset \(asset)")
            }
        }
    }

    func testSafeAssetNames() {
        XCTAssertTrue(ExtensionInstaller.isSafeAssetName("derby-1.2.0.tar.gz"))
        XCTAssertFalse(ExtensionInstaller.isSafeAssetName("a/b.tar.gz"))
        XCTAssertFalse(ExtensionInstaller.isSafeAssetName(".."))
    }

    // MARK: - Reaching the release

    // The anonymous GitHub API is sixty requests an hour per machine, shared
    // with everything else on it, so a 403 here is ordinary. UpdateChecker
    // already falls back to the local gh CLI; without the same fallback the
    // browser tells somebody whose network is fine that it couldn't download.
    func testTheReleaseFallsBackToTheGHCLI() {
        var askedGH: String?
        let data = ExtensionInstaller.releaseJSON(http: { _ in nil },
                                                  gh: { path in
                                                      askedGH = path
                                                      return Data("{}".utf8)
                                                  })
        XCTAssertNotNil(data)
        XCTAssertEqual(askedGH, UpdateChecker.latestGHPath)
    }

    // The CLI is the fallback, not the first choice — it spawns a process.
    func testTheCLIIsNotUsedWhenTheAPIAnswers() {
        var ghCalls = 0
        let data = ExtensionInstaller.releaseJSON(http: { _ in Data("{}".utf8) },
                                                  gh: { _ in ghCalls += 1; return nil })
        XCTAssertNotNil(data)
        XCTAssertEqual(ghCalls, 0)
    }

    func testBothPathsFailingIsReportedAsUnreachableRatherThanEmpty() {
        XCTAssertNil(ExtensionInstaller.releaseJSON(http: { _ in nil }, gh: { _ in nil }))
        let message = ExtensionInstaller.Failure.catalogueUnavailable.message
        XCTAssertTrue(message.contains("rate-limiting"), message)
    }

    // MARK: - The catalogue on a release

    private func releaseJSON(_ assets: [String]) -> Data {
        let entries = assets.map {
            "{\"name\":\"\($0)\",\"browser_download_url\":\"https://example.test/\($0)\"}"
        }.joined(separator: ",")
        return Data("{\"tag_name\":\"v1.0.0\",\"assets\":[\(entries)]}".utf8)
    }

    // A release published before extensions existed carries no index. That is an
    // empty catalogue, not a failure — otherwise every user on an older release
    // sees an error for something that is working correctly.
    func testAReleaseWithoutAnIndexIsAnEmptyCatalogue() {
        let result = ExtensionInstaller.catalogue(
            fromReleaseJSON: releaseJSON(["stack-nudge-1.0.0-macos-arm64.tar.gz"]),
            fetch: { _ in XCTFail("nothing to fetch"); return nil })
        guard case .success(let entries) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(entries.isEmpty)
    }

    func testAnIndexOnTheReleaseIsFetchedAndParsed() {
        let index = Data("{\"schema\":1,\"extensions\":[]}".utf8)
        let result = ExtensionInstaller.catalogue(
            fromReleaseJSON: releaseJSON(["extensions-index.json"]),
            fetch: { _ in index })
        guard case .success = result else { return XCTFail("\(result)") }
    }

    func testAnIndexThatCannotBeFetchedIsAFailureNotAnEmptyList() {
        let result = ExtensionInstaller.catalogue(
            fromReleaseJSON: releaseJSON(["extensions-index.json"]),
            fetch: { _ in nil })
        guard case .failure(.downloadFailed) = result else { return XCTFail("\(result)") }
    }

    func testAssetsAreReadFromTheReleaseJSON() {
        let assets = ExtensionInstaller.assets(
            fromReleaseJSON: releaseJSON(["a.tar.gz", "a.tar.gz.sha256"]))
        XCTAssertEqual(Set(assets.keys), ["a.tar.gz", "a.tar.gz.sha256"])
    }

    func testMalformedReleaseJSONYieldsNoAssets() {
        XCTAssertTrue(ExtensionInstaller.assets(fromReleaseJSON: Data("nonsense".utf8)).isEmpty)
    }

    // MARK: - Checksums

    func testTheSidecarFormatIsHashThenName() {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(ExtensionInstaller.expectedHex(fromSidecar: "\(hex)  derby-1.0.tar.gz\n"), hex)
        XCTAssertEqual(ExtensionInstaller.expectedHex(fromSidecar: hex), hex)
        XCTAssertEqual(ExtensionInstaller.expectedHex(fromSidecar: hex.uppercased()), hex)
    }

    func testAnUnusableSidecarIsNotTreatedAsAHash() {
        for raw in ["", "   ", "not-a-hash  file", String(repeating: "a", count: 63),
                    String(repeating: "z", count: 64)] {
            XCTAssertNil(ExtensionInstaller.expectedHex(fromSidecar: raw), raw)
        }
    }

    func testAMatchingChecksumPasses() {
        let data = Data("hello".utf8)
        guard case .success = ExtensionInstaller.verify(
            data, expectedHex: ExtensionInstaller.sha256Hex(data)) else {
            return XCTFail("expected a match")
        }
    }

    func testAMismatchedChecksumFails() {
        guard case .failure(.checksumMismatch) = ExtensionInstaller.verify(
            Data("hello".utf8), expectedHex: String(repeating: "0", count: 64)) else {
            return XCTFail("expected a mismatch")
        }
    }

    // Updater's policy, kept: a release without a sidecar is a tampered or
    // incomplete one, not a reason to install unverified.
    func testTheSidecarMissingMessageSaysWhyItRefuses() {
        let message = ExtensionInstaller.Failure.sidecarMissing("derby-1.0.tar.gz").message
        XCTAssertTrue(message.contains("refusing"), message)
    }

    // MARK: - The archive guard

    private func entries(_ listing: String, id: String = "derby")
        -> Result<[String], ExtensionInstaller.Failure> {
        ExtensionInstaller.safeEntries(fromListing: listing, id: id)
    }

    func testAnOrdinaryListing() {
        guard case .success(let paths) = entries("derby/\nderby/manifest.json\nderby/run\n") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(paths.count, 3)
    }

    // The three shapes Updater's bare `tar -xzf` would have written anywhere.
    func testAnAbsolutePathIsRefused() {
        guard case .failure(.unsafeArchive) = entries("/etc/passwd\n") else {
            return XCTFail("expected refusal")
        }
    }

    func testATraversingPathIsRefused() {
        for listing in ["derby/../../evil\n", "../evil\n", "derby/a/../../../evil\n"] {
            guard case .failure(.unsafeArchive) = entries(listing) else {
                return XCTFail("accepted \(listing)")
            }
        }
    }

    // ".." as a component, not as a substring — a file honestly named "..foo"
    // is fine and must not be collateral.
    func testALeadingDoubleDotInANameIsNotATraversal() {
        guard case .success = entries("derby/\nderby/manifest.json\nderby/..hidden\n") else {
            return XCTFail("rejected a legitimate name")
        }
    }

    // An archive that unpacks outside its own directory is not the extension it
    // claims to be, whichever direction it wanders.
    func testEverythingMustLiveUnderTheIDDirectory() {
        guard case .failure(.unsafeArchive) = entries("otherext/manifest.json\n") else {
            return XCTFail("expected refusal")
        }
    }

    func testAnArchiveWithoutAManifestIsRefused() {
        guard case .failure(.unsafeArchive) = entries("derby/\nderby/run\n") else {
            return XCTFail("expected refusal")
        }
    }

    func testAnEmptyArchiveIsRefused() {
        guard case .failure(.unsafeArchive) = entries("\n") else {
            return XCTFail("expected refusal")
        }
    }

    // The packaging script rejects symlinks at review time; this is the same
    // rule applied to the bytes that actually arrived, since the archive on a
    // release is not necessarily the tree that was reviewed.
    func testAVerboseListingRejectsSymlinksAndSpecialFiles() {
        let symlink = "lrwxr-xr-x  0 root  wheel  7 Jan  1 00:00 derby/vendor -> /usr/bin"
        XCTAssertEqual(ExtensionInstaller.rejectsNonRegularEntries(inVerboseListing: symlink),
                       .unsafeArchive("a symlink"))

        let device = "crw-rw-rw-  0 root  wheel  0 Jan  1 00:00 derby/null"
        guard case .unsafeArchive = ExtensionInstaller.rejectsNonRegularEntries(
            inVerboseListing: device) else {
            return XCTFail("expected a special-file refusal")
        }
    }

    func testAVerboseListingOfOrdinaryFilesPasses() {
        let listing = """
            drwxr-xr-x  0 root  wheel  0 Jan  1 00:00 derby/
            -rw-r--r--  0 root  wheel  91 Jan  1 00:00 derby/manifest.json
            -rwxr-xr-x  0 root  wheel  42 Jan  1 00:00 derby/run
            """
        XCTAssertNil(ExtensionInstaller.rejectsNonRegularEntries(inVerboseListing: listing))
    }

    // MARK: - Requirements

    func testTheFirstUnsatisfiedRequirementIsReported() {
        let missing = ExtensionInstaller.missingRequirement(in: ["python3", "ruby"]) { $0 == "python3" }
        XCTAssertEqual(missing, "ruby")
    }

    func testNoRequirementsIsSatisfied() {
        XCTAssertNil(ExtensionInstaller.missingRequirement(in: []) { _ in false })
    }

    func testEverythingPresentIsSatisfied() {
        XCTAssertNil(ExtensionInstaller.missingRequirement(in: ["python3"]) { _ in true })
    }

    // `requires` comes from a manifest and ends up as an executable name, so a
    // path or an argument is refused before it can be run.
    func testARequirementThatIsNotABareNameIsNeverSatisfied() {
        for name in ["/bin/sh", "../python3", "python3; rm -rf /", "py thon", ""] {
            XCTAssertFalse(ExtensionInstaller.interpreterWorks(name), name)
        }
    }

    // The point of executing rather than resolving: something that exists.
    func testARealInterpreterIsDetected() {
        XCTAssertTrue(ExtensionInstaller.interpreterWorks("sh"))
    }

    func testAnAbsentInterpreterIsNotDetected() {
        XCTAssertFalse(ExtensionInstaller.interpreterWorks("definitely-not-installed-xyz"))
    }
}
