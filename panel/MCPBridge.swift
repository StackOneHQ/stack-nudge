import Darwin
import Foundation

// `stack-nudge --mcp`: what an MCP client launches. It speaks no MCP itself.
// It tells the running app who launched it, then relays JSON-RPC lines
// between the client's stdio and ~/.stack-nudge/mcp.sock until either side
// closes, so the server lives in one place, the app (docs/design/local-mcp.md,
// "Transport").
//
//     claude mcp add stack-nudge -- ~/Applications/StackNudge.app/Contents/MacOS/stack-nudge --mcp
enum MCPBridge {

    static let flag = "--mcp"

    static func runIfAsked() {
        guard CommandLine.arguments.contains(flag) else { return }
        exit(run(socketPath: MCPServer.defaultSocketPath))
    }

    // The first line on the socket: what the bridge can tell about its client
    // from its own process. The app trusts this rather than anything a model
    // says, because it comes from the process the client launched.
    static func hello(environment: [String: String] = ProcessInfo.processInfo.environment,
                      parentPID: Int32 = getppid()) -> [String: Any] {
        var hello: [String: Any] = ["type": "hello", "parentPid": Int(parentPID)]
        if let session = environment["CLAUDE_CODE_SESSION_ID"], !session.isEmpty {
            hello["claudeSessionId"] = session
        }
        if let path = executablePath(forPID: parentPID), let app = appName(fromExecutablePath: path) {
            hello["parentApp"] = app
            if let bundleID = bundleID(fromExecutablePath: path) { hello["parentBundleId"] = bundleID }
        }
        return hello
    }

    // "Claude" for /Applications/Claude.app/Contents/..., nil for a process
    // that isn't inside an app bundle (a CLI such as claude or codex).
    static func executablePath(forPID pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func bundleID(fromExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
    }

    static func appName(fromExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }

    // Exit status: 0 when either side closes normally.
    static func run(socketPath: String) -> Int32 {
        guard let socket = connect(to: socketPath) else {
            serveNotRunning()
            return 0
        }
        guard let helloLine = MCPProtocol.encode(hello()), writeAll(socket, helloLine) else { return 1 }
        let done = DispatchSemaphore(value: 0)
        let toApp = Thread {
            relay(from: STDIN_FILENO, to: socket)
            Darwin.shutdown(socket, SHUT_WR)
            done.signal()
        }
        let toClient = Thread {
            relay(from: socket, to: STDOUT_FILENO)
            done.signal()
        }
        toApp.start()
        toClient.start()
        // Either direction ending ends the bridge: the client went away, or the
        // app quit.
        done.wait()
        Darwin.close(socket)
        return 0
    }

    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in _ = memcpy(dst.baseAddress, src.baseAddress, bytes.count) }
        }
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    private static func relay(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(source, &chunk, chunk.count)
            if n <= 0 { return }
            guard writeAll(destination, Data(chunk[0..<n])) else { return }
        }
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    // MARK: - The app isn't running

    static let notRunning = "stack-nudge isn't running, so none of its tools are available. Open StackNudge "
        + "and restart this MCP server."

    // Answers the client so its startup doesn't fail, with no tools and a line
    // saying why. It never launches the app.
    private static func serveNotRunning() {
        var reader = MCPLineReader(fd: STDIN_FILENO)
        while let line = reader.next() {
            guard let message = MCPProtocol.parse(line),
                  let reply = notRunningReply(to: message),
                  let data = MCPProtocol.encode(reply)
            else { continue }
            writeAll(STDOUT_FILENO, data)
        }
    }

    static func notRunningReply(to message: [String: Any]) -> [String: Any]? {
        guard let id = MCPProtocol.requestID(of: message), let method = message["method"] as? String else { return nil }
        let info: [String: Any] = ["name": "stack-nudge", "version": "not running"]
        switch method {
        case "initialize":
            let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? ""
            let version = MCPProtocol.legacyVersions.contains(asked) ? asked : MCPProtocol.legacyVersions[0]
            return MCPProtocol.response(id: id, result: ["protocolVersion": version, "capabilities": ["tools": [:] as [String: Any]],
                                                         "serverInfo": info, "instructions": notRunning])
        case "server/discover":
            return MCPProtocol.response(id: id, result: ["resultType": "complete",
                                                         "supportedVersions": [MCPProtocol.currentVersion],
                                                         "capabilities": ["tools": [:] as [String: Any]],
                                                         "instructions": notRunning,
                                                         "_meta": [MCPProtocol.metaServerInfo: info]])
        case "ping":
            return MCPProtocol.response(id: id, result: [:])
        case "tools/list":
            return MCPProtocol.response(id: id, result: ["tools": [] as [Any], "resultType": "complete"])
        case "resources/list":
            return MCPProtocol.response(id: id, result: ["resources": [] as [Any], "resultType": "complete"])
        default:
            return MCPProtocol.error(id: id, code: MCPProtocol.methodNotFound, message: notRunning)
        }
    }
}
