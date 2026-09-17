import XCTest

@testable import StackNudgePanelCore

// The install path, driven entirely through injected side effects. Every
// refusal here is one that must happen *before* bytes reach the extensions
// directory, so the ordering is as much under test as the outcomes.
final class ExtensionInstallTests: XCTestCase {

    private var root = ""
    private var served: [String: Data] = [:]
    private var fetched: [String] = []

    override func setUp() {
        super.setUp()
        root = NSTemporaryDirectory() + "stack-nudge-install-\(UUID().uuidString)"
        served = [:]
        fetched = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func url(_ name: String) -> URL { URL(string: "https://example.test/\(name)")! }

    private func entry(id: String = "derby",
                       asset: String = "derby-1.0.0.tar.gz",
                       sha: String,
                       requires: [String] = []) -> ExtensionInstaller.IndexEntry {
        .init(id: id, name: "Derby", version: "1.0.0", description: "",
              asset: asset, sha256: sha, requires: requires, config: [])
    }

    // Serves whatever the test published, and records what was asked for.
    private func sources(_ assets: [String: URL]) -> ExtensionInstaller.Sources {
        .init(assets: assets, fetch: { [self] url in
            fetched.append(url.lastPathComponent)
            return served[url.lastPathComponent]
        })
    }

    private func publish(_ name: String, _ data: Data) -> URL {
        served[name] = data
        return url(name)
    }

    private func sidecar(for data: Data, name: String) -> Data {
        Data("\(ExtensionInstaller.sha256Hex(data))  \(name)\n".utf8)
    }

    private let manifest = Data("""
        {"id":"derby","name":"Derby","version":"1.0.0","schema":1}
        """.utf8)

    // A stand-in archive: the bytes never matter because listing and extraction
    // are injected, only the checksum over them does.
    private let payload = Data("a plausible tarball".utf8)

    private func listing(_ id: String = "derby", verboseKind: Character = "-")
        -> (String, String) {
        ("\(id)/\n\(id)/manifest.json\n",
         "drwxr-xr-x  0 root wheel 0 Jan 1 00:00 \(id)/\n"
         + "\(verboseKind)rw-r--r--  0 root wheel 9 Jan 1 00:00 \(id)/manifest.json\n")
    }

    // Writes the manifest where a real tar would have put it.
    private func extractor(id: String = "derby",
                           manifest: Data? = nil) -> (String, String) -> Bool {
        let body = manifest ?? self.manifest
        return { _, directory in
            let dir = URL(fileURLWithPath: directory).appendingPathComponent(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? body.write(to: dir.appendingPathComponent("manifest.json"))
            return true
        }
    }

    private func install(_ e: ExtensionInstaller.IndexEntry,
                         assets: [String: URL],
                         list: @escaping (String) -> (plain: String, verbose: String)? = { _ in
                             ("derby/\nderby/manifest.json\n",
                              "drwxr-xr-x 0 root wheel 0 Jan 1 00:00 derby/\n")
                         },
                         extract: @escaping (String, String) -> Bool,
                         requires: @escaping (String) -> Bool = { _ in true })
        -> Result<String, ExtensionInstaller.Failure> {
        ExtensionInstaller.install(e, from: sources(assets), into: root,
                                   listArchive: list, extract: extract,
                                   probeRequirement: requires)
    }

    // MARK: - The happy path

    func testAVerifiedPackageIsInstalled() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))

        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             extract: extractor())
        guard case .success(let id) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(id, "derby")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(root)/derby/manifest.json"))
    }

    // MARK: - Refusals, in the order they must happen

    // Nothing is fetched at all when a requirement is missing — the check is
    // before the download, not after it.
    func testAMissingRequirementRefusesBeforeDownloading() {
        let e = entry(sha: "irrelevant", requires: ["python3"])
        let result = install(e, assets: [:], extract: { _, _ in
            XCTFail("must not extract"); return false
        }, requires: { _ in false })

        XCTAssertEqual(result, .failure(.missingRequirement("python3")))
        XCTAssertTrue(fetched.isEmpty, "downloaded despite an unmet requirement")
    }

    // Updater's policy, kept: no sidecar means refuse, never install unverified.
    func testAMissingSidecarRefuses() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))
        let result = install(e, assets: ["derby-1.0.0.tar.gz": asset],
                             extract: { _, _ in XCTFail("must not extract"); return false })
        XCTAssertEqual(result, .failure(.sidecarMissing("derby-1.0.0.tar.gz")))
    }

    func testATamperedPayloadRefuses() {
        let asset = publish("derby-1.0.0.tar.gz", Data("tampered".utf8))
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))
        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             extract: { _, _ in XCTFail("must not extract"); return false })
        guard case .failure(.checksumMismatch) = result else { return XCTFail("\(result)") }
    }

    // The index names the asset *and* carries a hash, so it agreeing with itself
    // proves nothing. The sidecar is the separate artifact, and a disagreement
    // between the two is a refusal rather than a preference.
    func testAnIndexHashDisagreeingWithTheSidecarRefuses() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: String(repeating: "b", count: 64))
        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             extract: { _, _ in XCTFail("must not extract"); return false })
        guard case .failure(.checksumMismatch) = result else { return XCTFail("\(result)") }
    }

    // The archive is inspected before it is unpacked — Updater extracts first
    // and asks nothing, which is the shape this deliberately does not inherit.
    func testAHostileArchiveIsRefusedWithoutExtracting() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))

        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             list: { _ in ("../../evil\n", "-rw-r--r-- 0 root wheel 0 Jan 1 00:00 ../../evil\n") },
                             extract: { _, _ in XCTFail("must not extract a hostile archive"); return false })
        guard case .failure(.unsafeArchive) = result else { return XCTFail("\(result)") }
    }

    func testASymlinkInTheArchiveIsRefusedWithoutExtracting() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))
        let (plain, verbose) = listing(verboseKind: "l")

        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             list: { _ in (plain, verbose) },
                             extract: { _, _ in XCTFail("must not extract"); return false })
        XCTAssertEqual(result, .failure(.unsafeArchive("a symlink")))
    }

    // A package whose manifest the runtime would refuse must never reach the
    // extensions directory to be refused later.
    func testAPackageWhoseManifestIsRejectedIsNotCommitted() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))
        let future = Data("{\"id\":\"derby\",\"name\":\"D\",\"version\":\"1\",\"schema\":2}".utf8)

        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             extract: extractor(manifest: future))
        guard case .failure(.manifestRejected(let why)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.contains("schema"), why)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/derby"))
    }

    // The package can claim one id in the index and another in its manifest.
    func testAManifestClaimingADifferentIDIsRefused() {
        let asset = publish("derby-1.0.0.tar.gz", payload)
        let side = publish("derby-1.0.0.tar.gz.sha256", sidecar(for: payload, name: "derby-1.0.0.tar.gz"))
        let e = entry(sha: ExtensionInstaller.sha256Hex(payload))
        let other = Data("{\"id\":\"radar\",\"name\":\"D\",\"version\":\"1\",\"schema\":1}".utf8)

        let result = install(e,
                             assets: ["derby-1.0.0.tar.gz": asset,
                                      "derby-1.0.0.tar.gz.sha256": side],
                             extract: extractor(manifest: other))
        guard case .failure(.manifestRejected) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/derby"))
    }

    // The installer never builds a URL — it only fetches assets the release
    // actually published, so an index naming something absent is a dead end
    // rather than a redirect.
    func testAnAssetTheReleaseDoesNotPublishIsNotFetched() {
        let e = entry(sha: "irrelevant")
        let result = install(e, assets: [:], extract: { _, _ in XCTFail("no"); return false })
        XCTAssertEqual(result, .failure(.downloadFailed("derby-1.0.0.tar.gz")))
        XCTAssertTrue(fetched.isEmpty)
    }

    // install() turns an id into a destination path, so it carries the same
    // guard removal does — and an index is fetched over the network, so the id
    // in it is not ours just because the release is.
    func testInstallingRefusesATraversingIDBeforeAnythingElse() {
        for id in ["../evil", "..", "/etc", "Derby", ""] {
            let e = entry(id: id, sha: "irrelevant")
            let result = install(e, assets: [:],
                                 extract: { _, _ in XCTFail("must not extract"); return false })
            XCTAssertEqual(result, .failure(.invalidEntry(id)), id)
            XCTAssertTrue(fetched.isEmpty, "fetched despite an invalid id")
        }
    }

    // MARK: - Removal

    func testRemovingDeletesTheDirectory() throws {
        let dir = "\(root)/derby"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(ExtensionInstaller.remove("derby", from: root), .success("derby"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    // Removal takes an id and turns it into a path to delete, which is the most
    // dangerous shape in this file. A canary outside the root proves the guard.
    func testRemovingRefusesATraversingID() throws {
        let canary = "\(root)-canary"
        try FileManager.default.createDirectory(atPath: canary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: canary) }

        for id in ["../\(URL(fileURLWithPath: canary).lastPathComponent)", "..", "/", ""] {
            guard case .failure(.invalidEntry) = ExtensionInstaller.remove(id, from: root) else {
                return XCTFail("accepted id \(id)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: canary), "canary was deleted")
    }

    func testRemovingSomethingAbsentIsNotAFailure() {
        XCTAssertEqual(ExtensionInstaller.remove("derby", from: root), .success("derby"))
    }
}
