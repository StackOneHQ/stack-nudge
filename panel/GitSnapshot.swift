import Foundation

// The uncommitted working-tree state of a repo at the moment an agent stopped:
// what's changed vs HEAD but not yet committed. This is the MVP baseline for
// outcome tracking — it answers "what did this session leave behind to review?".
// Work the agent already committed shows as clean here (filesChanged == 0); the
// later OutcomeWatcher is what detects committed/pushed/merged from headCommit.
struct GitSnapshot: Equatable {
    let headCommit: String?
    let filesChanged: Int   // tracked changes vs HEAD + untracked files
    let insertions: Int
    let deletions: Int

    var isDirty: Bool { filesChanged > 0 }

    // Build a snapshot for `cwd`, running git through the injected closure
    // (`git(cwd, args) -> stdout?`, nil on failure / non-repo). Injecting the
    // runner keeps this testable without shelling out. Returns nil when the
    // directory has no HEAD (not a repo, or a repo with no commits yet).
    static func capture(cwd: String, git: (String, [String]) -> String?) -> GitSnapshot? {
        guard let head = git(cwd, ["rev-parse", "HEAD"]) else { return nil }
        let numstat = git(cwd, ["diff", "--numstat", "HEAD"]) ?? ""
        let tracked = parseNumstat(numstat)
        let untracked = git(cwd, ["ls-files", "--others", "--exclude-standard"]) ?? ""
        let untrackedCount = untracked.split(separator: "\n").filter { !$0.isEmpty }.count
        return GitSnapshot(
            headCommit: head,
            filesChanged: tracked.files + untrackedCount,
            insertions: tracked.insertions,
            deletions: tracked.deletions)
    }

    // Parse `git diff --numstat` output: one tab-separated `<ins>\t<del>\t<path>`
    // line per changed file. Binary files report "-" for both counts, which we
    // count as a changed file with zero line deltas.
    static func parseNumstat(_ output: String) -> (files: Int, insertions: Int, deletions: Int) {
        var files = 0, insertions = 0, deletions = 0
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3 else { continue }
            files += 1
            insertions += Int(columns[0]) ?? 0
            deletions += Int(columns[1]) ?? 0
        }
        return (files, insertions, deletions)
    }
}
