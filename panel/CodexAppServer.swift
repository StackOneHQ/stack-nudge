import Foundation

// Live account rate limits from `codex app-server`: spawn it, speak
// line-delimited JSON-RPC over stdio, ask `account/rateLimits/read` and
// `account/read`, exit. Account-wide, so unlike the rollout reader it sees quota
// spent on the web, in the IDE or on another machine. See CodexQuotaProbe for
// why that matters. Both reads share the one spawn, which is the expensive part.
//
// Going through the binary rather than the HTTP endpoint it fronts is
// deliberate: OpenAI refresh tokens are single-use, so a second refresher
// racing the CLI can lock the user out of both.
enum CodexAppServer {

    // Room for a cold spawn; the exchange itself measured 0.59s.
    static let timeout: TimeInterval = 10

    // The account rides along on every case that got an answer: it names the
    // login on its card whether or not there were limits to show.
    enum Result: Equatable {
        case ok(CodexQuotaSnapshot, CodexAccount?)
        // Answered with nothing usable: API-key auth reports no limits, a
        // signed-out login is refused them, and an outage looks the same from
        // here. All are "nothing to show".
        case empty(CodexAccount?)
        // Spawned and died with no answer, or answered that it has no such
        // method: the shapes an old `codex` makes, so the caller latches this
        // path off for the process.
        case unsupported
        case cliMissing
    }

    // `codexHome` nil is the default login; any other runs with CODEX_HOME set
    // to it.
    static func fetch(codexHome: String? = nil, timeout: TimeInterval = CodexAppServer.timeout) -> Result {
        guard let path = ProcessOutput.codex() else { return .cliMissing }
        guard let replies = exchange(path: path, environment: environment(codexHome: codexHome),
                                     timeout: timeout)
        else { return .unsupported }
        return result(from: replies)
    }

    static func environment(codexHome: String?,
                            inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]? {
        ProcessOutput.environment(adding: "CODEX_HOME", value: codexHome, inherited: inherited)
    }

    // What the two replies add up to. A `codex` that predates `account/read`
    // refuses it, which costs the account line and nothing else.
    static func result(from replies: [Int: Reply]) -> Result {
        var account: CodexAccount?
        if case .result(let body)? = replies[accountRequestID] { account = Self.account(fromResult: body) }
        switch replies[rateLimitsRequestID] {
        case .result(let body)?:
            return snapshot(fromResult: body).map { .ok($0, account) } ?? .empty(account)
        case .error(let code)?:
            return code == methodNotFound ? .unsupported : .empty(account)
        case nil:
            return .unsupported
        }
    }

    enum Reply {
        case result([String: Any])
        case error(code: Int?)
    }

    // JSON-RPC's "no such method". Any other refusal (Codex answers a signed-out
    // login with -32600) says the method exists.
    static let methodNotFound = -32601

    // MARK: - Protocol

    // initialize → initialized → the reads. `initialized` is a notification, so
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
    static let rateLimitsRequestID = 2
    static let rateLimitsRequest =
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read",""#
        + #"params":{"supportsLunaReserve":false,"excludeResetCreditDetails":true}}"#

    // refreshToken false: who's signed in is all we want, and a refresh is the
    // CLI's to make (see the type comment).
    static let accountRequestID = 3
    static let accountRequest =
        #"{"jsonrpc":"2.0","id":3,"method":"account/read","params":{"refreshToken":false}}"#

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Transport

    // The replies to both reads by id, or nil if the child never got past
    // initialize. Blocking: the caller is already on a serial probe queue, so a
    // watchdog that kills the child at the deadline bounds it; the kill closes
    // the pipe, which unblocks the read.
    private static func exchange(path: String, environment: [String: String]?,
                                 timeout: TimeInterval) -> [Int: Reply]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["app-server"]
        if let environment { task.environment = environment }
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
              case .result? = collect(ids: [1], next: reader.next)[1],
              write(initializedNotification, to: stdin),
              write(rateLimitsRequest, to: stdin),
              write(accountRequest, to: stdin)
        else { return nil }
        return collect(ids: [rateLimitsRequestID, accountRequestID], next: reader.next)
    }

    private static func write(_ line: String, to pipe: Pipe) -> Bool {
        guard let data = (line + "\n").data(using: .utf8) else { return false }
        // An unknown subcommand exits between spawn and write, and writing to
        // a closed pipe raises SIGPIPE.
        do { try pipe.fileHandleForWriting.write(contentsOf: data) } catch { return false }
        return true
    }

    // Reads until every id has its reply, or the stream ends. The server
    // answers in whatever order it finishes, not the order asked (account/read
    // came back first when measured), and interleaves notifications, which have
    // no id and are skipped.
    static func collect(ids: Set<Int>, next: () -> Data?) -> [Int: Reply] {
        var replies: [Int: Reply] = [:]
        while replies.count < ids.count, let line = next() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue, ids.contains(id)
            else { continue }
            if let body = object["result"] as? [String: Any] {
                replies[id] = .result(body)
            } else {
                let code = ((object["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
                replies[id] = .error(code: code)
            }
        }
        return replies
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

    // `account` is null when signed out, which reads as an empty account rather
    // than none: it says who's signed in (nobody), where nil says nothing. The
    // workspace sits beside it rather than in it.
    static func account(fromResult result: [String: Any]) -> CodexAccount? {
        if result["account"] is NSNull { return CodexAccount() }
        guard let account = result["account"] as? [String: Any] else { return nil }
        let routing = result["workspaceRouting"] as? [String: Any]
        return CodexAccount(type: account["type"] as? String,
                            email: account["email"] as? String,
                            planType: account["planType"] as? String,
                            chatgptAccountId: routing?["chatgptAccountId"] as? String)
    }

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
