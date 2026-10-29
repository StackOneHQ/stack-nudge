import Foundation

// What the companion is reacting to, gathered from the same stores the pill's
// mascot reads. Kept as plain values so the mapping below is testable without
// a running app.
struct CompanionSignals: Equatable {
    var muted = false
    var permissionWaiting = false
    var quotaStressed = false
    var eventWaiting = false
    var sessionBusy = false
    var sessionsLive = false
    // Seconds since there was last anything to show; drives the nap.
    var quietFor: TimeInterval = 0
}

enum CompanionMode {
    // Five quiet minutes before the companion naps.
    static let sleepAfter: TimeInterval = 5 * 60

    // Highest priority first, and mute outranks the activity it is hiding.
    // Alert is for trouble (quota past the threshold); a permission prompt is
    // routine, so it waits like any other event instead of alarming.
    static func mode(for s: CompanionSignals) -> SkinMode {
        if s.muted { return .muted }
        if s.quotaStressed { return .alert }
        if s.permissionWaiting || s.eventWaiting { return .pending }
        if s.sessionBusy { return .thinking }
        if s.sessionsLive { return .polling }
        return s.quietFor >= sleepAfter ? .sleeping : .idle
    }
}
