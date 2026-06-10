import XCTest

@testable import StackNudgePanelCore

// GitSnapshot captures the uncommitted working-tree size at Stop. These pin the
// numstat parsing (including binary "-" deltas) and the capture wiring, using an
// injected git runner so no real repo is needed.
final class GitSnapshotTests: XCTestCase {

    func test_parseNumstat_sumsFilesAndLines() {
        let actual = GitSnapshot.parseNumstat("10\t2\tpanel/A.swift\n5\t0\tpanel/B.swift\n")
        XCTAssertEqual(actual.files, 2)
        XCTAssertEqual(actual.insertions, 15)
        XCTAssertEqual(actual.deletions, 2)
    }

    func test_parseNumstat_binaryFilesCountWithZeroDelta() {
        let actual = GitSnapshot.parseNumstat("-\t-\tassets/logo.png\n3\t1\tREADME.md\n")
        XCTAssertEqual(actual.files, 2)
        XCTAssertEqual(actual.insertions, 3)
        XCTAssertEqual(actual.deletions, 1)
    }

    func test_parseNumstat_emptyIsZero() {
        let actual = GitSnapshot.parseNumstat("")
        XCTAssertEqual(actual.files, 0)
        XCTAssertEqual(actual.insertions, 0)
        XCTAssertEqual(actual.deletions, 0)
    }

    func test_capture_combinesTrackedAndUntracked() {
        let git: (String, [String]) -> String? = { _, args in
            switch args.first {
            case "rev-parse": return "abc1234"
            case "diff":      return "10\t2\tA.swift\n5\t3\tB.swift\n"
            case "ls-files":  return "new1.txt\nnew2.txt\n"
            default:          return nil
            }
        }
        let actual = GitSnapshot.capture(cwd: "/repo", git: git)
        XCTAssertEqual(actual?.headCommit, "abc1234")
        XCTAssertEqual(actual?.filesChanged, 4)   // 2 tracked + 2 untracked
        XCTAssertEqual(actual?.insertions, 15)
        XCTAssertEqual(actual?.deletions, 5)
        XCTAssertEqual(actual?.isDirty, true)
    }

    func test_capture_nilWhenNoHead() {
        XCTAssertNil(GitSnapshot.capture(cwd: "/notrepo") { _, _ in nil })
    }

    func test_capture_cleanTreeIsNotDirty() {
        let actual = GitSnapshot.capture(cwd: "/repo") { _, args in
            args.first == "rev-parse" ? "abc1234" : ""
        }
        XCTAssertEqual(actual?.filesChanged, 0)
        XCTAssertEqual(actual?.isDirty, false)
    }
}
