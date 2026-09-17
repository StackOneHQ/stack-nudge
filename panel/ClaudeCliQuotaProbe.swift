import Foundation

// Reads Claude Code's quota by shelling out to `claude --print --output-format
// json /usage` and parsing the human-readable text the slash command renders.
// /usage is a client-side intercept (zero model cost, num_turns 0,
// duration_api_ms 0) that hits the same /api/oauth/usage endpoint our legacy
// QuotaProbe does — but it runs inside Claude Code, which has its own keychain
// ACL grant. Our process never touches the keychain, so the periodic
// "stack-nudge wants to access Claude Code-credentials" prompt goes away.
//
// Failure shapes:
//   hardFail — `claude` not on PATH, spawn/timeout failure, or unparseable
//              JSON envelope. PanelController falls back to the legacy probe.
//   softFail — CLI ran fine but the server-side bucket lines are absent
//              (rate-limited cold cache). We back off 60s locally without
//              clearing the existing snapshot; next tick should populate.
//   ok      — at least one Current bucket line parsed.
final class ClaudeCliQuotaProbe {

    // Main-queue only (mirrors QuotaProbe's threading model).
    private(set) var lastProbeFailed = false
    // True when the last fetch found no `claude` on PATH, as distinct from the
    // CLI running but failing to parse. Lets the caller stay silent for a
    // non-Claude user instead of surfacing a "usage unavailable" error, and hold
    // a prior snapshot on a genuine hard-fail rather than dropping it.
    private(set) var cliMissing = false
    private var retryAfterUntil: Date?
    private var lastSubscriptionType: String?
    private var subscriptionFetched = false
    // `--strict-mcp-config` makes the /usage probe skip loading MCP servers it
    // never needs (see usageArgs). A `claude` predating the flag rejects it
    // (exit 1, empty stdout), which would read as a permanent hard-fail — the
    // exact "Couldn't refresh" this probe exists to avoid, but forever rather
    // than intermittently. We detect that shape once, drop the flag for the rest
    // of the process, and stop paying for the check.
    private var strictMcpConfigSupported = true

    // How fresh Claude Code's own usage cache has to be before the probe serves
    // it instead of spawning the CLI. Matched to PanelController's fastest quota
    // poll: within one interval the cache is, by definition, no older than the
    // reading the spawn it replaces would have produced.
    //
    // Deliberately tight. Measured against a live account, `claude /usage` does
    // NOT serve its own cache on a normal run — it refreshes and writes back —
    // and Claude Code only rewrites the file every several minutes, so a 464s-old
    // cache read 6%/62% where the CLI read 9%/63%. Widening this would trade a
    // spawn for numbers that are visibly wrong during active use.
    static let cacheMaxAge: TimeInterval = 60

    // When the reported snapshot was actually measured. Date() for a CLI read,
    // the cache's own `fetchedAt` when the snapshot came from disk. The panel
    // dates the Usage tab from this, so a fallback reading can't be presented as
    // if it had just been taken. Read after the completion fires, like
    // cliMissing and lastProbeFailed.
    private(set) var snapshotAsOf: Date?

    var isRateLimited: Bool {
        guard let until = retryAfterUntil else { return false }
        return until > Date()
    }

    // CLI shell-out runs off-main; completion fires on main.
    private let probeQueue = DispatchQueue(label: "stack-nudge.claude-cli-quota")

    func fetch(completion: @escaping (QuotaSnapshot?) -> Void) {
        // Reset before the early-return gates so a rate-limited tick reports the
        // flag from its own run, not a stale value from an earlier missing-CLI one.
        cliMissing = false
        if isRateLimited {
            completion(nil)
            return
        }
        guard let path = ProcessOutput.claude() else {
            lastProbeFailed = true
            cliMissing = true
            completion(nil)
            return
        }
        let needsSubscriptionFetch = !subscriptionFetched
        let priorPlan = lastSubscriptionType
        // Captured on main like the two above; the latch is written back on main
        // in the completion, matching this class's threading model.
        let strictSupported = strictMcpConfigSupported

        probeQueue.async { [weak self] in
            var fetchedPlan: String? = priorPlan
            if needsSubscriptionFetch {
                if let json = ProcessOutput.read(
                    path, ["auth", "status", "--json"], timeout: 5, cwd: Self.probeCwd),
                   let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let plan = obj["subscriptionType"] as? String {
                    fetchedPlan = plan
                }
            }
            // Claude Code caches this exact payload to ~/.claude.json whenever it
            // refreshes its own bars, so while a session is running the answer is
            // already on disk and the spawn below buys nothing. Skip it while the
            // cache is younger than a poll interval — that is the window in which
            // it cannot be staler than what a fresh spawn would return anyway.
            // See ClaudeUsageCache for why `fetchedAt` gates this rather than
            // the file merely existing.
            var strictRejected = false
            var measuredAt = Date()
            let result: ParseResult
            if let cached = ClaudeUsageCache.read(maxAge: Self.cacheMaxAge) {
                result = .ok(cached.snapshot)
                measuredAt = cached.fetchedAt
            } else {
                // /usage is a client-side intercept that needs no MCP servers, so
                // usageArgs adds --strict-mcp-config to load none: without it every
                // spawn boots the user's whole MCP config (60+ servers on a heavy
                // setup), and that variable startup tail is what pushed an otherwise
                // -fine probe past a 10s timeout under load — a spurious hard-fail on
                // the Usage tab. The intercept's own local-session scan also slows on
                // a busy machine, so 20s leaves headroom rather than sitting on the
                // edge. runUsage drops the flag and retries once if this CLI is too
                // old to know it (see strictMcpConfigSupported).
                let (raw, rejected) = Self.runUsage(strictMcpConfig: strictSupported) {
                    ProcessOutput.read(path, $0, timeout: 20, cwd: Self.probeCwd)
                }
                strictRejected = rejected
                result = Self.parseEnvelope(raw)
                // Every `claude --print` spawns a new session rollout under
                // ~/.claude/projects/<cwd-encoded>/<uuid>.jsonl. At a 60s poll
                // cadence that's ~1.4k files/day — clutters `claude --resume`
                // and burns inodes for zero benefit (num_turns = 0). Pinning
                // cwd above means we know the exact directory; this scrubs the
                // single file the probe just produced.
                if let sid = Self.extractSessionId(raw) {
                    Self.removeSessionFile(sid)
                }
            }

            // The CLI broke. Claude Code may still have left a usable reading on
            // disk from before it did — at any age, since the alternative here is
            // "Couldn't refresh" over nothing at all. Read off-main and only on
            // the failing path, so the common case never parses the file twice.
            var fallback: ClaudeUsageCache.Reading?
            if case .hardFail = result {
                fallback = ClaudeUsageCache.read(maxAge: .infinity)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if strictRejected { self.strictMcpConfigSupported = false }
                if needsSubscriptionFetch { self.subscriptionFetched = true }
                self.lastSubscriptionType = fetchedPlan

                switch result {
                case .ok(let snap):
                    self.lastProbeFailed = false
                    self.retryAfterUntil = nil
                    self.snapshotAsOf = measuredAt
                    completion(QuotaSnapshot(
                        fiveHour:       snap.fiveHour,
                        sevenDay:       snap.sevenDay,
                        sevenDayOpus:   snap.sevenDayOpus,
                        sevenDaySonnet: snap.sevenDaySonnet,
                        planType:       fetchedPlan))
                case .softFail:
                    self.lastProbeFailed = false
                    self.retryAfterUntil = Date().addingTimeInterval(60)
                    completion(nil)
                case .hardFail:
                    self.lastProbeFailed = true
                    guard let usable = Self.fallbackReading(
                        fallback, lastReportedAt: self.snapshotAsOf) else {
                        completion(nil)
                        return
                    }
                    self.snapshotAsOf = usable.fetchedAt
                    completion(QuotaSnapshot(
                        fiveHour:       usable.snapshot.fiveHour,
                        sevenDay:       usable.snapshot.sevenDay,
                        sevenDayOpus:   usable.snapshot.sevenDayOpus,
                        sevenDaySonnet: usable.snapshot.sevenDaySonnet,
                        planType:       fetchedPlan))
                }
            }
        }
    }

    // Whether a disk reading should stand in after the CLI hard-failed. It has to
    // beat what we last reported, or a file left over from an earlier session
    // would walk a good snapshot backwards the first time the CLI timed out —
    // turning one bad tick into visibly wrong numbers instead of a held-stale
    // note. With nothing reported yet (cold start, broken CLI) any reading wins,
    // which is the case this exists for.
    static func fallbackReading(_ reading: ClaudeUsageCache.Reading?,
                                lastReportedAt: Date?) -> ClaudeUsageCache.Reading? {
        guard let reading,
              reading.fetchedAt > (lastReportedAt ?? .distantPast) else { return nil }
        return reading
    }

    // MARK: - Invocation

    // Args for `claude --print /usage`. --strict-mcp-config loads zero MCP
    // servers, which the intercept never needs — see the call site in fetch().
    static func usageArgs(strictMcpConfig: Bool) -> [String] {
        var args = ["--print"]
        if strictMcpConfig { args.append("--strict-mcp-config") }
        args += ["--output-format", "json", "/usage"]
        return args
    }

    // Runs the /usage probe and, if a `claude` too old to know --strict-mcp-config
    // rejects it, retries once without the flag. Returns the raw envelope plus
    // whether the flag was rejected, so fetch() can latch it off for the process.
    // `run` is injected so this is unit-testable without shelling out; the
    // function holds no instance state and does no I/O of its own.
    static func runUsage(strictMcpConfig: Bool,
                         run: (_ args: [String]) -> String?) -> (raw: String?, strictRejected: Bool) {
        let raw = run(usageArgs(strictMcpConfig: strictMcpConfig))
        // Only the flagged path can be rejected, and only an EMPTY result is the
        // rejection shape: an unknown flag exits non-zero with no stdout, while a
        // working /usage always returns a JSON envelope. A nil result is a timeout
        // — retrying there would reload every MCP server and be slower, the exact
        // path this fix protects — so we leave it alone.
        guard strictMcpConfig, raw?.isEmpty == true else {
            return (raw, false)
        }
        let retry = run(usageArgs(strictMcpConfig: false))
        // Latch the flag off only if dropping it actually produced output. If the
        // retry is empty/nil too it was something else (a real outage), so keep
        // the flag — the next poll should still get the no-MCP speedup.
        if let retry, !retry.isEmpty {
            return (retry, true)
        }
        return (raw, false)
    }

    // MARK: - Session cleanup

    // Pinned cwd for `claude --print` so its session-rollout file always
    // lands in a known directory we can scrub. ~/.stack-nudge always exists
    // by the time the probe runs (Bootstrap creates it on first launch).
    static let probeCwd = "\(NSHomeDirectory())/.stack-nudge"

    // Claude derives the projects-subdirectory name by replacing every "/"
    // AND every "." in the cwd with "-". So "/Users/me/.stack-nudge" becomes
    // "-Users-me--stack-nudge" (double dash for the dot-prefix).
    static var probeSessionsDir: String {
        let encoded = probeCwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(NSHomeDirectory())/.claude/projects/\(encoded)"
    }

    static func extractSessionId(_ raw: String?) -> String? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["session_id"] as? String
    }

    static func removeSessionFile(_ sessionId: String) {
        // Guard against a malformed session_id that could escape the
        // intended directory — only accept the UUID shape Claude actually
        // emits (lower-hex + hyphens, no separators).
        guard sessionId.range(of: "^[0-9a-f-]+$", options: .regularExpression) != nil
        else { return }
        let path = "\(probeSessionsDir)/\(sessionId).jsonl"
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Parsing

    enum ParseResult {
        case ok(QuotaSnapshot)  // planType is filled in by the caller
        case softFail           // bucket lines absent — CLI is rate-limited
        case hardFail           // envelope missing / unparseable
    }

    static func parseEnvelope(_ raw: String?) -> ParseResult {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["result"] as? String else {
            return .hardFail
        }
        return parseResultText(text)
    }

    static func parseResultText(_ text: String) -> ParseResult {
        var fiveHour:   QuotaTier?
        var sevenDay:   QuotaTier?
        var opus:       QuotaTier?
        var sonnet:     QuotaTier?
        var foundAny = false

        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("Current "),
                  let parsed = parseTierLine(s) else { continue }
            foundAny = true
            switch parsed.name {
            case "session":              fiveHour = parsed.tier
            case "week (all models)":    sevenDay = parsed.tier
            case "week (Opus only)":     opus     = parsed.tier
            case "week (Sonnet only)":   sonnet   = parsed.tier
            default:                     continue
            }
        }
        if !foundAny { return .softFail }
        return .ok(QuotaSnapshot(
            fiveHour:       fiveHour,
            sevenDay:       sevenDay,
            sevenDayOpus:   opus,
            sevenDaySonnet: sonnet,
            planType:       nil))
    }

    // "Current week (all models): 23% used · resets Jul 4 at 3am (Europe/London)"
    // "Current week (Sonnet only): 0% used"     ← no resets suffix on 0%
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^Current (.+?): (\d+)% used(?: · resets (.+))?$"#)

    // `now` is threaded through to parseResetsAt's plausibility window rather
    // than defaulted there, so a test can pin a line to the date it was written
    // against. Without it a fixed "resets Jun 30" line silently starts failing
    // once it drifts more than `plausibleWindow` into the past.
    static func parseTierLine(_ line: String,
                              now: Date = Date()) -> (name: String, tier: QuotaTier)? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = lineRegex.firstMatch(in: line, range: range) else { return nil }
        let name = ns.substring(with: m.range(at: 1))
        guard let pct = Double(ns.substring(with: m.range(at: 2))) else { return nil }
        let resetsAt: Date? = {
            let r = m.range(at: 3)
            guard r.location != NSNotFound else { return nil }
            return parseResetsAt(ns.substring(with: r), now: now)
        }()
        return (name, QuotaTier(utilization: pct,
                                resetsAt: resetsAt,
                                windowLength: windowLength(forTier: name)))
    }

    // The `/usage` text reports a reset time but never a window length, so it
    // has to come from the tier name.
    static func windowLength(forTier name: String) -> TimeInterval? {
        if name == "session" { return QuotaWindow.fiveHours }
        if name.hasPrefix("week") { return QuotaWindow.sevenDays }
        return nil
    }

    // Best-effort: "Jun 30 at 6:50pm (Europe/London)" → Date.
    //
    // The CLI omits the year, so try the neighbouring ones and keep whichever
    // lands nearest `now` — splicing in the current year alone put "Jan 2 at 1am"
    // read on Dec 31 twelve months in the past.
    //
    // Then range-check it: "nearest of the ones that parsed" is only sound while
    // the correct year parses, and a future-dated wrong answer is ~365 days out
    // and passes the past-guard downstream. Real windows are 7 days at most, so
    // 60 leaves room for a future monthly tier while still catching a year.
    static let plausibleWindow: TimeInterval = 60 * 24 * 3600

    static func parseResetsAt(_ raw: String, now: Date = Date()) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var dateTimeStr = trimmed
        var tz: TimeZone?
        if trimmed.hasSuffix(")"), let openIdx = trimmed.lastIndex(of: "(") {
            let afterOpen = trimmed.index(after: openIdx)
            let beforeClose = trimmed.index(before: trimmed.endIndex)
            let tzString = String(trimmed[afterOpen..<beforeClose])
            tz = TimeZone(identifier: tzString)
            dateTimeStr = String(trimmed[..<openIdx]).trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let tz { formatter.timeZone = tz }
        var calendar = Calendar(identifier: .gregorian)
        if let tz { calendar.timeZone = tz }
        let year = calendar.component(.year, from: now)

        var best: Date?
        for candidateYear in [year - 1, year, year + 1] {
            let withYear = "\(dateTimeStr) \(candidateYear)"
            // "h:mma" matches "6:50pm"; "ha" matches "3am".
            for fmt in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
                formatter.dateFormat = fmt
                guard let candidate = formatter.date(from: withYear) else { continue }
                let closer = best.map {
                    abs(candidate.timeIntervalSince(now)) < abs($0.timeIntervalSince(now))
                } ?? true
                if closer { best = candidate }
                break
            }
        }
        guard let best, abs(best.timeIntervalSince(now)) <= plausibleWindow else { return nil }
        return best
    }
}
