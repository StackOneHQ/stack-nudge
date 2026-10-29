import AppKit
import Combine
import SwiftUI

// Owns the companion window: shows it when STACKNUDGE_COMPANION is on, keeps
// it on a screen, and saves where the user drops it. Separate from the pill
// and its placement code, by design: the two can be on at the same time.
@MainActor
final class CompanionController {

    static let positionKey = "STACKNUDGE_COMPANION_POS"

    private let store: EventStore
    private let sessions: SessionStore
    private let nav: PanelNav
    private let model = CompanionModel()
    private let onClick: () -> Void
    private let onContextMenu: (NSEvent, NSView) -> Void
    // Fires while the character is dragged, so an open panel can follow it.
    var onMove: (() -> Void)?

    private var panel: CompanionPanel?
    private var anchor: CGPoint
    private var cancellables = Set<AnyCancellable>()

    init(store: EventStore, sessions: SessionStore, nav: PanelNav,
         onClick: @escaping () -> Void,
         onContextMenu: @escaping (NSEvent, NSView) -> Void) {
        self.store = store
        self.sessions = sessions
        self.nav = nav
        self.onClick = onClick
        self.onContextMenu = onContextMenu
        anchor = Self.savedAnchor() ?? Self.defaultAnchor()

        // Any store change may change the mood. Recomputing is cheap; the model
        // only publishes when the result differs, so the view stays still.
        // objectWillChange fires before the new value lands, hence the hop.
        Publishers.Merge4(store.objectWillChange, sessions.objectWillChange, nav.objectWillChange,
                          nav.companionInputs.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshModel() }
            .store(in: &cancellables)
        // Sleeping and snoozes ending depend on the clock alone. The nap
        // threshold is five minutes, so a quarter-minute check is plenty.
        Timer.publish(every: 15, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshModel() }
            .store(in: &cancellables)
        nav.$companionEnabled.combineLatest(nav.$companionSize)
            .removeDuplicates { $0 == $1 }
            // Deferred a turn so the @Published values have settled before apply() reads them.
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func apply() {
        guard nav.companionEnabled else {
            panel?.orderOut(nil)
            return
        }
        refreshModel()
        let panel = self.panel ?? makePanel()
        let size = nav.companionSize.points
        anchor = CompanionPlacement.clamp(anchor, size: size, screens: NSScreen.screens.map(\.frame))
        panel.setFrame(NSRect(origin: CompanionPlacement.origin(anchor: anchor, size: size), size: size), display: true)
        panel.orderFrontRegardless()
        CompanionGate.shared.refresh()
    }

    private func makePanel() -> CompanionPanel {
        let panel = CompanionPanel(size: nav.companionSize.points)
        let host = NSHostingView(rootView: CompanionView(model: model))
        panel.contentView = host
        panel.onClick = { [weak self] in self?.onClick() }
        panel.onContextMenu = { [weak self, weak host] event in
            guard let self, let host else { return }
            self.onContextMenu(event, host)
        }
        panel.onDragMove = { [weak self] in self?.onMove?() }
        panel.onDragEnd = { [weak self] in self?.dragEnded() }
        self.panel = panel
        return panel
    }

    private var quietSince = Date()

    private func refreshModel(now: Date = Date()) {
        guard nav.companionEnabled else { return }
        let waiting = store.events.filter { ($0.snoozedUntil ?? .distantPast) <= now }
        let live = sessions.liveSessions
        // Anything to show resets the nap clock; only a quiet spell lets it doze.
        if !waiting.isEmpty || !live.isEmpty { quietSince = now }
        var signals = CompanionSignals(
            preview: nav.companionPreviewPose,
            muted: nav.isMuted,
            permissionWaiting: waiting.contains { $0.kind == .permission },
            quotaStressed: nav.widgetQuota.peakUtilization >= Double(nav.quotaAlertThreshold),
            eventWaiting: !waiting.isEmpty,
            sessionBusy: live.contains { $0.liveStatus == "busy" },
            sessionsLive: !live.isEmpty,
            quietFor: now.timeIntervalSince(quietSince))
        let mode = CompanionMode.mode(for: signals)
        judgeNod(before: model.mode, signals: &signals, waiting: waiting, now: now)
        if model.mode != mode { model.mode = mode }
        if nodRequestsSeen != nav.companionInputs.nodRequests {
            nodRequestsSeen = nav.companionInputs.nodRequests
            model.nods &+= 1
        }
        let badge = nav.companionBadge ? waiting.count : 0
        if model.badgeCount != badge { model.badgeCount = badge }
        if model.badgeMuted != nav.isMuted { model.badgeMuted = nav.isMuted }
        if model.size != nav.companionSize { model.size = nav.companionSize }
    }

    // MARK: - Nod

    // Who may stir the character. PanelController narrows it to events whose
    // session isn't muted; by default everything does.
    var interrupts: (NudgeEvent) -> Bool = { _ in true }
    private var arrived: [NudgeEvent] = []
    private var lastNod: Date?
    private var nodRequestsSeen = 0

    // Called for each event that lands after launch. The pose is judged on the
    // next refresh, once the event is in the store, so "before" is still the
    // pose the character wore when it arrived.
    func noteArrival(_ event: NudgeEvent) {
        guard nav.companionEnabled else { return }
        arrived.append(event)
    }

    // A finished turn is what the nod is for, so it must not count as the pose
    // that rules the nod out: it waits to be read, which would otherwise always
    // read as pending. The pose afterwards is still the waiting one: a
    // finished turn waves.
    private func judgeNod(before: SkinMode, signals: inout CompanionSignals, waiting: [NudgeEvent], now: Date) {
        guard !arrived.isEmpty else { return }
        let events = arrived
        arrived = []
        let judged = Set(events.filter(CompanionNod.isInfo).map(\.id))
        signals.eventWaiting = waiting.contains { !judged.contains($0.id) }
        let calmAfter = CompanionMode.mode(for: signals)
        guard CompanionNod.shouldNod(arrivals: events, interrupts: interrupts, muted: nav.isMuted,
                                     reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                     gateActive: CompanionGate.shared.active, before: before, after: calmAfter,
                                     lastNod: lastNod, now: now) else { return }
        lastNod = now
        model.nods &+= 1
    }

    // The character's frame while it is on screen; nil when the companion is off.
    var visibleFrame: CGRect? {
        guard nav.companionEnabled, let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    private func dragEnded() {
        guard let panel else { return }
        let size = nav.companionSize.points
        anchor = CompanionPlacement.clamp(CGPoint(x: panel.frame.maxX, y: panel.frame.minY),
                                          size: size, screens: NSScreen.screens.map(\.frame))
        panel.setFrameOrigin(CompanionPlacement.origin(anchor: anchor, size: size))
        ConfigFile.write(key: Self.positionKey, value: CompactPlacement.formatPosition(anchor))
        onMove?()
    }

    // The menu's and Settings' "Reset position": forget the saved spot and put
    // the character back where a fresh install starts it.
    func resetPosition() {
        ConfigFile.remove(key: Self.positionKey)
        anchor = Self.defaultAnchor()
        apply()
        onMove?()
    }

    // A display came or went: return to the saved spot, clamped to a screen
    // that exists, so plugging the display back in puts the character back.
    // Only a drag rewrites the saved spot.
    private func screensChanged() {
        anchor = Self.savedAnchor() ?? anchor
        apply()
    }

    private static func savedAnchor() -> CGPoint? {
        CompactPlacement.parsePosition(ConfigFile.read()[positionKey])
    }

    private static func defaultAnchor() -> CGPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CompanionPlacement.defaultAnchor(visibleFrame: visible)
    }
}
