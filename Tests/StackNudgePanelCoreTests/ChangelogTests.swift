import XCTest

@testable import StackNudgePanelCore

// Settings > About renders the entry for the running version out of the
// CHANGELOG.md that build.sh copies into the bundle. The parser is the whole
// feature: everything downstream is a Text.
final class ChangelogTests: XCTestCase {

    // Two entries, the release-please shapes verbatim: a linked version heading,
    // the blank-line padding it emits, a `###` section, and bullets carrying
    // both a PR link and a commit link.
    private let source = """
    # Changelog

    All notable changes to stack-nudge are documented in this file.

    ## [1.34.1](https://github.com/StackOneHQ/stack-nudge/compare/v1.34.0...v1.34.1) (2026-09-17)


    ### Bug Fixes

    * **panel:** group Settings into categories ([#181](https://github.com/StackOneHQ/stack-nudge/issues/181)) ([5b99f59](https://github.com/StackOneHQ/stack-nudge/commit/5b99f59b8c081bf0dc5e4e7759a9e7ab914fac2b))

    ## [1.34.0](https://github.com/StackOneHQ/stack-nudge/compare/v1.33.1...v1.34.0) (2026-09-15)


    ### Features

    * **panel:** per-client usage errors ([#175](https://github.com/StackOneHQ/stack-nudge/issues/175)) ([0faf006](https://github.com/StackOneHQ/stack-nudge/commit/0faf00605ef9b3a1436715947ffea9ab1abcdd87))
    """

    func testEntriesAreNewestFirst() {
        let entries = Changelog.entries(in: source)
        XCTAssertEqual(entries.map(\.version), ["1.34.1", "1.34.0"])
        XCTAssertEqual(entries.first?.date, "2026-09-17")
    }

    // The preamble sits above the first version heading and belongs to no entry.
    func testThePreambleIsNotPartOfAnEntry() {
        let entries = Changelog.entries(in: source)
        for entry in entries {
            XCTAssertFalse(entry.body.contains("All notable changes"))
            XCTAssertFalse(entry.body.contains("# Changelog"))
        }
    }

    // `###` is a section inside an entry. Treating one as a version heading
    // would cut the entry in half and lose its bullets.
    func testSectionHeadingsStayInsideTheEntry() {
        let entry = Changelog.entries(in: source).first
        XCTAssertEqual(entry?.body.hasPrefix("### Bug Fixes"), true)
        XCTAssertEqual(Changelog.entries(in: source).count, 2)
    }

    // Both links render, and together they wrap a one-line bullet onto three in
    // a pane this narrow. The PR link is the one a reader follows.
    func testTheCommitLinkIsStrippedAndThePRLinkKept() {
        let body = Changelog.entries(in: source).first?.body ?? ""
        XCTAssertTrue(body.contains("[#181](https://github.com/StackOneHQ/stack-nudge/issues/181)"))
        XCTAssertFalse(body.contains("commit/5b99f59"))
        XCTAssertTrue(body.hasSuffix("([#181](https://github.com/StackOneHQ/stack-nudge/issues/181))"))
    }

    func testEntryForAVersionPicksThatVersion() {
        let entry = Changelog.entry(for: "1.34.0", in: source)
        XCTAssertEqual(entry?.version, "1.34.0")
        XCTAssertTrue(entry?.body.contains("per-client usage errors") == true)
    }

    // A locally built panel reports a version that was never released. Showing
    // the newest released notes beats showing nothing.
    func testAnUnreleasedVersionFallsBackToTheNewestEntry() {
        XCTAssertEqual(Changelog.entry(for: "9.9.9", in: source)?.version, "1.34.1")
    }

    func testAFileWithNoEntriesYieldsNothing() {
        XCTAssertNil(Changelog.entry(for: "1.0.0", in: "# Changelog\n\nNothing yet.\n"))
        XCTAssertTrue(Changelog.entries(in: "").isEmpty)
    }

    // release-please always writes the linked form, but the file is hand-editable
    // and a plain heading must not silently drop an entry.
    func testAPlainVersionHeadingIsStillAnEntry() {
        let plain = """
        ## 2.0.0 (2026-10-01)

        ### Features

        * something
        """
        let entry = Changelog.entries(in: plain).first
        XCTAssertEqual(entry?.version, "2.0.0")
        XCTAssertEqual(entry?.date, "2026-10-01")
    }

    // "## Unreleased" and similar are not versions; taking them as one would
    // put a heading where About expects a number.
    func testANonVersionHeadingIsNotAnEntry() {
        XCTAssertTrue(Changelog.entries(in: "## Unreleased\n\n* wip\n").isEmpty)
    }

    // The shipped file is the real input, so parse it rather than trusting the
    // fixture above to stay representative of it.
    //
    // Found by walking up from the working directory, not from #filePath: the
    // no-Xcode runner compiles these sources out of a temp stage, so #filePath
    // points at a directory with no repo above it. Both runners start at the
    // repo root. Never skipped when the file isn't found — a test that quietly
    // passes on a missing input is worse than no test.
    func testTheRepositoryChangelogParses() throws {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: manager.currentDirectoryPath)
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("CHANGELOG.md")
            if manager.fileExists(atPath: candidate.path) { found = candidate; break }
            directory = directory.deletingLastPathComponent()
        }
        let url = try XCTUnwrap(found, "no CHANGELOG.md above \(manager.currentDirectoryPath)")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = Changelog.entries(in: text)
        XCTAssertGreaterThan(entries.count, 10, "the changelog stopped parsing")
        let newest = try XCTUnwrap(entries.first)
        XCTAssertFalse(newest.body.isEmpty, "newest entry parsed with no body")
        XCTAssertFalse(newest.body.contains("/commit/"), "commit links survived")
    }
}
