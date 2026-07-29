import Foundation

// One persisted record per agent *session* (not per turn). Created/updated on
// each Stop so it carries the session's latest usage; keyed by the agent's
// session id so repeated Stops upsert rather than pile up. The token + ticket
// fields are the basis for the per-ticket usage rollup; risk/outcome/PR fields
// are added by later iterations (RiskClassifier, OutcomeWatcher).
struct HandoffRecord: Codable, Identifiable, Equatable {
    let id: String              // upsert key "<session id>\n<branch>" (per session+branch)
    let agent: String           // canonical agent: "claude" | "codex" | "agy"
    var repoRoot: String?
    var branch: String?
    var ticket: String?         // Linear/Jira key (e.g. "ENG-12142"); nil if none
    var model: String?
    // Cumulative context-window tokens for the session — summed growth across
    // compaction cycles (see ContextTokens.fold), not just the latest reading,
    // so a compacted session still reflects its real effort.
    var contextTokens: Int?
    // Last raw context-occupancy reading, kept only to fold the next one. Defaults
    // nil so records written before cumulative tracking decode cleanly (→ re-seeded)
    // and existing constructions don't need to supply this bookkeeping field.
    var lastContextReading: Int? = nil
    // Uncommitted working-tree diff at the latest Stop (vs HEAD, + untracked).
    // Optional so records written before this field decode cleanly.
    var headCommit: String?
    var filesChanged: Int?
    var insertions: Int?
    var deletions: Int?
    let createdAt: Date
    var updatedAt: Date
}

// Why a Stop event produced no record. Every case is a legitimate skip *or* a
// broken install, and the two look identical from the Tickets tab, so the reason
// is counted and surfaced there rather than dropped on the floor.
enum HandoffDropReason: String, Equatable {
    // The hook payload carried no session id. Means the installed notify.sh
    // predates the field (see Bootstrap.refreshNotifyScriptIfNeeded) or couldn't
    // parse the hook JSON. Nothing can be recorded without it.
    case missingSessionID
    // No cwd in the payload, so there's no repo to attribute the work to.
    case missingProjectPath
    // Agent ran outside a git repo. Expected, not a fault: there's no branch or
    // ticket to roll up.
    case notAGitRepo

    // Shown in the Tickets empty state, in reason-priority order.
    var summary: String {
        switch self {
        case .missingSessionID:
            return "the hook payload had no session id"
        case .missingProjectPath:
            return "the hook payload had no working directory"
        case .notAGitRepo:
            return "the agent wasn't running inside a git repo"
        }
    }

    // The user-actionable next step, or nil when the drop is expected. Both
    // payload gaps point at the same culprit: a hook script the app couldn't
    // bring up to date.
    var remedy: String? {
        switch self {
        case .missingSessionID, .missingProjectPath:
            return "Reinstall from Settings to refresh ~/.stack-nudge/notify.sh."
        case .notAGitRepo:
            return nil
        }
    }
}
