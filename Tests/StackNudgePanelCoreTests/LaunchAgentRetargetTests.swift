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
                                       exists: exists ?? everythingExists,
                                       isSuperseded: { _ in true })
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
            exists: everythingExists,
            isSuperseded: { _ in true }))

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
            exists: everythingExists,
            isSuperseded: { _ in true }))
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
    // A path in scratch where no venv link exists, for tests not about it.
    private var noLink: String { scratch.appendingPathComponent("no-venv-link").path }

    private func makeBundle(at relative: String, version: String?) throws -> String {
        let bundle = scratch.appendingPathComponent(relative)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macOS.appendingPathComponent("stack-nudge").path,
                                       contents: Data())
        if let version {
            let info = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        return bundle.path
    }

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

    // A path into ANOTHER app must be left alone even when the same relative
    // path exists inside ours. Directories pass the existence check, and
    // every app has `Contents/Resources`, so existence alone would re-point a
    // foreign app's path into stack-nudge. Uses a real bundle, so the file
    // really does exist and only the ours-only guard can stop it.
    func test_leavesAPathIntoAForeignAppAloneEvenWhenItExistsInOurs() throws {
        let bundle = try makeInstalledBundle()
        let foreign = scratch.appendingPathComponent("Applications/Other.app/Contents/MacOS").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(bundle)/Contents/MacOS"),
                      "precondition: the same path exists inside our bundle")
        XCTAssertNil(Bootstrap.retargetedBundlePath(
            foreign, toBundle: bundle, exists: { FileManager.default.fileExists(atPath: $0) },
            isSuperseded: { _ in true }))
    }

    // The installed bundle reached through a symlinked parent is the SAME
    // bundle. Comparing spelling would call it different and trigger a
    // spurious retarget: skip the app kickstart and retire a good job.
    func test_recognisesTheInstalledBundleThroughASymlinkedParent() throws {
        let bundle = try makeInstalledBundle()
        let alias = scratch.appendingPathComponent("Apps")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: scratch.appendingPathComponent("Applications"))
        let viaAlias = alias.appendingPathComponent("StackNudge.app/Contents/MacOS/stack-nudge").path
        XCTAssertNil(Bootstrap.retargetedBundlePath(
            viaAlias, toBundle: bundle, exists: { FileManager.default.fileExists(atPath: $0) },
            isSuperseded: { _ in true }))
    }

    // Names our bundle has actually had: the pre-1.7 one, and Finder's
    // duplicate-download suffix. Case-insensitive, as APFS is by default.
    func test_retargetsEveryNameOurBundleHasShippedOrBeenSavedAs() {
        for name in ["stack-nudge.app", "StackNudge.app", "StackNudge 2.app", "stacknudge.app"] {
            XCTAssertNotNil(retarget("/Users/u/Downloads/\(name)/Contents/MacOS/stack-nudge"),
                            "\(name) should be recognised as ours")
        }
    }

    // E/M8: args already correct, only the environment stale. The spec
    // must still report a change — otherwise the stale data dir survives.
    func test_specMovesAStaleEnvironmentEvenWhenTheArgumentsAreCorrect() throws {
        let spec = try XCTUnwrap(Bootstrap.retargetedLaunchSpec(
            arguments: ["\(installed)/Contents/Resources/venv/bin/python3", "serve"],
            environment: ["ESPEAK_DATA_PATH": "/Users/u/Applications/stack-nudge.app/Contents/Resources/data"],
            toBundle: installed, exists: everythingExists, isSuperseded: { _ in true }))
        XCTAssertEqual(spec.environment["ESPEAK_DATA_PATH"], "\(installed)/Contents/Resources/data")
    }

    // MARK: - The whole update-time step

    // The wiring the updater relies on, end to end on disk: both agents
    // re-pointed, the daemon's environment saved (not just computed), and
    // crash-only KeepAlive applied to the app ONLY — the daemon's `true` is
    // deliberate, and flipping it would stop voice coming back after a crash.
    func test_retargetAgentsAfterUpdate_rewritesBothAndFixesKeepAliveOnTheAppOnly() throws {
        let bundle = try makeInstalledBundle()
        let venv = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources/venv")
        for sub in ["bin", "lib/espeak-ng-data"] {
            try FileManager.default.createDirectory(at: venv.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        for file in ["bin/python3", "bin/stackvox"] {
            FileManager.default.createFile(atPath: venv.appendingPathComponent(file).path, contents: Data())
        }

        let old = "/Users/u/Applications/stack-nudge.app"
        let appPath = try writeAgent(["Label": Bootstrap.appLabel, "KeepAlive": true,
                                      "ProgramArguments": ["\(old)/Contents/MacOS/stack-nudge"]],
                                     label: Bootstrap.appLabel)
        let daemonPath = try writeAgent([
            "Label": Bootstrap.daemonLabel, "KeepAlive": true,
            "ProgramArguments": ["\(old)/Contents/Resources/venv/bin/python3",
                                 "\(old)/Contents/Resources/venv/bin/stackvox", "serve"],
            "EnvironmentVariables": ["ESPEAK_DATA_PATH": "\(old)/Contents/Resources/venv/lib/espeak-ng-data"],
        ], label: Bootstrap.daemonLabel)

        // The voice-engine link, pointing into the same old bundle.
        let link = scratch.appendingPathComponent("venv-link").path
        try FileManager.default.createSymbolicLink(atPath: link,
                                                   withDestinationPath: "\(old)/Contents/Resources/venv")

        let retargeted = Bootstrap.retargetAgentsAfterUpdate(toBundle: bundle, agentsDir: scratch.path,
                                                              venvSymlinkPath: link)
        XCTAssertEqual(retargeted, [Bootstrap.appLabel, Bootstrap.daemonLabel])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), venv.path,
                       "the update-time step didn't re-point the voice-engine link")

        let app = try readAgent(appPath)
        XCTAssertEqual(app["ProgramArguments"] as? [String], ["\(bundle)/Contents/MacOS/stack-nudge"])
        XCTAssertEqual(app["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])

        let daemon = try readAgent(daemonPath)
        XCTAssertEqual((daemon["ProgramArguments"] as? [String])?.first,
                       "\(bundle)/Contents/Resources/venv/bin/python3")
        XCTAssertEqual((daemon["EnvironmentVariables"] as? [String: String])?["ESPEAK_DATA_PATH"],
                       "\(bundle)/Contents/Resources/venv/lib/espeak-ng-data",
                       "daemon environment was computed but not saved")
        XCTAssertEqual(daemon["KeepAlive"] as? Bool, true, "daemon KeepAlive must stay unconditional")
    }

    // An ordinary install: nothing to move, nothing touched, nothing reported.
    func test_retargetAgentsAfterUpdate_isANoOpForAnOrdinaryInstall() throws {
        let bundle = try makeInstalledBundle()
        let appPath = try writeAgent(["Label": Bootstrap.appLabel, "KeepAlive": true,
                                      "ProgramArguments": ["\(bundle)/Contents/MacOS/stack-nudge"]],
                                     label: Bootstrap.appLabel)
        let before = FileManager.default.contents(atPath: appPath)
        XCTAssertEqual(Bootstrap.retargetAgentsAfterUpdate(toBundle: bundle, agentsDir: scratch.path,
                                                              venvSymlinkPath: noLink), [])
        XCTAssertEqual(FileManager.default.contents(atPath: appPath), before,
                       "touched an agent that didn't need retargeting")
    }

    // MARK: - Which bundles to move away from

    func test_superseded_whenTheOldBundleIsGone() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        XCTAssertTrue(Bootstrap.bundleIsSuperseded(scratch.appendingPathComponent("Downloads/StackNudge.app").path,
                                                   by: installed))
    }

    func test_superseded_whenTheOldBundleIsThePreRebrandName() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let legacy = try makeBundle(at: "Applications/stack-nudge.app", version: "2.1.6")
        XCTAssertTrue(Bootstrap.bundleIsSuperseded(legacy, by: installed))
    }

    func test_superseded_whenTheOldBundleIsAnOlderVersion() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let stale = try makeBundle(at: "Downloads/StackNudge.app", version: "2.1.5")
        XCTAssertTrue(Bootstrap.bundleIsSuperseded(stale, by: installed))
    }

    // The developer case review found: a build/ bundle at the current
    // version or ahead of it is deliberate, and an in-app update must not
    // silently re-point their launch agent at the release.
    func test_notSuperseded_aCurrentOrNewerDeveloperBuild() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let same = try makeBundle(at: "code/build/StackNudge.app", version: "2.1.6")
        let ahead = try makeBundle(at: "code2/build/StackNudge.app", version: "2.2.0")
        XCTAssertFalse(Bootstrap.bundleIsSuperseded(same, by: installed))
        XCTAssertFalse(Bootstrap.bundleIsSuperseded(ahead, by: installed))
    }

    func test_superseded_whenTheOldBundlesVersionCantBeRead() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let damaged = try makeBundle(at: "Downloads/StackNudge.app", version: nil)
        XCTAssertTrue(Bootstrap.bundleIsSuperseded(damaged, by: installed))
    }

    // End to end on disk: a dev's agent pointing at their current build is
    // left byte-for-byte alone by the update-time step.
    func test_retargetAgentsAfterUpdate_leavesACurrentDeveloperBuildAlone() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let dev = try makeBundle(at: "code/build/StackNudge.app", version: "2.1.6")
        let appPath = try writeAgent(["Label": Bootstrap.appLabel,
                                      "ProgramArguments": ["\(dev)/Contents/MacOS/stack-nudge"]],
                                     label: Bootstrap.appLabel)
        let before = FileManager.default.contents(atPath: appPath)
        XCTAssertEqual(Bootstrap.retargetAgentsAfterUpdate(toBundle: installed, agentsDir: scratch.path,
                                                          venvSymlinkPath: noLink), [])
        XCTAssertEqual(FileManager.default.contents(atPath: appPath), before)
    }

    // MARK: - The venv symlink

    private func makeVenv(in bundle: String) throws -> String {
        let venv = "\(bundle)/Contents/Resources/venv"
        try FileManager.default.createDirectory(atPath: venv, withIntermediateDirectories: true)
        return venv
    }

    func test_venvSymlink_isRepointedFromADeletedCopy() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let venv = try makeVenv(in: installed)
        let link = scratch.appendingPathComponent("venv").path
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: scratch.appendingPathComponent("Downloads/StackNudge.app/Contents/Resources/venv").path)

        XCTAssertTrue(Bootstrap.retargetVenvSymlink(toBundle: installed, symlinkPath: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), venv)
        // Still a link — replaced, not resolved into a copy or a directory.
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType,
                       .typeSymbolicLink)
    }

    func test_venvSymlink_isLeftAloneWhenAlreadyCurrent() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        let venv = try makeVenv(in: installed)
        let link = scratch.appendingPathComponent("venv").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: venv)
        XCTAssertFalse(Bootstrap.retargetVenvSymlink(toBundle: installed, symlinkPath: link))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), venv)
    }

    func test_venvSymlink_noLinkIsNotAnError() throws {
        let installed = try makeBundle(at: "Applications/StackNudge.app", version: "2.1.6")
        XCTAssertFalse(Bootstrap.retargetVenvSymlink(toBundle: installed, symlinkPath: noLink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: noLink), "invented a link")
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

    // `false` means "never respawn" and absent means the same; rewriting
    // either to crash-only would turn a job that stays down into one that
    // comes back. Only the unconditional `true` is the old bug.
    func test_crashOnlyKeepAlive_leavesFalseAndAbsentAlone() throws {
        for (label, plist) in [("ka.false", ["Label": "ka.false", "KeepAlive": false,
                                             "ProgramArguments": ["/x"]] as [String: Any]),
                               ("ka.absent", ["Label": "ka.absent", "ProgramArguments": ["/x"]])] {
            let path = try writeAgent(plist, label: label)
            let before = FileManager.default.contents(atPath: path)
            XCTAssertFalse(Bootstrap.crashOnlyKeepAliveOnDisk(label: label, agentsDir: scratch.path), label)
            XCTAssertEqual(FileManager.default.contents(atPath: path), before, label)
        }
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
