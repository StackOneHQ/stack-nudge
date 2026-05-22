import Foundation

// Terminal.app integration. Same shape as ITerm2Integration — batched
// AppleScript query, 15s cache, tty-keyed join — but the AppleScript
// surface differs:
//
//   * Terminal.app exposes `tabs of window` with a `tty` property.
//   * No stable per-tab UUID; we use the tty path itself as tabId.
//     That's stable for the tab's lifetime, which is enough.
//   * `custom title` is the user-set tab title; if absent, fall back
//     to nothing (the auto-derived names are usually the running
//     process and not very useful).
final class TerminalAppIntegration: TerminalIntegration {

    static let shared = TerminalAppIntegration()

    let name = "Terminal.app"

    private let cacheLifetime: TimeInterval = 15.0
    private var cache: [String: TabInfo]?
    private var cacheStamp: Date = .distantPast
    private let lock = NSLock()

    func enrich(_ sessions: [Session]) -> [Session] {
        let pids = sessions
            .filter { $0.terminalApp == "Terminal" }
            .map(\.pid)
        guard !pids.isEmpty else { return sessions }

        let snapshot = sessionsByTTY()
        guard !snapshot.isEmpty else { return sessions }

        let ttys = ITerm2Integration.ttyMap(forPids: pids)

        return sessions.map { session in
            guard session.terminalApp == "Terminal",
                  let tty = ttys[session.pid],
                  let info = snapshot[tty]
            else { return session }
            var copy = session
            copy.tabId = info.tabId
            copy.tabName = info.tabName
            return copy
        }
    }

    // Snapshot of Terminal.app's tabs keyed by tty. Same locking +
    // cache-around-AppleScript pattern as ITerm2Integration.
    private func sessionsByTTY() -> [String: TabInfo] {
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

    private static func query() -> [String: TabInfo] {
        // Pipe-delimited output. `try` blocks guard against tabs that
        // lack `custom title` (older versions) or processes that race
        // with us mid-query.
        let script = """
        tell application "Terminal"
            if not running then return ""
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set ttyPath to tty of t
                        set tabTitle to ""
                        try
                            set tabTitle to custom title of t
                        end try
                        set output to output & ttyPath & "|" & tabTitle & linefeed
                    end try
                end repeat
            end repeat
            return output
        end tell
        """

        guard let raw = runOsaScript(script), !raw.isEmpty else { return [:] }

        var result: [String: TabInfo] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count >= 1 else { continue }
            let tty = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !tty.isEmpty else { continue }
            let title: String?
            if parts.count == 2 {
                let raw = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                title = raw.isEmpty ? nil : raw
            } else {
                title = nil
            }
            // Use the tty itself as tabId. Stable for the tab's lifetime,
            // and avoids inventing an ID where Terminal.app gives us none.
            result[tty] = TabInfo(tabId: tty, tabName: title, windowTitle: nil)
        }
        return result
    }

    // Same osascript shape as ITerm2Integration but kept local so the
    // two integrations stay independent — if one acquires a quirk we
    // don't want to leak it into the other.
    private static func runOsaScript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }
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
