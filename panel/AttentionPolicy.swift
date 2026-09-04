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
