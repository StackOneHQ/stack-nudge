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

        if listen(serverFD, 16) != 0 {
            let err = errno
            close(serverFD); serverFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }

        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
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

        for line in buffer.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            guard let dto = try? decoder.decode(NudgeEventDTO.self, from: line) else {
                continue
            }
            let event = dto.toNudgeEvent()
            DispatchQueue.main.async { [weak self] in
                self?.store.append(event)
            }
        }
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
    let fifo_path: String?
    let voice_message: String?
    let sound_name: String?
    let bypass_mute: Bool?

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
            fifoPath: fifo_path,
            voiceMessage: voice_message,
            soundName: sound_name,
            bypassMute: bypass_mute ?? false
        )
    }
}
