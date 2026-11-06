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
}
