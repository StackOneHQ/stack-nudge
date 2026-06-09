import XCTest

@testable import StackNudgePanelCore

// Pure-logic tests for the version-comparison and release-asset matching
// helpers. UpdateChecker's network paths are exercised manually; the
// regressable pieces are these static helpers, which gate when the
// "Update available" badge appears and which artifact we try to install.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - stripV

    func test_stripV_removesLeadingV() {
        XCTAssertEqual(UpdateChecker.stripV("v1.2.3"), "1.2.3")
    }

    func test_stripV_isNoOpWithoutPrefix() {
        XCTAssertEqual(UpdateChecker.stripV("1.2.3"), "1.2.3")
    }

    func test_stripV_doesNotStripMidString() {
        XCTAssertEqual(UpdateChecker.stripV("1.v2.3"), "1.v2.3")
    }

    // MARK: - isNewer

    func test_isNewer_returnsTrueOnHigherPatch() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.4", than: "1.2.3"))
    }

    func test_isNewer_returnsFalseOnEqual() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2.3", than: "1.2.3"))
    }

    func test_isNewer_returnsFalseOnLower() {
        XCTAssertFalse(UpdateChecker.isNewer("1.2.2", than: "1.2.3"))
    }

    // The classic semver pitfall: "1.10" must beat "1.9" numerically,
    // not lexicographically. A regression here means users on 1.9 never
    // see the 1.10 update.
    func test_isNewer_comparesComponentsNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.20.0", than: "0.3.0"))
    }

    func test_isNewer_handlesAsymmetricComponentCounts() {
        // "2.0" vs "2.0.0" should treat as equal (missing trailing zero).
        XCTAssertFalse(UpdateChecker.isNewer("2.0", than: "2.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: "2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.1", than: "2.0"))
    }

    func test_isNewer_handlesMinorBump() {
        XCTAssertTrue(UpdateChecker.isNewer("1.16.0", than: "1.15.5"))
    }

    // MARK: - hasArtifact

    private func release(assetNames: [String]) -> [String: Any] {
        ["assets": assetNames.map { ["name": $0] as [String: Any] }]
    }

    func test_hasArtifact_findsMatchingArm64() {
        let json = release(assetNames: [
            "stack-nudge-1.16.1-macos-arm64.tar.gz",
            "stack-nudge-1.16.1-macos-arm64.tar.gz.sha256",
            "stack-nudge-1.16.1-macos-x86_64.tar.gz",
        ])
        XCTAssertTrue(UpdateChecker.hasArtifact(in: json, arch: "arm64"))
        XCTAssertTrue(UpdateChecker.hasArtifact(in: json, arch: "x86_64"))
    }

    // The pre-CI-build window: release-please created the tag but the
    // build/upload step hasn't finished. Asset list is empty (or only has
    // unrelated files). Badge must stay hidden.
    func test_hasArtifact_returnsFalseWhenAssetsEmpty() {
        XCTAssertFalse(UpdateChecker.hasArtifact(in: ["assets": [[String: Any]]()], arch: "arm64"))
    }

    func test_hasArtifact_returnsFalseWhenAssetsMissing() {
        XCTAssertFalse(UpdateChecker.hasArtifact(in: [:], arch: "arm64"))
        XCTAssertFalse(UpdateChecker.hasArtifact(in: nil, arch: "arm64"))
    }

    // sha256 sidecar must not be mistaken for the tarball — they share
    // the arch suffix as a substring.
    func test_hasArtifact_ignoresShaSidecarOnly() {
        let json = release(assetNames: [
            "stack-nudge-1.16.1-macos-arm64.tar.gz.sha256",
        ])
        XCTAssertFalse(UpdateChecker.hasArtifact(in: json, arch: "arm64"))
    }

    func test_hasArtifact_returnsFalseWhenOnlyOtherArchPresent() {
        let json = release(assetNames: [
            "stack-nudge-1.16.1-macos-arm64.tar.gz",
        ])
        XCTAssertFalse(UpdateChecker.hasArtifact(in: json, arch: "x86_64"))
    }
}
