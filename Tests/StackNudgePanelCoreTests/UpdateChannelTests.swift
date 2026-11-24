import XCTest

@testable import StackNudgePanelCore

// Stable follows tagged releases; Nightly follows the rolling `nightly`
// pre-release that nightly.yml rebuilds from main each night.
@MainActor
final class UpdateChannelTests: XCTestCase {

    // MARK: - Versions

    func testAVersionReadsAsAReleaseOrANightly() {
        XCTAssertEqual(BuildVersion("2.10.1"), BuildVersion(base: "2.10.1"))
        XCTAssertEqual(BuildVersion("2.10.0-nightly.812"), BuildVersion(base: "2.10.0", nightly: 812))
        XCTAssertEqual(BuildVersion("2.10.0-nightly.x"), BuildVersion(base: "2.10.0-nightly.x"),
                       "a nightly needs a number")
        XCTAssertEqual(BuildVersion(base: "2.10.0", nightly: 812).string, "2.10.0-nightly.812")
        XCTAssertEqual(BuildVersion(base: "2.10.0", nightly: 812).display, "2.10.0 (nightly 812)")
        XCTAssertEqual(BuildVersion(base: "2.10.0").display, "2.10.0")
    }

    func testTheVersionComesFromThisArchsArtifact() {
        XCTAssertEqual(BuildVersion.fromArtifact("stack-nudge-2.10.0-nightly.812-macos-arm64.tar.gz", arch: "arm64"),
                       BuildVersion(base: "2.10.0", nightly: 812))
        XCTAssertNil(BuildVersion.fromArtifact("stack-nudge-2.10.0-nightly.812-macos-x86_64.tar.gz", arch: "arm64"))
        XCTAssertNil(BuildVersion.fromArtifact("stack-nudge-2.10.0-nightly.812-macos-arm64.tar.gz.sha256", arch: "arm64"))
        XCTAssertNil(BuildVersion.fromArtifact("extension-away-1.1.1.tar.gz", arch: "arm64"))
    }

    private func release(tag: String, assets: [String]) -> [String: Any] {
        ["tag_name": tag, "assets": assets.map { ["name": $0] }]
    }

    // A nightly's tag is just "nightly", and each arch's upload replaces its
    // own files, so the arm64 and x86_64 builds can briefly differ.
    func testANightlyIsReadFromItsArtifactNotItsTag() {
        let json = release(tag: "nightly", assets: [
            "stack-nudge-2.10.0-nightly.813-macos-arm64.tar.gz",
            "stack-nudge-2.10.0-nightly.813-macos-arm64.tar.gz.sha256",
            "stack-nudge-2.10.0-nightly.812-macos-x86_64.tar.gz",
        ])
        XCTAssertEqual(BuildVersion.offered(by: json, channel: .nightly, arch: "arm64"),
                       BuildVersion(base: "2.10.0", nightly: 813))
        XCTAssertEqual(BuildVersion.offered(by: json, channel: .nightly, arch: "x86_64"),
                       BuildVersion(base: "2.10.0", nightly: 812))
        XCTAssertNil(BuildVersion.offered(by: release(tag: "nightly", assets: []), channel: .nightly, arch: "arm64"))
        XCTAssertEqual(BuildVersion.offered(by: release(tag: "v2.11.0", assets: []), channel: .stable, arch: "arm64"),
                       BuildVersion(base: "2.11.0"))
    }

    // MARK: - What each channel offers

    // Semver: 2.10.1-nightly.812 comes before 2.10.1.
    func testStableOffersANewerReleaseIncludingTheOneANightlyLedUpTo() {
        let offer = { UpdateOffer.shouldOffer(BuildVersion($0), to: BuildVersion($1), on: .stable) }
        XCTAssertTrue(offer("2.11.0", "2.10.0"))
        XCTAssertFalse(offer("2.10.0", "2.10.0"))
        // Back on Stable, a nightly waits for the release it was heading for
        // rather than stepping back to the one before it.
        XCTAssertFalse(offer("2.10.0", "2.10.1-nightly.812"))
        XCTAssertTrue(offer("2.10.1", "2.10.1-nightly.812"))
        XCTAssertTrue(offer("2.11.0", "2.10.1-nightly.812"))
        XCTAssertFalse(offer("2.10.1-nightly.900", "2.10.0"), "the stable channel offers releases only")
    }

    func testNightlyOffersALaterBuildOrMovesAReleaseOnToTheNextVersion() {
        let offer = { UpdateOffer.shouldOffer(BuildVersion($0), to: BuildVersion($1), on: .nightly) }
        XCTAssertTrue(offer("2.10.1-nightly.813", "2.10.1-nightly.812"))
        XCTAssertFalse(offer("2.10.1-nightly.812", "2.10.1-nightly.812"))
        XCTAssertFalse(offer("2.10.1-nightly.811", "2.10.1-nightly.812"))
        // A feat landing moves the next version from a patch to a minor.
        XCTAssertTrue(offer("2.11.0-nightly.815", "2.10.1-nightly.812"))
        // After 2.10.0 the nightlies lead up to 2.10.1, which is ahead of it.
        XCTAssertTrue(offer("2.10.1-nightly.812", "2.10.0"))
        // A nightly of the release that's running comes before it.
        XCTAssertFalse(offer("2.10.1-nightly.812", "2.10.1"))
        XCTAssertFalse(offer("2.11.0", "2.10.0"), "the nightly channel offers nightlies only")
    }

    // MARK: - The setting

    func testAnythingButNightlyIsStable() {
        XCTAssertEqual(UpdateChannel.from(config: nil), .stable)
        XCTAssertEqual(UpdateChannel.from(config: " Nightly "), .nightly)
        XCTAssertEqual(UpdateChannel.from(config: "beta"), .stable)
    }

    func testTheChannelIsAValueRowUnderActions() {
        let nav = PanelNav()
        XCTAssertTrue(nav.rows(in: .actions).contains(.updateChannel))
        nav.settingsCategory = .actions
        nav.settingsDetailFocused = true
        nav.selectedSettingIndex = nav.index(of: .updateChannel)
        XCTAssertTrue(nav.selectedRowIsPicker)
        nav.cycleForward()
        XCTAssertEqual(nav.updateChannel, .stable, "arrows do nothing until a pick starts")
    }

    // An offer from the other channel no longer applies, so switching drops
    // it and asks again. setUpdateChannel writes the real config, so this
    // stops short of calling it and checks the pieces it relies on.
    func testTheChannelsReleasesAreDifferentEndpoints() {
        XCTAssertTrue(UpdateChannel.stable.releaseURL.path.hasSuffix("/releases/latest"))
        XCTAssertTrue(UpdateChannel.nightly.releaseURL.path.hasSuffix("/releases/tags/nightly"))
        XCTAssertEqual(UpdateChannel.nightly.releaseGHPath, "repos/StackOneHQ/stack-nudge/releases/tags/nightly")
    }
}
