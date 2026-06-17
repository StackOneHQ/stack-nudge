import Foundation

// Shared client for the running `agy` CLI's local loopback Connect-RPC
// (`exa.language_server_pb.LanguageServerService` — the Codeium/Windsurf
// "Cascade" language server; no public proto, ~256 methods embedded in the
// agy binary). agy serves it on two 127.0.0.1 ports (one HTTP, one HTTPS);
// we POST to the HTTP one — no TLS, no CSRF, no auth (the running agy is
// already signed in; loopback only, nothing leaves the machine).
enum AntigravityLocalServer {

    // Metadata envelope every method expects.
    static let metadataBody =
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        return URLSession(configuration: cfg)
    }()

    // POST a unary method and return the 200 JSON body, or nil. Synchronous
    // (blocks via a semaphore) — only call off the main thread.
    static func call(_ method: String, body: String = metadataBody) -> Data? {
        for port in listeningPorts() {
            if let data = request(method: method, body: body, port: port) { return data }
        }
        return nil
    }

    private static func request(method: String, body: String, port: Int) -> Data? {
        guard let url = URL(string:
            "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = body.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        session.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        // Backstop above URLSession's own resource timeout (6s) so the request's
        // completion handler is what releases the wait — not a shorter deadline
        // that returns while the dataTask is still running.
        _ = semaphore.wait(timeout: .now() + 8)
        return status == 200 ? payload : nil
    }

    // Loopback listen ports of the running `agy` process. Empty when not running.
    private static func listeningPorts() -> [Int] {
        let output = ProcessOutput.read(
            "/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-c", "agy"])
        var ports: Set<Int> = []
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: #"127\.0\.0\.1:\d+"#, options: .regularExpression),
                  let port = Int(line[range].split(separator: ":").last ?? "") else { continue }
            ports.insert(port)
        }
        return Array(ports)
    }

    // MARK: - Session status

    struct LiveStatus: Equatable {
        let status: String        // "busy" | "idle"
        let lastActivityAt: Date?
    }

    // Live busy/idle per workspace, from GetAllCascadeTrajectories. Keyed by the
    // absolute workspace path (file:// stripped) so SessionStore can match it to
    // a running agy session by cwd. When a workspace has several trajectories,
    // the most-recently-modified one wins (that's the active conversation).
    static func liveStatusByWorkspace() -> [String: LiveStatus] {
        guard let data = call("GetAllCascadeTrajectories"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summaries = json["trajectorySummaries"] as? [String: Any]
        else { return [:] }

        var best: [String: (modified: Date, status: LiveStatus)] = [:]
        for value in summaries.values {
            guard let summary = value as? [String: Any],
                  let rawStatus = summary["status"] as? String,
                  let status = busyIdle(rawStatus),
                  let workspace = workspacePath(summary) else { continue }
            let modified = date(summary["lastModifiedTime"]) ?? .distantPast
            let activity = date(summary["lastUserInputTime"]) ?? date(summary["lastModifiedTime"])
            if let existing = best[workspace], existing.modified >= modified { continue }
            best[workspace] = (modified, LiveStatus(status: status, lastActivityAt: activity))
        }
        return best.mapValues { $0.status }
    }

    // Map the cascade run-status enum to the same busy/idle vocabulary the
    // Claude sidecar uses, so both flow through one rendering path.
    private static func busyIdle(_ raw: String) -> String? {
        switch raw {
        case "CASCADE_RUN_STATUS_BUSY",
             "CASCADE_RUN_STATUS_RUNNING",
             "CASCADE_RUN_STATUS_CANCELING":
            return "busy"
        case "CASCADE_RUN_STATUS_IDLE":
            return "idle"
        default:
            return nil
        }
    }

    private static func workspacePath(_ summary: [String: Any]) -> String? {
        guard let workspaces = summary["workspaces"] as? [[String: Any]],
              let uri = workspaces.first?["workspaceFolderAbsoluteUri"] as? String
        else { return nil }
        return uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static func date(_ any: Any?) -> Date? {
        guard let string = any as? String else { return nil }
        return iso.date(from: string) ?? isoNoFrac.date(from: string)
    }
}
