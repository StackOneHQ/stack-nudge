import Foundation

// Integration for VSCode and Cursor's integrated terminals. Both are
// Electron and present as "Code Helper" / "Cursor Helper (Renderer)"
// processes in our session chain. Per-window identity comes from
// VSCODE_IPC_HOOK_CLI — a Unix socket path that's unique per editor
// window and stable for that window's lifetime. We use it as tabId.
//
// The integration is **bi-directional**: notify.sh ships `ipc_hook` +
// `window_title` on every event, EventListener feeds those into our
// in-memory cache, and the Sessions-tab side enriches each
// VSCode-hosted Session by reading its VSCODE_IPC_HOOK_CLI from the
// process environment (`ps eww`) and joining to the cache.
//
// Why this shape: VSCode itself doesn't expose AppleScript like iTerm2
// does, and we don't want to talk to its CLI socket from the panel.
// The event side already carries the window title for free — we just
// have to remember it.
final class VSCodeIntegration: TerminalIntegration {

    static let shared = VSCodeIntegration()

    let name = "VSCode/Cursor/Antigravity"

    private struct WindowInfo {
        var windowTitle: String?
        var projectPath: String?
        var lastSeenAt: Date
    }

    private var cache: [String: WindowInfo] = [:]
    private let lock = NSLock()

    // Session.terminalApp values our process-chain walker emits when an
    // agent is hosted inside one of these editors. All three are Code
    // forks; they each inherit VSCODE_IPC_HOOK_CLI in their integrated
    // terminal so the same enrichment path works for all of them.
    // Anything outside this set is passed through untouched.
    private static let recognizedTerminals: Set<String> = [
        "Code", "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)",
        "Cursor", "Cursor Helper", "Cursor Helper (Plugin)", "Cursor Helper (Renderer)",
        "Antigravity", "Antigravity Helper", "Antigravity Helper (Plugin)", "Antigravity Helper (Renderer)",
    ]

    // MARK: - Event-side feed

    // Called from EventListener whenever an event with a non-empty
    // ipcHook arrives. windowTitle / projectPath are optional but help
    // produce nicer display labels later.
    func note(ipcHook: String, windowTitle: String?, projectPath: String?) {
        guard !ipcHook.isEmpty else { return }
        let trimmedTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = (trimmedTitle?.isEmpty ?? true) ? nil : trimmedTitle
        lock.lock()
        defer { lock.unlock() }
        var entry = cache[ipcHook] ?? WindowInfo(windowTitle: nil, projectPath: nil, lastSeenAt: .distantPast)
        // Latest non-nil value wins — a later event in the same window
        // might carry a more specific title.
        if let cleanTitle { entry.windowTitle = cleanTitle }
        if let projectPath, !projectPath.isEmpty { entry.projectPath = projectPath }
        entry.lastSeenAt = Date()
        cache[ipcHook] = entry
    }

    // MARK: - TerminalIntegration

    func enrich(_ sessions: [Session]) -> [Session] {
        let candidatePids = sessions
            .filter { Self.isVSCodeHosted($0.terminalApp) }
            .map(\.pid)
        guard !candidatePids.isEmpty else { return sessions }

        let hooks = Self.ipcHookMap(forPids: candidatePids)
        guard !hooks.isEmpty else { return sessions }

        lock.lock()
        let snapshot = cache
        lock.unlock()

        return sessions.map { session in
            guard Self.isVSCodeHosted(session.terminalApp),
                  let hook = hooks[session.pid]
            else { return session }
            var copy = session
            copy.tabId = hook
            copy.tabName = snapshot[hook]?.windowTitle ?? Self.tabNameFallback(forHook: hook)
            return copy
        }
    }

    // MARK: - Internals

    static func isVSCodeHosted(_ terminalApp: String?) -> Bool {
        guard let terminalApp else { return false }
        return recognizedTerminals.contains(terminalApp)
    }

    // Batched lookup. `ps eww -o pid=,args= -p P1,P2,...` prints each
    // pid followed by its command line plus environment variables
    // (`-e`). We scan each line for VSCODE_IPC_HOOK_CLI=… and pair it
    // with the pid at the start of the line.
    //
    // macOS restricts env-var visibility for processes you don't own;
    // the agents here are spawned by the same user, so the readout works.
    static func ipcHookMap(forPids pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let raw = ProcessOutput.read("/bin/ps", ["eww", "-o", "pid=,command=", "-p", pidList])
        return parseIpcHooks(raw)
    }

    // Pulled out for testability — given the raw ps output, return a
    // map of pid → VSCODE_IPC_HOOK_CLI value. No subprocess in here.
    static func parseIpcHooks(_ raw: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<space]) else { continue }
            let rest = trimmed[trimmed.index(after: space)...]
            // VSCODE_IPC_HOOK_CLI is the canonical env var (vscode-cli,
            // cursor-cli alike). Match the equals sign so a later var
            // sharing the prefix wouldn't accidentally match.
            if let range = rest.range(of: "VSCODE_IPC_HOOK_CLI=") {
                let valueStart = range.upperBound
                let valueEnd = rest[valueStart...].firstIndex(where: { $0 == " " }) ?? rest.endIndex
                let value = String(rest[valueStart..<valueEnd])
                guard !value.isEmpty else { continue }
                result[pid] = value
            }
        }
        return result
    }

    // Without a window title from an event, surface a stable label
    // derived from the hook path — better than nothing for cards that
    // get rendered before any event lands.
    static func tabNameFallback(forHook hook: String) -> String? {
        let basename = (hook as NSString).lastPathComponent
        // VSCode socket names follow `vscode-ipc-<uuid>.sock`. The
        // UUID alone isn't human-readable; render the trailing
        // segment with the prefix stripped if present, otherwise nil.
        if basename.isEmpty { return nil }
        return nil  // intentionally nil — UI prefers no chip over a UUID
    }

    // MARK: - Testing seam

    // Builds a fresh integration with its own (empty) cache so tests
    // don't bleed into the live singleton. Marked internal so only the
    // test target reaches it via `@testable import`.
    static func testInstance() -> VSCodeIntegration {
        VSCodeIntegration()
    }

    // Same shape as enrich() but takes the pid → ipcHook map directly,
    // bypassing the `ps eww` subprocess. Lets tests exercise the
    // cache-join half without spawning processes or relying on a real
    // VSCode being installed.
    func enrichForTests(_ sessions: [Session], ipcHooksByPid: [Int: String]) -> [Session] {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        return sessions.map { session in
            guard Self.isVSCodeHosted(session.terminalApp),
                  let hook = ipcHooksByPid[session.pid]
            else { return session }
            var copy = session
            copy.tabId = hook
            copy.tabName = snapshot[hook]?.windowTitle ?? Self.tabNameFallback(forHook: hook)
            return copy
        }
    }
}
