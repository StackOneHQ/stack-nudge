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

    // Only iTerm2 gives a usable host signal through tmux: it sets
    // LC_TERMINAL=iTerm2, which survives tmux/ssh. Terminal.app sets
    // TERM_PROGRAM=Apple_Terminal — which tmux overwrites with "tmux" — and does
    // not propagate LC_TERMINAL, and it has no tmux `-CC` integration anyway, so
    // there is no reliable way to identify or raise it from here. nil host means
    // focus still selects the pane; only the app-raise/tab-surfacing is skipped.
    static func hostBundleID(forLCTerminal lcTerminal: String?) -> String? {
        lcTerminal == "iTerm2" ? "com.googlecode.iterm2" : nil
    }

    // Live resolve: read the agent pid's environment and pull the tmux identity.
    // Runs on a background queue (callers dispatch), with a timeout so a hung
    // `ps` can't wedge the focus path.
    static func target(agentPID: Int) -> Target? {
        guard let raw = ProcessOutput.read(
            "/bin/ps", ["eww", "-o", "pid=,command=", "-p", String(agentPID)],
            timeout: 3) else { return nil }
        let resolved = parse(psOutput: raw, pid: agentPID)
        debug("target(pid=\(agentPID)) -> " + (resolved.map {
            "pane=\($0.pane) socket=\($0.socket ?? "default") host=\($0.hostBundleID ?? "nil")"
        } ?? "nil (no TMUX_PANE in that pid's env)"))
        return resolved
    }

    // Gated on STACKNUDGE_PANEL_DEBUG (same switch AppActivator uses). Off by
    // default; surfaces what the running app resolved for a focus attempt.
    static func debug(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["STACKNUDGE_PANEL_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("TmuxFocus: \(message())\n".utf8))
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
