import AppKit

// True while the companion can actually be seen. Its animations run on the
// render server, so pausing them when the window is covered, the display
// sleeps or the screen is locked is what keeps it near 0% CPU.
@MainActor
final class CompanionGate: ObservableObject {
    static let shared = CompanionGate()

    @Published private(set) var active = true
    private var displayAsleep = false
    private var locked = false
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        tokens.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.displayAsleep = asleep; self?.refresh() }
            })
        }
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = isLocked; self?.refresh() }
            })
        }
    }

    func refresh() {
        // Before the window exists there is nothing to judge, so stay awake.
        let panels = NSApp.windows.compactMap { $0 as? CompanionPanel }
        let seen = panels.isEmpty || panels.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        let next = seen && !displayAsleep && !locked
        if next != active { active = next }
    }
}
