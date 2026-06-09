import Foundation
import SwiftUI

enum SessionStatus: Equatable {
    case active
    case finished(at: Date)
}

struct Session: Identifiable, Equatable {
    let id: Int           // pid — pids are reusable but stable for this process's lifetime
    let pid: Int
    let agent: String     // "claude" | "gemini" | "codex" | "agy"
    let projectPath: String?
    let projectName: String?
    let terminalPID: Int?
    let terminalApp: String?
    let elapsed: String?  // ps etime — display-only
    var customName: String?
    var status: SessionStatus
    // iTerm2 (Stage 2) enrichment. tabId is the iTerm session's unique id
    // — stable for the tab's lifetime, used to scope renames/colors to a
    // specific tab. tabName is the user-visible label. Both nil for
    // sessions not running inside iTerm2 (or when Automation is denied),
    // which is exactly the pre-Stage-2 behaviour.
    var tabId: String?
    var tabName: String?
    // Claude's per-pid sidecar (~/.claude/sessions/<pid>.json) gives an
    // authoritative session id without waiting for a hook event.
    var claudeSessionID: String?
    // Live agent state, agent-agnostic: Claude fills these from its sidecar,
    // Antigravity from its language-server RPC (see SessionStore.enrichAntigravity
    // + AntigravityLocalServer). They drive the busy/idle dot, the status line,
    // and the busy-first sort; nil for agents that expose no live state.
    var liveTitle: String?            // session name (Claude sidecar; "main-agent" = default)
    var liveStatus: String?           // "busy" | "idle" | other
    var lastActivityAt: Date?         // last-activity timestamp
}

// Decoded shape of ~/.claude/sessions/<pid>.json. Only the fields we
// actually use; Claude Code emits more. updatedAt is milliseconds since
// the Unix epoch; SessionStore converts to Date at discovery time.
private struct ClaudeSessionSidecar: Decodable {
    let sessionId: String?
    let name: String?
    let status: String?
    let updatedAt: Double?
}

// Polls for live agent processes (claude / gemini / codex / agy). Uses a
// tight cadence while the Sessions tab is visible and a lower-frequency
// background cadence for the compact widget. Maintains "finished" state
// for sessions that disappeared between polls so the user can see ones
// that just exited.
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published var selectedPID: Int?
    @Published var renamingPID: Int?
    @Published var renameBuffer: String = ""
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var didFirstScan: Bool = false

    private let persistence: SessionPersistence
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval?
    private var hasSweptSidecars = false
    private let queue = DispatchQueue(label: "stack-nudge.sessions", qos: .utility)
    private static let agentBinaries: Set<String> = ["claude", "gemini", "codex", "agy"]
    private static let foregroundPollInterval: TimeInterval = 3.0
    // Pill-only cadence when the Sessions tab isn't open. 10s keeps the
    // mascot's busy/idle reflection on hook-less sidecar state changes
    // (Claude liveStatus) with a worst-case latency that still feels
    // live, while combined with the batched discover() (3 forks/scan
    // instead of ~22) it cuts steady-state subprocess load by ~91% vs
    // the original 3s, ~22-fork design. Hook events still surface
    // immediately via the socket regardless of this interval.
    private static let backgroundPollInterval: TimeInterval = 10.0

    init(persistence: SessionPersistence = .shared) {
        self.persistence = persistence
    }

    func startPolling() {
        startPolling(every: Self.backgroundPollInterval)
    }

    func startForegroundPolling() {
        startPolling(every: Self.foregroundPollInterval)
    }

    private func startPolling(every interval: TimeInterval) {
        // One-shot sweep of dead-PID sidecars left in ~/.claude/sessions/.
        // Claude Code writes these but doesn't garbage-collect them, so they
        // accumulate over weeks of use. Conservative guards (PID actually
        // dead + file at least 5 min old) keep us from racing a session
        // that's just starting up or mid-write.
        if !hasSweptSidecars {
            hasSweptSidecars = true
            DispatchQueue.global(qos: .utility).async {
                Self.sweepStaleClaudeSidecars()
            }
        }
        guard pollInterval != interval || pollTimer == nil else { return }
        scan()
        pollTimer?.invalidate()
        pollInterval = interval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = nil
    }

    func killSession(_ pid: Int) {
        // SIGTERM — give the agent a chance to clean up
        kill(pid_t(pid), SIGTERM)
        // Optimistically mark finished so the UI updates without waiting
        // for the next poll.
        if let idx = sessions.firstIndex(where: { $0.pid == pid }) {
            sessions[idx].status = .finished(at: Date())
        }
    }

    func rename(_ pid: Int, to name: String?) {
        guard let idx = sessions.firstIndex(where: { $0.pid == pid }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        let final: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        sessions[idx].customName = final
        // tabId-scoped write when we know which tab the user is renaming,
        // so two tabs in the same cwd get independent names. Falls back
        // to the (agent, projectPath) key when no iTerm enrichment is
        // available — matches Stage 1 behaviour exactly.
        persistence.setCustomName(
            agent: sessions[idx].agent,
            projectPath: sessions[idx].projectPath,
            tabId: sessions[idx].tabId,
            final
        )
    }

    func startRenaming(_ pid: Int) {
        guard let session = sessions.first(where: { $0.pid == pid }) else { return }
        renamingPID = pid
        renameBuffer = session.customName ?? session.projectName ?? ""
    }

    func commitRename() {
        guard let pid = renamingPID else { return }
        rename(pid, to: renameBuffer.trimmingCharacters(in: .whitespaces))
        renamingPID = nil
        renameBuffer = ""
    }

    func cancelRename() {
        renamingPID = nil
        renameBuffer = ""
    }

    private func scan() {
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            // discover() shells out to ps/lsof; TerminalRegistry.enrich
            // calls each terminal integration (iTerm2, VSCode, …) in
            // turn — each batches its own subprocess work. The whole
            // thing runs on the background poll queue so the main thread
            // never sees a subprocess spawn.
            let raw = Self.discover()
            let enriched = TerminalRegistry.enrich(raw)
            DispatchQueue.main.async { [weak self] in
                self?.merge(enriched)
                self?.isScanning = false
                self?.didFirstScan = true
            }
        }
    }

    private func merge(_ found: [Session]) {
        let foundByPID = Dictionary(uniqueKeysWithValues: found.map { ($0.pid, $0) })
        let now = Date()
        let cutoff = now.addingTimeInterval(-30) // hide finished sessions after 30s

        var next: [Session] = []

        // Update / mark-finished existing sessions in place so customName
        // persists. We also re-apply the freshly-enriched tabId/tabName
        // from the live snapshot — a tab rename or pane move should
        // propagate without waiting for the session to restart.
        for var existing in sessions {
            if let live = foundByPID[existing.pid] {
                existing = live.with(
                    customName: existing.customName,
                    status: .active,
                    tabId: live.tabId,
                    tabName: live.tabName
                )
                next.append(existing)
            } else {
                switch existing.status {
                case .active:
                    existing.status = .finished(at: now)
                    next.append(existing)
                case .finished(let at) where at >= cutoff:
                    next.append(existing)
                default:
                    break // drop stale finished
                }
            }
        }

        // Add genuinely new sessions, seeding customName from persistence
        // so a renamed (agent, projectPath[, tabId]) keeps its name across
        // restarts and across process churn within a single launch.
        let knownPIDs = Set(next.map(\.pid))
        for var session in found where !knownPIDs.contains(session.pid) {
            if let persisted = persistence.customName(
                agent: session.agent,
                projectPath: session.projectPath,
                tabId: session.tabId
            ) {
                session.customName = persisted
                persistence.noteSeen(
                    agent: session.agent,
                    projectPath: session.projectPath,
                    tabId: session.tabId
                )
            }
            next.append(session)
        }

        // Sort: active first, busy above non-busy within active, then by
        // most-recent lastActivityAt (or process pid as tiebreaker so
        // ordering stays stable when sidecar timestamps are absent).
        // Distant past for sessions with no updatedAt sinks them below
        // any timestamped session.
        let distantPast = Date.distantPast
        next.sort { lhs, rhs in
            let lActive = lhs.status == .active
            let rActive = rhs.status == .active
            if lActive != rActive { return lActive && !rActive }

            let lBusy = lhs.liveStatus == "busy"
            let rBusy = rhs.liveStatus == "busy"
            if lBusy != rBusy { return lBusy && !rBusy }

            let lAt = lhs.lastActivityAt ?? distantPast
            let rAt = rhs.lastActivityAt ?? distantPast
            if lAt != rAt { return lAt > rAt }
            return lhs.pid < rhs.pid
        }

        sessions = next

        if let sel = selectedPID, !sessions.contains(where: { $0.pid == sel }) {
            selectedPID = sessions.first?.pid
        } else if selectedPID == nil {
            selectedPID = sessions.first?.pid
        }
    }

    // MARK: - Discovery

    // Parse ps output as `pid etime <full args>`. Agent detection is done on
    // args because `comm` is truncated by ps and node-hosted agents (gemini,
    // codex when installed via npm) show comm as "node" with the script
    // path in args.
    private static func discover() -> [Session] {
        let lines = runProcess("/bin/ps", ["-axo", "pid=,etime=,args="])
            .split(separator: "\n")

        var candidates: [(pid: Int, elapsed: String, agent: String)] = []
        for raw in lines {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            // pid (digits) <ws> etime <ws> args...
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            guard let pid = Int(parts[0]) else { continue }
            let etime = String(parts[1])
            let args = String(parts[2])

            guard let agent = detectAgent(args: args) else { continue }
            candidates.append((pid: pid, elapsed: etime, agent: agent))
        }

        let pids = candidates.map(\.pid)
        let cwdByPID = readCWDs(pids: pids)
        let processTable = readProcessTable()

        var found: [Session] = []
        for candidate in candidates {
            let cwd = cwdByPID[candidate.pid]
            let chain = walkParentChain(from: candidate.pid, processTable: processTable)
            let sidecar = (candidate.agent == "claude")
                ? readClaudeSidecar(pid: candidate.pid)
                : nil
            found.append(Session(
                id: candidate.pid,
                pid: candidate.pid,
                agent: candidate.agent,
                projectPath: cwd,
                projectName: cwd.map { ($0 as NSString).lastPathComponent },
                terminalPID: chain.terminalPID,
                terminalApp: chain.terminalApp,
                elapsed: candidate.elapsed,
                customName: nil,
                status: .active,
                tabId: nil,
                tabName: nil,
                claudeSessionID: sidecar?.sessionId,
                liveTitle:      sidecar?.name,
                liveStatus:    sidecar?.status,
                lastActivityAt: sidecar?.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            ))
        }
        enrichAntigravity(&found)
        return found
    }

    // Antigravity has no per-pid sidecar like Claude; instead the running `agy`
    // process serves live session status over a local RPC. Match each agy
    // session to its trajectory by workspace path (cwd) and fill the live
    // busy/idle state, so agy sessions get the same dot + sort as Claude.
    // One RPC call per scan, only when an agy session is present.
    private static func enrichAntigravity(_ found: inout [Session]) {
        guard found.contains(where: { $0.agent == "agy" }) else { return }
        let states = AntigravityLocalServer.liveStatusByWorkspace()
        guard !states.isEmpty else { return }
        for index in found.indices where found[index].agent == "agy" {
            guard let cwd = found[index].projectPath else { continue }
            let match = states[cwd]
                ?? states.first(where: { cwd == $0.key || cwd.hasPrefix($0.key + "/") })?.value
            if let match {
                found[index].liveStatus = match.status
                found[index].lastActivityAt = match.lastActivityAt
            }
        }
    }

    private static func detectAgent(args: String) -> String? {
        // First token of args is the executable path.
        let firstToken = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let baseName = (firstToken as NSString).lastPathComponent

        if baseName == "claude" { return "claude" }
        if baseName == "gemini" { return "gemini" }
        if baseName == "codex"  { return "codex"  }
        if baseName == "agy"    { return "agy"    }

        // Node / Deno-hosted agents: inspect later tokens for known script paths.
        if baseName == "node" || baseName == "deno" || baseName == "bun" {
            if args.range(of: #"\bgemini(-cli)?\b"#, options: .regularExpression) != nil {
                return "gemini"
            }
            if args.range(of: #"\bcodex(-cli)?\b"#, options: .regularExpression) != nil {
                return "codex"
            }
            if args.range(of: #"\b(agy|antigravity(-cli)?)\b"#, options: .regularExpression) != nil {
                return "agy"
            }
        }
        return nil
    }

    // Walk ~/.claude/sessions/ and recycle any <pid>.json whose PID is no
    // longer running. Claude Code writes these on session start but doesn't
    // remove them on exit, so a long-lived user accumulates dozens of stale
    // entries which (a) take up inodes, (b) risk surfacing stale data if a
    // future PID collides with a dead session's PID. Age guard (file must
    // be at least 5 minutes old) protects against deleting the sidecar of
    // a session that's mid-bootstrap on a freshly-reused PID.
    private static func sweepStaleClaudeSidecars() {
        let dir = "\(NSHomeDirectory())/.claude/sessions"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let minAge: TimeInterval = 300
        let now = Date()
        for entry in entries {
            guard entry.hasSuffix(".json") else { continue }
            let basename = String(entry.dropLast(".json".count))
            guard let pid = Int32(basename) else { continue }
            // kill(pid, 0) returns 0 iff signal would be delivered. A
            // not-running PID surfaces ESRCH; lacking permission surfaces
            // EPERM (process exists but isn't ours) — only ESRCH lets us
            // confidently say "gone."
            if kill(pid, 0) == 0 { continue }
            if errno != ESRCH { continue }
            let path = "\(dir)/\(entry)"
            if let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) < minAge {
                continue
            }
            try? fm.removeItem(atPath: path)
        }
    }

    // Per-PID sidecar emitted by Claude Code (interactive runs) with the
    // session UUID, user-facing name, and live busy/idle status. Reading
    // this lets us bind a Session to its transcript immediately without
    // waiting for a hook event to fire.
    private static func readClaudeSidecar(pid: Int) -> ClaudeSessionSidecar? {
        let path = "\(NSHomeDirectory())/.claude/sessions/\(pid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeSessionSidecar.self, from: data)
    }

    private static func readCWDs(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        let output = runProcess(
            "/usr/sbin/lsof",
            ["-a", "-d", "cwd", "-p", pidList, "-Fpn"]
        )
        var result: [Int: String] = [:]
        var currentPID: Int?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let currentPID {
                result[currentPID] = String(line.dropFirst())
            }
        }
        return result
    }

    private struct ParentChain {
        var terminalPID: Int?
        var terminalApp: String?
    }

    private struct ProcessInfo {
        let parentPID: Int
        let command: String
    }

    private static let terminalApps: Set<String> = [
        "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)", "Code",
        "Cursor Helper", "Cursor Helper (Plugin)", "Cursor Helper (Renderer)", "Cursor",
        "Antigravity Helper", "Antigravity Helper (Plugin)", "Antigravity Helper (Renderer)", "Antigravity",
        "iTerm2", "iTerm", "Terminal", "Warp", "WarpTerminal", "ghostty", "Ghostty",
    ]

    private static func readProcessTable() -> [Int: ProcessInfo] {
        let output = runProcess("/bin/ps", ["-axww", "-o", "pid=,ppid=,comm="])
        var result: [Int: ProcessInfo] = [:]
        for raw in output.split(separator: "\n") {
            let parts = String(raw)
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int(parts[0]),
                  let parentPID = Int(parts[1])
            else { continue }
            result[pid] = ProcessInfo(parentPID: parentPID, command: String(parts[2]))
        }
        return result
    }

    private static func walkParentChain(
        from pid: Int,
        processTable: [Int: ProcessInfo]
    ) -> ParentChain {
        var chain = ParentChain()
        var current: Int? = pid
        for _ in 0..<12 {
            guard let next = current, next > 1,
                  let info = processTable[next]
            else { break }
            let base = (info.command as NSString).lastPathComponent
            if terminalApps.contains(base) {
                chain.terminalPID = next
                chain.terminalApp = base
                return chain
            }
            current = info.parentPID
        }
        return chain
    }

    private static func runProcess(_ path: String, _ args: [String]) -> String {
        // Thin wrapper around the shared helper so all subprocess
        // plumbing lives in one place — keeps stderr-swallow + failure
        // semantics consistent across SessionStore and the terminal
        // integrations.
        ProcessOutput.read(path, args)
    }
}

private extension Session {
    func with(customName: String?, status: SessionStatus,
              tabId: String? = nil, tabName: String? = nil) -> Session {
        Session(
            id: id,
            pid: pid,
            agent: agent,
            projectPath: projectPath,
            projectName: projectName,
            terminalPID: terminalPID,
            terminalApp: terminalApp,
            elapsed: elapsed,
            customName: customName,
            status: status,
            tabId: tabId ?? self.tabId,
            tabName: tabName ?? self.tabName,
            // Preserve the live sidecar values from the freshly-discovered
            // snapshot — these change turn-to-turn (status especially), so
            // we want the merge to surface the latest, not the stale value
            // from the previous poll.
            claudeSessionID: self.claudeSessionID,
            liveTitle:      self.liveTitle,
            liveStatus:    self.liveStatus,
            lastActivityAt: self.lastActivityAt
        )
    }
}
