import Foundation

// The one-off nod for a finished agent turn: a quiet heads-up that something
// small arrived, never a replacement for a pose that already says more.
enum CompanionNod {
    // A burst of arrivals earns one nod.
    static let window: TimeInterval = 2

    // An agent finishing a turn. A permission prompt has a pose of its own.
    static func isInfo(_ event: NudgeEvent) -> Bool { event.kind == .stop }

    // The pose before and after the arrivals must be calm, so the nod never
    // competes with another pose.
    static func shouldNod(arrivals: [NudgeEvent], interrupts: (NudgeEvent) -> Bool, muted: Bool,
                          reduceMotion: Bool, gateActive: Bool, before: SkinMode, after: SkinMode,
                          lastNod: Date?, now: Date) -> Bool {
        let calm: Set<SkinMode> = [.idle, .sleeping, .polling]
        guard !muted, !reduceMotion, gateActive, calm.contains(before), calm.contains(after) else { return false }
        if let lastNod, now.timeIntervalSince(lastNod) < window { return false }
        return arrivals.contains { isInfo($0) && interrupts($0) }
    }
}
