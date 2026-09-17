import Foundation

// Reads Codex's account rate limits from `codex app-server`, the JSON-RPC
// service the Codex TUI and IDE extension both sit on. Spawn it, speak
// line-delimited JSON-RPC over stdio, ask `account/rateLimits/read`, exit.
//
// Why this exists alongside the rollout reader in CodexQuotaProbe: the rollout
// only advances when the CLI runs a turn on this machine. Everything spent on
// the web, in the IDE, in the desktop app or on another Mac is invisible to it,
// and once its 5-hour window expires the reader correctly discards it and shows
// nothing at all. The app-server returns live account state instead, which is
// the same number whichever surface spent it.
//
// It also keeps the property the rollout reader had and a direct HTTP call would
// lose: the `codex` binary owns the credential and makes the network call, so
// this process never reads a token and never refreshes one. That last part
// matters more than it looks — OpenAI refresh tokens are single-use, so a
// second refresher racing the CLI can lock the user out of both.
enum CodexAppServer {

    // Enough for a cold spawn on a busy machine; the exchange itself measured
    // 0.59s end to end (0.03s handshake, 0.56s read).
    static let timeout: TimeInterval = 10

    enum Result: Equatable {
        case ok(CodexQuotaSnapshot)
        // The binary answered but gave us nothing usable — API-key auth reports
        // no limits, and a genuine outage looks the same from here. Both mean
        // "nothing to show", which is what the Usage tab already does with a nil
        // Codex snapshot, so neither is worth an error row.
        case empty
        // Spawned and died without a single line of stdout. That is the shape an
        // unknown subcommand makes, so the caller latches this path off for the
        // rest of the process rather than paying for a doomed spawn every tick.
        case unsupported
        // No `codex` on PATH. Not a Codex user; stay silent.
        case cliMissing
    }

    static func fetch(timeout: TimeInterval = CodexAppServer.timeout) -> Result {
        guard let path = ProcessOutput.codex() else { return .cliMissing }
        guard let response = exchange(path: path, timeout: timeout) else { return .unsupported }
        guard let snapshot = snapshot(fromResult: response) else { return .empty }
        return .ok(snapshot)
    }

    // MARK: - Protocol

    // The handshake is initialize → initialized → the read. `initialized` is a
    // notification, so it carries no id and gets no reply.
    static func initializeRequest(version: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":"#
            + #"{"name":"stack-nudge","version":"\#(version)"}}}"#
    }

    static let initializedNotification = #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#

    // `supportsLunaReserve` is an opt-in for clients that can act on a Reserve
    // fallback; Codex's own source reserves it for those and says passive usage
    // readers should leave it off, since setting it records experiment exposure.
    // `excludeResetCreditDetails` skips a second backend lookup we never render —
    // the Codex TUI sets exactly this on its own periodic polls.
    static let rateLimitsRequest =
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read",""#
        + #"params":{"supportsLunaReserve":false,"excludeResetCreditDetails":true}}"#

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Transport

    // Runs the exchange and returns the `result` object of response id 2. nil
    // means the child never produced a line we could use — see .unsupported.
    //
    // Blocking by design: the only caller is already on CodexQuotaProbe's serial
    // probe queue, so a watchdog that kills the child at the deadline is enough
    // to bound it. Killing closes the pipe, which is what unblocks the read.
    private static func exchange(path: String, timeout: TimeInterval) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        // Same contract as ProcessOutput: an undrained stderr pipe would block
        // the child once it wrote past the buffer.
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            guard finished.wait(timeout: .now() + timeout) == .timedOut else { return }
            task.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut, task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
        defer {
            finished.signal()
            if task.isRunning { task.terminate() }
        }

        let reader = LineReader(handle: stdout.fileHandleForReading)
        guard write(initializeRequest(version: clientVersion), to: stdin),
              awaitResponse(id: 1, reader: reader) != nil,
              write(initializedNotification, to: stdin),
              write(rateLimitsRequest, to: stdin)
        else { return nil }
        return awaitResponse(id: 2, reader: reader)
    }

    private static func write(_ line: String, to pipe: Pipe) -> Bool {
        guard let data = (line + "\n").data(using: .utf8) else { return false }
        // The child can exit between spawn and write (an unknown subcommand
        // does exactly that), and writing to a closed pipe raises SIGPIPE.
        do { try pipe.fileHandleForWriting.write(contentsOf: data) } catch { return false }
        return true
    }

    // Reads lines until one is a JSON-RPC response carrying `id`, ignoring the
    // notifications the server interleaves. nil on EOF, an error reply, or a
    // response whose body isn't an object.
    private static func awaitResponse(id: Int, reader: LineReader) -> [String: Any]? {
        while let line = reader.next() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id
            else { continue }
            return object["result"] as? [String: Any]
        }
        return nil
    }

    // Splits the child's stdout into newline-delimited frames. `availableData`
    // blocks until the child writes or the pipe closes, and returns empty at
    // EOF — including the EOF the watchdog manufactures by killing it.
    private final class LineReader {
        private let handle: FileHandle
        private var buffer = Data()

        init(handle: FileHandle) { self.handle = handle }

        func next() -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if line.isEmpty { continue }
                    return Data(line)
                }
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
            }
        }
    }

    // MARK: - Parsing

    // Maps GetAccountRateLimitsResponse onto the same snapshot the rollout
    // reader produces, so the Usage tab can't tell which source it came from.
    //
    // `rateLimits` is documented as the backward-compatible single-bucket view
    // and mirrors whichever bucket the account meters against, which is the one
    // we want; `rateLimitsByLimitId` splits the same numbers per metered id and
    // is left alone until there is something in the UI to spend it on.
    static func snapshot(fromResult result: [String: Any]) -> CodexQuotaSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let snapshot = CodexQuotaSnapshot(
            primary: tier(limits["primary"]),
            secondary: tier(limits["secondary"]),
            planType: limits["planType"] as? String)
        return snapshot.hasTier ? snapshot : nil
    }

    // Unlike the rollout reader, this deliberately keeps a window whose reset has
    // already passed. There the guard is what stops a stale file being read as
    // current; here the server just told us, so the honest thing is to show it
    // and let the countdown read zero rather than blank the row on clock skew.
    private static func tier(_ raw: Any?) -> QuotaTier? {
        guard let dict = raw as? [String: Any],
              let used = (dict["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resetsAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        let windowLength = (dict["windowDurationMins"] as? NSNumber)
            .map { $0.doubleValue * 60 }
        return QuotaTier(utilization: used, resetsAt: resetsAt, windowLength: windowLength)
    }
}
