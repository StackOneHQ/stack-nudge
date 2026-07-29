import Foundation

// Rate limiter for work that recomputes everything from scratch, and is
// therefore safe to defer or collapse. The Tickets tab asks for both of its
// refreshes on every appearance, so flipping to it re-paid the full cost each
// time: for the PR fetch that is dozens of network round-trips against a
// rate-limited API, and a Stop landing mid-burst used to kick another pass.
//
// A request inside the window is deferred rather than dropped, so the last
// request always gets served and the caller never has to know whether its data
// made it in. Repeated requests inside one window collapse into a single run.
//
// Main-thread only. `now` and `after` are injected so the timing behaviour can be
// tested without waiting on real timers.
final class RefreshGate {

    private let interval: TimeInterval
    private let now: () -> Date
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let work: () -> Void

    // nil until the first run, so a cold gate always fires immediately.
    private var lastRun: Date?
    private var deferredRun = false

    init(interval: TimeInterval,
         now: @escaping () -> Date = Date.init,
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
         },
         work: @escaping () -> Void) {
        self.interval = interval
        self.now = now
        self.after = after
        self.work = work
    }

    // Run now if the window has elapsed, otherwise once when it does.
    func request() {
        guard let lastRun else { return run() }
        let remaining = interval - now().timeIntervalSince(lastRun)
        guard remaining > 0 else { return run() }
        guard !deferredRun else { return }
        deferredRun = true
        after(remaining) { [weak self] in
            self?.deferredRun = false
            self?.run()
        }
    }

    // Bypass the window for an explicit user action, where waiting would read as
    // the click having done nothing.
    func force() { run() }

    private func run() {
        lastRun = now()
        work()
    }
}
