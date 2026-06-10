import XCTest

@testable import StackNudgePanelCore

// OutcomeWatcher derives "did it ship?" from current git state via an injected
// runner. These drive each branch through the precedence ladder
// (merged > pushed > committed > needsReview > clean) with a stub git that
// answers rev-parse / merge-base for a small fake commit graph.
final class OutcomeWatcherTests: XCTestCase {

    // A tiny linear graph: base ← b1 ← b2. `refs` maps a ref to its tip sha;
    // `ancestors[x]` is the set of shas reachable from x (x included), so
    // merge-base(a, b) = a when a ∈ ancestors[b].
    private func stubGit(refs: [String: String],
                         ancestors: [String: Set<String>]) -> ([String]) -> String? {
        { args in
            switch args.first {
            case "rev-parse":
                // ["rev-parse", "--verify", "--quiet", <ref>]
                guard let ref = args.last else { return nil }
                return refs[ref]
            case "merge-base":
                // ["merge-base", <a>, <b>] → the one that's an ancestor of the other
                let a = args[1], b = args[2]
                if ancestors[b]?.contains(a) == true { return a }
                if ancestors[a]?.contains(b) == true { return b }
                return nil
            default:
                return nil
            }
        }
    }

    func test_merged_branchTipReachableFromBase() {
        // base is at b2, branch tip b1 → b1 is an ancestor of base → merged.
        let git = stubGit(
            refs: ["origin/main": "b2", "ENG-1/x": "b1"],
            ancestors: ["b2": ["base", "b1", "b2"], "b1": ["base", "b1"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .merged)
    }

    func test_pushed_remoteHasAllLocalCommits() {
        // Not in base; remote branch tip == local tip → pushed.
        let git = stubGit(
            refs: ["origin/main": "base", "ENG-1/x": "b2", "origin/ENG-1/x": "b2"],
            ancestors: ["base": ["base"], "b2": ["base", "b1", "b2"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "b2",
                                             filesChangedAtStop: 0, git: git), .pushed)
    }

    func test_committed_localAheadOfRemote() {
        // Remote at b1, local at b2 (ahead) → committed (unpushed commits).
        let git = stubGit(
            refs: ["origin/main": "base", "ENG-1/x": "b2", "origin/ENG-1/x": "b1"],
            ancestors: ["base": ["base"], "b1": ["base", "b1"], "b2": ["base", "b1", "b2"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "b2",
                                             filesChangedAtStop: 0, git: git), .committed)
    }

    func test_committed_noRemoteButCommitsBeyondBase() {
        // No remote branch; branch has commits on top of base → committed.
        let git = stubGit(
            refs: ["origin/main": "base", "ENG-1/x": "b1"],
            ancestors: ["base": ["base"], "b1": ["base", "b1"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .committed)
    }

    func test_needsReview_uncommittedWorkNoCommitsSinceStop() {
        // Branch tip == base (no new commits), no remote, dirty work at Stop.
        let git = stubGit(
            refs: ["origin/main": "base", "ENG-1/x": "base"],
            ancestors: ["base": ["base"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "base",
                                             filesChangedAtStop: 7, git: git), .needsReview)
    }

    func test_clean_noPendingWorkOnBase() {
        let git = stubGit(
            refs: ["origin/main": "base", "ENG-1/x": "base"],
            ancestors: ["base": ["base"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "base",
                                             filesChangedAtStop: 0, git: git), .clean)
    }

    func test_deletedBranch_mergedIfHeadInBase() {
        // Branch ref gone; recorded head is an ancestor of base → merged.
        let git = stubGit(
            refs: ["origin/main": "b2"],
            ancestors: ["b2": ["base", "b1", "b2"]])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .merged)
    }

    func test_nilBranch_isClean() {
        XCTAssertEqual(OutcomeWatcher.derive(branch: nil, headCommit: nil,
                                             filesChangedAtStop: 5) { _ in nil }, .clean)
    }
}
