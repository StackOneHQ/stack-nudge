import XCTest

@testable import StackNudgePanelCore

// The rule that re-points the launch agents at the bundle an update just
// installed. Without it, a plist written by a bundle somewhere else — a
// pre-1.7 `stack-nudge.app`, or a copy the wizard ran from in ~/Downloads —
// kept pointing there forever, and the update's restart call hung on it
// (#205) or relaunched the previous version.
final class LaunchAgentRetargetTests: XCTestCase {

    private let installed = "/Users/u/Applications/StackNudge.app"
    private let everythingExists: (String) -> Bool = { _ in true }

    private func retarget(_ path: String,
                          exists: ((String) -> Bool)? = nil) -> String? {
        Bootstrap.retargetedBundlePath(path, toBundle: installed,
                                       exists: exists ?? everythingExists)
    }

    // MARK: - The two cases this exists for

    func test_retargetsAPreRebrandBundle() {
        XCTAssertEqual(
            retarget("/Users/u/Applications/stack-nudge.app/Contents/MacOS/stack-nudge"),
            "\(installed)/Contents/MacOS/stack-nudge")
    }

    func test_retargetsACopyTheWizardRanFromElsewhere() {
        XCTAssertEqual(
            retarget("/Users/u/Downloads/StackNudge.app/Contents/MacOS/stack-nudge"),
            "\(installed)/Contents/MacOS/stack-nudge")
    }

    // MARK: - What it must leave alone

    // The ordinary install: already pointing at the installed bundle. Nil
    // matters, not just "same string back" — nil is what tells the updater
    // nothing was retargeted, so the restart behaves exactly as before.
    func test_leavesAPathAlreadyInTheInstalledBundleAlone() {
        XCTAssertNil(retarget("\(installed)/Contents/MacOS/stack-nudge"))
    }

    func test_recognisesTheInstalledBundleDespiteNonCanonicalSpelling() {
        XCTAssertNil(retarget("/Users/u/Applications/./StackNudge.app/Contents/MacOS/stack-nudge"))
        XCTAssertNil(retarget("/Users/u/Downloads/../Applications/StackNudge.app/Contents/MacOS/stack-nudge"))
    }

    func test_leavesArgumentsThatAreNotBundlePathsAlone() {
        XCTAssertNil(retarget("serve"))
        XCTAssertNil(retarget("/usr/bin/python3"))
    }

    // Never trade one missing path for another: if the new bundle doesn't
    // contain the file, leave the plist as it was.
    func test_leavesAPathAloneWhenTheInstalledBundleLacksTheFile() {
        XCTAssertNil(retarget("/Users/u/Applications/stack-nudge.app/Contents/Resources/venv/bin/python3",
                              exists: { _ in false }))
    }

    // A directory merely NAMED like a bundle is not one. The existence check
    // is what keeps it safe: the rewritten path won't exist inside the app.
    func test_leavesADirectoryThatMerelyEndsInDotAppAlone() {
        let projectPath = "/Users/u/code/my.app/scripts/run.sh"
        XCTAssertNil(retarget(projectPath, exists: { FileManager.default.fileExists(atPath: $0) }))
    }

    // A path into a helper nested inside the app belongs to the app, so the
    // OUTERMOST bundle is the one replaced.
    func test_retargetsByTheOutermostBundle() {
        XCTAssertEqual(
            retarget("/Users/u/Downloads/StackNudge.app/Contents/Helpers/Notifier.app/Contents/MacOS/n"),
            "\(installed)/Contents/Helpers/Notifier.app/Contents/MacOS/n")
    }

    // MARK: - Whole launch specs

    // The daemon's real shape: interpreter, script, a bare argument, and an
    // environment variable pointing into the bundle's data dir. All three
    // bundle paths move together; the bare argument and unrelated env don't.
    func test_retargetsTheDaemonSpecIncludingItsEnvironment() throws {
        let old = "/Users/u/Applications/stack-nudge.app/Contents/Resources/venv"
        let spec = try XCTUnwrap(Bootstrap.retargetedLaunchSpec(
            arguments: ["\(old)/bin/python3", "\(old)/bin/stackvox", "serve"],
            environment: ["ESPEAK_DATA_PATH": "\(old)/lib/espeak-ng-data", "LANG": "en_GB.UTF-8"],
            toBundle: installed,
            exists: everythingExists))

        let new = "\(installed)/Contents/Resources/venv"
        XCTAssertEqual(spec.arguments, ["\(new)/bin/python3", "\(new)/bin/stackvox", "serve"])
        XCTAssertEqual(spec.environment["ESPEAK_DATA_PATH"], "\(new)/lib/espeak-ng-data")
        XCTAssertEqual(spec.environment["LANG"], "en_GB.UTF-8")
    }

    func test_specIsNilWhenNothingNeedsToMove() {
        XCTAssertNil(Bootstrap.retargetedLaunchSpec(
            arguments: ["\(installed)/Contents/MacOS/stack-nudge"],
            environment: [:],
            toBundle: installed,
            exists: everythingExists))
    }

    // MARK: - On disk

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("retarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // A real bundle layout with the binary present, so the existence check
    // passes for real rather than through a stub.
    private func makeInstalledBundle() throws -> String {
        let bundle = scratch.appendingPathComponent("Applications/StackNudge.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macOS.appendingPathComponent("stack-nudge").path,
                                       contents: Data())
        return bundle.path
    }

    private func writeAgent(_ plist: [String: Any], label: String = "test.agent") throws -> String {
        let path = scratch.appendingPathComponent("\(label).plist").path
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func readAgent(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                             as? [String: Any])
    }

    func test_rewritesALegacyAgentOnDiskAndKeepsEverythingElse() throws {
        let bundle = try makeInstalledBundle()
        let path = try writeAgent([
            "Label": "test.agent",
            "ProgramArguments": ["/Users/u/Applications/stack-nudge.app/Contents/MacOS/stack-nudge"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": "/tmp/app.log",
        ])

        XCTAssertTrue(Bootstrap.retargetLaunchAgentOnDisk(
            label: "test.agent", toBundle: bundle, agentsDir: scratch.path))

        let plist = try readAgent(path)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["\(bundle)/Contents/MacOS/stack-nudge"])
        // A retarget that dropped KeepAlive would turn a user's Quit back into
        // a respawn — the bug #106 fixed. Everything but the paths survives.
        XCTAssertEqual(plist["Label"] as? String, "test.agent")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(plist["StandardOutPath"] as? String, "/tmp/app.log")
        XCTAssertNil(plist["EnvironmentVariables"], "invented an empty environment")
    }

    // Idempotent: the second update after a retarget must report nothing to
    // do, or every update would skip the app kickstart for no reason.
    func test_secondRunReportsNothingToDo() throws {
        let bundle = try makeInstalledBundle()
        _ = try writeAgent(["Label": "test.agent",
                            "ProgramArguments": ["/elsewhere/StackNudge.app/Contents/MacOS/stack-nudge"]])
        XCTAssertTrue(Bootstrap.retargetLaunchAgentOnDisk(label: "test.agent", toBundle: bundle,
                                                          agentsDir: scratch.path))
        XCTAssertFalse(Bootstrap.retargetLaunchAgentOnDisk(label: "test.agent", toBundle: bundle,
                                                           agentsDir: scratch.path))
    }

    func test_reportsNothingForAMissingAgent() throws {
        XCTAssertFalse(Bootstrap.retargetLaunchAgentOnDisk(
            label: "not.there", toBundle: try makeInstalledBundle(), agentsDir: scratch.path))
    }

    // MARK: - KeepAlive

    // Plists old enough to need retargeting predate #106 and say
    // `KeepAlive: true`, which restarts the panel even after a user's Quit.
    func test_crashOnlyKeepAlive_rewritesTheUnconditionalForm() throws {
        let path = try writeAgent(["Label": "test.agent", "KeepAlive": true,
                                   "ProgramArguments": ["/x"]])
        XCTAssertTrue(Bootstrap.crashOnlyKeepAliveOnDisk(label: "test.agent", agentsDir: scratch.path))
        let plist = try readAgent(path)
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/x"])
    }

    // Already crash-only: no change, and false — so the first-launch
    // migration that shares this sees nothing to reload.
    func test_crashOnlyKeepAlive_leavesTheCrashOnlyFormAlone() throws {
        let path = try writeAgent(["Label": "test.agent", "KeepAlive": ["SuccessfulExit": false],
                                   "ProgramArguments": ["/x"]])
        let before = FileManager.default.contents(atPath: path)
        XCTAssertFalse(Bootstrap.crashOnlyKeepAliveOnDisk(label: "test.agent", agentsDir: scratch.path))
        XCTAssertEqual(FileManager.default.contents(atPath: path), before)
    }

    // A plist we can't parse is left byte-for-byte as we found it.
    func test_leavesAnUnreadableAgentUntouched() throws {
        let path = scratch.appendingPathComponent("test.agent.plist").path
        let garbage = Data("not a plist".utf8)
        FileManager.default.createFile(atPath: path, contents: garbage)

        XCTAssertFalse(Bootstrap.retargetLaunchAgentOnDisk(
            label: "test.agent", toBundle: try makeInstalledBundle(), agentsDir: scratch.path))
        XCTAssertEqual(FileManager.default.contents(atPath: path), garbage)
    }
}
