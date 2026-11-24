import Foundation

// The MCP server's socket, ~/.stack-nudge/mcp.sock (0600). It sits beside
// panel.sock rather than sharing it: panel.sock reads each connection to EOF
// one at a time, and a bridge holds its connection open for as long as its
// client runs. Each connection gets its own reader thread and a writer queue,
// so a client that stops reading can't block the main thread that sends it
// change notifications. See docs/design/local-mcp.md.
final class MCPServer {

    // A client that stops reading is dropped once this much is queued for it.
    static let maxQueuedBytes = 4 << 20

    private let socketPath: String
    private let context: MCPContext
    // What every connection's event streams and polls read from.
    let events = MCPEventHub()
    // Who changed a setting, for settings.changed: an MCP client's write
    // names it here just before the change watcher sees the new value.
    let attribution = MCPAttribution()
    private var serverFD: Int32 = -1
    private var boundInode: ino_t?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: MCPConnection] = [:]

    init(socketPath: String, context: MCPContext) {
        self.socketPath = socketPath
        self.context = context
    }

    static var defaultSocketPath: String {
        (("~/.stack-nudge" as NSString).expandingTildeInPath as NSString).appendingPathComponent("mcp.sock")
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in _ = memcpy(dst.baseAddress, src.baseAddress, pathBytes.count) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        chmod(socketPath, 0o600)
        var st = stat()
        if stat(socketPath, &st) == 0 { boundInode = st.st_ino }
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        serverFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "stack-nudge.mcp.accept"
        thread.start()
    }

    // As EventListener does: only unlink the socket file when it's still the
    // one this process bound, so an app replacing us after an update keeps its
    // own.
    func stop() {
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        lock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.close() }
        guard let want = boundInode else { return }
        var st = stat()
        guard stat(socketPath, &st) == 0, st.st_ino == want else { return }
        unlink(socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let connection = MCPConnection(fd: client, context: context, events: events) { [weak self] closed in
                self?.forget(closed)
            }
            lock.lock()
            connections[ObjectIdentifier(connection)] = connection
            lock.unlock()
            connection.start()
        }
    }

    private func forget(_ connection: MCPConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    // Every connected client's session, for change notifications.
    var sessions: [MCPSession] {
        lock.lock()
        defer { lock.unlock() }
        return connections.values.compactMap(\.session)
    }

    func resourcesUpdated(_ uris: Set<String>) {
        guard !uris.isEmpty else { return }
        sessions.forEach { $0.resourcesUpdated(uris) }
    }

    func toolsListChanged() {
        sessions.forEach { $0.toolsListChanged() }
    }

    // Records an event and hands it to every stream that matches. Main thread,
    // from wherever the app notices the thing happening.
    func emit(_ name: String, data: [String: Any], eventID: String? = nil) {
        let occurrence = events.emit(name, data: data, eventID: eventID)
        sessions.forEach { $0.deliver(occurrence) }
    }

    func eventsListChanged() {
        sessions.forEach { $0.eventsListChanged() }
    }
}

// One bridge's connection: the hello line, then JSON-RPC lines both ways.
final class MCPConnection {

    private let fd: Int32
    private let context: MCPContext
    private let events: MCPEventHub
    private let onClose: (MCPConnection) -> Void
    private let writer = DispatchQueue(label: "stack-nudge.mcp.writer")
    private let lock = NSLock()
    private var queuedBytes = 0
    private var closed = false
    private(set) var session: MCPSession?

    init(fd: Int32, context: MCPContext, events: MCPEventHub, onClose: @escaping (MCPConnection) -> Void) {
        self.fd = fd
        self.context = context
        self.events = events
        self.onClose = onClose
    }

    func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "stack-nudge.mcp.connection"
        thread.start()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        session?.close()
        Darwin.shutdown(fd, SHUT_RDWR)
        writer.async { [fd] in Darwin.close(fd) }
        onClose(self)
    }

    private func readLoop() {
        var reader = MCPLineReader(fd: fd)
        defer { close() }
        guard let first = reader.next(), let hello = MCPProtocol.parse(first), hello["type"] as? String == "hello"
        else { return }
        let session = MCPSession(context: context, events: events, caller: .fromHello(hello)) { [weak self] message in
            self?.write(message)
        }
        lock.lock()
        self.session = session
        lock.unlock()
        while let line = reader.next() {
            guard let message = MCPProtocol.parse(line) else {
                write(MCPProtocol.error(id: nil, code: MCPProtocol.parseError, message: "Parse error"))
                continue
            }
            session.receive(message)
        }
    }

    private func write(_ message: [String: Any]) {
        guard let data = MCPProtocol.encode(message) else { return }
        lock.lock()
        if closed || queuedBytes + data.count > MCPServer.maxQueuedBytes {
            lock.unlock()
            close()
            return
        }
        queuedBytes += data.count
        lock.unlock()
        writer.async { [weak self, fd] in
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            guard let self else { return }
            self.lock.lock()
            self.queuedBytes -= data.count
            self.lock.unlock()
        }
    }
}

// Newline-delimited lines from a file descriptor, capped at
// MCPProtocol.maxLineBytes: a longer line ends the connection.
struct MCPLineReader {
    let fd: Int32
    private var buffer = Data()
    private var done = false

    init(fd: Int32) { self.fd = fd }

    mutating func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return Data(line)
            }
            if done || buffer.count > MCPProtocol.maxLineBytes { return nil }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                done = true
                if buffer.isEmpty { return nil }
                let last = buffer
                buffer.removeAll()
                return last
            }
            buffer.append(chunk, count: n)
        }
    }
}

// Which client last changed which setting, for a few seconds: long enough for
// the debounced change watcher to credit the change, short enough that a later
// edit in Settings isn't credited to it.
final class MCPAttribution {
    private let lock = NSLock()
    private var writes: [String: (by: String, at: Date)] = [:]

    func note(_ key: String, by: String, at: Date = Date()) {
        lock.lock()
        writes[key] = (by, at)
        lock.unlock()
    }

    func take(_ key: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let write = writes.removeValue(forKey: key), now.timeIntervalSince(write.at) < 5 else { return nil }
        return write.by
    }
}
