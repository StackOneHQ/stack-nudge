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
    private var retryAfterUntil: Date?
    private var lastSubscriptionType: String?
    private var subscriptionFetched = false

    var isRateLimited: Bool {
        guard let until = retryAfterUntil else { return false }
        return until > Date()
    }

    // CLI shell-out runs off-main; completion fires on main.
    private let probeQueue = DispatchQueue(label: "stack-nudge.claude-cli-quota")

    func fetch(completion: @escaping (QuotaSnapshot?) -> Void) {
        if isRateLimited {
            completion(nil)
            return
        }
        guard let path = ProcessOutput.claude() else {
            lastProbeFailed = true
            completion(nil)
            return
        }
        let needsSubscriptionFetch = !subscriptionFetched
        let priorPlan = lastSubscriptionType

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
            let raw = ProcessOutput.read(
                path, ["--print", "--output-format", "json", "/usage"],
                timeout: 10, cwd: Self.probeCwd)
            let result = Self.parseEnvelope(raw)
            // Every `claude --print` spawns a new session rollout under
            // ~/.claude/projects/<cwd-encoded>/<uuid>.jsonl. At a 60s poll
            // cadence that's ~1.4k files/day — clutters `claude --resume`
            // and burns inodes for zero benefit (num_turns = 0). Pinning
            // cwd above means we know the exact directory; this scrubs the
            // single file the probe just produced.
            if let sid = Self.extractSessionId(raw) {
                Self.removeSessionFile(sid)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if needsSubscriptionFetch { self.subscriptionFetched = true }
                self.lastSubscriptionType = fetchedPlan

                switch result {
                case .ok(let snap):
                    self.lastProbeFailed = false
                    self.retryAfterUntil = nil
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
                    completion(nil)
                }
            }
        }
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

    static func parseTierLine(_ line: String) -> (name: String, tier: QuotaTier)? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = lineRegex.firstMatch(in: line, range: range) else { return nil }
        let name = ns.substring(with: m.range(at: 1))
        guard let pct = Double(ns.substring(with: m.range(at: 2))) else { return nil }
        let resetsAt: Date? = {
            let r = m.range(at: 3)
            guard r.location != NSNotFound else { return nil }
            return parseResetsAt(ns.substring(with: r))
        }()
        return (name, QuotaTier(utilization: pct, resetsAt: resetsAt))
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
