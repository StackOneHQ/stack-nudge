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
            guard let socket = Self.socketKey(tmuxes[pid]),
                  titlesBySocket[socket] == nil
            else { continue }
            titlesBySocket[socket] = Self.paneTitles(socket: socket)
        }

        return Self.apply(sessions, panes: panes, tmuxes: tmuxes,
                          titlesBySocket: titlesBySocket)
    }

    // Pure half of enrich: given the env values and one title map per server,
    // stamp the sessions. Split out because the property that matters most here
    // cannot be reached through enrich() — that a title is only ever taken from
    // the session's *own* server. Pane ids repeat across servers ("%0" exists on
    // every one), so pooling them into a single map is a silent, plausible
    // refactor that hands a session another tmux's title, and it needs a
    // two-server fixture to catch.
    static func apply(_ sessions: [Session],
                      panes: [Int: String],
                      tmuxes: [Int: String],
                      titlesBySocket: [String: [String: String]]) -> [Session] {
        sessions.map { session in
            guard session.terminalApp == "tmux", let pane = panes[session.pid] else { return session }
            var copy = session
            let tmux = tmuxes[session.pid]
            copy.tabId = tabId(pane: pane, tmux: tmux)
            // Assigned unconditionally: a failed query blanks the title for one
            // poll and it returns on the next, which is the honest behaviour.
            // Anything cleverer needs to tell "the query failed" apart from
            // "this pane's title is the hostname sentinel", and parseTitles
            // cannot — both arrive as a missing key. Preserving across polls on
            // that ambiguity is how a title that was cleared sticks forever.
            copy.tabName = socketKey(tmux).flatMap { titlesBySocket[$0]?[pane] }
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

    // The socket path from TMUX's first comma-field, or nil when there isn't a
    // usable one.
    //
    // nil means "don't look up a title", NOT "use tmux's default socket". The
    // default socket is a real server, so guessing it hands a session the title
    // of whatever pane happens to share its id over there — pane ids are only
    // unique within a server, and "%0" exists on every one. That is reachable:
    // the standard nested-tmux idioms (`TMUX= cmd`, `env -u TMUX cmd`) clear
    // TMUX while leaving TMUX_PANE in place, so the pane is known and the server
    // is not. A missing title is a row that reads a little plainer; a wrong one
    // is a Slack DM naming the wrong session. This matches what tabId already
    // does with a malformed TMUX — fall back rather than guess.
    static func socketKey(_ tmux: String?) -> String? {
        guard let field = tmux?
                .split(separator: ",", omittingEmptySubsequences: false)
                .first.map(String.init),
              !field.isEmpty
        else { return nil }
        return field
    }

    // How long a server that failed to answer is skipped for. A wedged tmux —
    // blocked, SIGSTOPped, or a socket that accepts and never replies — does not
    // fail fast: it hangs, and ProcessOutput then spends the timeout plus its
    // SIGTERM/SIGKILL/drain waits (~5s all told) before giving up. Without a
    // backoff that cost is paid again on every 3s poll, forever, with the
    // session scan latched behind it. The happy path stays uncached — see the
    // measurement above; this only remembers failures.
    static let failureBackoff: TimeInterval = 30

    private static let backoffLock = NSLock()
    private static var skipUntil: [String: Date] = [:]

    // Pane titles for one tmux server, keyed by pane id ("%4"). The socket is
    // always explicit — see socketKey for why the default is never assumed.
    // Empty on any failure: no tmux binary, a server that died between the `ps`
    // read and here, or a hung query hitting the timeout.
    // `tmuxPath` and `run` are injectable so a test can assert what this
    // actually *sends*. Asserting the helpers in isolation is not enough: a test
    // that only checks tmuxEnv() returns a UTF-8 locale still passes when the
    // call site stops passing it, which is exactly how the locale fix could be
    // deleted with the suite green. Injecting the path too keeps the test off
    // the question of whether the runner happens to have tmux installed.
    static func paneTitles(socket: String, now: Date = Date(),
                           tmuxPath: () -> String? = AppActivator.tmuxPath,
                           run: (String, [String], [String: String]) -> String? = {
                               ProcessOutput.read($0, $1, timeout: 2, env: $2)
                           }) -> [String: String] {
        guard let tmux = tmuxPath(), !isBackedOff(socket, now: now) else { return [:] }
        // Tab-delimited: a pane title is arbitrary program output and "|" turns
        // up in shell prompts constantly, whereas tmux accepts neither a tab nor
        // a newline into a pane title at all — it strips them from an OSC title
        // and rejects a `select-pane -T` carrying one outright.
        //
        // #{host} rides along so the sentinel comparison is tmux's own answer
        // rather than our guess at it. tmux seeds an untitled pane from
        // gethostname(); ProcessInfo.hostName is the mDNS spelling, which is
        // lowercased here and on a DHCP/corp-DNS machine can be a different name
        // entirely. Asking tmux removes the guess, the case-folding, and the
        // staleness after a runtime rename.
        return titles(from: run(tmux, listPanesArgs(socket: socket), AppActivator.tmuxEnv()),
                      socket: socket, now: now)
    }

    // The three fields, in order, that parseTitles expects back. Extracted from
    // the arg vector so a test can build a line exactly the way tmux would and
    // push it back through the parser: the format string and the parser are two
    // halves of one contract, and nothing at runtime notices when they drift.
    // Dropping a field here doesn't fail loudly — parseTitles' field-count guard
    // rejects every line, so no session gets a title again, silently.
    static let paneFormat = "#{pane_id}\t#{host}\t#{pane_title}"

    // `-a` is load-bearing: without it list-panes only reports the *current*
    // session's panes, so agents in every other tmux session lose their titles.
    static func listPanesArgs(socket: String) -> [String] {
        ["-S", socket, "list-panes", "-a", "-F", paneFormat]
    }

    // Record the outcome and parse. nil means ProcessOutput gave up — a spawn
    // failure or, the case that matters, a hang — and only that arms the
    // backoff. A server that is merely *gone* is not a hang: tmux exits rc=1
    // immediately with the message on stderr, so `raw` is "" and the poll pays
    // nothing. Parking that would suppress titles for half a minute after a
    // perfectly ordinary tmux restart, which is the opposite of the goal.
    static func titles(from raw: String?, socket: String, now: Date = Date()) -> [String: String] {
        guard let raw else {
            noteFailure(socket, now: now)
            return [:]
        }
        clearFailure(socket)
        return parseTitles(raw)
    }

    static func isBackedOff(_ socket: String, now: Date = Date()) -> Bool {
        backoffLock.lock(); defer { backoffLock.unlock() }
        guard let until = skipUntil[socket] else { return false }
        if now >= until { skipUntil[socket] = nil; return false }
        return true
    }

    private static func noteFailure(_ socket: String, now: Date) {
        backoffLock.lock(); defer { backoffLock.unlock() }
        skipUntil[socket] = now.addingTimeInterval(failureBackoff)
    }

    private static func clearFailure(_ socket: String) {
        backoffLock.lock(); defer { backoffLock.unlock() }
        skipUntil[socket] = nil
    }

    // Test seam: forget every recorded failure.
    static func resetBackoff() {
        backoffLock.lock(); defer { backoffLock.unlock() }
        skipUntil.removeAll()
    }

    // Pure. tmux seeds every pane's title with the machine's hostname and only
    // replaces it once the program emits an OSC title escape, so "never set" is
    // indistinguishable from "set to the hostname". Treating a title equal to
    // the host as no title is the safe read: the alternative labels every plain
    // shell pane "Hiskiass-MacBook-Pro-2.local", which is noise in the meta row
    // and actively wrong once the toggle lets a tab title title a Slack DM.
    //
    // The host arrives per line from tmux itself, so the comparison is exact —
    // no case-folding, and no matching against the bare first label, which would
    // have swallowed every pane a user on a machine called "orion" legitimately
    // titled "orion".
    static func parseTitles(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let pane = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let host = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pane.isEmpty, !title.isEmpty, title != host else { continue }
            result[pane] = title
        }
        return result
    }
}
