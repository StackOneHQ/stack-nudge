import Foundation

// One persisted record per agent *session* (not per turn). Created/updated on
// each Stop so it carries the session's latest usage; keyed by the agent's
// session id so repeated Stops upsert rather than pile up. The token + ticket
// fields are the basis for the per-ticket usage rollup; risk/outcome/PR fields
// are added by later iterations (RiskClassifier, OutcomeWatcher).
struct HandoffRecord: Codable, Identifiable, Equatable {
    let id: String              // agent session id — the upsert key
    let agent: String           // canonical agent: "claude" | "codex" | "agy"
    var repoRoot: String?
    var branch: String?
    var ticket: String?         // Linear/Jira key (e.g. "ENG-12142"); nil if none
    var model: String?
    var contextTokens: Int?     // latest context-window tokens for the session
    // Uncommitted working-tree diff at the latest Stop (vs HEAD, + untracked).
    // Optional so records written before this field decode cleanly.
    var headCommit: String?
    var filesChanged: Int?
    var insertions: Int?
    var deletions: Int?
    let createdAt: Date
    var updatedAt: Date
}
