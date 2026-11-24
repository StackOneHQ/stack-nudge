import Foundation

// One agent session as stack-nudge describes it to anything outside the panel:
// service extensions behind `event:session`, and the MCP server once it reads
// this too. Built from SessionStore's poll and the prompts waiting in Events,
// so both get the same shape and agree on what "waiting" means.
//
// What it leaves out is deliberate: no paths, no prompt or tool text, no
// terminal or tab identifiers. The repo's name and the name a person chose for
// the session are enough to show it; the pid and Claude's session id are there
// so a caller seen elsewhere (an MCP bridge, a hook) can be matched to it.
struct SessionSnapshot: Equatable {
    enum State: String {
        case busy, idle
        // A permission prompt from it is waiting on you.
        case waiting
        // Running, but the agent reports no live state, so busy or idle would
        // be a guess.
        case active
        case ended
    }

    // Stable for the process's life. A pid alone is reused; with the agent it
    // can't name a different kind of session.
    let handle: String
    let pid: Int
    let agent: String
    let repo: String?
    // Only a name someone chose, never one derived from the directory.
    let name: String?
    let claudeSessionID: String?
    let state: State

    static func list(sessions: [Session], events: [NudgeEvent],
                     isBlocking: (NudgeEvent) -> Bool = { $0.isStillBlocking }) -> [SessionSnapshot] {
        let prompts = events.filter { !$0.isFeed && $0.kind == .permission && isBlocking($0) }
        return sessions.map { session in
            let waiting = prompts.contains { prompt in
                prompt.agentPID == session.pid
                    || (prompt.claudeSessionID != nil && prompt.claudeSessionID == session.claudeSessionID)
            }
            return SessionSnapshot(handle: "\(session.agent)-\(session.pid)", pid: session.pid,
                                   agent: session.agent, repo: session.projectName,
                                   name: SessionLabel.chosenName(for: session),
                                   claudeSessionID: session.claudeSessionID,
                                   state: state(of: session, waiting: waiting))
        }
    }

    private static func state(of session: Session, waiting: Bool) -> State {
        if case .finished = session.status { return .ended }
        if waiting { return .waiting }
        switch session.liveStatus {
        case "busy"?: return .busy
        case "idle"?: return .idle
        default:      return .active
        }
    }

    // What to tell a listener who heard `old`: each session that's new or
    // changed, then an `ended` for each one that's gone without saying so.
    static func changes(from old: [SessionSnapshot], to new: [SessionSnapshot]) -> [SessionSnapshot] {
        let before = Dictionary(old.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(new.map(\.handle))
        let changed = new.filter { before[$0.handle] != $0 }
        let gone = old.filter { !now.contains($0.handle) && $0.state != .ended }.map { $0.with(state: .ended) }
        return changed + gone
    }

    func with(state: State) -> SessionSnapshot {
        SessionSnapshot(handle: handle, pid: pid, agent: agent, repo: repo, name: name,
                        claudeSessionID: claudeSessionID, state: state)
    }

    // The `event:session` line's fields. Every event carries the whole
    // session, so a listener keeps a map by `session` and never has to have
    // seen the one before.
    var fields: [String: ServiceProtocol.Value] {
        var fields: [String: ServiceProtocol.Value] = [
            "session": .string(handle), "pid": .int(pid), "agent": .string(agent),
            "state": .string(state.rawValue),
        ]
        if let repo { fields["repo"] = .string(repo) }
        if let name { fields["title"] = .string(name) }
        if let claudeSessionID { fields["claude_session"] = .string(claudeSessionID) }
        return fields
    }
}
