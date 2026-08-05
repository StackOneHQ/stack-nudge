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
        // nullDevice rather than a Pipe nobody reads: an undrained pipe blocks
        // the child forever once it writes past the ~64KB buffer. Discarding
        // stderr is the same contract, without the hang.
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        // Drain before waiting — the reverse order deadlocks on large output.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Time-bounded variant. Returns nil on spawn failure or timeout (so the
    // caller can distinguish "ran and got empty stdout" from "never finished").
    // On timeout we send SIGTERM, wait briefly, then SIGKILL.
    // Optional cwd pins the child's working directory — used by the Claude CLI
    // probe so its session-jsonl files always land in a known, scrub-able dir.
    static func read(_ path: String, _ args: [String], timeout: TimeInterval, cwd: String? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice

        let exited = DispatchGroup()
        exited.enter()
        task.terminationHandler = { _ in exited.leave() }

        do { try task.run() } catch {
            // Balance the enter() — terminationHandler never fires if run() throws.
            exited.leave()
            return nil
        }

        // Drain stdout concurrently with the wait, never after it. Waiting for
        // exit first deadlocks any child that outgrows the ~64KB pipe buffer:
        // it blocks writing, we block waiting, and the timeout fires on a
        // command that was working fine. `ps -axo args=` clears 250KB on a
        // busy machine, which is how this emptied the whole sessions pane.
        let drained = DispatchGroup()
        var output = Data()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            output = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, task.isRunning {
                kill(task.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            // Death closes the child's write end, so the drain unblocks.
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        // EOF arrives when the write end closes at exit; the group's ordering
        // is what publishes `output` to this thread.
        guard drained.wait(timeout: .now() + timeout) != .timedOut else { return nil }
        return String(data: output, encoding: .utf8) ?? ""
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
