import Foundation

// Resolves a tmux-hosted agent to the values AppActivator needs to focus its
// pane. tmux severs the process tree from the host terminal — the agent runs
// under the tmux server (parented to launchd), so none of the usual terminal
// enrichment reaches iTerm2/Terminal. Instead we read the agent process's live
// environment (TMUX socket, TMUX_PANE, LC_TERMINAL) at focus time. Reading it
// live rather than storing it keeps custom sockets and the host terminal
// current, and a dead pid simply yields nil (focus becomes a no-op).
enum TmuxFocus {

    struct Target: Equatable {
        let pane: String          // TMUX_PANE, e.g. "%4"
        let socket: String?       // tmux server socket path; nil → default socket
        let hostBundleID: String? // app to raise; nil → rely on -CC tab surfacing
    }

    // iTerm2 and Terminal.app propagate LC_TERMINAL through tmux/ssh. Only map
    // the hosts we can actually raise; anything else leaves hostBundleID nil,
    // so focus still selects the pane and (under iTerm2 `-CC`) the mapped tab
    // still surfaces.
    static func hostBundleID(forLCTerminal lcTerminal: String?) -> String? {
        switch lcTerminal {
        case "iTerm2":         return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        default:               return nil
        }
    }

    // Live resolve: read the agent pid's environment and pull the tmux identity.
    static func target(agentPID: Int) -> Target? {
        let raw = ProcessOutput.read(
            "/bin/ps", ["eww", "-o", "pid=,command=", "-p", String(agentPID)])
        return parse(psOutput: raw, pid: agentPID)
    }

    // Pure: given `ps eww` output and the pid, extract the tmux target. Returns
    // nil when the process isn't inside tmux (no TMUX_PANE). Reuses the generic
    // env-var parser so the extraction rules stay in one place.
    static func parse(psOutput raw: String, pid: Int) -> Target? {
        let panes = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX_PANE")
        guard let pane = panes[pid], !pane.isEmpty else { return nil }
        // TMUX is "<socket>,<serverPID>,<sessionN>" — the socket is the part
        // before the first comma; tmux -S wants just that path.
        let socket = EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "TMUX")[pid]
            .flatMap { $0.split(separator: ",").first.map(String.init) }
        let host = hostBundleID(forLCTerminal:
            EnvVarTerminalIntegration.parseEnvValues(raw, envVar: "LC_TERMINAL")[pid])
        return Target(pane: pane, socket: socket, hostBundleID: host)
    }
}
