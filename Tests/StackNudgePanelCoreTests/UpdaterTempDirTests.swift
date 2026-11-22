import XCTest

@testable import StackNudgePanelCore

// The updater keeps each run's download in a folder of its own under the temp
// dir, and only ever lists that folder to clear out what a crashed run left.
// Listing the whole temp dir instead took minutes on a Mac where test suites
// had left 400k entries there, with the update screen stuck on "Preparing…".
final class UpdaterTempDirTests: XCTestCase {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("updater-temp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testUpdatesLiveInAFolderOfTheirOwn() {
        XCTAssertEqual(Updater.updatesRoot(temp: "/tmp/x/").path, "/tmp/x/stack-nudge-updates")
    }

    func testTheSweepClearsOldRunsAndNothingElse() throws {
        let temp = try scratch()
        let root = Updater.updatesRoot(temp: temp.path)
        let oldRun = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: oldRun, withIntermediateDirectories: true)
        try Data("tarball".utf8).write(to: oldRun.appendingPathComponent("stack-nudge.tar.gz"))
        // Someone else's file beside it in the temp dir, named like the old layout too.
        let neighbour = temp.appendingPathComponent("stack-nudge-update-\(UUID().uuidString)")
        try Data("not ours to list".utf8).write(to: neighbour)

        Updater.sweepStaleTempDirs(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRun.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }

    func testTheSweepIsANoOpBeforeAnyRun() throws {
        let temp = try scratch()
        Updater.sweepStaleTempDirs(root: Updater.updatesRoot(temp: temp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Updater.updatesRoot(temp: temp.path).path))
    }
}
