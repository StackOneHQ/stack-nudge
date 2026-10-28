import Foundation

// A reminder worth checking: its queue key, the link to look for, and the start.
struct JoinCandidate: Equatable {
    let id: String
    let url: String
    let start: Date
}

// Polls a detector for the meeting reminders inside their check window and
// reports who joined. Main thread only.
final class JoinWatcher {
    typealias Background = (@escaping @Sendable () -> Void) -> Void
    typealias Deliver = (@escaping @Sendable () -> Void) -> Void

    static let interval: TimeInterval = 15
    static let lead: TimeInterval = 300
    static let tail: TimeInterval = 300

    private let detector: JoinDetector
    private let clock: () -> Date
    private let enabled: () -> Bool
    private let background: Background
    private let deliver: Deliver
    private let autoSchedule: Bool
    private let onJoined: (JoinCandidate) -> Void
    private let onNotJoined: (JoinCandidate) -> Void

    private var candidates: [String: JoinCandidate] = [:]
    private var lastCheck: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var joined: Set<String> = []
    private var reportedAfterStart: Set<String> = []
    private var timer: Timer?

    init(detector: JoinDetector, clock: @escaping () -> Date = { Date() }, enabled: @escaping () -> Bool = { true },
         background: @escaping Background = { work in DispatchQueue.global(qos: .utility).async(execute: work) },
         deliver: @escaping Deliver = { work in DispatchQueue.main.async(execute: work) },
         autoSchedule: Bool = true,
         onJoined: @escaping (JoinCandidate) -> Void,
         onNotJoined: @escaping (JoinCandidate) -> Void = { _ in }) {
        self.detector = detector; self.clock = clock; self.enabled = enabled; self.background = background; self.deliver = deliver
        self.autoSchedule = autoSchedule; self.onJoined = onJoined; self.onNotJoined = onNotJoined
    }

    // Reminders worth checking: a join link, and from 5 minutes before the start to 5 minutes after.
    static func inWindow(_ c: JoinCandidate, at now: Date) -> Bool {
        guard MeetingDiff.isJoinUrl(c.url) else { return false }
        return now >= c.start.addingTimeInterval(-lead) && now < c.start.addingTimeInterval(tail)
    }

    // Called with the live reminders whenever the calendar refreshes.
    func sync(_ reminders: [JoinCandidate]) {
        let now = clock()
        let live = enabled() ? reminders.filter { Self.inWindow($0, at: now) && !joined.contains($0.id) } : []
        candidates = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lastCheck = lastCheck.filter { candidates[$0.key] != nil }
        if candidates.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        poll()
        if autoSchedule, timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                self?.poll()
            }
            t.tolerance = 2
            timer = t
        }
    }

    // Checks every candidate not checked in the last interval; a candidate whose window has passed is dropped.
    func poll() {
        let now = clock()
        candidates = candidates.filter { Self.inWindow($0.value, at: now) }
        if candidates.isEmpty || !enabled() {
            candidates = [:]
            timer?.invalidate()
            timer = nil
            return
        }
        for (id, candidate) in candidates where !inFlight.contains(id) && now.timeIntervalSince(lastCheck[id] ?? .distantPast) >= Self.interval {
            lastCheck[id] = now
            inFlight.insert(id)
            let (detector, deliver, url) = (detector, deliver, candidate.url)
            let finish: @Sendable (JoinState) -> Void = { [weak self] state in self?.finish(candidate, state) }
            background {
                let state = detector.check(url: url)
                deliver { finish(state) }
            }
        }
    }

    private func finish(_ candidate: JoinCandidate, _ state: JoinState) {
        inFlight.remove(candidate.id)
        guard candidates[candidate.id] != nil else { return }
        switch state {
        case .joined:
            joined.insert(candidate.id)
            candidates[candidate.id] = nil
            onJoined(candidate)
        case .notJoined:
            if clock() >= candidate.start, reportedAfterStart.insert(candidate.id).inserted { onNotJoined(candidate) }
        case .unknown:
            break
        }
    }
}
