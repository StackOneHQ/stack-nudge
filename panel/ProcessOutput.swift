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
    // Optional env replaces (not merges into) the child's environment — tmux
    // needs a UTF-8 locale forced on it or it renders non-ASCII pane titles as
    // "_", so callers pass AppActivator.tmuxEnv(), which is the inherited
    // environment plus LC_ALL. nil inherits ours unchanged.
    static func read(_ path: String, _ args: [String], timeout: TimeInterval,
                     cwd: String? = nil, env: [String: String]? = nil) -> String? {
        guard let completion = run(path, args, timeout: timeout, cwd: cwd, env: env),
              // Incomplete output is not output. nil has always meant "don't
              // trust this", and a caller reading a string has no way to tell a
              // short answer from a wrong one.
              !completion.truncated
        else { return nil }
        return completion.output
    }

    // What the child actually did. `read` is this minus the exit status, which
    // most callers don't want: a probe that prints nothing useful is the same
    // failure whether it exited 0 or 1. Extensions do want it — a non-zero exit
    // is how a script says "I couldn't", and that reads differently from stdout
    // that didn't parse.
    struct Completion: Equatable {
        let status: Int32
        let output: String
        // A signalled child reports the signal number in `status` — not an exit
        // code, and not 128+n. Without this flag a SIGSEGV reads as "exited 11".
        let signalled: Bool
        // The child exited but EOF never came, so `output` may be missing the
        // tail. Callers that parse permissively need this: a truncated
        // `ps -axo args=` reads as a perfectly valid, shorter session list, and
        // losing sessions silently is worse than failing outright.
        let truncated: Bool

        init(status: Int32, output: String, signalled: Bool = false,
             truncated: Bool = false) {
            self.status = status
            self.output = output
            self.signalled = signalled
            self.truncated = truncated
        }
    }

    // How long to keep reading after the child is gone. Once it has exited, a
    // pipe still held open means a *grandchild* inherited stdout — an extension
    // that backgrounded something — not a slow child. Waiting the full timeout
    // there turned a successful run into a fabricated timeout.
    static let drainGrace: TimeInterval = 1

    // Ceiling on what one child may print. `ps -axo args=` clears 250KB on a
    // busy machine and an extension document is a few KB, so this is generous
    // by a wide margin while still bounding a runaway script.
    static let maxOutputBytes = 8 * 1024 * 1024

    static func run(_ path: String, _ args: [String], timeout: TimeInterval,
                    cwd: String? = nil, env: [String: String]? = nil) -> Completion? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if let cwd { task.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { task.environment = env }
        let outPipe = Pipe()
        task.standardOutput = outPipe
        // nullDevice rather than a Pipe nobody reads: an undrained pipe blocks
        // the child forever once it writes past the ~64KB buffer.
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
        // command that was working fine. `ps -axo args=` clears 250KB on a busy
        // machine, which is how this emptied the whole sessions pane.
        //
        // A read *source* rather than readDataToEndOfFile, because a blocking
        // read on a pool thread can never be abandoned. EOF needs every holder
        // of the write end to close it, and a child that backgrounds anything
        // hands that end to a grandchild we never see — so the read blocked
        // forever, leaking a thread and the pipe with it. At around 64 of those
        // the global utility pool is starved and unrelated work stops being
        // scheduled: the sessions poll, the quota probes, everything.
        //
        // The fd is duplicated so the source owns a descriptor it can close in
        // its cancel handler; the Pipe's own FileHandle closes the original. A
        // dup shares the file description, so reading from it drains the same
        // pipe.
        let readFD = dup(outPipe.fileHandleForReading.fileDescriptor)
        guard readFD >= 0 else {
            // Only reachable under fd exhaustion — which is this function's own
            // failure mode, so it is exactly when it will happen. Returning here
            // with the child running would leave an orphan and a leaked group.
            terminateTree(task, exited: exited)
            try? outPipe.fileHandleForReading.close()
            return nil
        }
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)

        let lock = NSLock()
        var output = Data()
        // EOF is the only proof the output is whole. The drain group merely says
        // the source stopped, which it also does when we cancel it at the
        // deadline or when the ceiling is hit.
        var sawEOF = false
        // Distinct from sawEOF: the child may close cleanly having printed more
        // than we were willing to keep, which is complete but not whole.
        var overflowed = false
        let drained = DispatchGroup()
        drained.enter()

        let source = DispatchSource.makeReadSource(fileDescriptor: readFD,
                                                   queue: .global(qos: .utility))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { raw in
                Foundation.read(readFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                lock.lock()
                // Stop *storing* at the ceiling, but keep reading. A script that
                // prints for as long as the budget allows would otherwise take
                // the app's memory with it, and no legitimate document is
                // anywhere near this size — but abandoning the pipe would block
                // the child on a full buffer and turn its own overrun into a
                // timeout, so the bytes are read and dropped.
                let room = maxOutputBytes - output.count
                if room > 0 { output.append(contentsOf: buffer[0..<min(count, room)]) }
                if room < count { overflowed = true }
                lock.unlock()
            } else if count == 0 {
                lock.lock(); sawEOF = true; lock.unlock()
                source.cancel()
            } else if errno != EINTR && errno != EAGAIN {
                source.cancel()
            }
        }
        // Runs exactly once, whether cancellation came from EOF or from us. It
        // does not close the fd: the final drain below still needs it, and
        // closing under an in-flight read would race.
        source.setCancelHandler { drained.leave() }
        source.resume()

        // One deadline for the whole call. The old shape waited `timeout` for
        // exit and then a further `timeout` for the drain, so the worst case was
        // double what the budget — and the user-facing message — claimed.
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            terminateTree(task, exited: exited)
        }
        // Stop the source and take the fd back, so the last of the pipe can be
        // read without racing the handler.
        source.cancel()
        _ = drained.wait(timeout: .now() + drainGrace)

        // The child has exited (or been killed), so everything *it* wrote is
        // already in the pipe buffer — a read that reaches EAGAIN has therefore
        // seen all of it, whether or not EOF ever arrives. That is what makes an
        // idle background helper holding the write end harmless: EOF alone
        // cannot distinguish "complete, helper idle" from "incomplete, helper
        // still writing", but quiescence can.
        //
        // Bounded, because a helper that keeps writing would otherwise keep this
        // loop fed forever. Hitting that bound is the genuinely unknowable case,
        // and it is the one that gets flagged.
        let quiesced = drainRemainder(readFD, into: &output, lock: lock,
                                      deadline: .now() + drainGrace, sawEOF: &sawEOF,
                                      overflowed: &overflowed)
        close(readFD)

        lock.lock()
        let collected = output
        let complete = quiesced && !overflowed
        lock.unlock()

        // Close the Pipe's own descriptors rather than waiting for its
        // FileHandles to deallocate. They don't, promptly — measured one FIFO
        // left open per call, which is the leak that eventually starves the
        // pool. The write end is already closed by Foundation during spawn
        // (EOF could never arrive otherwise), so that one throws and is
        // swallowed; the read end is the one that accumulates.
        try? outPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()

        guard !timedOut else { return nil }
        return Completion(status: task.terminationStatus,
                          output: String(data: collected, encoding: .utf8) ?? "",
                          signalled: task.terminationReason == .uncaughtSignal,
                          truncated: !complete)
    }

    // Reads what is left in the pipe until it goes quiet, EOF arrives, or the
    // deadline passes. Returns whether it reached a point where the child's own
    // output is known to be complete.
    private static func drainRemainder(_ fd: Int32,
                                       into output: inout Data,
                                       lock: NSLock,
                                       deadline: DispatchTime,
                                       sawEOF: inout Bool,
                                       overflowed: inout Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while DispatchTime.now() < deadline {
            let count = buffer.withUnsafeMutableBytes { raw in
                Foundation.read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                lock.lock()
                let room = maxOutputBytes - output.count
                if room > 0 { output.append(contentsOf: buffer[0..<min(count, room)]) }
                if room < count { overflowed = true }
                lock.unlock()
            } else if count == 0 {
                sawEOF = true
                return true
            } else if errno == EAGAIN {
                return true          // nothing left that the child could have written
            } else if errno != EINTR {
                return false
            }
        }
        return false
    }

    // SIGTERM, a moment, then SIGKILL — to the child's whole process group, not
    // just the child. Foundation spawns into a new group, so a script that
    // backgrounds `curl &` and then hangs used to leave the curl running after
    // every timeout, forever. The group is read back rather than assumed, and
    // our own is never signalled: killpg on the wrong id would take out the app.
    //
    // Waiting on the termination group rather than polling isRunning, so a child
    // that refuses to die costs a bounded wait instead of a spinning thread.
    private static func terminateTree(_ task: Process, exited: DispatchGroup) {
        let pid = task.processIdentifier
        let group = getpgid(pid)
        let ourGroup = getpgrp()

        // Nothing is signalled once the child is gone. getpgid returns -1 for a
        // reaped pid, and falling through to kill(pid, …) on that would signal
        // whatever has since been given the number. The window is microseconds
        // and only on a timeout, but this function already takes care never to
        // signal our own group, so leaving the neighbouring case open would be
        // inconsistent rather than pragmatic.
        func signalAll(_ signal: Int32) {
            guard task.isRunning else { return }
            if group > 0, group != ourGroup {
                killpg(group, signal)
            } else if group != -1 {
                kill(pid, signal)
            }
        }

        signalAll(SIGTERM)
        guard exited.wait(timeout: .now() + 1) == .timedOut else { return }
        signalAll(SIGKILL)
        _ = exited.wait(timeout: .now() + 1)
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
    // A launchd-spawned .app gets a minimal PATH, so the binary is resolved from
    // absolute candidates rather than looked up. Version managers (volta, mise,
    // asdf, bun) and custom npm prefixes all land outside this list, which is
    // what STACKNUDGE_CLAUDE_PATH is for.
    static func claude() -> String? {
        if let override = ConfigFile.read()["STACKNUDGE_CLAUDE_PATH"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.local/share/mise/shims/claude",
            "\(home)/.asdf/shims/claude",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
