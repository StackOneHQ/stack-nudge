import XCTest

@testable import StackNudgePanelCore

final class BootstrapTests: XCTestCase {

    // MARK: - notifyVersion(inScript:)

    func test_notifyVersion_readsTheStampFromTheHeader() {
        let script = """
        #!/usr/bin/env bash
        # stack-nudge: Cross-platform notifications for AI coding agent hooks
        # stack-nudge-version: 1.26.0 # x-release-please-version
        AGENT="${1:-agent}"
        """
        XCTAssertEqual(Bootstrap.notifyVersion(inScript: script), "1.26.0")
    }

    func test_notifyVersion_isNilForAScriptWithoutAStamp() {
        let script = """
        #!/usr/bin/env bash
        # stack-nudge: Cross-platform notifications for AI coding agent hooks
        AGENT="${1:-agent}"
        """
        XCTAssertNil(Bootstrap.notifyVersion(inScript: script))
    }

    func test_notifyVersion_ignoresAMalformedStamp() {
        let script = "#!/usr/bin/env bash\n# stack-nudge-version: v1.26\n"
        XCTAssertNil(Bootstrap.notifyVersion(inScript: script))
    }

    // The stamp is a header comment; a mention further down (a heredoc, a log
    // line, a doc block) must not be mistaken for it.
    func test_notifyVersion_ignoresMatchesBelowTheHeader() {
        let filler = Array(repeating: "# padding", count: 60).joined(separator: "\n")
        let script = "#!/usr/bin/env bash\n\(filler)\n# stack-nudge-version: 9.9.9\n"
        XCTAssertNil(Bootstrap.notifyVersion(inScript: script))
    }

    func test_notifyVersion_toleratesNoSpaceAfterTheHash() {
        XCTAssertEqual(Bootstrap.notifyVersion(inScript: "#stack-nudge-version:1.2.3"), "1.2.3")
    }

    // MARK: - needsNotifyRefresh

    func test_needsNotifyRefresh_isTrueWhenTheInstalledScriptIsUnstamped() {
        // Every install predating the stamp: the drift this repairs.
        XCTAssertTrue(Bootstrap.needsNotifyRefresh(installed: nil, bundled: "1.26.0"))
    }

    func test_needsNotifyRefresh_isTrueWhenTheVersionsDiffer() {
        XCTAssertTrue(Bootstrap.needsNotifyRefresh(installed: "1.12.0", bundled: "1.26.0"))
    }

    // Not just "older": a downgrade to an earlier bundle should also restore the
    // script that bundle expects to be talking to.
    func test_needsNotifyRefresh_isTrueWhenTheInstalledScriptIsNewer() {
        XCTAssertTrue(Bootstrap.needsNotifyRefresh(installed: "1.30.0", bundled: "1.26.0"))
    }

    func test_needsNotifyRefresh_isFalseWhenTheVersionsMatch() {
        XCTAssertFalse(Bootstrap.needsNotifyRefresh(installed: "1.26.0", bundled: "1.26.0"))
    }

    // An unstamped bundle is a local swiftc build, where the developer's own
    // script is the one under test. Leave it alone rather than guess.
    func test_needsNotifyRefresh_isFalseWhenTheBundleIsUnstamped() {
        XCTAssertFalse(Bootstrap.needsNotifyRefresh(installed: "1.12.0", bundled: nil))
        XCTAssertFalse(Bootstrap.needsNotifyRefresh(installed: nil, bundled: nil))
    }

    // MARK: - writeNotifyScript

    func test_writeNotifyScript_writesExecutableContent() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path

        try Bootstrap.writeNotifyScript("#!/usr/bin/env bash\necho new\n", to: path)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       "#!/usr/bin/env bash\necho new\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    func test_writeNotifyScript_replacesAnExistingScript() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "old".write(toFile: path, atomically: true, encoding: .utf8)

        try Bootstrap.writeNotifyScript("new", to: path)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    // The swap must never leave the destination absent, since a hook firing
    // mid-write would otherwise find no script to run.
    func test_writeNotifyScript_leavesNoTempFilesBehind() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "old".write(toFile: path, atomically: true, encoding: .utf8)

        try Bootstrap.writeNotifyScript("new", to: path)

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, ["notify.sh"])
    }

    func test_writeNotifyScript_throwsWhenTheDirectoryIsMissing() {
        let path = "/nonexistent-\(UUID().uuidString)/notify.sh"
        XCTAssertThrowsError(try Bootstrap.writeNotifyScript("new", to: path))
    }

    // MARK: - refreshNotifyScript

    private static let stamped = "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho new\n"

    func test_refreshNotifyScript_replacesAnUnstampedInstall() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "#!/usr/bin/env bash\necho old\n".write(toFile: path, atomically: true, encoding: .utf8)

        let written = Bootstrap.refreshNotifyScript(bundled: Self.stamped, installedPath: path)

        XCTAssertEqual(written, "1.26.0")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), Self.stamped)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    func test_refreshNotifyScript_leavesAMatchingInstallUntouched() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        let installed = "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho mine\n"
        try installed.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertNil(Bootstrap.refreshNotifyScript(bundled: Self.stamped, installedPath: path))
        // Same stamp means same protocol, so a locally tweaked script survives.
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), installed)
    }

    func test_refreshNotifyScript_doesNothingWithoutABundledScript() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "old".write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertNil(Bootstrap.refreshNotifyScript(bundled: nil, installedPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "old")
    }

    // No installed script means no install to repair; writing one would leave a
    // file nothing is wired to invoke.
    func test_refreshNotifyScript_doesNotCreateAMissingScript() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path

        XCTAssertNil(Bootstrap.refreshNotifyScript(bundled: Self.stamped, installedPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // A stamp-only version bump (which release-please does on every release) must
    // NOT rewrite the script: rewriting would reset Codex's hook-trust hash and
    // silently disable codex capture until the user re-trusts via /hooks.
    func test_refreshNotifyScript_skipsAStampOnlyBump() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        let installed = "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho same\n"
        try installed.write(toFile: path, atomically: true, encoding: .utf8)
        let bundled = "#!/usr/bin/env bash\n# stack-nudge-version: 1.27.0\necho same\n"

        XCTAssertNil(Bootstrap.refreshNotifyScript(bundled: bundled, installedPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), installed)
    }

    func test_refreshNotifyScript_rewritesOnALogicChange() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho old\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        let bundled = "#!/usr/bin/env bash\n# stack-nudge-version: 1.27.0\necho new\n"

        XCTAssertEqual(Bootstrap.refreshNotifyScript(bundled: bundled, installedPath: path), "1.27.0")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), bundled)
    }

    func test_notifyScriptOutdated_falseForAStampOnlyDifference_trueForALogicChange() throws {
        let dir = try temporaryDirectory()
        let path = dir.appendingPathComponent("notify.sh").path
        try "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho same\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertFalse(Bootstrap.notifyScriptOutdated(
            bundled: "#!/usr/bin/env bash\n# stack-nudge-version: 1.27.0\necho same\n", installedPath: path))
        XCTAssertTrue(Bootstrap.notifyScriptOutdated(
            bundled: "#!/usr/bin/env bash\n# stack-nudge-version: 1.27.0\necho changed\n", installedPath: path))
    }

    func test_functionalContent_neutralisesTheVersionStamp() {
        let v1 = "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0 # x-release-please-version\necho hi\n"
        let v2 = "#!/usr/bin/env bash\n# stack-nudge-version: 9.9.9 # x-release-please-version\necho hi\n"
        XCTAssertEqual(Bootstrap.functionalContent(v1), Bootstrap.functionalContent(v2))
        let changed = "#!/usr/bin/env bash\n# stack-nudge-version: 1.26.0\necho DIFFERENT\n"
        XCTAssertNotEqual(Bootstrap.functionalContent(v1), Bootstrap.functionalContent(changed))
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bootstrap-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
