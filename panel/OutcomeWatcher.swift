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

// Derives the outcome from *current* git state, read through an injected runner
// (`git(args) -> stdout?`, bound to the repo by the caller; nil on failure).
// Ref-based only — never checks out — so it's safe for any historical branch and
// fully unit-testable with a stub. Precedence: merged > pushed > committed >
// needsReview > clean.
enum OutcomeWatcher {

    // Local default branch first — it's the one the user keeps pulled, and in a
    // fork workflow `origin/main` (the fork) can lag the real mainline. Falls
    // back to the fork's, then the upstream's, default branch.
    private static let baseCandidates = [
        "main", "master",
        "origin/main", "origin/master",
        "upstream/main", "upstream/master",
    ]

    static func derive(branch: String?,
                       headCommit: String?,
                       filesChangedAtStop: Int,
                       git: ([String]) -> String?) -> OutcomeStatus {
        guard let branch, !branch.isEmpty else { return .clean }

        // Branch ref is gone (deleted): shipped if the recorded head merged into
        // the base, otherwise we can't tell — treat as clean.
        guard let branchTip = revParse(branch, git) else {
            if let head = headCommit, let base = resolveBaseSha(git), isAncestor(head, base, git) {
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
        if let base = resolveBaseSha(git), branchTip != base, isAncestor(branchTip, base, git) {
            return .merged
        }
        if let remoteTip = revParse("origin/\(branch)", git) {
            return isAncestor(branchTip, remoteTip, git) ? .pushed : .committed
        }
        if let base = resolveBaseSha(git), base != branchTip, isAncestor(base, branchTip, git) {
            return .committed   // commits beyond base, no remote branch
        }
        return pendingOrClean(branchTip: branchTip, headCommit: headCommit, filesChangedAtStop: filesChangedAtStop)
    }

    private static func pendingOrClean(branchTip: String, headCommit: String?, filesChangedAtStop: Int) -> OutcomeStatus {
        (filesChangedAtStop > 0 && branchTip == headCommit) ? .needsReview : .clean
    }

    // Resolve the base branch's sha (local default first; see baseCandidates).
    // Shared with handoff capture, which uses it to read only branch-local
    // commits when deriving the ticket.
    static func resolveBaseSha(_ git: ([String]) -> String?) -> String? {
        for candidate in baseCandidates {
            if let sha = revParse(candidate, git) { return sha }
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
