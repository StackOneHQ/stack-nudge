import XCTest

@testable import StackNudgePanelCore

// OutcomeWatcher derives "did it ship?" from current git state: branch tips come
// from a RepoRefs loaded once per repo, ancestry from an injected runner. These
// drive each branch through the precedence ladder
// (merged > pushed > committed > needsReview > clean) over a small fake graph.
final class OutcomeWatcherTests: XCTestCase {

    // A tiny linear graph: base ← b1 ← b2. `ancestors[x]` is the set of shas
    // reachable from x (x included), so merge-base(a, b) = a when a ∈ ancestors[b].
    private func stubGit(ancestors: [String: Set<String>]) -> ([String]) -> String? {
        { args in
            guard args.first == "merge-base" else { return nil }
            // ["merge-base", <a>, <b>] → the one that's an ancestor of the other
            let a = args[1], b = args[2]
            if ancestors[b]?.contains(a) == true { return a }
            if ancestors[a]?.contains(b) == true { return b }
            return nil
        }
    }

    private func refs(_ shaByRef: [String: String]) -> OutcomeWatcher.RepoRefs {
        OutcomeWatcher.RepoRefs(shaByRef: shaByRef)
    }

    func test_merged_branchTipReachableFromBase() {
        // base is at b2, branch tip b1 → b1 is an ancestor of base → merged.
        let git = stubGit(ancestors: ["b2": ["base", "b1", "b2"], "b1": ["base", "b1"]])
        let repo = refs(["origin/main": "b2", "ENG-1/x": "b1"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .merged)
    }

    func test_pushed_remoteHasAllLocalCommits() {
        // Not in base; remote branch tip == local tip → pushed.
        let git = stubGit(ancestors: ["base": ["base"], "b2": ["base", "b1", "b2"]])
        let repo = refs(["origin/main": "base", "ENG-1/x": "b2", "origin/ENG-1/x": "b2"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "b2",
                                             filesChangedAtStop: 0, git: git), .pushed)
    }

    func test_committed_localAheadOfRemote() {
        // Remote at b1, local at b2 (ahead) → committed (unpushed commits).
        let git = stubGit(ancestors: ["base": ["base"], "b1": ["base", "b1"], "b2": ["base", "b1", "b2"]])
        let repo = refs(["origin/main": "base", "ENG-1/x": "b2", "origin/ENG-1/x": "b1"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "b2",
                                             filesChangedAtStop: 0, git: git), .committed)
    }

    func test_committed_noRemoteButCommitsBeyondBase() {
        // No remote branch; branch has commits on top of base → committed.
        let git = stubGit(ancestors: ["base": ["base"], "b1": ["base", "b1"]])
        let repo = refs(["origin/main": "base", "ENG-1/x": "b1"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .committed)
    }

    func test_needsReview_uncommittedWorkNoCommitsSinceStop() {
        // Branch tip == base (no new commits), no remote, dirty work at Stop.
        let git = stubGit(ancestors: ["base": ["base"]])
        let repo = refs(["origin/main": "base", "ENG-1/x": "base"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "base",
                                             filesChangedAtStop: 7, git: git), .needsReview)
    }

    func test_clean_noPendingWorkOnBase() {
        let git = stubGit(ancestors: ["base": ["base"]])
        let repo = refs(["origin/main": "base", "ENG-1/x": "base"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "base",
                                             filesChangedAtStop: 0, git: git), .clean)
    }

    func test_deletedBranch_mergedIfHeadInBase() {
        // Branch ref gone; recorded head is an ancestor of base → merged.
        let git = stubGit(ancestors: ["b2": ["base", "b1", "b2"]])
        let repo = refs(["origin/main": "b2"])
        XCTAssertEqual(OutcomeWatcher.derive(branch: "ENG-1/x", refs: repo, headCommit: "b1",
                                             filesChangedAtStop: 0, git: git), .merged)
    }

    func test_nilBranch_isClean() {
        XCTAssertEqual(OutcomeWatcher.derive(branch: nil, refs: refs([:]), headCommit: nil,
                                             filesChangedAtStop: 5) { _ in nil }, .clean)
    }

    // MARK: - RepoRefs (bulk ref loading)

    private func showRefGit(_ output: String) -> ([String]) -> String? {
        { args in args.first == "show-ref" ? output : nil }
    }

    func test_loadRefs_parsesHeadsAndRemotes() {
        let repo = OutcomeWatcher.loadRefs(git: showRefGit("""
        aaa refs/heads/main
        bbb refs/heads/ENG-1/x
        aaa refs/remotes/origin/main
        ccc refs/remotes/origin/ENG-1/x
        ddd refs/remotes/upstream/main
        """))
        XCTAssertEqual(repo.tip("main"), "aaa")
        XCTAssertEqual(repo.tip("ENG-1/x"), "bbb")
        XCTAssertEqual(repo.remoteTip("ENG-1/x"), "ccc")
        XCTAssertEqual(repo.shaByRef["upstream/main"], "ddd")
        XCTAssertNil(repo.remoteTip("nope"))
        // tip() is a plain ref lookup, mirroring the `rev-parse <ref>` it replaced,
        // so a remote ref resolves through it too (as it does in real git). The
        // ladder simply never asks for one that way; it goes via remoteTip.
        XCTAssertEqual(repo.tip("origin/ENG-1/x"), "ccc")
        XCTAssertNil(repo.remoteTip("origin/ENG-1/x"))
    }

    // A detached session records its branch as literally "HEAD", so HEAD has to be
    // in the map or those rows would read as deleted branches and change status.
    func test_loadRefs_includesHEAD() {
        let repo = OutcomeWatcher.loadRefs(git: showRefGit("""
        detached refs/heads/main
        zzz HEAD
        """))
        XCTAssertEqual(repo.tip("HEAD"), "zzz")
    }

    // Refs the ladder never consults must not enter the map, so a tag can't
    // shadow a branch of the same name.
    func test_loadRefs_ignoresTagsAndOtherRemotes() {
        let repo = OutcomeWatcher.loadRefs(git: showRefGit("""
        aaa refs/heads/release
        bbb refs/tags/release
        ccc refs/remotes/fork/release
        ddd refs/notes/commits
        """))
        XCTAssertEqual(repo.tip("release"), "aaa")
        XCTAssertEqual(repo.shaByRef.count, 1)
    }

    // Branch names contain slashes, and the sha/ref split must stop at the first
    // space or a name would be truncated.
    func test_loadRefs_branchNameWithSlashesIsNotTruncated() {
        let repo = OutcomeWatcher.loadRefs(git: showRefGit("ddd refs/heads/feat/a/b/c"))
        XCTAssertEqual(repo.tip("feat/a/b/c"), "ddd")
    }

    func test_loadRefs_skipsMalformedLines() {
        let repo = OutcomeWatcher.loadRefs(git: showRefGit("""
        onlyonefield

        aaa refs/heads/good
        bbb refs/heads/
        """))
        XCTAssertEqual(repo.tip("good"), "aaa")
        XCTAssertEqual(repo.shaByRef.count, 1)
    }

    func test_loadRefs_noGitOutput_isEmptyWithNoBase() {
        let repo = OutcomeWatcher.loadRefs { _ in nil }
        XCTAssertNil(repo.baseSha)
        XCTAssertNil(repo.tip("main"))
    }

    // Base precedence: local default first, then the fork's, then upstream's.
    func test_baseSha_prefersLocalDefaultThenOriginThenUpstream() {
        XCTAssertEqual(refs(["main": "a", "origin/main": "b", "upstream/main": "c"]).baseSha, "a")
        XCTAssertEqual(refs(["origin/main": "b", "upstream/main": "c"]).baseSha, "b")
        XCTAssertEqual(refs(["upstream/main": "c"]).baseSha, "c")
        XCTAssertEqual(refs(["master": "m", "origin/main": "b"]).baseSha, "m")
        XCTAssertNil(refs(["ENG-1/x": "z"]).baseSha)
    }

    // The spawning path (used once per Stop) and the preloaded path must agree on
    // which ref is the base, or a handoff's ticket and its chip could disagree.
    func test_resolveBaseSha_matchesRepoRefs() {
        let shaByRef = ["master": "m", "origin/main": "b", "upstream/master": "u"]
        let spawning = OutcomeWatcher.resolveBaseSha { args in
            args.first == "rev-parse" ? args.last.flatMap { shaByRef[$0] } : nil
        }
        XCTAssertEqual(spawning, refs(shaByRef).baseSha)
    }

    // Equal local and remote tips prove the branch is pushed, so the ladder must
    // answer without asking git anything.
    func test_pushed_equalTips_asksGitNothing() {
        var calls: [[String]] = []
        let repo = refs(["origin/main": "base", "ENG-1/x": "b2", "origin/ENG-1/x": "b2"])
        let actual = OutcomeWatcher.derive(
            branch: "ENG-1/x", refs: repo, headCommit: "b2", filesChangedAtStop: 0
        ) { args in
            calls.append(args)
            // Answer the merged check truthfully (b2 is not in base).
            return args.first == "merge-base" ? "base" : nil
        }
        XCTAssertEqual(actual, .pushed)
        // Only the merged check ran; no second merge-base for the push comparison.
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Cache inputs

    // The cache is only sound if these capture everything the ladder reads.
    func test_inputs_captureEveryValueTheLadderReads() {
        let repo = refs(["main": "base", "ENG-1/x": "tip", "origin/ENG-1/x": "remote"])
        let actual = OutcomeWatcher.inputs(branch: "ENG-1/x", refs: repo,
                                           headCommit: "head", filesChangedAtStop: 3)
        XCTAssertEqual(actual, OutcomeInputs(branchTip: "tip", remoteTip: "remote",
                                             baseSha: "base", headCommit: "head",
                                             filesChanged: 3))
    }

    func test_inputs_differWhenAnyGitValueMoves() {
        let base = refs(["main": "base", "ENG-1/x": "tip", "origin/ENG-1/x": "remote"])
        let reference = OutcomeWatcher.inputs(branch: "ENG-1/x", refs: base,
                                              headCommit: "head", filesChangedAtStop: 3)
        // A commit (tip moves), a push (remote moves), a pull (base moves), a new
        // Stop (head or dirty count changes) must each invalidate.
        let moved = [
            OutcomeWatcher.inputs(branch: "ENG-1/x",
                                  refs: refs(["main": "base", "ENG-1/x": "tip2", "origin/ENG-1/x": "remote"]),
                                  headCommit: "head", filesChangedAtStop: 3),
            OutcomeWatcher.inputs(branch: "ENG-1/x",
                                  refs: refs(["main": "base", "ENG-1/x": "tip", "origin/ENG-1/x": "remote2"]),
                                  headCommit: "head", filesChangedAtStop: 3),
            OutcomeWatcher.inputs(branch: "ENG-1/x",
                                  refs: refs(["main": "base2", "ENG-1/x": "tip", "origin/ENG-1/x": "remote"]),
                                  headCommit: "head", filesChangedAtStop: 3),
            OutcomeWatcher.inputs(branch: "ENG-1/x", refs: base,
                                  headCommit: "head2", filesChangedAtStop: 3),
            OutcomeWatcher.inputs(branch: "ENG-1/x", refs: base,
                                  headCommit: "head", filesChangedAtStop: 0),
        ]
        for candidate in moved { XCTAssertNotEqual(candidate, reference) }
        // A branch deleted since the last pass drops its tip, so it invalidates too.
        XCTAssertNotEqual(OutcomeWatcher.inputs(branch: "ENG-1/x", refs: refs(["main": "base"]),
                                                headCommit: "head", filesChangedAtStop: 3),
                          reference)
    }
}
