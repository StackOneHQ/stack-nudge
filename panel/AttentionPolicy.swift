import Foundation

// When an unanswered permission prompt has earned another nudge, and when a
// session that claims to be working has gone quiet long enough to be worth
// flagging. Pure so the thresholds are testable without a live agent, a timer,
// or a blocked hook.
//
// The premise the whole app rests on is that you aren't watching the terminal.
// A single banner doesn't hold up under that: macOS slides it into Notification
// Center after a few seconds, and until now nothing ever mentioned the prompt
// again — so walking away turned a 10-second interruption into a blocked agent.
enum AttentionPolicy {

    // MARK: - Unanswered prompts

    // Reminder intervals offered in Settings, in minutes. 0 = off.
    //
    // Derived rather than hardcoded: an interval at or past promptLifetime can
    // never fire, because the first reminder is due after `interval` but the
    // lifetime gate closes at 550s. A 10m option therefore sat in Settings
    // looking active while behaving exactly like Off. Deriving it means the two
    // constants can't drift apart again.
    static let reminderMinuteOptions: [Int] =
        [0, 1, 2, 5, 10].filter { $0 == 0 || TimeInterval($0 * 60) < promptLifetime }

    // notify.sh gives the FIFO 550s before it gives up and lets the agent fall
    // back to its own terminal prompt (see wait_for_permission_response). Past
    // that the prompt can no longer be answered from the panel, so a reminder
    // would point at a button that does nothing.
    static let promptLifetime: TimeInterval = 550

    // Ceiling on re-nudges for one prompt. Someone who has ignored three
    // banners is not at the desk; continuing is nagging, and the menu-bar
    // count still carries the state for when they come back.
    static let maxReminders = 3

    static func shouldRemind(now: Date,
                             firstSeenAt: Date,
                             lastNudgedAt: Date,
                             remindersSent: Int,
                             intervalMinutes: Int) -> Bool {
        guard intervalMinutes > 0, remindersSent < maxReminders else { return false }
        guard now.timeIntervalSince(firstSeenAt) < promptLifetime else { return false }
        return now.timeIntervalSince(lastNudgedAt) >= TimeInterval(intervalMinutes * 60)
    }

    // Banner body for a reminder. The title is left alone so the reminder reads
    // as the same prompt rather than a new one; the wait goes in front of the
    // original message, which is the part that says what's being asked.
    static func reminderBody(original: String, waitedSince: Date, now: Date = Date()) -> String {
        let waited = elapsedLabel(since: waitedSince, now: now)
        return original.isEmpty
            ? "Still waiting \(waited)"
            : "Still waiting \(waited) · \(original)"
    }

    // "45s", "4m", "1h2m" — same vocabulary as QuotaReset.shortLabel, but
    // counting up. Sub-minute stays in seconds: the first reminder can land
    // under a minute after the prompt when the interval is 1m and the tick
    // lands early, and "0m" would read as a bug.
    static func elapsedLabel(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        return "\(seconds / 60)m"
    }

    // MARK: - Is a prompt still answerable?

    // The FIFO's existence was treated as proof a prompt is still blocking, on
    // the grounds that notify.sh removes it on exit. It doesn't always: the trap
    // is on EXIT, which bash honours for SIGTERM but nothing honours for
    // SIGKILL, and the agent kills the hook outright when the user answers in
    // its own UI. Evidence from one machine: 536 leaked FIFO directories going
    // back three months, every single one still holding a live FIFO, so the
    // trap had not run once.
    //
    // The consequence is the bug this fixes. Approve a plan in the terminal and
    // the hook is killed, the FIFO survives, and the panel goes on believing the
    // prompt is blocking — keeping it in the menu-bar count and firing reminders
    // at you, and at Slack, for the full 550 seconds.
    //
    // So the FIFO answers "was a prompt raised?" and the hook's liveness answers
    // "is anyone still listening?". Both are required: a prompt whose hook is
    // gone cannot be answered from the panel, because there is nothing left to
    // read the decision.
    //
    // A zombie — exited but not yet reaped — still answers kill(0), so there is a
    // window where a dead hook reads as alive. It closes when the agent reaps
    // its child, which is prompt in practice, and the next 5s tick corrects it.
    // That reaping is load-bearing rather than incidental: a SIGKILLed child
    // still answering kill(0) is precisely the case this exists to catch, so if
    // an agent ever left hooks unreaped the check would degrade to the old
    // FIFO-only behaviour — never worse, but no longer a fix.
    //
    // Pid reuse is the obvious objection: a SIGKILLed hook's pid can be recycled,
    // and a recycled pid answers kill(0). It is bounded and benign. A watch is
    // built with `firstSeenAt: event.timestamp` and retired in the same pass once
    // that exceeds promptLifetime, so a stale event cannot be resurrected by a
    // reused pid even if one appears — the window is 550s from the prompt, not
    // the sweep interval. And inside that window the worst case is simply the
    // behaviour this fix replaced: a prompt counted slightly too long. Never
    // worse than the bug, and usually much better.
    //
    // `hookPID` nil means the hook predates this field, so fall back to the old
    // behaviour rather than treating every prompt from an older notify.sh as
    // dead — the script self-updates, but not before the first event after an
    // upgrade.
    // A pid arrives on the same local socket as fifo_path, which is validated, so
    // this is validated too rather than hardening one half of a pair.
    //
    // Both rejections were checked against the real syscall. kill(0, 0) signals
    // the caller's whole process group and kill(-1, 0) every process it may
    // signal, and both return 0 — so a pid of 0 or a negative would make every
    // prompt read as alive and quietly undo the liveness check. And pid_t is
    // Int32, so pid_t(4_000_000_000) traps rather than wrapping: an oversized
    // number in the payload would crash the panel outright.
    static func validHookPID(_ raw: Int?) -> Int? {
        guard let raw, raw > 0, raw <= Int(pid_t.max) else { return nil }
        return raw
    }

    static func isAnswerable(kind: NudgeKind,
                             fifoPath: String?,
                             hookPID: Int?,
                             fifoExists: (String) -> Bool,
                             processAlive: (Int) -> Bool) -> Bool {
        guard kind == .permission, let fifoPath, fifoExists(fifoPath) else { return false }
        guard let hookPID else { return true }
        return processAlive(hookPID)
    }

    // MARK: - Stalled sessions

    // Thresholds offered in Settings, in minutes. 0 = off.
    static let stalledMinuteOptions = [0, 10, 20, 30, 60]

    // A session the agent still reports as busy but which hasn't produced an
    // event in `thresholdMinutes` — usually a wedged tool call or a hung
    // request. Only `busy` sessions qualify: an idle session with no recent
    // activity is just a session you aren't using, which is not a problem.
    //
    // `lastActivityAt` nil means the agent has never reported activity, so
    // there's no baseline to call it stalled against.
    static func isStalled(lastActivityAt: Date?,
                          busy: Bool,
                          now: Date,
                          thresholdMinutes: Int) -> Bool {
        guard thresholdMinutes > 0, busy, let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= TimeInterval(thresholdMinutes * 60)
    }

    // Label for a stalled row in the Sessions tab: "no output 24m".
    static func stalledLabel(lastActivityAt: Date, now: Date = Date()) -> String {
        "no output \(elapsedLabel(since: lastActivityAt, now: now))"
    }

    // Settings row value for a minute option. Shared by both cycle rows so
    // "Off" and the "10m"/"1h" shapes can't drift apart.
    static func minuteLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "Off" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
}

extension NudgeEvent {
    // "Is this prompt still waiting on me?", asked against the live system.
    // Lives here rather than on PanelController because the view layer asks it
    // too — a dead prompt must not keep offering Allow/Deny, since writeFIFO
    // would get ENXIO and the button would silently do nothing.
    var isStillBlocking: Bool {
        AttentionPolicy.isAnswerable(
            kind: kind,
            fifoPath: fifoPath,
            hookPID: hookPID,
            fifoExists: { FileManager.default.fileExists(atPath: $0) },
            // kill(pid, 0) asks "does this exist and may I signal it" without
            // sending anything. `exactly:` rather than pid_t(_:) because that
            // traps above Int32.max — the listener rejects such a pid, but a
            // crash is not something to leave one guard away.
            processAlive: { pid in
                guard let pid = pid_t(exactly: pid) else { return false }
                return kill(pid, 0) == 0
            })
    }
}
