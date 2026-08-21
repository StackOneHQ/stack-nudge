import Foundation

// Enriches tmux-hosted sessions with a per-pane tabId. A bare TMUX_PANE ("%4")
// is unique only within a single tmux server; a user running multiple servers
// (separate sockets) can have the same %N in each, which would collide the
// per-tab renames/colours keyed on tabId and the event↔session fallback match.
// Compose the server id (the pid in TMUX="<socket>,<serverPID>,<n>") with the
// pane so the id is unique across servers. notify.sh builds the same
// "<serverPID>:<pane>" for event payloads so the two paths agree.
final class TmuxIntegration: TerminalIntegration {

    static let shared = TmuxIntegration()

    let name = "tmux"

    func enrich(_ sessions: [Session]) -> [Session] {
        let pids = sessions.filter { $0.terminalApp == "tmux" }.map(\.pid)
        guard !pids.isEmpty else { return sessions }

        // One `ps eww` for both vars — TMUX_PANE (the pane) and TMUX (carries
        // the server id). Reuses the generic env-var parser.
        let raw = ProcessOutput.read(
            "/bin/ps",
            ["eww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        let panes = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX_PANE")
        let tmuxes = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX")
        guard !panes.isEmpty else { return sessions }

        return sessions.map { session in
            guard session.terminalApp == "tmux", let pane = panes[session.pid] else { return session }
            var copy = session
            copy.tabId = Self.tabId(pane: pane, tmux: tmuxes[session.pid])
            return copy
        }
    }

    // "<serverPID>:<pane>" — serverPID is the second comma-field of TMUX
    // ("<socket>,<serverPID>,<n>"). Falls back to the bare pane when TMUX is
    // absent or malformed. Must stay in sync with notify.sh's session-id build.
    static func tabId(pane: String, tmux: String?) -> String {
        guard let server = tmux?.split(separator: ",").dropFirst().first.map(String.init),
              !server.isEmpty
        else { return pane }
        return "\(server):\(pane)"
    }
}
