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

    // Live resolve: read the agent pid's environment and pull the tmux identity,
    // walking up the ancestry until a process carries TMUX_PANE. The agent often
    // runs in a shell that didn't inherit it — pi, and anything launched from a
    // nested Claude Code tool shell, sees no TMUX_PANE even though an ancestor in
    // the same pane still does. Every ancestor up to the tmux server belongs to
    // the same pane, so the first one carrying TMUX_PANE names the right pane.
    // Bounded so an unexpected/detached tree can't loop. Runs on a background
    // queue (callers dispatch); each `ps` has a timeout so a hang can't wedge us.
    static func target(agentPID: Int) -> Target? {
        // Sidecar first: agents whose env `ps` can't read (pi renames its process
        // title, clobbering the argv+env region) write their tmux pane to a
        // per-pid sidecar from inside the process. When present it's authoritative
        // and needs no `ps` at all. claude et al. have no sidecar and fall through.
        if let resolved = sidecarTarget(pid: agentPID) {
            debug("target(pid=\(agentPID)) -> pane=\(resolved.pane) via sidecar "
                + "socket=\(resolved.socket ?? "default") host=\(resolved.hostBundleID ?? "nil")")
            return resolved
        }

        var pid = agentPID
        var depth = 0
        while pid > 1 && depth < 10 {
            if let resolved = resolveOne(pid: pid) {
                debug("target(pid=\(agentPID)) -> pane=\(resolved.pane) via pid=\(pid) "
                    + "socket=\(resolved.socket ?? "default") host=\(resolved.hostBundleID ?? "nil")")
                return resolved
            }
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
            depth += 1
        }
        debug("target(pid=\(agentPID)) -> nil (no sidecar, no TMUX_PANE up the ancestry)")
        return nil
    }

    // Read a per-pid tmux sidecar (~/.stack-nudge/pi-sessions/<pid>.json), written
    // by an in-process extension for agents whose env `ps` can't read. Shape:
    // {"pane":"%39","socket":"/private/tmp/tmux-502/default","lcTerminal":"iTerm2"}.
    // `dir` is injectable for tests; production uses the install location.
    static func sidecarTarget(pid: Int,
                              dir: String = "\(NSHomeDirectory())/.stack-nudge/pi-sessions") -> Target? {
        let path = "\(dir)/\(pid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pane = obj["pane"] as? String, !pane.isEmpty
        else { return nil }
        let socket = (obj["socket"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Target(pane: pane,
                      socket: socket,
                      hostBundleID: hostBundleID(forLCTerminal: obj["lcTerminal"] as? String))
    }

    // Read one pid's environment and parse the tmux identity out of it.
    private static func resolveOne(pid: Int) -> Target? {
        guard let raw = ProcessOutput.read(
            "/bin/ps", ["eww", "-o", "pid=,command=", "-p", String(pid)],
            timeout: 3) else { return nil }
        return parse(psOutput: raw, pid: pid)
    }

    // Parent pid of `pid`, or nil if it can't be read (dead process / no ppid).
    private static func parentPID(of pid: Int) -> Int? {
        guard let raw = ProcessOutput.read(
            "/bin/ps", ["-o", "ppid=", "-p", String(pid)],
            timeout: 3) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
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
