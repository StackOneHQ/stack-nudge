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
        // Sidecar first, but only for a live `pi` process. pi renames its process
        // title, clobbering the argv+env region `ps` reads, so its pane can't be
        // recovered from the env — the in-process extension writes it to a per-pid
        // sidecar instead. Gating on a live `pi` (comm IS readable) stops a stale
        // sidecar, left by a crash, from hijacking focus once the OS reuses that
        // pid for another process (or another agent). claude et al. have no
        // sidecar and fall through to the env read.
        if isLivePi(pid: agentPID), let resolved = sidecarTarget(pid: agentPID) {
            debug("target(pid=\(agentPID)) -> pane=\(resolved.pane) via sidecar "
                + "socket=\(resolved.socket ?? "default") host=\(resolved.hostBundleID ?? "nil")")
            return resolved
        }

        guard let raw = ProcessOutput.read(
            "/bin/ps", ["eww", "-o", "pid=,command=", "-p", String(agentPID)],
            timeout: 3) else { return nil }
        let resolved = parse(psOutput: raw, pid: agentPID)
        debug("target(pid=\(agentPID)) -> " + (resolved.map {
            "pane=\($0.pane) socket=\($0.socket ?? "default") host=\($0.hostBundleID ?? "nil")"
        } ?? "nil (no sidecar, no TMUX_PANE in that pid's env)"))
        return resolved
    }

    // True when `pid` is a live process named `pi`. `ps -o comm=` is readable even
    // though pi's environment is not, so this cheaply confirms a sidecar belongs
    // to the pi it was written for rather than a later reuse of the same pid.
    private static func isLivePi(pid: Int) -> Bool {
        guard let comm = ProcessOutput.read(
            "/bin/ps", ["-o", "comm=", "-p", String(pid)], timeout: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !comm.isEmpty
        else { return false }
        return (comm as NSString).lastPathComponent == "pi"
    }

    // Read a per-pid tmux sidecar (~/.stack-nudge/pi-sessions/<pid>.json), written
    // by an in-process extension for agents whose env `ps` can't read. Shape:
    // {"pane":"%39","socket":"/private/tmp/tmux-502/default","lcTerminal":"iTerm2"}.
    // `dir` is injectable for tests; production uses the install location. Callers
    // gate on isLivePi first — this does not itself validate the pid.
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
