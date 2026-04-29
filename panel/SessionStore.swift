import Foundation
import SwiftUI

enum SessionStatus: Equatable {
    case active
    case finished(at: Date)
}

struct Session: Identifiable, Equatable {
    let id: Int           // pid — pids are reusable but stable for this process's lifetime
    let pid: Int
    let agent: String     // "claude" | "gemini" | "codex"
    let projectPath: String?
    let projectName: String?
    let terminalPID: Int?
    let terminalApp: String?
    let elapsed: String?  // ps etime — display-only
    var customName: String?
    var status: SessionStatus
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

    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "stack-nudge.sessions", qos: .utility)
    private static let agentBinaries: Set<String> = ["claude", "gemini", "codex"]
    private static let pollInterval: TimeInterval = 3.0

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
        if let idx = sessions.firstIndex(where: { $0.pid == pid }) {
            sessions[idx].customName = (name?.isEmpty ?? true) ? nil : name
        }
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
            let found = Self.discover()
            DispatchQueue.main.async { [weak self] in
                self?.merge(found)
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

        // Update / mark-finished existing sessions in place so customName persists.
        for var existing in sessions {
            if let live = foundByPID[existing.pid] {
                existing = live.with(customName: existing.customName, status: .active)
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

        // Add genuinely new sessions.
        let knownPIDs = Set(next.map(\.pid))
        for session in found where !knownPIDs.contains(session.pid) {
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
                status: .active
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

        // Node / Deno-hosted agents: inspect later tokens for known script paths.
        if baseName == "node" || baseName == "deno" || baseName == "bun" {
            if args.range(of: #"\bgemini(-cli)?\b"#, options: .regularExpression) != nil {
                return "gemini"
            }
            if args.range(of: #"\bcodex(-cli)?\b"#, options: .regularExpression) != nil {
                return "codex"
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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension Session {
    func with(customName: String?, status: SessionStatus) -> Session {
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
            status: status
        )
    }
}
