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

    // MARK: - The assumption the archive guard rests on

    // safeEntries splits the listing on newlines, which is only safe because
    // tar escapes control characters in a name rather than emitting them raw.
    // Nothing in the tar format guarantees that and GNU tar quotes differently,
    // so this builds a real archive and asserts the property directly — if the
    // listing ever starts carrying raw newlines, this fails rather than the
    // guard silently weakening.
    func testTarEscapesANewlineInANameRatherThanSplittingTheListing() throws {
        let root = NSTemporaryDirectory() + "tarnl-\(UUID().uuidString)"
        let package = "\(root)/derby"
        try FileManager.default.createDirectory(atPath: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(package)/manifest.json"))

        // A name crafted so that a line-split listing would yield two lines
        // which each look safe on their own.
        let hostile = "\(package)/safe\n../../escaped"
        // The no-Xcode runner has no XCTSkip, so a filesystem that refuses the
        // name simply leaves nothing to assert about.
        guard FileManager.default.createFile(atPath: hostile, contents: Data("x".utf8)) else {
            return
        }

        let archive = "\(root)/hostile.tar.gz"
        guard ProcessOutput.run("/usr/bin/tar", ["czf", archive, "-C", root, "derby"],
                                timeout: 20)?.status == 0,
              let listing = ProcessOutput.read("/usr/bin/tar", ["-tzf", archive], timeout: 20)
        else { return XCTFail("could not build the fixture archive") }

        XCTAssertFalse(listing.contains("\n../../escaped"),
                       "tar emitted a raw newline — the line-split parse is no longer safe")

        // And the guard refuses it either way, because the escaped form still
        // carries ".." as a component.
        guard case .failure(.unsafeArchive) =
                ExtensionInstaller.safeEntries(fromListing: listing, id: "derby") else {
            return XCTFail("accepted an archive containing an escaping name")
        }
    }

    // The verbose listing is what the symlink and hard-link guard reads, and
    // ProcessOutput discards stderr — so if tar wrote it there the guard would
    // be a silent no-op with nothing failing.
    func testTheVerboseListingArrivesOnStdout() throws {
        let root = NSTemporaryDirectory() + "tarv-\(UUID().uuidString)"
        let package = "\(root)/derby"
        try FileManager.default.createDirectory(atPath: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(package)/manifest.json"))
        try FileManager.default.createSymbolicLink(atPath: "\(package)/link",
                                                   withDestinationPath: "/usr/bin")

        let archive = "\(root)/withlink.tar.gz"
        guard ProcessOutput.run("/usr/bin/tar", ["czf", archive, "-C", root, "derby"],
                                timeout: 20)?.status == 0,
              let verbose = ProcessOutput.read("/usr/bin/tar", ["-tvzf", archive], timeout: 20)
        else { return XCTFail("could not build the fixture archive") }

        XCTAssertFalse(verbose.isEmpty, "the verbose listing did not reach stdout")
        XCTAssertEqual(ExtensionInstaller.rejectsNonRegularEntries(inVerboseListing: verbose),
                       .unsafeArchive("a symlink"))
    }

    // A hostile release JSON can name any scheme. It failed closed only because
    // httpGET insists on an HTTPURLResponse; this makes it not depend on that.
    func testOnlyHTTPSAssetURLsAreAccepted() {
        let json = Data(#"{"assets":[{"name":"a.tar.gz","browser_download_url":"file:///etc/passwd"},{"name":"b.tar.gz","browser_download_url":"http://example.test/b.tar.gz"},{"name":"c.tar.gz","browser_download_url":"https://example.test/c.tar.gz"}]}"#.utf8)
        XCTAssertEqual(Set(ExtensionInstaller.assets(fromReleaseJSON: json).keys), ["c.tar.gz"])
    }

    // MARK: - Staging

    // The defer that cleans up only runs on a normal return, so a quit or crash
    // mid-install leaves a staging directory behind for good.
    func testStaleStagingDirectoriesAreSwept() throws {
        let root = NSTemporaryDirectory() + "sweep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let stale = "\(root)/\(ExtensionInstaller.stagingPrefix)abandoned"
        let unrelated = "\(root)/somebody-elses-temp"
        for path in [stale, unrelated] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        ExtensionInstaller.sweepStaleStaging(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated),
                      "the sweep must only claim its own directories")
    }

    // MARK: - Ids

    // An id reaches tar as an operand, so a leading dash is read as an option —
    // the packaging script validated one and then failed with "Can't specify
    // both -x and -c".
    func testAnIDMayNotBeginWithADash() {
        XCTAssertFalse(ExtensionManifest.isValidID("-x"))
        XCTAssertFalse(ExtensionManifest.isValidID("--"))
        XCTAssertTrue(ExtensionManifest.isValidID("x-y"))
        XCTAssertTrue(ExtensionManifest.isValidID("a"))
        XCTAssertTrue(ExtensionManifest.isValidID("9lives"))
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
        for raw in ["", "   ", "not-a-hash  file",
                    String(repeating: "a", count: 63),
                    String(repeating: "a", count: 65),
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

    // The whole justification for the sidecar is that the index agreeing with
    // itself proves nothing. Only a *missing* sidecar was covered; a present
    // but unparseable one is the tampering case that actually matters, and it
    // must not fall back to the hash the index supplied.
    func testAnUnparseableSidecarDoesNotFallBackToTheIndexHash() {
        for body in ["", "   ", "not a hash at all", "\n\n"] {
            XCTAssertNil(ExtensionInstaller.expectedHex(fromSidecar: body), body)
        }
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
    //
    // Each listing below is otherwise *valid* — it carries a manifest and stays
    // under the id — so only the guard under test can reject it. Without that
    // the three guards mask each other: a listing with no manifest.json is
    // refused for that reason alone, and removing any one guard left the suite
    // green while the hole was open.
    private func reason(_ listing: String) -> String? {
        guard case .failure(.unsafeArchive(let why)) = entries(listing) else { return nil }
        return why
    }

    func testAnAbsolutePathIsRefused() {
        // Under the id, no "..", manifest present — only the absolute-path
        // guard stands between this and a write to /derby/run.
        let why = reason("derby/manifest.json\n/derby/run\n")
        XCTAssertEqual(why?.contains("absolute"), true, "\(why ?? "accepted")")
    }

    func testATraversingPathIsRefused() {
        for listing in ["derby/manifest.json\nderby/../../evil\n",
                        "derby/manifest.json\nderby/a/../../../evil\n"] {
            let why = reason(listing)
            XCTAssertEqual(why?.contains("escapes"), true, "\(why ?? "accepted"): \(listing)")
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
        // Relative and traversal-free, so only the under-the-id guard applies.
        let why = reason("derby/manifest.json\nsomewhereelse/run\n")
        XCTAssertEqual(why?.contains("outside"), true, "\(why ?? "accepted")")
    }

    // Each of the terminal guards, pinned by its own reason rather than by the
    // generic case — an archive with no manifest is refused for that reason,
    // which is what let the others survive mutation while looking covered.
    func testAnEmptyArchiveIsRefusedForBeingEmpty() {
        XCTAssertEqual(reason("\n"), "no files")
    }

    // A manifest nested somewhere below the root is not this package's manifest.
    func testAManifestMustBeAtThePackageRoot() {
        let why = reason("derby/\nderby/inner/manifest.json\n")
        XCTAssertEqual(why?.contains("no manifest.json"), true, "\(why ?? "accepted")")
    }

    // docs/extensions.md claims any symlink or special file is refused, and a
    // hard link is how you reach a file you were not given.
    func testAVerboseListingRejectsHardLinks() {
        let listing = "hrw-r--r--  0 root wheel 0 Jan 1 00:00 derby/run link to /etc/passwd"
        XCTAssertEqual(ExtensionInstaller.rejectsNonRegularEntries(inVerboseListing: listing),
                       .unsafeArchive("a hard link"))
    }

    func testAnArchiveWithoutAManifestIsRefused() {
        guard case .failure(.unsafeArchive) = entries("derby/\nderby/run\n") else {
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
