import Foundation

// Enriches tmux-hosted sessions with a per-pane tabId and the pane's title.
//
// A bare TMUX_PANE ("%4") is unique only within a single tmux server; a user
// running multiple servers (separate sockets) can have the same %N in each,
// which would collide the per-tab renames/colours keyed on tabId and the
// event↔session fallback match. Compose the server id (the pid in
// TMUX="<socket>,<serverPID>,<n>") with the pane so the id is unique across
// servers. notify.sh builds the same "<serverPID>:<pane>" for event payloads so
// the two paths agree.
//
// The title comes from #{pane_title}, which is the OSC title the running
// program set — the same signal iTerm2 exposes as `autoName`, and what Claude
// Code rewrites each turn ("✳ Review repository structure"). It carries no
// proof a *human* chose it, which is why it feeds the pane's meta row by
// default and only becomes a session name behind the opt-in toggle. See
// SessionLabel.
//
// Not used: #{window_name}. tmux auto-derives it from the running command
// unless the window was explicitly renamed, and the one signal that would tell
// the two apart — `show-options -w -t <win> automatic-rename`, which reads back
// "off" only after a manual rename — costs a subprocess per window. The
// #{automatic_rename} *format* looks like it would do the same job for free but
// renders empty whether or not the window was renamed, so it is not usable
// here. Batching is the rule this protocol exists to enforce, so a renamed tmux
// window is a documented gap rather than N more spawns per poll.
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

        // One list-panes per distinct server, not per session: pane ids repeat
        // across servers, so the titles can't be pooled into one flat map.
        // Unlike the AppleScript integrations there's no 15s cache — a
        // list-panes measured 8.4ms against osascript's 90ms (and that was
        // iTerm2's not-running fast path), so at the 3s poll cadence the query
        // is cheaper than the staleness would be. It matters more now the title
        // can reach a banner: a cached one would name the previous turn's task.
        var titlesBySocket: [String: [String: String]] = [:]
        for pid in pids where panes[pid] != nil {
            let key = Self.socketKey(tmuxes[pid])
            guard titlesBySocket[key] == nil else { continue }
            titlesBySocket[key] = Self.paneTitles(socket: key.isEmpty ? nil : key)
        }

        return sessions.map { session in
            guard session.terminalApp == "tmux", let pane = panes[session.pid] else { return session }
            var copy = session
            copy.tabId = Self.tabId(pane: pane, tmux: tmuxes[session.pid])
            // Only overwrite on a hit. Assigning unconditionally would blank
            // every tmux session's name the one poll a server is mid-restart or
            // the query times out, making names flicker in and out of rows.
            if let title = titlesBySocket[Self.socketKey(tmuxes[session.pid])]?[pane] {
                copy.tabName = title
            }
            return copy
        }
    }

    // "<serverPID>:<pane>" — serverPID is the second comma-field of TMUX
    // ("<socket>,<serverPID>,<n>"). Falls back to the bare pane when TMUX is
    // absent or malformed. Must stay in sync with notify.sh's session-id build.
    static func tabId(pane: String, tmux: String?) -> String {
        // serverPID is positional (2nd field), so keep empty fields — otherwise
        // a malformed "<socket>,,<n>" would slide the session index into the
        // server slot. An empty/absent server field falls back to the bare pane.
        guard let server = tmux?
                .split(separator: ",", omittingEmptySubsequences: false)
                .dropFirst().first.map(String.init),
              !server.isEmpty
        else { return pane }
        return "\(server):\(pane)"
    }

    // The socket path from TMUX's first comma-field, or "" for the default
    // socket. A total key, so the per-server title map never needs an optional
    // lookup — and "" is not a path tmux could ever hand us, so it can't
    // collide with a real socket.
    static func socketKey(_ tmux: String?) -> String {
        guard let field = tmux?
                .split(separator: ",", omittingEmptySubsequences: false)
                .first.map(String.init)
        else { return "" }
        return field
    }

    // Pane titles for one tmux server, keyed by pane id ("%4"). nil socket uses
    // tmux's default socket. Empty on any failure — no tmux binary, a server
    // that died between the `ps` read and here, or a hung query hitting the
    // timeout. Callers degrade to "no title", never to a wrong one.
    static func paneTitles(socket: String?) -> [String: String] {
        guard let tmux = AppActivator.tmuxPath() else { return [:] }
        var args: [String] = []
        if let socket, !socket.isEmpty { args += ["-S", socket] }
        // Tab-delimited: a pane title is arbitrary user/program text and "|"
        // shows up in shell prompts often enough to matter, whereas tmux
        // collapses a literal tab out of #{pane_title}.
        args += ["list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}"]
        guard let raw = ProcessOutput.read(tmux, args, timeout: 2,
                                           env: AppActivator.tmuxEnv())
        else { return [:] }
        return parseTitles(raw, hostNames: hostNames())
    }

    // Matching is case-insensitive and `hostNames` arrives lowercased. The two
    // sides genuinely disagree on case: tmux seeds the title from the
    // SystemConfiguration name ("Hiskiass-MacBook-Pro-2.local") while
    // ProcessInfo.hostName returns the mDNS spelling, which is lowercased
    // ("hiskiass-macbook-pro-2.local"). An exact match never fires, so every
    // untitled pane would be labelled with the machine's own name.
    //
    // Pure. tmux seeds every pane's title with the machine's hostname and only
    // replaces it once the program emits an OSC title escape, so "never set" is
    // indistinguishable from "set to the hostname". Treating the hostname as no
    // title is the safe read: the alternative labels every plain shell pane
    // "Hiskiass-MacBook-Pro-2.local", which is noise in the meta row and
    // actively wrong once the toggle lets a tab title title a Slack DM.
    static func parseTitles(_ raw: String, hostNames: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let pane = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pane.isEmpty, !title.isEmpty,
                  !hostNames.contains(title.lowercased())
            else { continue }
            result[pane] = title
        }
        return result
    }

    // Both spellings tmux might have seeded a title with: ProcessInfo's
    // hostName ("host.local") and its first label ("host"), since which one
    // tmux picks depends on how the machine resolves its own name. Lowercased,
    // because the comparison in parseTitles is case-insensitive — see there.
    static func hostNames() -> Set<String> {
        let full = ProcessInfo.processInfo.hostName.lowercased()
        var names: Set<String> = [full]
        if let short = full.split(separator: ".").first { names.insert(String(short)) }
        return names
    }
}
