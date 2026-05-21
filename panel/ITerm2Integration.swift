import AppKit
import Foundation

// Snapshot of one iTerm2 session at the moment we queried it. tabId is
// the iTerm session's unique id (stable across renames within the tab's
// lifetime); tabName is the user-visible label (changeable). tty is the
// natural join key against `ps` output on our side.
struct ITerm2Session {
    let tabId: String
    let tabName: String?
    let tty: String
}

// Bridge to iTerm2 via AppleScript. The panel needs to know, given an
// agent process's tty, which iTerm tab/pane it's running in. iTerm2's
// AppleScript surface exposes everything we need; we just batch a single
// query per poll cycle (cached for 15s) rather than per-session lookups.
//
// Stage 3 hoisted a TerminalIntegration protocol so peer terminals
// (VSCode, Terminal.app, Warp, …) can share the same pipeline.
final class ITerm2Integration: TerminalIntegration {

    static let shared = ITerm2Integration()

    let name = "iTerm2"

    // Bumped above the SessionStore poll cadence (3s) so most polls hit
    // the cache instead of paying the ~50-200ms osascript round-trip.
    // Tab names rarely change inside a 15s window; a slightly stale
    // label is a cheap price for keeping scroll smooth.
    private let cacheLifetime: TimeInterval = 15.0
    private var cache: [String: ITerm2Session]?
    private var cacheStamp: Date = .distantPast
    // The cache is read from SessionStore's background poll queue; an
    // NSLock keeps reads/writes consistent without serialising the
    // osascript call itself (which runs *outside* the lock).
    private let lock = NSLock()

    // Returns a snapshot map keyed by tty. Empty when iTerm2 isn't
    // running, when Automation permission was denied, or when the
    // osascript times out. Always best-effort — callers must treat
    // nil/empty as "no info" and degrade gracefully.
    //
    // Safe to call from any thread. Two concurrent cache-miss callers
    // may both run the query (small wasted work, never unsafe) — we
    // accept the duplicate over a long-held lock that'd stall the
    // panel during AppleScript.
    func sessionsByTTY() -> [String: ITerm2Session] {
        lock.lock()
        if let cache, Date().timeIntervalSince(cacheStamp) < cacheLifetime {
            defer { lock.unlock() }
            return cache
        }
        lock.unlock()
        let fresh = Self.query()
        lock.lock()
        cache = fresh
        cacheStamp = Date()
        lock.unlock()
        return fresh
    }

    // Force the next sessionsByTTY() call to re-query. Used after a
    // user-driven event that might have changed iTerm state (e.g. a
    // rename) — not strictly needed for correctness, just freshness.
    func invalidate() {
        lock.lock()
        cache = nil
        cacheStamp = .distantPast
        lock.unlock()
    }

    // MARK: - TerminalIntegration

    func enrich(_ sessions: [Session]) -> [Session] {
        let itermPids = sessions
            .filter { $0.terminalApp?.contains("iTerm") == true }
            .map(\.pid)
        guard !itermPids.isEmpty else { return sessions }

        let snapshot = sessionsByTTY()
        guard !snapshot.isEmpty else { return sessions }

        let ttys = Self.ttyMap(forPids: itermPids)

        return sessions.map { session in
            guard session.terminalApp?.contains("iTerm") == true,
                  let tty = ttys[session.pid],
                  let info = snapshot[tty]
            else { return session }
            var copy = session
            copy.tabId = info.tabId
            copy.tabName = info.tabName
            return copy
        }
    }

    // Batched tty lookup. `ps -p P1,P2,...` returns one row per pid,
    // `-o pid=,tty=` strips headers. Cuts N subprocess spawns down to
    // 1 — the biggest single win on poll latency. ps prints the tty in
    // short form ("ttys001"); iTerm2's AppleScript returns the full
    // /dev/ path. We canonicalise to /dev/<short> so the two sides
    // join cleanly.
    static func ttyMap(forPids pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let raw = ProcessOutput.read("/bin/ps", ["-p", pidList, "-o", "pid=,tty="])
        var result: [Int: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = String(line)
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
            let tty = String(parts[1])
            guard tty != "??" else { continue }
            result[pid] = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        }
        return result
    }

    private static func query() -> [String: ITerm2Session] {
        // Pipe-delimited output is cheaper to parse than JSON from
        // AppleScript and avoids quoting headaches. Pane TTYs never
        // contain "|", so the delimiter is unambiguous.
        let script = """
        tell application "iTerm2"
            if not running then return ""
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set ttyPath to tty of s
                            set sessionId to unique id of s
                            set sessionName to name of s
                            set output to output & ttyPath & "|" & sessionId & "|" & sessionName & linefeed
                        end try
                    end repeat
                end repeat
            end repeat
            return output
        end tell
        """

        guard let raw = runOsaScript(script), !raw.isEmpty else { return [:] }

        var result: [String: ITerm2Session] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let tty = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let id  = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty, !id.isEmpty else { continue }
            let name: String?
            if parts.count >= 3 {
                let n = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                name = n.isEmpty ? nil : n
            } else {
                name = nil
            }
            result[tty] = ITerm2Session(tabId: id, tabName: name, tty: tty)
        }
        return result
    }

    // Runs osascript out-of-process and returns stdout, or nil on
    // failure / TCC denial. We deliberately swallow stderr — iTerm2
    // / TCC errors are routine here (cold cache, app not running) and
    // wouldn't help the user.
    private static func runOsaScript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }
        // osascript shouldn't take more than a few hundred ms; if iTerm2
        // is hung we'd rather give up than block the poll loop.
        let deadline = Date().addingTimeInterval(1.5)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
