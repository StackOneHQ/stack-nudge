import Foundation

// Tiny helper for shelling out and reading stdout. Used by SessionStore
// (ps/lsof) and the terminal integrations (ps -eww). Centralised so
// every caller gets the same "swallow stderr, return empty string on
// any failure" contract — we never want a flaky subprocess to surface
// as a panel crash.
enum ProcessOutput {
    static func read(_ path: String, _ args: [String]) -> String {
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

    // Time-bounded variant. Returns nil on spawn failure or timeout (so the
    // caller can distinguish "ran and got empty stdout" from "never finished").
    // On timeout we send SIGTERM, wait briefly, then SIGKILL — the pipe's
    // writer end closes either way so the readDataToEndOfFile below can't hang.
    // Optional cwd pins the child's working directory — used by the Claude CLI
    // probe so its session-jsonl files always land in a known, scrub-able dir.
    static func read(_ path: String, _ args: [String], timeout: TimeInterval, cwd: String? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        let group = DispatchGroup()
        group.enter()
        task.terminationHandler = { _ in group.leave() }

        do { try task.run() } catch {
            // Balance the enter() — terminationHandler never fires if run() throws.
            group.leave()
            return nil
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if group.wait(timeout: .now() + 1) == .timedOut, task.isRunning {
                kill(task.processIdentifier, SIGKILL)
                _ = group.wait(timeout: .now() + 1)
            }
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Resolve the `gh` CLI from common install locations. A launchd-spawned app
    // has a minimal PATH, so we probe paths directly rather than relying on env.
    // nil ⇒ not installed (callers no-op). Used for release checks/downloads.
    static func gh() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Resolve the `claude` CLI. Same minimal-PATH rationale as gh(). The
    // native installer (current default) symlinks into ~/.local/bin; the
    // ~/.claude/local fallback covers the older curl-bash/migration installer.
    static func claude() -> String? {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
