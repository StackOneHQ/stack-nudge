import Foundation

// macOS Focus (Do Not Disturb included) as an automatic mute source, separate
// from the timed mute: events still land in the list and the badges still count,
// only the banner, sound and voice are held. macOS gives an app no public way to
// read Focus, so a Shortcuts automation pushes the state in through the
// `focus on|off` socket command.
struct FocusPolicy: Equatable {
    var focused: Bool
    var respect: Bool
    var meetingsPass: Bool

    func holds(_ event: NudgeEvent) -> Bool {
        focused && respect && !(meetingsPass && Self.isMeetingReminder(event))
    }

    // The one place that decides what a meeting reminder is, so the calendar
    // feed can be matched here without touching the policy.
    static func isMeetingReminder(_ event: NudgeEvent) -> Bool {
        event.source == .calendar
    }
}

// The pushed state plus what it held back. In memory only: a missed "off" must
// not hold banners for good, so a relaunch during a Focus starts as off.
struct FocusTracker: Equatable {
    private(set) var active = false
    private(set) var held: [NudgeEvent] = []
    private(set) var lastChange: Date?

    mutating func hold(_ event: NudgeEvent) {
        held.append(event)
    }

    // Returns what the Focus held when it just ended, else nothing. Repeating
    // the state it is already in is a no-op, because a Shortcuts automation can
    // fire twice.
    mutating func set(_ on: Bool, now: Date = Date()) -> [NudgeEvent] {
        guard on != active else { return [] }
        active = on
        lastChange = now
        guard !on else { return [] }
        defer { held = [] }
        return held
    }
}

enum FocusDigest {
    // The one notice shown when Focus ends, in place of replaying every held
    // banner. A single event keeps its own title.
    static func text(for events: [NudgeEvent]) -> String? {
        guard let first = events.first else { return nil }
        let prefix = "While Focus was on: "
        if events.count == 1 { return prefix + first.title }
        let byLabel = Dictionary(grouping: events, by: label(for:)).sorted {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }
        return prefix + byLabel.map { "\($0.value.count) \($0.key)" }.joined(separator: ", ")
    }

    private static func label(for event: NudgeEvent) -> String {
        guard let tag = event.tag, !tag.isEmpty else {
            return event.source == .agent ? "agent" : event.source.label.lowercased()
        }
        return tag == "ci" ? "CI" : tag
    }
}

// Per-tag "Notify me about". A tag listed here still lists its events, but they
// do not pop a banner or change the companion pose. Stored comma-separated as
// STACKNUDGE_QUIET_TAGS.
enum QuietTags {
    static let configKey = "STACKNUDGE_QUIET_TAGS"

    // The tags the shipped feeds use; the page also lists any other tag seen
    // since launch and any already turned off.
    static let builtin = ["review", "review-request", "ci", "ready", "deploy",
                          "pipeline", "calendar", "plan", "audit"]

    static func parse(_ raw: String?) -> Set<String> {
        Set((raw ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static func serialize(_ tags: Set<String>) -> String {
        tags.sorted().joined(separator: ",")
    }

    static func isQuiet(_ event: NudgeEvent, in quiet: Set<String>) -> Bool {
        guard let tag = event.tag, !tag.isEmpty else { return false }
        return quiet.contains(tag)
    }

    static func known(seen: [String], quiet: Set<String>) -> [String] {
        var all = builtin
        for tag in seen.sorted() + quiet.sorted() where !all.contains(tag) { all.append(tag) }
        return all
    }
}
