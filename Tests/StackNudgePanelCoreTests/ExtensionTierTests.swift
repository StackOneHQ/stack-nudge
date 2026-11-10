import XCTest

@testable import StackNudgePanelCore

// What each tier may be given, and where the tier comes from: a host-owned
// file that, missing or wrong, always errs toward fewer privileges.
final class ExtensionTierTests: XCTestCase {

    private func service(_ capabilities: [String], mode: String = "service") -> ExtensionManifest {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"away","name":"Away","version":"1","schema":2,"mode":"\(mode)","capabilities":[\(list)]}
            """.utf8)) else { fatalError("fixture manifest didn't parse") }
        return m
    }

    private let everything = ExtensionCapability.allCases.map(\.rawValue)

    func testTheTiersAreOrdered() {
        XCTAssertLessThan(ExtensionTier.view, .service)
        XCTAssertLessThan(ExtensionTier.service, .trusted)
        XCTAssertFalse(ExtensionTier.view.allowsServiceMode)
        XCTAssertTrue(ExtensionTier.service.allowsServiceMode)
        XCTAssertTrue(ExtensionTier.trusted.allowsServiceMode)
    }

    // The allowance table from the design, asked for everything.
    func testGrantsAreWhatWasAskedForThatTheTierAllows() {
        let manifest = service(everything)
        XCTAssertEqual(ExtensionTier.grants(for: manifest, tier: .view), [])
        XCTAssertEqual(ExtensionTier.grants(for: manifest, tier: .service),
                       [.eventIdle, .eventPanel, .feed])
        XCTAssertEqual(ExtensionTier.grants(for: manifest, tier: .trusted),
                       ExtensionCapability.allCases)
    }

    // A tier is a ceiling, not a gift: nothing undeclared is granted.
    func testNothingUndeclaredIsGranted() {
        XCTAssertEqual(ExtensionTier.grants(for: service(["event:idle"]), tier: .trusted), [.eventIdle])
        XCTAssertEqual(ExtensionTier.grants(for: service([]), tier: .trusted), [])
    }

    func testTheGrantKeepsTheManifestsOrder() {
        XCTAssertEqual(ExtensionTier.grants(for: service(["feed", "signal:presence", "event:idle"]),
                                            tier: .trusted),
                       [.feed, .signalPresence, .eventIdle])
    }

    // Nothing reaches a view extension through a one-shot fetch, so it gets
    // nothing whatever its tier.
    func testAViewExtensionIsGrantedNothing() {
        XCTAssertEqual(ExtensionTier.grants(for: service(everything, mode: "view"), tier: .trusted), [])
    }

    // MARK: - The tiers file

    private func tiers(_ contents: String?) throws -> [String: ExtensionTier] {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiers-\(UUID().uuidString).json").path
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return ExtensionTiers.read(path: path)
    }

    func testTheTiersFileMapsIDsToTiers() throws {
        XCTAssertEqual(try tiers(#"{"away":"trusted","radar":"service","derby":"view"}"#),
                       ["away": .trusted, "radar": .service, "derby": .view])
    }

    func testAMissingOrBrokenFileMeansEverythingIsView() throws {
        XCTAssertEqual(try tiers(nil), [:])
        XCTAssertEqual(try tiers("not json"), [:])
        XCTAssertEqual(try tiers(#"["away"]"#), [:])
    }

    // An entry this host can't read is dropped, which leaves it at `view`.
    func testUnknownTiersAndInvalidIDsAreDropped() throws {
        XCTAssertEqual(try tiers(#"{"away":"root","../x":"trusted","radar":1,"ok":"service"}"#),
                       ["ok": .service])
    }

    // The file sits among the extension directories, and must not be taken for one.
    func testTheTiersFileIsNotDiscoveredAsAnExtension() {
        XCTAssertFalse(ExtensionManifest.isValidID(".tiers.json"))
        XCTAssertTrue(ExtensionTiers.path.hasSuffix("/extensions/.tiers.json"))
    }

    // MARK: - Recording from the index

    private func entry(_ id: String, tier: String?) -> ExtensionInstaller.IndexEntry {
        ExtensionInstaller.IndexEntry(id: id, name: id, version: "1", description: "",
                                      asset: "extension-\(id)-1.tar.gz", sha256: "ab",
                                      requires: [], config: [], tier: tier)
    }

    func testTheIndexTierReadsAsViewWhenMissingOrUnknown() {
        XCTAssertEqual(entry("away", tier: "trusted").reviewedTier, .trusted)
        XCTAssertEqual(entry("away", tier: nil).reviewedTier, .view)
        XCTAssertEqual(entry("away", tier: "root").reviewedTier, .view)
    }

    // Installing takes the index's word, up or down: it's the package that
    // was reviewed for that tier.
    func testInstallingRecordsTheIndexTier() {
        XCTAssertEqual(ExtensionTiers.recording(entry("away", tier: "trusted"), in: [:]),
                       ["away": .trusted])
        XCTAssertEqual(ExtensionTiers.recording(entry("away", tier: "service"),
                                                in: ["away": .trusted, "derby": .view]),
                       ["away": .service, "derby": .view])
    }

    func testAFetchDemotesToWhatTheIndexNowSays() {
        let recorded: [String: ExtensionTier] = ["away": .trusted, "radar": .service]
        XCTAssertEqual(ExtensionTiers.reconciling(recorded, with: [entry("away", tier: "service"),
                                                                   entry("radar", tier: "service")]),
                       ["away": .service, "radar": .service])
    }

    // No promotion without an install: the copy on disk may be older than
    // the version the index now vouches for.
    func testAFetchNeverPromotes() {
        XCTAssertEqual(ExtensionTiers.reconciling(["away": .view],
                                                  with: [entry("away", tier: "trusted")]),
                       ["away": .view])
    }

    // Dropped from the index, or listed without a tier this host knows:
    // `view`, the same as an extension nobody installed from it.
    func testAnExtensionTheIndexNoLongerVouchesForIsView() {
        XCTAssertEqual(ExtensionTiers.reconciling(["away": .trusted, "radar": .service],
                                                  with: [entry("radar", tier: "superuser")]),
                       ["away": .view, "radar": .view])
        XCTAssertEqual(ExtensionTiers.reconciling(["away": .trusted], with: []), ["away": .view])
    }

    func testTheRecordRoundTripsThroughTheFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiers-\(UUID().uuidString)/.tiers.json").path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        ExtensionTiers.record(entry("away", tier: "trusted"), path: path)
        ExtensionTiers.record(entry("derby", tier: nil), path: path)
        XCTAssertEqual(ExtensionTiers.read(path: path), ["away": .trusted, "derby": .view])

        XCTAssertFalse(ExtensionTiers.reconcile(with: [entry("away", tier: "trusted"),
                                                       entry("derby", tier: "view")],
                                                path: path, config: [:]),
                       "nothing changed, so nothing needs restarting")
        XCTAssertTrue(ExtensionTiers.reconcile(with: [entry("away", tier: "service")],
                                               path: path, config: [:]))
        XCTAssertEqual(ExtensionTiers.read(path: path), ["away": .service, "derby": .view])

        ExtensionTiers.forget("away", path: path)
        XCTAssertEqual(ExtensionTiers.read(path: path), ["derby": .view])
    }

    // The developer setting: the file is authoritative, so a tier written by
    // hand for an extension no index lists survives every fetch.
    func testLocalTiersStopTheIndexFromReCheckingTheFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiers-\(UUID().uuidString).json").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        ExtensionTiers.write(["away": .trusted], path: path)

        let local = ["STACKNUDGE_EXTENSIONS_LOCAL_TIERS": "true"]
        XCTAssertFalse(ExtensionTiers.indexReconciles(config: local))
        XCTAssertFalse(ExtensionTiers.reconcile(with: [], path: path, config: local))
        XCTAssertEqual(ExtensionTiers.read(path: path), ["away": .trusted])

        // Unset, or anything but true, is the normal rule.
        XCTAssertTrue(ExtensionTiers.indexReconciles(config: [:]))
        XCTAssertTrue(ExtensionTiers.indexReconciles(config: ["STACKNUDGE_EXTENSIONS_LOCAL_TIERS": "false"]))
        XCTAssertTrue(ExtensionTiers.reconcile(with: [], path: path, config: [:]))
        XCTAssertEqual(ExtensionTiers.read(path: path), ["away": .view])
    }
}
