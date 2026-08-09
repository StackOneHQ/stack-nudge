import Foundation

// "Did it ship?" for a session's branch. Ordered most-shipped first so a single
// value summarises the branch; the UI maps these to labels/colours.
enum OutcomeStatus: String, Equatable {
    case merged       // branch is fully contained in the base (origin/main, main, …)
    case pushed       // remote branch has all local commits (pushed, not yet merged)
    case committed    // local commits beyond base, not pushed
    case needsReview  // uncommitted work left at Stop, no commits since
    case clean        // nothing pending (on base / no net change / can't determine)
}

// Every value OutcomeWatcher.derive reads for one branch. Ancestry between two
// fixed shas cannot change (rewriting a commit gives it a new sha), so identical
// inputs guarantee an identical status; that makes this a sound cache key and
// lets a repeat refresh skip the merge-base spawns entirely. Build it with
// `OutcomeWatcher.inputs(...)` so a new input can't be added to the ladder
// without being added here.
struct OutcomeInputs: Equatable {
    let branchTip: String?
    let remoteTip: String?
    let baseSha: String?
    let headCommit: String?
    let filesChanged: Int
}

// Derives the outcome from *current* git state, read through an injected runner
// (`git(args) -> stdout?`, bound to the repo by the caller; nil on failure).
// Ref-based only — never checks out — so it's safe for any historical branch and
// fully unit-testable with a stub. Precedence: merged > pushed > committed >
// needsReview > clean.
enum OutcomeWatcher {

    // The user-facing "did it ship?" status: a known PR state supersedes the
    // local git heuristic, because a squash-merged branch only reads as `.merged`
    // through its PR (its commits never land on the base by ancestry). Open means
    // at least pushed; closed-not-merged falls back to the local truth. This is
    // the single definition the Tickets tab (OutcomesView) and the Insights
    // rollup both read, so the two cannot drift.
    static func effective(local: OutcomeStatus?, pr: PullRequestInfo?) -> OutcomeStatus? {
        guard let pr else { return local }
        switch pr.state {
        case .merged: return .merged
        case .open:   return .pushed
        case .closed: return local
        }
    }

    // Local default branch first — it's the one the user keeps pulled, and in a
    // fork workflow `origin/main` (the fork) can lag the real mainline. Falls
    // back to the fork's, then the upstream's, default branch.
    private static let baseCandidates = [
        "main", "master",
        "origin/main", "origin/master",
        "upstream/main", "upstream/master",
    ]

    // Every ref one repo's branches need, read in a single spawn. `derive` used to
    // resolve these itself: two `rev-parse`s per branch (the branch and its
    // origin counterpart) plus a walk of baseCandidates per branch, which on a
    // 90-day ledger meant ~6 subprocesses per branch and over 1,500 per refresh.
    // Resolving the whole repo once turns all of that into one `show-ref`.
    struct RepoRefs: Equatable {
        // Short ref name to sha, across heads and the origin / upstream remotes.
        // Keyed exactly as the old `rev-parse --verify <ref>` was called, so a
        // lookup here is a drop-in for that spawn.
        let shaByRef: [String: String]
        let baseSha: String?

        func tip(_ branch: String) -> String? { shaByRef[branch] }
        func remoteTip(_ branch: String) -> String? { shaByRef["origin/\(branch)"] }

        init(shaByRef: [String: String]) {
            self.shaByRef = shaByRef
            self.baseSha = OutcomeWatcher.baseSha { shaByRef[$0] }
        }
    }

    // `show-ref --head` rather than `for-each-ref`, because it is the one that
    // also reports HEAD: a session run detached records its branch as literally
    // "HEAD" (that's what `rev-parse --abbrev-ref HEAD` gives), and for-each-ref
    // only matches patterns under refs/, so those rows would look like deleted
    // branches and change status. Output is `<sha> <full ref>`; shortening is done
    // here so only the namespaces the ladder names can enter the map, which keeps
    // a tag from shadowing a same-named branch.
    static func loadRefs(git: ([String]) -> String?) -> RepoRefs {
        let output = git(["show-ref", "--head"]) ?? ""
        var shaByRef: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let sha = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, let short = shortRef(ref) else { continue }
            shaByRef[short] = sha
        }
        return RepoRefs(shaByRef: shaByRef)
    }

    // Full ref to the name the ladder and baseCandidates use, or nil for refs we
    // never consult (tags, notes, other remotes).
    private static func shortRef(_ ref: String) -> String? {
        if ref == "HEAD" { return ref }
        for (prefix, keep) in [("refs/heads/", ""),
                               ("refs/remotes/origin/", "origin/"),
                               ("refs/remotes/upstream/", "upstream/")]
        where ref.hasPrefix(prefix) {
            let name = String(ref.dropFirst(prefix.count))
            return name.isEmpty ? nil : keep + name
        }
        return nil
    }

    // The inputs `derive` will read for this branch, for cache comparison.
    static func inputs(branch: String?,
                       refs: RepoRefs,
                       headCommit: String?,
                       filesChangedAtStop: Int) -> OutcomeInputs {
        OutcomeInputs(
            branchTip: branch.flatMap(refs.tip),
            remoteTip: branch.flatMap(refs.remoteTip),
            baseSha: refs.baseSha,
            headCommit: headCommit,
            filesChanged: filesChangedAtStop)
    }

    static func derive(branch: String?,
                       refs: RepoRefs,
                       headCommit: String?,
                       filesChangedAtStop: Int,
                       git: ([String]) -> String?) -> OutcomeStatus {
        guard let branch, !branch.isEmpty else { return .clean }

        // Branch ref is gone (deleted): shipped if the recorded head merged into
        // the base, otherwise we can't tell — treat as clean.
        guard let branchTip = refs.tip(branch) else {
            if let head = headCommit, let base = refs.baseSha, isAncestor(head, base, git) {
                return .merged
            }
            return .clean
        }

        // A session run directly on the base branch isn't a feature branch, so
        // the merged/committed ladder doesn't apply.
        if branch == "main" || branch == "master" {
            return pendingOrClean(branchTip: branchTip, headCommit: headCommit, filesChangedAtStop: filesChangedAtStop)
        }

        // Merged: the branch's tip is contained in the base *and* differs from
        // it. The `!= base` guard stops a branch sitting exactly at base (no
        // commits of its own) from reading as merged — it's clean/pending.
        if let base = refs.baseSha, branchTip != base, isAncestor(branchTip, base, git) {
            return .merged
        }
        if let remoteTip = refs.remoteTip(branch) {
            // Equal shas already prove every local commit is on the remote; only
            // a divergence needs git to settle which side is ahead.
            if remoteTip == branchTip { return .pushed }
            return isAncestor(branchTip, remoteTip, git) ? .pushed : .committed
        }
        if let base = refs.baseSha, base != branchTip, isAncestor(base, branchTip, git) {
            return .committed   // commits beyond base, no remote branch
        }
        return pendingOrClean(branchTip: branchTip, headCommit: headCommit, filesChangedAtStop: filesChangedAtStop)
    }

    private static func pendingOrClean(branchTip: String, headCommit: String?, filesChangedAtStop: Int) -> OutcomeStatus {
        (filesChangedAtStop > 0 && branchTip == headCommit) ? .needsReview : .clean
    }

    // Resolve the base branch's sha (local default first; see baseCandidates).
    // Shared with handoff capture, which uses it to read only branch-local
    // commits when deriving the ticket. One spawn per candidate tried, so it's
    // for the once-per-Stop path; RepoRefs resolves the same ladder off its
    // already-loaded map.
    static func resolveBaseSha(_ git: ([String]) -> String?) -> String? {
        baseSha { revParse($0, git) }
    }

    // The baseCandidates ladder over any ref-to-sha lookup, so the spawning and
    // preloaded paths can't drift on which ref counts as the base.
    static func baseSha(lookup: (String) -> String?) -> String? {
        for candidate in baseCandidates {
            if let sha = lookup(candidate) { return sha }
        }
        return nil
    }

    private static func revParse(_ ref: String, _ git: ([String]) -> String?) -> String? {
        let output = git(["rev-parse", "--verify", "--quiet", ref])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else { return nil }
        return output
    }

    // `a` is an ancestor of `b` ⟺ merge-base(a, b) == a. Both must be resolved
    // shas (callers pass rev-parse output) so the equality check is meaningful.
    private static func isAncestor(_ a: String, _ b: String, _ git: ([String]) -> String?) -> Bool {
        let mergeBase = git(["merge-base", a, b])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return mergeBase == a
    }
}
