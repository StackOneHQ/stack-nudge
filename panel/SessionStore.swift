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
}

// Polls for live agent processes (claude / gemini / codex) every few seconds
// while the sessions view is on screen. Maintains "finished" state for
// sessions that disappeared between polls so the user can see ones that
// just exited.
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published var selectedPID: Int?
    @Published var renamingPID: Int?
    @Published var renameBuffer: String = ""
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var didFirstScan: Bool = false

    private let persistence: SessionPersistence
    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "stack-nudge.sessions", qos: .utility)
    private static let agentBinaries: Set<String> = ["claude", "gemini", "codex", "agy"]
    private static let pollInterval: TimeInterval = 3.0

    init(persistence: SessionPersistence = .shared) {
        self.persistence = persistence
    }

    func startPolling() {
        scan()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
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

        // Sort: active first, then most-recently-finished, then by agent/pid.
        next.sort { lhs, rhs in
            let lActive = lhs.status == .active
            let rActive = rhs.status == .active
            if lActive != rActive { return lActive && !rActive }
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

        var found: [Session] = []
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

            let cwd = readCWD(pid: pid)
            let chain = walkParentChain(from: pid)

            found.append(Session(
                id: pid,
                pid: pid,
                agent: agent,
                projectPath: cwd,
                projectName: cwd.map { ($0 as NSString).lastPathComponent },
                terminalPID: chain.terminalPID,
                terminalApp: chain.terminalApp,
                elapsed: etime,
                customName: nil,
                status: .active,
                tabId: nil,
                tabName: nil
            ))
        }
        return found
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

    private static func readCWD(pid: Int) -> String? {
        let output = runProcess("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"])
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    private struct ParentChain {
        var terminalPID: Int?
        var terminalApp: String?
    }

    private static let terminalApps: Set<String> = [
        "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)", "Code",
        "Cursor Helper", "Cursor Helper (Plugin)", "Cursor Helper (Renderer)", "Cursor",
        "Antigravity Helper", "Antigravity Helper (Plugin)", "Antigravity Helper (Renderer)", "Antigravity",
        "iTerm2", "iTerm", "Terminal", "Warp", "WarpTerminal", "ghostty", "Ghostty",
    ]

    private static func walkParentChain(from pid: Int) -> ParentChain {
        var chain = ParentChain()
        var current: Int? = pid
        for _ in 0..<12 {
            guard let next = current, next > 1 else { break }
            let comm = runProcess("/bin/ps", ["-p", "\(next)", "-o", "comm="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = (comm as NSString).lastPathComponent
            if terminalApps.contains(base) {
                chain.terminalPID = next
                chain.terminalApp = base
                return chain
            }
            let ppidStr = runProcess("/bin/ps", ["-p", "\(next)", "-o", "ppid="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current = Int(ppidStr)
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
            tabName: tabName ?? self.tabName
        )
    }
}
