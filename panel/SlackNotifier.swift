import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Seconds since the user last touched this Mac. Wrapped so SlackDelivery can take
// idle as a plain number and stay testable, and so the one CoreGraphics call sits
// in a place that documents why it needs no permission prompt.
enum IdleTime {
    // hidSystemState + the catch-all event type gives system-wide idle across
    // keyboard, mouse and trackpad. Unlike Accessibility-based approaches this
    // needs no TCC grant, which matters for a background menu-bar app.
    static func seconds() -> TimeInterval {
        #if canImport(CoreGraphics)
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        #else
        return 0
        #endif
    }
}

// Whether a nudge earns a Slack DM, and what it says. Pure, because every
// interesting decision here is a policy question and none of it needs a network.
enum SlackDelivery {

    // Minutes of idle before Slack is used. 0 = always (the user asked for an
    // explicit "no gate" entry rather than a separate toggle).
    static let idleMinuteOptions = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]

    static func idleLabel(_ minutes: Int) -> String {
        minutes <= 0 ? "Always" : "\(minutes)m"
    }

    // Deliberately not gated on the global mute. Mute means "stop interrupting me
    // *here*"; Slack exists precisely because the user is elsewhere. It has its
    // own `enabled` switch instead. A per-session mute *is* respected, matching
    // the first-banner gate in PanelController.postBannerIfNeeded.
    static func shouldSend(kind: NudgeKind,
                           isReminder: Bool,
                           sessionMuted: Bool,
                           enabled: Bool,
                           notifyOnStop: Bool,
                           idleSeconds: TimeInterval,
                           idleThresholdMinutes: Int) -> Bool {
        guard enabled, !sessionMuted else { return false }
        switch kind {
        case .permission: break
        case .stop: guard notifyOnStop else { return false }
        case .other: return false
        }
        // A reminder already proved the prompt went unanswered, so it isn't
        // re-gated on idle: the user may well have returned to the desk and still
        // not seen the banner, which is the case reminders exist for.
        if isReminder { return true }
        guard idleThresholdMinutes > 0 else { return true }
        return idleSeconds >= TimeInterval(idleThresholdMinutes * 60)
    }

    // `label` is the resolved session name; falls back to the repo the event came
    // from. Detail is opt-in because a permission message is raw tool text —
    // "Bash(rm -rf build/)" — which can carry paths, hostnames, and secrets in
    // command lines, and this is the one path that leaves the machine.
    static func text(for event: NudgeEvent,
                     label: String?,
                     includeDetail: Bool,
                     isReminder: Bool) -> String {
        let who = agentName(event.agent)
        let subject = (label ?? projectName(event.projectPath))
            .map { "\(who) in \($0)" } ?? who

        let headline: String
        switch event.kind {
        case .permission:
            headline = isReminder
                ? "\(subject) is still waiting for permission"
                : "\(subject) needs permission"
        case .stop:
            headline = "\(subject) finished a turn"
        case .other:
            headline = "\(subject) sent a nudge"
        }

        guard includeDetail, !event.message.isEmpty else { return headline }
        return "\(headline)\n\(event.message)"
    }

    static func projectName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    // notify.sh sends hook-side labels ("claude-code"); the Slack message should
    // read the way the banner does.
    static func agentName(_ agent: String) -> String {
        switch agent.lowercased() {
        case "claude-code", "claude": return "Claude Code"
        case "codex":                 return "Codex"
        case "gemini":                return "Gemini"
        case "agy", "antigravity":    return "Antigravity"
        default:                      return agent
        }
    }
}

// DMs the configured member as the StackNudge bot.
//
// The sender being the app rather than the user is the entire point: Slack does
// not notify you about your own messages, so the earlier user-token build landed
// silently in a self-DM. Passing a user id as `channel` opens the 1:1 with the
// app, so there is no separate conversations.open round trip.
//
// Fire-and-forget: a Slack outage must never slow or block the hook-delivery
// path, so failures are recorded for the Settings row and otherwise dropped
// rather than retried into a queue nobody drains.
final class SlackNotifier {

    static let postMessageURL = URL(string: "https://slack.com/api/chat.postMessage")!

    private let session: URLSession

    // Surfaced on the Settings row so a silently-broken integration is visible.
    // Written off-main, read on main — both through this queue.
    private let stateQueue = DispatchQueue(label: "stack-nudge.slack-notifier")
    private var _lastError: String?
    var lastError: String? { stateQueue.sync { _lastError } }

    init(session: URLSession = .shared) {
        self.session = session
    }

    // `completion` reports the outcome for the test-message row; ordinary
    // deliveries pass nil and read `lastError` on the next tick instead.
    func send(_ text: String,
              to memberID: String?,
              completion: ((String?) -> Void)? = nil) {
        guard let memberID, !memberID.isEmpty else {
            finish("No Slack user set — run Detect or paste a member ID", completion)
            return
        }
        // SecItemCopyMatching is sub-millisecond warm but blocks outright if the
        // keychain needs unlocking, and this runs from postBannerIfNeeded on the
        // main thread for every event — so it stays off the hook-delivery path.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let token = SlackCredentials.botToken() else {
                self.finish("No Slack bot token — paste one in Settings", completion)
                return
            }
            self.post(text: text, token: token, memberID: memberID, completion: completion)
        }
    }

    private func post(text: String, token: String, memberID: String,
                      completion: ((String?) -> Void)?) {
        var request = URLRequest(url: Self.postMessageURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "channel": memberID,
            "text": text,
        ])

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            // Slack answers 200 with {"ok": false, "error": ...}, so the status
            // code alone would report success on every failure.
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let failure = json["ok"] as? Bool == true
                    ? nil
                    : Self.explain(json["error"] as? String ?? "unknown")
                self.finish(failure, completion)
            } else {
                self.finish(error?.localizedDescription ?? "no response", completion)
            }
        }.resume()
    }

    // Slack's error strings are terse and the fix differs sharply between them,
    // so translate the ones a misconfigured setup will actually hit.
    static func explain(_ slackError: String) -> String {
        switch slackError {
        case "invalid_auth", "token_revoked", "account_inactive":
            return "Slack rejected the bot token — paste a fresh one"
        case "missing_scope", "not_allowed_token_type":
            return "Bot token is missing chat:write"
        case "channel_not_found":
            return "Slack user not found — check the member ID"
        default:
            return slackError
        }
    }

    private func finish(_ error: String?, _ completion: ((String?) -> Void)?) {
        record(error: error)
        if let completion {
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func record(error: String?) {
        stateQueue.async { self._lastError = error }
    }

    func clearState() {
        stateQueue.async { self._lastError = nil }
    }
}
