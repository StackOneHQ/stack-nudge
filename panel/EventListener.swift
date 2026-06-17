import Foundation

// Unix-domain socket server. notify.sh writes one JSON object per connection
// (newline-terminated). The wire shape mirrors the existing CLI args to
// stack-nudge.app — same fields, just JSON-serialised.
final class EventListener {

    // 64 KiB is two orders of magnitude above the largest realistic nudge
    // (a permission event quoting a Bash command). Anything above this is
    // either malicious or a bug; drop the connection rather than buffer.
    private static let maxPayloadBytes = 64 * 1024

    private let store: EventStore
    private let socketPath: String
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "stack-nudge.panel.listener")
    private let decoder = JSONDecoder()
    // Inode of the socket file we created in start(). Checked again in
    // stop() so we only unlink when the file on disk is still the one we
    // bound to — protects against the post-update race where the old
    // bundle's shutdown otherwise removes the new bundle's socket file.
    private var boundInode: ino_t?

    init(store: EventStore, socketPath: String) {
        self.store = store
        self.socketPath = socketPath
    }

    func start() throws {
        unlink(socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if serverFD < 0 { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= pathCapacity else {
            close(serverFD); serverFD = -1
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                _ = memcpy(dst.baseAddress, src.baseAddress, pathBytes.count)
            }
        }

        let bindStatus = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(serverFD, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindStatus != 0 {
            let err = errno
            close(serverFD); serverFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        chmod(socketPath, 0o600)

        // Stat after bind so stop() can verify we still own this file
        // before unlinking it. Avoids the post-update race where the old
        // bundle's terminate handler removes the new bundle's socket.
        var st = stat()
        if stat(socketPath, &st) == 0 {
            boundInode = st.st_ino
        }

        if listen(serverFD, 16) != 0 {
            let err = errno
            close(serverFD); serverFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        // Only remove the file if it's still the one we bound to. If a
        // successor process (post-update relaunch) has already replaced
        // it, our unlink would wipe their freshly-bound socket and break
        // event delivery for them.
        guard let want = boundInode else { return }
        var st = stat()
        guard stat(socketPath, &st) == 0, st.st_ino == want else { return }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            let client = accept(serverFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = read(fd, &chunk, chunkSize)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.count > Self.maxPayloadBytes { return }
        }
        guard !buffer.isEmpty else { return }

        for event in Self.parseEvents(buffer) {
            // Teach the VSCode integration about this event's window
            // before we dispatch — the Sessions tab's next poll will
            // pick up the new (ipcHook → window title) pairing.
            if let hook = event.ipcHook, !hook.isEmpty {
                VSCodeIntegration.shared.note(
                    ipcHook: hook,
                    windowTitle: event.windowTitle,
                    projectPath: event.projectPath
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.store.append(event)
            }
        }
    }

    // Pure parser: newline-split the wire buffer and decode each non-empty
    // line as a NudgeEvent. Malformed lines are silently skipped (drop the
    // bad line, keep the rest) — handleClient already enforced the payload
    // size limit upstream. Exposed for tests.
    static func parseEvents(_ buffer: Data) -> [NudgeEvent] {
        let decoder = JSONDecoder()
        var events: [NudgeEvent] = []
        for line in buffer.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            guard let dto = try? decoder.decode(NudgeEventDTO.self, from: line) else {
                continue
            }
            events.append(dto.toNudgeEvent())
        }
        return events
    }
}

private struct NudgeEventDTO: Decodable {
    let agent: String
    let event: String
    let title: String
    let message: String
    let project_path: String?
    let bundle_id: String?
    let window_title: String?
    let ipc_hook: String?
    let has_action_button: Bool?
    let timestamp: Double?
    let agent_pid: Int?
    let shell_pid: Int?
    let terminal_pid: Int?
    let terminal_app: String?
    let term_program: String?
    let session_id: String?
    let iterm_tab_name: String?
    let fifo_path: String?
    let voice_message: String?
    let sound_name: String?
    let bypass_mute: Bool?
    // Claude Code's session UUID (distinct from session_id, which is the
    // terminal/iTerm session id) and the path to its JSONL transcript.
    // Populated only for Claude Code hook events; nil for other agents.
    let claude_session_id: String?
    let transcript_path: String?

    // Only accept a fifo_path that looks like one of our permission FIFOs AND
    // is actually a FIFO on disk. The socket is a trust boundary: any same-uid
    // process that can write it could otherwise supply an arbitrary path, and
    // the panel's writeFIFO would then clobber a regular file or deliver a
    // fabricated allow/deny to the agent. We drop just the path (not the whole
    // event) on failure, so the nudge still shows but can't auto-resolve.
    private static func validatedFifoPath(_ path: String?) -> String? {
        guard let path,
              path.contains("/stack-nudge-perm."),
              (path as NSString).lastPathComponent == "fifo"
        else { return nil }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFIFO else { return nil }
        return path
    }

    func toNudgeEvent() -> NudgeEvent {
        NudgeEvent(
            agent: agent,
            kind: NudgeKind(rawWireValue: event),
            title: title,
            message: message,
            projectPath: project_path,
            bundleID: bundle_id,
            windowTitle: window_title,
            ipcHook: ipc_hook,
            hasActionButton: has_action_button ?? false,
            timestamp: timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            agentPID: agent_pid,
            shellPID: shell_pid,
            terminalPID: terminal_pid,
            terminalApp: terminal_app,
            termProgram: term_program,
            sessionID: session_id,
            itermTabName: iterm_tab_name,
            fifoPath: Self.validatedFifoPath(fifo_path),
            voiceMessage: voice_message,
            soundName: sound_name,
            bypassMute: bypass_mute ?? false,
            claudeSessionID: claude_session_id,
            transcriptPath: transcript_path
        )
    }
}
