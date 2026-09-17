import Foundation

// Live account rate limits from `codex app-server` — spawn it, speak
// line-delimited JSON-RPC over stdio, ask `account/rateLimits/read`, exit.
// Account-wide, so unlike the rollout reader it sees quota spent on the web, in
// the IDE or on another machine. See CodexQuotaProbe for why that matters.
//
// Going through the binary rather than the HTTP endpoint it fronts is
// deliberate: OpenAI refresh tokens are single-use, so a second refresher
// racing the CLI can lock the user out of both.
enum CodexAppServer {

    // Room for a cold spawn; the exchange itself measured 0.59s.
    static let timeout: TimeInterval = 10

    enum Result: Equatable {
        case ok(CodexQuotaSnapshot)
        // Answered with nothing usable — API-key auth reports no limits, and an
        // outage looks the same from here. Both are "nothing to show".
        case empty
        // Spawned and died with no stdout: the shape an unknown subcommand
        // makes, so the caller latches this path off for the process.
        case unsupported
        case cliMissing
    }

    static func fetch(timeout: TimeInterval = CodexAppServer.timeout) -> Result {
        guard let path = ProcessOutput.codex() else { return .cliMissing }
        guard let response = exchange(path: path, timeout: timeout) else { return .unsupported }
        guard let snapshot = snapshot(fromResult: response) else { return .empty }
        return .ok(snapshot)
    }

    // MARK: - Protocol

    // initialize → initialized → the read. `initialized` is a notification, so
    // it carries no id and gets no reply.
    static func initializeRequest(version: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":"#
            + #"{"name":"stack-nudge","version":"\#(version)"}}}"#
    }

    static let initializedNotification = #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#

    // supportsLunaReserve records experiment exposure and is meant for clients
    // that can act on a Reserve fallback, not passive readers.
    // excludeResetCreditDetails skips a backend lookup we never render — what
    // the Codex TUI sets on its own periodic polls.
    static let rateLimitsRequest =
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read",""#
        + #"params":{"supportsLunaReserve":false,"excludeResetCreditDetails":true}}"#

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Transport

    // Returns the `result` of response id 2, or nil if the child never produced
    // a usable line. Blocking: the caller is already on a serial probe queue, so
    // a watchdog that kills the child at the deadline bounds it — the kill
    // closes the pipe, which unblocks the read.
    private static func exchange(path: String, timeout: TimeInterval) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["app-server"]
        let stdin = Pipe()
        let stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        // As in ProcessOutput: an undrained pipe blocks the child past ~64KB.
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
        // An unknown subcommand exits between spawn and write, and writing to
        // a closed pipe raises SIGPIPE.
        do { try pipe.fileHandleForWriting.write(contentsOf: data) } catch { return false }
        return true
    }

    // Skips the notifications the server interleaves. nil on EOF or an error
    // reply.
    private static func awaitResponse(id: Int, reader: LineReader) -> [String: Any]? {
        while let line = reader.next() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id
            else { continue }
            return object["result"] as? [String: Any]
        }
        return nil
    }

    // `availableData` blocks until the child writes, and returns empty at EOF —
    // including the EOF the watchdog manufactures by killing it.
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

    // `rateLimits` is the backward-compatible view and mirrors whichever bucket
    // the account meters against. `rateLimitsByLimitId` splits the same numbers
    // per metered id; unused until the UI has somewhere to put them.
    static func snapshot(fromResult result: [String: Any]) -> CodexQuotaSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let snapshot = CodexQuotaSnapshot(
            primary: tier(limits["primary"]),
            secondary: tier(limits["secondary"]),
            planType: limits["planType"] as? String)
        return snapshot.hasTier ? snapshot : nil
    }

    // Keeps a window whose reset has passed, unlike the rollout reader — there
    // the guard catches a stale file, here the server just told us, so blanking
    // the row on clock skew would be the wrong call.
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
