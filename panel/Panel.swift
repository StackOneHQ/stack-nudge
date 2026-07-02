import AppKit
import Combine
import SwiftUI
import UserNotifications

protocol PanelKeyDelegate: AnyObject {
    func panelHandlesKey(_ event: NSEvent) -> Bool
}

private enum KeyCode {
    static let escape:    UInt16 = 53
    static let upArrow:   UInt16 = 126
    static let downArrow: UInt16 = 125
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let numpadEnter: UInt16 = 76
    static let space:     UInt16 = 49
    static let tab:       UInt16 = 48
    static let oKey:      UInt16 = 31
    static let sKey:      UInt16 = 1
    static let rKey:      UInt16 = 15
    static let delete:    UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let comma:     UInt16 = 43
    static let one:       UInt16 = 18
    static let two:       UInt16 = 19
    static let three:     UInt16 = 20
    static let four:      UInt16 = 21
    static let five:      UInt16 = 23
    static let nKey:      UInt16 = 45
    static let pKey:      UInt16 = 35
    static let mKey:      UInt16 = 46
}

// Floating, non-activating panel. Shown via global hotkey; receives key
// events without activating the parent app, so the user's editor stays
// frontmost in the system sense while the panel captures keystrokes.
final class FloatingPanel: NSPanel {

    weak var keyDelegate: PanelKeyDelegate?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = .floating
        self.isFloatingPanel = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isMovableByWindowBackground = true
        self.isReleasedWhenClosed = false
        self.hasShadow = true
        // borderless + resizable: no visible chrome but mouse-drag on edges
        // still works (standard Mac borderless-but-resizable pattern).
        // contentMinSize keeps the layout from breaking; no max — let users
        // expand to whatever fits their workflow.
        self.contentMinSize = NSSize(width: 560, height: 260)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if let delegate = keyDelegate, delegate.panelHandlesKey(event) {
            return
        }
        super.keyDown(with: event)
    }
}

struct PanelContentView: View {

    @ObservedObject var store: EventStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var nav: PanelNav
    @ObservedObject var phrases: PhrasesViewModel

    let onGrantPermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if nav.compactMode, !nav.compactExpanded,
               nav.mode != .bootstrap, nav.mode != .postUpdate {
                // Glance-only widget. Expand button → transient full panel;
                // double-click on the pill → exit compact mode entirely.
                // Callbacks are wired from PanelController so the window
                // resize happens synchronously before SwiftUI re-renders
                // the full panel content into the still-compact frame.
                CompactView(
                    store: store,
                    sessions: sessions,
                    nav: nav,
                    // Both the expand button and double-click exit compact
                    // mode persistently — that's what the user wants: a
                    // one-way "ok I want the full panel from now on."
                    onExpand: { nav.actions?.exitCompactMode() },
                    onExitCompact: { nav.actions?.exitCompactMode() }
                )
            } else if nav.mode == .bootstrap {
                // Full-screen first-launch experience: install + onboarding
                // + Grant Permissions, all in one cohesive flow.
                BootstrapView(
                    nav: nav,
                    hotkeyDisplay: nav.hotkeyDisplay,
                    onInstall: { nav.actions?.runBootstrap() },
                    onGrantPermissions: onGrantPermissions,
                    onQuit: { Bootstrap.userQuit() }
                )
            } else if nav.mode == .postUpdate {
                // Full-screen takeover, no tab strip — matches welcome's
                // single-purpose first-launch feel.
                PostUpdateView(nav: nav, onDismiss: {
                    nav.postUpdateVersion = nil
                    nav.postUpdateNotes = nil
                    nav.mode = .events
                })
            } else {
                tabStrip
                Divider().opacity(0.4)

                switch nav.mode {
                case .events:   eventsBody
                case .sessions: SessionsView(store: sessions, events: store, nav: nav)
                case .usage:    UsageView(nav: nav)
                case .outcomes: OutcomesView(nav: nav)
                case .settings: SettingsView(nav: nav)
                case .phrases:  PhrasesView(model: phrases) { nav.mode = .settings }
                case .updateConfirm:
                    UpdateConfirmView(
                        nav: nav,
                        onCancel: { nav.mode = .settings },
                        onConfirm: { nav.actions?.runUpdate() }
                    )
                case .updating: UpdatingView(nav: nav)
                case .postUpdate: EmptyView()  // handled above
                case .bootstrap:  EmptyView()  // handled above
                case .uninstall:
                    UninstallView(
                        nav: nav,
                        onCancel: { nav.mode = .settings },
                        onConfirm: { nav.actions?.runUninstall() }
                    )
                }
            }
        }
    }

    // Distinct ticket/branch groups in the ledger — the badge on the Tickets
    // tab. Reads nav.handoffsRevision so the count refreshes when a Stop adds
    // a session while the panel is open.
    private var ticketGroupCount: Int {
        _ = nav.handoffsRevision
        return Set(HandoffLedger.shared.all().map { $0.ticket ?? $0.branch ?? "—" }).count
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarController.brandMarkImage(height: 14))
                .padding(.trailing, 4)

            tab(.events,   label: "Events",   count: store.events.count)
            tab(.sessions, label: "Sessions", count: sessions.sessions.filter { $0.status == .active }.count)
            tab(.usage,    label: "Usage",    count: 0)
            tab(.outcomes, label: "Tickets",  count: ticketGroupCount)
            tab(.settings, label: "Settings", count: 0, dot: nav.updateAvailable != nil)

            Spacer()

            // One combined hint instead of per-tab keycaps — keeps the strip
            // uncluttered while still surfacing the shortcut range.
            HStack(spacing: 2) {
                KeyCapView(symbol: "⌘")
                KeyCapView(symbol: "1-5")
            }
            .opacity(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tab(_ mode: PanelMode, label: String, count: Int, dot: Bool = false) -> some View {
        let isActive = nav.mode == mode
        return Button {
            nav.mode = mode
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.primary.opacity(isActive ? 0.18 : 0.10))
                        )
                }
                if dot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var eventsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = nav.listenerError {
                listenerErrorBanner(error)
            }
            if store.events.isEmpty {
                emptyState
            } else {
                eventList
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func listenerErrorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No nudges yet")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.events) { event in
                        EventRow(event: event,
                                 selected: store.selectedID == event.id)
                            .id(event.id)
                            .contentShape(Rectangle())
                            .onTapGesture { store.selectedID = event.id }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .background(ThinScrollers())
            }
            // Without an explicit max-height claim the ScrollView expands to
            // fit its content, which pushes the last row past the panel's
            // visible bottom — same shape as the prior Usage fix.
            .frame(maxHeight: .infinity)
            // Arrow-key selection changes the model but not the viewport,
            // so the new selection can land off-screen. Mirror it back into
            // view; .center keeps the row comfortably inside the strip
            // rather than flush against the edge.
            .onChange(of: store.selectedID) { newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        PageFooter {
            if store.events.isEmpty {
                FooterHint(label: "Hide", keys: ["Esc"])
            } else {
                if let primary = primaryActionLabel {
                    FooterHint(label: primary, keys: ["⏎"], primary: true)
                    FooterDivider()
                }
                FooterHint(label: "Select",  keys: ["↑", "↓"])
                FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
                // Snooze is always rendered so the footer never reflows when
                // selection moves between event types — dimmed when the row
                // isn't snoozable. The S key is wired to fire only for
                // snoozable rows, so the dim state matches behavior.
                FooterHint(label: "Snooze",  keys: ["S"])
                    .opacity(snoozeEnabled ? 1.0 : 0.35)
                FooterHint(label: dismissLabel, keys: ["⌫"])
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
    }

    private var snoozeEnabled: Bool {
        guard let selected = store.selectedEvent else { return false }
        return selected.kind == .permission && selected.hasActionButton
    }

    private var primaryActionLabel: String? {
        guard let event = store.selectedEvent else { return nil }
        return event.kind == .permission ? "Approve" : "Open editor"
    }

    // ⌫ denies a blocking permission (writes "deny" to its FIFO); for any other
    // event it's a plain dismiss. Label it to match so the gesture isn't a surprise.
    private var dismissLabel: String {
        guard let event = store.selectedEvent,
              event.kind == .permission, event.hasActionButton else { return "Dismiss" }
        return "Deny"
    }
}


struct EventRow: View {

    let event: NudgeEvent
    let selected: Bool

    // The disk-backed name store. Observed so a rename in the Sessions
    // tab immediately re-renders any visible event for the same
    // (agent, projectPath) — render-time lookup, not ingest-time snapshot.
    @EnvironmentObject private var persistence: SessionPersistence


    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.body)
                .foregroundStyle(glyphColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let term = terminalLabel {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(term)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let label = sessionLabel {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let tab = secondaryTabLabel {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(tab)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Text(rightTimestamp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(event.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .opacity(isSnoozed ? 0.55 : 1.0)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .padding(.horizontal, 6)
    }

    // Composes the selection tint with a 3pt left-edge accent in the
    // session's stable color — same treatment as the Sessions tab card,
    // so the eye can connect a nudge to its session at a glance.
    private var rowBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            if let accent = SessionColor.color(
                agent: event.agent,
                projectPath: event.projectPath,
                tabId: tabIdentifier
            ) {
                Rectangle()
                    .fill(accent.opacity(0.85))
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var isSnoozed: Bool {
        guard let until = event.snoozedUntil else { return false }
        return until > Date()
    }

    // Show the user-chosen session name when one is set, otherwise the
    // project folder's basename. Lookup is keyed by (agent, projectPath,
    // tabId) — iTerm contributes its session id, VSCode/Cursor
    // contribute the IPC hook path. Falls back to (agent, projectPath)
    // transparently for events without a tab-scoped id and for
    // pre-Stage-2 persistence entries.
    private var sessionLabel: String? {
        if let custom = persistence.customName(
            agent: event.agent,
            projectPath: event.projectPath,
            tabId: tabIdentifier
        ) {
            return custom
        }
        guard let project = event.projectPath else { return nil }
        return (project as NSString).lastPathComponent
    }

    // First non-empty of [iTerm session id, VSCode IPC hook]. Each
    // terminal contributes whatever it has; the lookup layer doesn't
    // care which one fired as long as it's stable per tab/window.
    private var tabIdentifier: String? {
        if let sid = event.sessionID, !sid.isEmpty { return sid }
        if let hook = event.ipcHook, !hook.isEmpty { return hook }
        return nil
    }

    // iTerm2 tab/session label shown next to the session chip, but only
    // when it adds information — suppress it if it'd just echo the
    // session label we already showed.
    private var secondaryTabLabel: String? {
        guard let raw = event.itermTabName?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty,
              raw != sessionLabel else { return nil }
        return raw
    }

    // Where the event came from. Normalises the helper-process names
    // we capture in the wire payload to short, human-readable labels —
    // "Code Helper (Renderer)" reads as terminal-developer noise; "Code"
    // reads as "this came from VSCode". Returns nil when we don't know
    // the terminal, so the chip silently vanishes for those events.
    private var terminalLabel: String? {
        guard let raw = event.terminalApp?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        switch raw {
        case "Code", "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)":
            return "VSCode"
        case "Cursor", "Cursor Helper", "Cursor Helper (Plugin)", "Cursor Helper (Renderer)":
            return "Cursor"
        case "Antigravity", "Antigravity Helper", "Antigravity Helper (Plugin)", "Antigravity Helper (Renderer)":
            return "Antigravity"
        case "WarpTerminal":             return "Warp"
        case "iTerm", "iTerm2":          return "iTerm2"
        case "ghostty", "Ghostty":       return "Ghostty"
        case "Terminal":                 return "Terminal"
        case "Zed", "zed":               return "Zed"
        default:                         return raw
        }
    }

    // For snoozed events show "snoozed Xm" in place of the relative
    // timestamp so the user can see how long is left until the re-fire.
    private var rightTimestamp: String {
        if let until = event.snoozedUntil, until > Date() {
            return "snoozed " + RelativeTime.string(until)
        }
        return RelativeTime.string(event.timestamp)
    }

    private var glyph: String {
        if isSnoozed { return "moon.zzz.fill" }
        return event.kind == .permission ? "questionmark.circle.fill" : "checkmark.circle.fill"
    }

    private var glyphColor: Color {
        if isSnoozed { return .gray }
        return event.kind == .permission ? .orange : .green
    }
}

// Owns the panel + hotkey + listener + menu bar.
final class PanelController: NSObject, NSApplicationDelegate, PanelKeyDelegate,
                             UNUserNotificationCenterDelegate {

    private var panel: FloatingPanel!
    // Held so applyCompactLayout can swap its corner radius between the
    // full-panel value and the pill's capsule radius — otherwise the
    // smaller-radius rect corners poke past the SwiftUI capsule curve.
    private weak var contentBlurView: NSVisualEffectView?
    private var hotkey: Hotkey?
    private let store = EventStore()
    private let sessions = SessionStore()
    let nav = PanelNav()
    private let phrases = PhrasesViewModel()
    private var listener: EventListener?
    private var menuBar: MenuBarController?
    private var permissionsWC: PermissionsWindowController?
    private var updateChecker: UpdateChecker?
    private var updater: Updater?
    private let quotaProbe = QuotaProbe()
    private let claudeCliQuotaProbe = ClaudeCliQuotaProbe()
    private let codexQuotaProbe = CodexQuotaProbe()
    private let antigravityUsageProbe = AntigravityUsageProbe()
    private var quotaTimer: Timer?
    private struct TranscriptRefreshKey: Equatable {
        let pid: Int
        let agent: String
        let projectPath: String?
        let claudeSessionID: String?
        let liveStatus: String?
        let lastActivityAt: Date?
    }
    // Subscriptions to other ObservableObjects we react to from PanelController.
    // Currently: SessionStore.sessions → refresh transcript stats proactively
    // so threshold alerts fire even when no hook has arrived yet.
    private var cancellables = Set<AnyCancellable>()
    // Tracks whether the banner has already fired this period per tier so
    // we don't refire on every poll. Reset when the tier's resets_at
    // advances (a new period started, fresh budget).
    // Per-tier alert state. `maxBucketFired` is the highest 5%-bucket
    // (80, 85, 90, …) we've already alerted on; further alerts only fire
    // when utilization crosses into a *new* higher bucket. `peakUtil`
    // detects period rollover heuristically — a >30 pp drop from the
    // running peak resets the bucket gate (the 5-hour window's
    // resets_at slides forward every poll so we can't trust it).
    private var quotaLastFired: [String: (maxBucketFired: Int, peakUtil: Double)] = [:]

    // When a notification banner is clicked, macOS fires
    // applicationShouldHandleReopen BEFORE userNotificationCenter(_:didReceive:).
    // Our reopen handler shows the panel; didReceive then hides it as
    // part of the banner-click flow — producing a visible flash. We
    // defer the reopen-show and let didReceive cancel it by setting
    // this deadline. See applicationShouldHandleReopen for the deferral
    // logic and didReceive for the cancellation.
    private var bannerActivationUntil: Date = .distantPast

    // Last time onAppend fired. macOS can deliver applicationShouldHandleReopen
    // as a side effect of posting a banner (notably under Ghostty), not just
    // when the user clicks one — so the bannerActivationUntil veto, which
    // only sets in didReceive, doesn't catch this case. Suppress the deferred
    // showPanel for ~2s after any event arrival so a banner post never
    // pops the panel uninvited.
    private var lastEventArrivalAt: Date = .distantPast

    // UserDefaults keys for panel size + origin persistence. UserDefaults
    // lives in ~/Library/Preferences/com.stackonehq.stack-nudge.plist, so it
    // survives uninstall/reinstall cycles of ~/.stack-nudge/ and across
    // app updates that swap the .app bundle.
    private static let panelSizeKey   = "PanelSize"
    private static let panelOriginKey = "PanelOrigin"
    private static let panelDefaultSize = NSSize(width: 600, height: 320)
    private static let panelMinWidth:  CGFloat = 560
    private static let panelMinHeight: CGFloat = 260

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-1.7 users had `stack-nudge.app` in ~/Applications/. If we're
        // running from the new `StackNudge.app` location, scrub the
        // stale bundle + rewrite the launchd plist so launchctl points
        // at us, not the old path.
        Bootstrap.migrateBundleNameIfNeeded()
        // Updater preserves the previous bundle at StackNudge.app.old as a
        // rollback safety net. We're the new bundle, we've successfully
        // launched, so the safety net has served its purpose — recycle it
        // so Spotlight stops indexing two StackNudge.app entries.
        Bootstrap.cleanupPostUpdateBackup()
        // We're back up, so any prior user-Quit intent is satisfied. Clear
        // the marker so notify.sh will relaunch us on the next event after
        // the *next* Quit.
        Bootstrap.clearUserQuitMarker()

        let size = Self.loadSavedPanelSize()
        let frame = NSRect(origin: .zero, size: size)
        panel = FloatingPanel(contentRect: frame)
        panel.keyDelegate = self

        // HUD-blur background, rounded corners. SwiftUI hosts inside.
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        contentBlurView = blur

        let host = NSHostingView(rootView: PanelContentView(
            store: store, sessions: sessions, nav: nav, phrases: phrases,
            onGrantPermissions: { [weak self] in self?.handleGrantPermissions() }
        ).environmentObject(SessionPersistence.shared))
        // Don't let SwiftUI's preferred / intrinsic content size drive
        // the NSPanel frame. The panel is user-resizable + size-persisted;
        // a tab whose root view reports a different sizeThatFits (e.g.,
        // the Loading-quota empty state) was causing the window to
        // resize on every switch.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])
        panel.contentView = blur

        positionPanel()
        observePanelFrameChanges()

        let config = PanelConfig.load()
        nav.hotkeyDisplay = config.hotkeySpec
        _ = registerHotkey(spec: config.hotkeySpec)

        startListener()
        menuBar = MenuBarController(panelController: self)

        nav.actions = SettingsActions(
            checkPermissions: { [weak self] in self?.showPermissions() },
            openConfig: { [weak self] in
                // Same z-order issue: the editor app's regular window opens
                // below our floating panel. Hide the panel first.
                self?.panel.orderOut(nil)
                self?.nav.mode = .events
                NSWorkspace.shared.open(URL(fileURLWithPath: ConfigFile.path))
            },
            editPhrases:      { [weak self] in
                self?.phrases.load()
                self?.phrases.selectedRow = nil
                self?.nav.mode = .phrases
            },
            openReleaseNotes: {
                // Versioned tag URL when we know the bundle version,
                // otherwise the releases index. Tag URL falls through
                // to /releases on 404, so a typo'd version still lands
                // the user somewhere useful.
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                let url = version.flatMap {
                    URL(string: "https://github.com/StackOneHQ/stack-nudge/releases/tag/v\($0)")
                } ?? URL(string: "https://github.com/StackOneHQ/stack-nudge/releases")!
                NSWorkspace.shared.open(url)
            },
            checkForUpdates:  { [weak self] in self?.runUserUpdateCheck() },
            beginUpdate:      { [weak self] in self?.beginUpdateFlow() },
            runUpdate:        { [weak self] in self?.updater?.run() },
            beginUninstall:   { [weak self] in self?.beginUninstallFlow() },
            runUninstall:     { [weak self] in self?.runUninstall() },
            runBootstrap:     { [weak self] in self?.runBootstrap() },
            quit:             { Bootstrap.userQuit() },
            expandFromCompact: { [weak self] in self?.expandFromCompact() },
            exitCompactMode:   { [weak self] in self?.exitCompactMode() }
        )
        nav.setHotkey = { [weak self] spec in
            self?.registerHotkey(spec: spec) ?? false
        }
        nav.refreshOutcomes = { [weak self] in self?.refreshOutcomes() }
        nav.refreshPullRequests = { [weak self] in self?.refreshPullRequests() }
        nav.startGithubSignIn = { [weak self] in self?.startGithubSignIn() }
        nav.cancelGithubSignIn = { [weak self] in self?.cancelGithubSignIn() }

        startConfigWatcher()
        setupNotificationCenter()
        store.onAppend = { [weak self] event in
            self?.lastEventArrivalAt = Date()
            self?.postBannerIfNeeded(event)
            self?.refreshTranscriptStats(for: event)
            self?.captureHandoff(for: event)
            self?.nav.reactToEvent(event.kind)
        }
        nav.loadFromConfig()  // populate panelPinned + other live values up-front
        // Scan agent configs for missing wires (post-update / post-install
        // reconciliation). Surfaces a "Set up X" banner in Settings when
        // any detected agent lacks our notify.sh hook.
        nav.refreshUnwiredAgents()

        updateChecker = UpdateChecker(nav: nav)
        updateChecker?.start()
        updater = Updater(nav: nav)

        startQuotaPolling()
        // The pill (CompactView) reads sessions.sessions for the busy/idle
        // headline and mascot state, so polling has to run as soon as the
        // app is up — not gated on the Sessions tab being visible. Sessions
        // view switches to the foreground cadence while it is on screen.
        sessions.startPolling()

        // Refresh transcript stats when meaningful session state changes,
        // not when ps's display-only elapsed string advances on every poll.
        // Hook events still refresh immediately; sidecar activity changes
        // keep proactive context alerts current.
        sessions.$sessions
            .map { sessions in
                sessions.map {
                    TranscriptRefreshKey(
                        pid: $0.pid,
                        agent: $0.agent,
                        projectPath: $0.projectPath,
                        claudeSessionID: $0.claudeSessionID,
                        liveStatus: $0.liveStatus,
                        lastActivityAt: $0.lastActivityAt
                    )
                }
            }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshAllClaudeStats() }
            .store(in: &cancellables)

        // Re-apply window layout whenever compact-mode state flips. Covers
        // both the persistent toggle (Settings → "Compact widget") and the
        // transient expanded flag (widget click → expand).
        nav.$compactMode
            .removeDuplicates()
            .dropFirst()  // initial value applied via applyCompactLayout on launch
            .sink { [weak self] _ in self?.applyCompactLayout() }
            .store(in: &cancellables)
        nav.$compactExpanded
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyCompactLayout() }
            .store(in: &cancellables)
        nav.$compactCorner
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.applyCompactLayout() }
            .store(in: &cancellables)
        nav.$compactAlpha
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyCompactAlpha() }
            .store(in: &cancellables)
        nav.$compactContent
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.applyCompactLayout() }
            .store(in: &cancellables)
        store.maxEventsPerSession = nav.eventsPerSession
        nav.$eventsPerSession
            .removeDuplicates()
            .sink { [weak self] value in self?.store.maxEventsPerSession = value }
            .store(in: &cancellables)
        applyCompactLayout()

        // If a previous panel instance was pkilled mid-update by install.sh,
        // it left a status file behind. Read it now and surface a brief toast
        // so the user knows the update completed (or failed).
        if let result = Updater.consumePostUpdateStatus() {
            handlePostUpdateStatus(result: result)
        }

        // First-launch detection: if no install artifacts exist on this Mac,
        // route the user through the bootstrap wizard before they can use
        // anything else. handlePostUpdateStatus took priority above so a
        // freshly-installed user upgrading via auto-update doesn't see the
        // wizard again.
        if !Bootstrap.isInstalled(), nav.mode != .postUpdate {
            nav.bootstrapAvailableAgents = Bootstrap.availableAgents()
            // Pre-select every detected agent — Claude, Cursor, Codex,
            // and Gemini all wire real hooks. Earlier versions excluded
            // Gemini because its row was info-only; that's no longer
            // true (AfterAgent + Notification are wired now).
            nav.bootstrapSelectedAgents  = Set(nav.bootstrapAvailableAgents)
            nav.bootstrapPhase           = .idle
            nav.mode                     = .bootstrap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
            }
        }

        // Auto-hide when the panel loses key focus, if pin is off.
        // Detect "click outside" without polling — NSWindow fires this when
        // another window or app takes focus.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        // Compact-mode drag handling: explicit mouse-up signal beats the
        // ambiguous time-based debounce. mouseDown resets the "moved"
        // flag; didMoveNotification sets it; mouseUp consults it to
        // decide whether to snap. A plain click without movement doesn't
        // trigger a snap.
        compactMouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  event.window === self.panel,
                  self.nav.compactMode, !self.nav.compactExpanded
            else { return event }
            switch event.type {
            case .leftMouseDown:
                self.compactMovedSinceMouseDown = false
                self.nav.compactDragging = true
            case .leftMouseUp:
                self.nav.compactDragging = false
                if self.compactMovedSinceMouseDown {
                    self.compactMovedSinceMouseDown = false
                    self.snapCompactToNearestCorner()
                }
            default: break
            }
            return event
        }
    }

    // Triggered from the welcome screen's "Grant permissions" button. Opens
    // the in-app Permissions window — it shows live status for Notifications,
    // Accessibility, and Automation, with per-row "Prompt" and "Settings"
    // buttons so the user can drive each grant without surprise modal dialogs
    // covering anything.
    private func handleGrantPermissions() {
        showPermissions()
    }

    // Click on the "Update available" row → load release notes (if not
    // already populated by the background checker) and switch to the
    // confirmation mode. The actual install kicks off only when the user
    // hits Update Now / Enter from the confirm view.
    private func beginUpdateFlow() {
        nav.mode = .updateConfirm
        // Fetch release notes lazily if we haven't already.
        if nav.updateReleaseNotes == nil {
            updateChecker?.fetchReleaseNotes { [weak self] body in
                self?.nav.updateReleaseNotes = body
            }
        }
    }

    // Surface the post-update view on first launch after a successful
    // update. Sets the version + mode immediately so the user sees the
    // confirmation right away, then kicks off an async release-notes
    // fetch (gh CLI fallback for private repos) that fills in the body
    // when it arrives. Failures during update get a one-line message
    // logged to stderr — no UI for that case yet.
    private func handlePostUpdateStatus(result: (state: String, version: String, error: String?)) {
        switch result.state {
        case "success":
            // Expand the window BEFORE flipping the mode. The order matters:
            // setting nav.mode = .postUpdate triggers a SwiftUI re-render
            // immediately, and if the window is still pill-sized at that
            // point, PostUpdateView (or even the Events page during a
            // transition) renders into the 320×56 frame and looks crushed.
            // Resizing first guarantees the full-panel content lands in a
            // full-panel-sized window.
            if nav.compactMode, !nav.compactExpanded {
                nav.compactExpanded = true
                // applyCompactLayout already ran via the Combine sink;
                // call again here so the synchronous setFrame is committed
                // before the mode flip below schedules SwiftUI work.
                applyCompactLayout()
            }
            nav.postUpdateVersion = result.version.isEmpty ? "?" : result.version
            nav.postUpdateNotes = nil
            nav.mode = .postUpdate
            // Auto-open the panel so the user immediately sees the
            // "what shipped" view rather than discovering it via hotkey.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
            }
            if !result.version.isEmpty {
                updateChecker?.fetchReleaseNotes(for: result.version) { [weak self] body in
                    self?.nav.postUpdateNotes = body
                }
            }
        case "failed":
            FileHandle.standardError.write(Data(
                "stack-nudge: previous update failed: \(result.error ?? "unknown")\n".utf8))
        default:
            return
        }
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        // Compact mode: don't hide on focus loss — the widget is meant to
        // stay visible. Collapse back from "expanded" if the user clicked
        // away while in the full-panel render. Apply layout synchronously
        // so the panel actually shrinks before SwiftUI re-evaluates body
        // (otherwise the new CompactView renders at the still-large size).
        if nav.compactMode {
            // Pin panel + Widget: Pin wins. Stay full-size on focus loss;
            // the widget collapse still happens via Esc / hotkey / explicit
            // user gestures, but auto-collapse on focus loss is suppressed.
            if nav.panelPinned { return }
            if nav.compactExpanded {
                nav.compactExpanded = false
                applyCompactLayout()
            }
            return
        }
        guard !nav.panelPinned, panel.isVisible else { return }
        hidePanel()
    }

    // MARK: - Compact widget layout

    private static let compactWidgetSize = NSSize(width: 290, height: 56)
    private static let compactWidgetUsageSize = NSSize(width: 145, height: 66)
    private static let compactWidgetInset: CGFloat = 14

    private var compactWidgetSizeForMode: NSSize {
        nav.compactContent == .usage
            ? Self.compactWidgetUsageSize
            : Self.compactWidgetSize
    }

    // Apply window size + origin appropriate to the current compact-mode
    // state. Called whenever nav.compactMode or nav.compactExpanded changes
    // and once at launch to handle config-restored state.
    private func applyCompactLayout() {
        if nav.compactMode, !nav.compactExpanded {
            // Widget: shrink + pin to the chosen corner, float above
            // everything, follow the user across spaces. Transparent
            // window background so the SwiftUI Capsule shows through.
            let size = compactWidgetSizeForMode
            // Lower the minimum content size below the widget dimensions
            // so AppKit doesn't enforce the original 560x260 floor after
            // a system event like screen reconfiguration or lock/unlock.
            panel.contentMinSize = size
            var frame = panel.frame
            frame.size = size
            frame.origin = compactCornerOrigin(for: size)
            ignoringProgrammaticMove = true
            panel.setFrame(frame, display: true, animate: false)
            ignoringProgrammaticMove = false
            // Match the SwiftUI Capsule's corner radius (half the pill
            // height) so the blur backing doesn't poke out beyond the
            // capsule curve and show as dark squares in the corners.
            contentBlurView?.layer?.cornerRadius = size.height / 2
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                        .fullScreenAuxiliary, .ignoresCycle]
            panel.hasShadow = false  // SwiftUI Capsule provides its own
            panel.isMovableByWindowBackground = true  // drag to reposition
            // Dropping .resizable kills invisible edge-resize handles and
            // opts out of macOS Sequoia's drag-to-edge tile gesture.
            panel.styleMask.remove(.resizable)
            panel.orderFront(nil)
        } else {
            // Full panel: restore saved size + saved origin. Keep
            // backgroundColor/isOpaque at the original transparent
            // settings — the NSVisualEffectView contentView provides
            // the visual; overriding the window's opacity here would
            // break the blur.
            let size = Self.loadSavedPanelSize()
            var frame = panel.frame
            frame.size = size
            // display:false defers the redraw to AppKit's next layout pass,
            // by which time SwiftUI has re-evaluated body and replaced
            // CompactView with the full panel content. With display:true
            // here, AppKit forces an immediate paint while SwiftUI still
            // has the stale CompactView in its tree — the pill renders into
            // the new larger frame for one frame and the user sees a flicker.
            panel.setFrame(frame, display: false, animate: false)
            // Restore the original layout-protecting minimum so SwiftUI's
            // full panel content (Settings, Sessions, etc.) has room.
            panel.contentMinSize = NSSize(width: 560, height: 260)
            contentBlurView?.layer?.cornerRadius = 12
            panel.level = .floating
            panel.collectionBehavior = []
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.styleMask.insert(.resizable)
            positionPanel()
            if nav.compactExpanded {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        }
        applyCompactAlpha()
    }

    // Called from the widget's expand button. Sets the expanded flag,
    // applies layout synchronously (so the panel is resized before SwiftUI
    // re-renders the full content into the still-compact frame), then
    // brings the window forward.
    private func expandFromCompact() {
        nav.compactExpanded = true
        applyCompactLayout()
    }

    // Applies the user-configured widget opacity to the window. Only takes
    // effect in pill mode; expanded panel + full-mode are always fully
    // opaque so the user can actually read content.
    private func applyCompactAlpha() {
        if nav.compactMode, !nav.compactExpanded {
            panel.alphaValue = CGFloat(nav.compactAlpha)
        } else {
            panel.alphaValue = 1.0
        }
    }

    // Wraps expandFromCompact for entry points that come from mouse/tap
    // events on the pill itself — the SwiftUI expand button and the
    // double-tap gesture. Notification banners sit at the same screen
    // corner as the pill, so a click meant for the banner can leak
    // through and activate these. Hotkey + keyboard paths (M, global
    // toggle) bypass this veto because keyboard input is unambiguous.
    private func expandFromCompactUserGesture() {
        if Date().timeIntervalSince(lastEventArrivalAt) < 2 { return }
        expandFromCompact()
    }

    // Compact mode is always on, so what used to be "exit compact"
    // (double-click, expand button) now means "expand to full panel
    // temporarily." Calling expandFromCompact lets the existing wiring
    // and Settings actions keep working without renaming.
    private func exitCompactMode() {
        // exitCompactMode is wired into the SwiftUI expand button and the
        // pill's double-tap gesture — both ambiguous in the banner window.
        // The hotkey/M paths call expandFromCompact directly and skip this
        // veto, so a deliberate keystroke still expands instantly.
        expandFromCompactUserGesture()
    }

    // Debounced snap: each move during a drag bumps the deadline forward.
    // After the user releases (no further moves for ~280ms), pick the
    // nearest corner of the active screen, persist it, and animate the
    // panel home.
    // Set TRUE around each programmatic setFrame so the resulting
    // didMoveNotification (which fires synchronously when the frame
    // changes) doesn't get treated as a user drag.
    private var ignoringProgrammaticMove = false
    // Tracks whether the panel actually moved since the user pressed
    // the mouse button. The .leftMouseUp monitor consumes this to
    // decide whether a snap is warranted (a plain click shouldn't snap).
    private var compactMovedSinceMouseDown = false
    private var compactMouseEventMonitor: Any?

    private func snapCompactToNearestCorner() {
        guard nav.compactMode, !nav.compactExpanded else { return }
        let visible = activeScreen().visibleFrame
        let size = panel.frame.size
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let corner: CompactCorner
        switch (center.x < visible.midX, center.y < visible.midY) {
        case (true,  false): corner = .topLeft
        case (false, false): corner = .topRight
        case (true,  true):  corner = .bottomLeft
        case (false, true):  corner = .bottomRight
        }
        // Animate from the released position to the target corner FIRST.
        // Persist the corner only after the animation finishes — otherwise
        // updating nav.compactCorner mid-animation fires the Combine sink,
        // applyCompactLayout instant-snaps the panel to the new corner,
        // and the subsequent animator setFrame has nothing to tween.
        let target = cornerOrigin(for: size, corner: corner)
        // animator().setFrame updates panel.frame synchronously (the
        // animation is purely visual via Core Animation). Wrap that one
        // synchronous call so its didMove doesn't schedule another snap.
        ignoringProgrammaticMove = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: target, size: size),
                                      display: true)
        }
        ignoringProgrammaticMove = false
        // Commit the corner. Combine sink fires applyCompactLayout, which
        // also goes through ignoringProgrammaticMove via its own
        // wrapped setFrame, so no extra snap is scheduled.
        if nav.compactCorner != corner {
            nav.compactCorner = corner
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CORNER",
                             value: corner.rawValue)
        }
    }

    private func compactCornerOrigin(for size: NSSize) -> NSPoint {
        cornerOrigin(for: size, corner: nav.compactCorner)
    }

    private func cornerOrigin(for size: NSSize, corner: CompactCorner) -> NSPoint {
        let visible = activeScreen().visibleFrame
        let inset = Self.compactWidgetInset
        switch corner {
        case .topLeft:
            return NSPoint(x: visible.minX + inset,
                           y: visible.maxY - size.height - inset)
        case .topRight:
            return NSPoint(x: visible.maxX - size.width - inset,
                           y: visible.maxY - size.height - inset)
        case .bottomLeft:
            return NSPoint(x: visible.minX + inset,
                           y: visible.minY + inset)
        case .bottomRight:
            return NSPoint(x: visible.maxX - size.width - inset,
                           y: visible.minY + inset)
        }
    }

    // MARK: - Bootstrap (first-launch install)

    // Run Bootstrap.install on a background queue, stream progress lines
    // into nav.bootstrapLog so the wizard updates live. Switch phase to
    // .done on success, .failed on error.
    private func runBootstrap() {
        let agents = nav.bootstrapSelectedAgents
        nav.bootstrapPhase = .installing
        nav.bootstrapLog = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Bootstrap.install(agents: agents) { line in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let prefix = self.nav.bootstrapLog.isEmpty ? "" : "\n"
                        self.nav.bootstrapLog += prefix + line
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.nav.bootstrapPhase = .done
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.nav.bootstrapPhase = .failed(
                        (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Uninstall

    // Switch to the uninstall confirmation view from anywhere in Settings.
    private func beginUninstallFlow() {
        nav.uninstallPhase = .confirm
        nav.uninstallLog = ""
        nav.mode = .uninstall
    }

    // User confirmed uninstall. Run Bootstrap.uninstall on a background
    // queue. The final step (recycle + NSApp.terminate) is dispatched
    // from inside Bootstrap.uninstall so the app exits cleanly.
    private func runUninstall() {
        nav.uninstallPhase = .uninstalling
        nav.uninstallLog = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Bootstrap.uninstall { line in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let prefix = self.nav.uninstallLog.isEmpty ? "" : "\n"
                        self.nav.uninstallLog += prefix + line
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.nav.uninstallPhase = .failed(
                        (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Quota polling

    // Fires QuotaProbe on a recurring timer. Cadence varies: 60s while the
    // panel is visible (keeps the Usage tab feeling alive), longer when
    // hidden (default 5 min, configurable via STACKNUDGE_USAGE_POLL_MIN).
    // Re-evaluating on every tick keeps the timer schedule responsive to
    // the panel being shown/hidden.
    private static let quotaPollVisibleInterval: TimeInterval = 60
    private var quotaPollHiddenInterval: TimeInterval {
        let mins = Double(ConfigFile.read()["STACKNUDGE_USAGE_POLL_MIN"] ?? "") ?? 5
        return max(60, mins * 60)  // floor at 60s to avoid hammering the endpoint
    }

    private var quotaTrackingEnabled: Bool {
        ConfigFile.bool(ConfigFile.read(), "STACKNUDGE_QUOTA_TRACKING", default: true)
    }

    private func startQuotaPolling() {
        runQuotaProbe()
        scheduleNextQuotaPoll()
    }

    private func scheduleNextQuotaPoll() {
        quotaTimer?.invalidate()
        // Schedule unconditionally so a re-enable from Settings picks up
        // again on the next tick without needing an explicit start call.
        // The probe itself bails when tracking is off.
        let interval = panel.isVisible ? Self.quotaPollVisibleInterval : quotaPollHiddenInterval
        quotaTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.runQuotaProbe()
            self?.scheduleNextQuotaPoll()
        }
    }

    private func runQuotaProbe() {
        guard quotaTrackingEnabled else { return }
        nav.quotaSyncing = true
        // CLI probe first — Claude CLI reads its own keychain, so our process
        // never triggers the periodic password prompt. Only fall back to the
        // direct API probe when the CLI invocation failed outright (binary
        // missing, spawn/timeout error, or unparseable envelope). The CLI's
        // own soft-fail (rate-limited cold cache, no bucket lines) is treated
        // as "leave the prior snapshot alone" — NOT a reason to re-prompt
        // the user via the keychain path.
        claudeCliQuotaProbe.fetch { [weak self] snapshot in
            guard let self else { return }
            if let snapshot {
                self.nav.quotaSyncing = false
                self.nav.usingClaudeCliProbe = true
                self.nav.usingPlaintextCredentials = false
                self.nav.quota = snapshot
                self.nav.quotaError = nil
                self.nav.quotaLastUpdated = Date()
                self.evaluateQuotaThresholds(snapshot)
                return
            }
            if self.claudeCliQuotaProbe.isRateLimited {
                // Soft-fail: hold the prior snapshot, don't fall back to the
                // API probe (which would just hit the same upstream limit).
                self.nav.quotaSyncing = false
                self.nav.usingClaudeCliProbe = true
                return
            }
            // Hard-fail from the CLI probe → try the API probe.
            self.quotaProbe.fetch { [weak self] snapshot in
                guard let self else { return }
                self.nav.quotaSyncing = false
                self.nav.usingClaudeCliProbe = false
                self.nav.usingPlaintextCredentials = self.quotaProbe.usingPlaintextCredentials
                if let snapshot {
                    self.nav.quota = snapshot
                    self.nav.quotaError = nil
                    self.nav.quotaLastUpdated = Date()
                    self.evaluateQuotaThresholds(snapshot)
                } else if self.quotaProbe.isRateLimited {
                    self.nav.quotaError = "Rate-limited by Anthropic — retrying shortly."
                } else if self.quotaProbe.lastProbeFailed {
                    self.nav.quotaError = "Quota data unavailable — the usage endpoint may have changed."
                }
            }
        }
        // Codex (ChatGPT-plan) rate limits — read locally from the newest
        // rollout, no network. Independent of the Anthropic probe above so one
        // failing/absent doesn't suppress the other.
        codexQuotaProbe.fetch { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.nav.codexQuota = snapshot
            self.nav.quotaLastUpdated = Date()
        }
        // Antigravity (agy) usage — read from the running CLI's loopback RPC
        // (localhost only, no auth). Independent of the probes above.
        antigravityUsageProbe.fetch { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.nav.antigravityQuota = snapshot
            self.nav.quotaLastUpdated = Date()
        }
    }

    // Public hook for the Usage tab's "Sync now" keystroke.
    func syncQuotaNow() { runQuotaProbe() }

    // MARK: - Usage tab detail scrolling

    // SwiftUI's ScrollView has no programmatic delta-scroll API, so walk the
    // AppKit hierarchy to the underlying NSScrollView and nudge its clip view.
    // Only one ScrollView is rendered at a time (mode-gated), so the first
    // match is whichever detail pane is showing — the Usage tiers or the
    // Tickets rollup.
    private func scrollDetailBy(_ dy: CGFloat) {
        guard let scrollView = findScrollView(in: panel.contentView),
              let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(0, origin.y + dy), maxY)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // ⌘↑/↓ in a pure-scroll detail pane (no selection to move): jump the clip
    // view to the very top or bottom.
    private func scrollDetailToEdge(top: Bool) {
        guard let scrollView = findScrollView(in: panel.contentView),
              let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = top ? 0 : maxY
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // User-triggered update check with transient row feedback. Sets
    // .checking immediately, swaps to .upToDate / .failed on response
    // (the .updateAvailable path doesn't need transient feedback — the
    // pinned "Update to vX.Y.Z" row at the top is its own signal), and
    // auto-clears back to .idle after a few seconds.
    private func runUserUpdateCheck() {
        nav.updateCheckStatus = .checking
        // Minimum visible duration for the "Checking…" flash. Without
        // it, a sub-second network call would swap status faster than
        // the user can perceive, leaving the click feeling silent.
        let started = Date()
        let minChecking: TimeInterval = 0.6
        updateChecker?.check { [weak self] result in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(started)
            let delay = max(0, minChecking - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                switch result {
                case .updateAvailable: self.nav.updateCheckStatus = .updateAvailable
                case .upToDate:        self.nav.updateCheckStatus = .upToDate
                case .failed:          self.nav.updateCheckStatus = .failed
                }
                // Auto-clear so the row label returns to neutral on the
                // next visit. 3s is long enough to notice, short enough
                // not to mislead a later glance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    if self.nav.updateCheckStatus != .checking {
                        self.nav.updateCheckStatus = .idle
                    }
                }
            }
        }
    }

    // Fire a banner each time a tier crosses into a new 5% bucket at or
    // above the user's configured threshold. With threshold=80, the user
    // sees one alert at 80%, one at 85%, one at 90%, etc. — never more
    // than once per bucket. Buckets reset when we detect a sharp drop in
    // utilization (period rollover).
    //
    // Previous logic used the tier's `resets_at` to detect rollover, but
    // the 5-hour window's reset is a rolling timestamp that advances on
    // every poll, which caused spurious re-fires every few minutes.
    private static let quotaBucketSize: Int = 5
    private static let quotaResetDropThreshold: Double = 30   // pp

    private func evaluateQuotaThresholds(_ snapshot: QuotaSnapshot) {
        guard nav.quotaAlertsEnabled else { return }
        // Respect the global Banner notifications toggle — quota alerts
        // are system-level banners and shouldn't bypass it.
        guard nav.bannerEnabled else { return }
        let threshold = Double(nav.quotaAlertThreshold)

        let tiers: [(name: String, label: String, tier: QuotaTier?)] = [
            ("five_hour",        "Session",         snapshot.fiveHour),
            ("seven_day",        "Weekly",          snapshot.sevenDay),
            ("seven_day_opus",   "Weekly (Opus)",   snapshot.sevenDayOpus),
            ("seven_day_sonnet", "Weekly (Sonnet)", snapshot.sevenDaySonnet),
        ]

        let bucketSize = Self.quotaBucketSize

        for (name, label, tier) in tiers {
            guard let tier else { continue }
            var state = quotaLastFired[name] ?? (maxBucketFired: 0, peakUtil: 0)

            // Heuristic period-rollover: a >30 pp drop from our running
            // peak means a window rolled over (or the user is on a fresh
            // billing cycle). Clear the bucket gate so future climbs
            // alert again.
            if state.peakUtil - tier.utilization > Self.quotaResetDropThreshold {
                state = (maxBucketFired: 0, peakUtil: tier.utilization)
            } else {
                state.peakUtil = max(state.peakUtil, tier.utilization)
            }

            // Current 5% bucket: floor utilization to the nearest 5.
            let currentBucket = (Int(tier.utilization) / bucketSize) * bucketSize
            if currentBucket >= Int(threshold), currentBucket > state.maxBucketFired {
                postQuotaBanner(label: label,
                                percent: Int(tier.utilization.rounded()),
                                resetsAt: tier.resetsAt)
                state.maxBucketFired = currentBucket
            }
            quotaLastFired[name] = state
        }
    }

    private func postQuotaBanner(label: String, percent: Int, resetsAt: Date?) {
        let body: String
        if let resetsAt {
            body = "\(percent)% used. Resets \(RelativeTime.string(resetsAt, style: .full))."
        } else {
            body = "\(percent)% used."
        }
        let content = UNMutableNotificationContent()
        content.title = "\(label) quota at \(percent)%"
        content.body  = body
        content.categoryIdentifier = "STOP"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenter

    private func setupNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Request permission (shows the system dialog once; subsequent calls are no-ops).
        center.requestAuthorization(options: [.alert]) { _, _ in }

        // Register categories: STOP (no actions) and PERMISSION with Allow +
        // two snooze options. macOS surfaces the first action as a primary
        // button on the banner and collapses the rest into the chevron
        // expansion automatically once the action count exceeds two.
        let allow = UNNotificationAction(identifier: "ALLOW",
                                          title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "DENY",
                                         title: "Deny", options: [])
        let snooze5 = UNNotificationAction(identifier: "SNOOZE_5M",
                                            title: "Snooze 5 min", options: [])
        let snooze15 = UNNotificationAction(identifier: "SNOOZE_15M",
                                             title: "Snooze 15 min", options: [])
        // .customDismissAction routes a swipe-away through didReceive (as
        // UNNotificationDismissActionIdentifier) so we can resolve a blocking
        // permission's FIFO instead of leaving the hook hung to its timeout.
        let permCategory = UNNotificationCategory(identifier: "PERMISSION",
                                                   actions: [allow, deny, snooze5, snooze15],
                                                   intentIdentifiers: [],
                                                   options: [.customDismissAction])
        let stopCategory = UNNotificationCategory(identifier: "STOP",
                                                   actions: [],
                                                   intentIdentifiers: [],
                                                   options: [])
        center.setNotificationCategories([permCategory, stopCategory])
    }

    // Fire the user-facing cues (chime + voice + banner) for an incoming
    // event. Audio used to live in notify.sh (`afplay` and `stackvox say`
    // forked from the shell hook), but that meant quitting stack-nudge
    // didn't stop the bell — bash had already detached the child. Owning
    // playback here means Speaker.stopAllAudio() on quit silences us.
    //
    // Mute-when-focused: when the user is staring at the source editor
    // window we suppress the banner + voice, keeping only a subtle chime —
    // unless voice is on, in which case we stay fully silent (voice
    // replaces the chime in the existing UX contract).
    //
    // If STACKNUDGE_ACTIVATE_IMMEDIATELY is set, focus the source editor
    // right away without waiting for the user to click; we skip cues
    // entirely in that flow since the editor jump is the signal.
    // Re-read the Claude Code transcript referenced by an incoming
    // event and publish updated context-window stats to nav. Runs
    // off-main since transcripts can be a few MB; the final assignment
    // hops back to main so SwiftUI re-renders cleanly.
    // Refresh transcript stats for every known claude session whose
    // sidecar gave us a sessionId. Triggered when meaningful SessionStore
    // state changes, so stats stay current without rereading transcripts
    // for elapsed-time-only poll updates.
    private func refreshAllClaudeStats() {
        for session in sessions.sessions
            where session.agent == "claude" && session.status == .active
        {
            guard let id = session.claudeSessionID,
                  let project = session.projectPath
            else { continue }
            let path = Self.transcriptPath(projectPath: project, sessionID: id)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let stats = TranscriptReader.read(path: path) else { return }
                DispatchQueue.main.async {
                    self?.nav.claudeSessionStats[id] = stats
                    self?.evaluateContextThreshold(sessionID: id, stats: stats)
                }
            }
        }

        // Non-sidecar agents (Codex): re-read from the transcript path learned
        // from their hook events, keyed by PID. Keeps stats live and repopulates
        // them after EventStore pruning / panel navigation, mirroring the
        // Claude path above (which is driven by the per-pid sidecar).
        for session in sessions.sessions where session.status == .active {
            guard session.agent != "claude",
                  let ref = nav.transcriptRefByPID[session.pid]
            else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let stats = TranscriptReader.read(path: ref.path) else { return }
                DispatchQueue.main.async {
                    self?.nav.claudeSessionStats[ref.sessionID] = stats
                    self?.evaluateContextThreshold(sessionID: ref.sessionID, stats: stats)
                }
            }
        }
    }

    // Claude Code stores transcripts at:
    //   ~/.claude/projects/<slug>/<session-uuid>.jsonl
    // where the slug is the absolute project path with '/' replaced by '-'.
    private static func transcriptPath(projectPath: String, sessionID: String) -> String {
        let slug = projectPath.replacingOccurrences(of: "/", with: "-")
        return "\(NSHomeDirectory())/.claude/projects/\(slug)/\(sessionID).jsonl"
    }

    private func refreshTranscriptStats(for event: NudgeEvent) {
        guard let sessionID = event.claudeSessionID,
              let path = event.transcriptPath, !path.isEmpty
        else { return }
        // Cache the (session id, path) by agent PID so non-sidecar agents
        // (Codex) resolve + re-read stats without depending on this event
        // still being in the event list later.
        if let pid = event.agentPID, pid > 0 {
            nav.transcriptRefByPID[pid] = TranscriptRef(sessionID: sessionID, path: path)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let stats = TranscriptReader.read(path: path) else { return }
            DispatchQueue.main.async {
                self?.nav.claudeSessionStats[sessionID] = stats
                self?.evaluateContextThreshold(sessionID: sessionID, stats: stats)
            }
        }
    }

    // Persist a per-session handoff record at Stop (Claude + Codex — agy has no
    // Stop hook). Resolves git repo/branch + ticket + the latest token usage
    // off-main, then upserts the session's row in the ledger. This is the basis
    // for the per-ticket usage rollup. Non-git directories are skipped — there's
    // nothing to attribute to a repo/ticket.
    private func captureHandoff(for event: NudgeEvent) {
        guard event.kind == .stop,
              let sessionID = event.claudeSessionID,
              let cwd = event.projectPath, !cwd.isEmpty
        else { return }
        let agent = Agent.canonical(event.agent)
        let transcriptPath = event.transcriptPath
        DispatchQueue.global(qos: .utility).async {
            guard let repoRoot = Self.gitValue(cwd, ["rev-parse", "--show-toplevel"]) else { return }
            let branch = Self.gitValue(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
            // Only consider the subject of a commit *unique to this branch*
            // (base..HEAD). The absolute last commit may already be on main —
            // e.g. an ENG-689 commit — and must not be attributed to the
            // current, still-uncommitted ENG-688 work. No base / no branch-local
            // commit ⇒ no commit subject ⇒ fall back to the branch alone.
            let baseSha = OutcomeWatcher.resolveBaseSha { Self.gitValue(cwd, $0) }
            let commitSubject = baseSha.flatMap {
                Self.gitValue(cwd, ["log", "-1", "--format=%s", "\($0)..HEAD"])
            }
            let ticket = TicketAttribution.ticket(branch: branch, commitSubject: commitSubject)
            let stats = transcriptPath.flatMap { TranscriptReader.read(path: $0) }
            let snapshot = GitSnapshot.capture(cwd: cwd) { Self.gitValue($0, $1) }
            DispatchQueue.main.async { [weak self] in
                HandoffLedger.shared.upsert(sessionID: sessionID, branch: branch, agent: agent) { record in
                    record.repoRoot = repoRoot
                    record.branch = branch
                    // Re-derive every Stop (not derive-once): git state evolves
                    // within a session, so the latest derivation is the most
                    // accurate and lets a misattributed row self-correct. nil is
                    // fine — the rollup re-derives from the branch at display.
                    record.ticket = ticket
                    if let stats {
                        record.model = stats.model
                        // Fold the reading into a running total so a compacted
                        // session reflects its real effort, not just the
                        // post-compaction remainder (see ContextTokens.fold).
                        let folded = ContextTokens.fold(total: record.contextTokens,
                                                        lastReading: record.lastContextReading,
                                                        newReading: stats.tokens)
                        record.contextTokens = folded.total
                        record.lastContextReading = folded.lastReading
                    }
                    if let snapshot {
                        record.headCommit = snapshot.headCommit
                        record.filesChanged = snapshot.filesChanged
                        record.insertions = snapshot.insertions
                        record.deletions = snapshot.deletions
                    }
                }
                // Nudge the Tickets tab + its tab-strip count to re-read the
                // ledger so a session shows up live while the panel is open.
                self?.nav.handoffsRevision += 1
                self?.refreshOutcomes()
            }
        }
    }

    // Recompute "did it ship?" for every distinct repo+branch in the ledger,
    // off-main (git is slow), then publish to nav for the Tickets tab. Uses the
    // newest record per branch (ledger is newest-first) for the headCommit /
    // uncommitted-at-Stop inputs to the derivation.
    func refreshOutcomes() {
        var pairs: [(repo: String, branch: String, head: String?, files: Int)] = []
        var seen = Set<String>()
        for record in HandoffLedger.shared.all() {
            guard let repo = record.repoRoot, let branch = record.branch else { continue }
            if seen.insert(PanelNav.outcomeKey(repo, branch)).inserted {
                pairs.append((repo, branch, record.headCommit, record.filesChanged ?? 0))
            }
        }
        guard !pairs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [String: OutcomeStatus] = [:]
            for pair in pairs {
                result[PanelNav.outcomeKey(pair.repo, pair.branch)] = OutcomeWatcher.derive(
                    branch: pair.branch, headCommit: pair.head, filesChangedAtStop: pair.files
                ) { Self.gitValue(pair.repo, $0) }
            }
            DispatchQueue.main.async { self?.nav.outcomeByBranch = result }
        }
    }

    // Opt-in (STACKNUDGE_GITHUB): fetch the PR + CI state for each distinct
    // repo+branch via the GitHub GraphQL API with our stored token, off-main,
    // publishing incrementally so chips appear as each branch resolves. A PR's
    // MERGED state is what closes the squash gap the local OutcomeWatcher can't
    // see. No-op when disabled or not signed in.
    func refreshPullRequests() {
        guard nav.githubLinkingEnabled, let token = GitHubAuth.token() else { return }
        var pairs: [(repo: String, branch: String)] = []
        var seen = Set<String>()
        for record in HandoffLedger.shared.all() {
            guard let repo = record.repoRoot, let branch = record.branch else { continue }
            if seen.insert(PanelNav.outcomeKey(repo, branch)).inserted {
                pairs.append((repo, branch))
            }
        }
        guard !pairs.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for pair in pairs {
                guard let slug = Self.repoSlug(forRepo: pair.repo) else { continue }
                let info = GitHubAPI.pullRequest(owner: slug.owner, repo: slug.repo,
                                                 branch: pair.branch) { body in
                    Self.graphQLPOST(body, token: token)
                }
                guard let info else { continue }
                let key = PanelNav.outcomeKey(pair.repo, pair.branch)
                DispatchQueue.main.async { self?.nav.pullRequestByBranch[key] = info }
            }
        }
    }

    // owner/repo for a working copy — prefer `upstream` (the real mainline in a
    // fork workflow, where PRs live) then `origin`.
    private static func repoSlug(forRepo repoRoot: String) -> (owner: String, repo: String)? {
        for remote in ["upstream", "origin"] {
            if let url = gitValue(repoRoot, ["remote", "get-url", remote]),
               let slug = GitHubAPI.repoSlug(fromRemoteURL: url) {
                return slug
            }
        }
        return nil
    }

    // Synchronous GraphQL POST (called from the off-main fetch loop) — blocks on
    // a semaphore so the caller's loop stays simple; 10s ceiling.
    private static func graphQLPOST(_ body: String, token: String) -> String? {
        var request = URLRequest(url: GitHubAPI.graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        var result: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { result = String(data: data, encoding: .utf8) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return result
    }

    // MARK: - GitHub device-flow sign-in

    // Kick off the in-panel device flow: request a code, surface it to the
    // Tickets-tab card, then poll until the user approves (or it expires).
    func startGithubSignIn() {
        guard let clientID = GitHubAuth.clientID() else {
            nav.githubSignIn = .failed("GitHub client ID not configured")
            return
        }
        nav.githubSignIn = .requesting
        GitHubAuth.requestDeviceCode(clientID: clientID) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let response else {
                    self.nav.githubSignIn = .failed("Couldn't reach GitHub — try again")
                    return
                }
                self.nav.githubSignIn = .awaitingApproval(
                    userCode: response.userCode, verificationURI: response.verificationURI)
                self.pollGithubSignIn(clientID: clientID,
                                      deviceCode: response.deviceCode,
                                      interval: response.interval,
                                      deadline: Date().addingTimeInterval(TimeInterval(response.expiresIn)))
            }
        }
    }

    func cancelGithubSignIn() { nav.githubSignIn = .idle }

    // One poll per `interval` seconds. Stops if the user cancelled (state left
    // awaitingApproval). On success, stores the token and kicks a PR refresh.
    private func pollGithubSignIn(clientID: String, deviceCode: String, interval: Int, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(max(1, interval))) { [weak self] in
            guard let self, case .awaitingApproval = self.nav.githubSignIn else { return }
            // Enforce the device code's own expiry (RFC 8628 §3.5) rather than
            // polling forever if the endpoint never returns expired_token.
            if Date() >= deadline {
                self.nav.githubSignIn = .failed("Code expired — try again")
                return
            }
            GitHubAuth.poll(clientID: clientID, deviceCode: deviceCode) { result in
                DispatchQueue.main.async {
                    guard case .awaitingApproval = self.nav.githubSignIn else { return }
                    switch result {
                    case .token(let token):
                        GitHubAuth.store(token: token)
                        self.nav.githubSignedIn = true
                        self.nav.githubSignIn = .idle
                        self.refreshPullRequests()
                    case .pending:
                        self.pollGithubSignIn(clientID: clientID, deviceCode: deviceCode, interval: interval, deadline: deadline)
                    case .slowDown(let slower):
                        // RFC 8628: back off by at least 5s; honour a larger server interval.
                        self.pollGithubSignIn(clientID: clientID, deviceCode: deviceCode, interval: max(slower, interval + 5), deadline: deadline)
                    case .expired:
                        self.nav.githubSignIn = .failed("Code expired — try again")
                    case .denied:
                        self.nav.githubSignIn = .failed("Access denied")
                    case .failed(let message):
                        self.nav.githubSignIn = .failed(message)
                    }
                }
            }
        }
    }

    // Run `git -C <cwd> <args>`; trim, and treat non-repo / empty output as nil.
    private static func gitValue(_ cwd: String, _ args: [String]) -> String? {
        let output = ProcessOutput.read("/usr/bin/git", ["-C", cwd] + args)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, !output.hasPrefix("fatal"),
              !output.contains("not a git repository") else { return nil }
        return output
    }

    // Per-session state for context-threshold dedup. Lives on the
    // controller (not nav) because it's pure bookkeeping for the
    // alert pipeline, not anything the UI observes.
    private var contextAlertLastTokens: [String: Int] = [:]
    private var contextAlertFired: Set<String> = []

    // Decide whether to fire a context-fill banner for this session.
    // Rules:
    //   - Off (threshold = 0) → never fire.
    //   - First time crossing threshold → fire, mark as fired.
    //   - Already fired → skip until re-armed.
    //   - Re-arm: any single-reading drop of ≥20K tokens (compact /
    //     /clear signal); next crossing fires again.
    private func evaluateContextThreshold(sessionID: String, stats: TranscriptStats) {
        let thresholdK = nav.contextAlertThresholdK
        guard thresholdK > 0 else { return }
        // Respect the global Banner notifications toggle — context-fill
        // banners are still system-level notifications and shouldn't fire
        // when the user has turned banners off.
        guard nav.bannerEnabled else { return }
        let threshold = thresholdK * 1_000
        let current = stats.tokens

        if let last = contextAlertLastTokens[sessionID],
           last - current >= ContextTokens.compactDropThreshold {
            contextAlertFired.remove(sessionID)
        }
        contextAlertLastTokens[sessionID] = current

        guard current >= threshold, !contextAlertFired.contains(sessionID) else { return }
        contextAlertFired.insert(sessionID)
        postContextBanner(tokens: current, model: stats.model,
                          sessionLabel: labelForClaudeSession(id: sessionID))
    }

    // Find a user-recognisable label for the session crossing the threshold.
    // Cascade mirrors what the Sessions row shows: customName → meaningful
    // claudeName → project name. Falls back to "a session" if we know
    // nothing (alert still useful, just less specific).
    private func labelForClaudeSession(id: String) -> String {
        guard let session = sessions.sessions.first(where: { $0.claudeSessionID == id })
        else { return "a session" }
        if let custom = session.customName, !custom.isEmpty { return custom }
        if let name = session.liveTitle,
           !name.isEmpty, name != "main-agent" {
            return name
        }
        return session.projectName ?? "a session"
    }

    private func postContextBanner(tokens: Int, model: String?, sessionLabel: String) {
        let tokensFmt = "\(Int((Double(tokens) / 1_000).rounded()))K"
        let content = UNMutableNotificationContent()
        content.title = "Context filling up — \(sessionLabel)"
        if let model {
            content.body = "At \(tokensFmt) tokens (\(model)). Consider /compact."
        } else {
            content.body = "At \(tokensFmt) tokens. Consider /compact."
        }
        content.categoryIdentifier = "STOP"
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func postBannerIfNeeded(_ event: NudgeEvent) {
        let config = PanelConfig.load()

        // Mascot/ripple still fire — they're driven from onAppend, not here.
        if !event.bypassMute,
           nav.isSessionMuted(event: event, in: sessions.sessions) {
            return
        }

        if config.activateImmediately, let bundleID = event.bundleID {
            DispatchQueue.global(qos: .userInitiated).async {
                AppActivator.activate(bundleID: bundleID,
                                      windowTitle: event.windowTitle,
                                      ipcHook: event.ipcHook,
                                      projectPath: event.projectPath,
                                      sessionID: event.sessionID,
                                      sendApproval: false,
                                      agent: event.agent)
            }
            return
        }

        let muted = !event.bypassMute
            && config.muteWhenFocused
            && isEventSourceFocused(event)

        if muted {
            // Source window is frontmost — keep a minimal cue (chime when
            // voice is off and sound is on; nothing otherwise, matching
            // notify.sh's prior contract). No banner, no voice utterance.
            if config.soundEnabled, !config.voiceEnabled, let sound = event.soundName {
                Speaker.playSound(named: sound)
            }
            return
        }

        if config.soundEnabled, !config.voiceEnabled, let sound = event.soundName {
            Speaker.playSound(named: sound)
        }
        if config.voiceEnabled, let phrase = event.voiceMessage, !phrase.isEmpty {
            Speaker.speak(phrase, voice: config.voiceName, speed: config.voiceSpeed)
        }

        guard config.bannerEnabled else { return }
        postBanner(for: event)
    }

    // Returns true if the event's source editor window appears to be the
    // user's current focus. Ported from notify.sh's mute_when_focused
    // block: match the frontmost app's bundle ID first (cheap), and when
    // we have a window title to compare against, confirm via System Events.
    private func isEventSourceFocused(_ event: NudgeEvent) -> Bool {
        guard let sourceBundle = event.bundleID,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              front == sourceBundle
        else { return false }

        guard let want = event.windowTitle, !want.isEmpty,
              let processName = processName(for: sourceBundle)
        else {
            // No window title to disambiguate — bundle match alone is
            // enough (single-window editors, or the user has just the one
            // project open in this app).
            return true
        }

        let script = """
        tell application "System Events"
          tell process "\(processName)"
            try
              return title of window 1
            end try
          end tell
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let frontTitle = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return frontTitle == want
    }

    // Same bundle-ID → System Events process-name mapping as notify.sh's
    // notify_macos(); only the editors/terminals we already special-case
    // for click-to-focus need an entry here.
    private func processName(for bundleID: String) -> String? {
        switch bundleID {
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.microsoft.VSCode":          return "Code"
        case "dev.zed.Zed":                   return "Zed"
        case "com.googlecode.iterm2":         return "iTerm2"
        case "dev.warp.Warp-Stable":          return "Warp"
        case "com.mitchellh.ghostty":         return "Ghostty"
        case "com.apple.Terminal":            return "Terminal"
        default: return nil
        }
    }

    // Posts a UNNotificationRequest for an event. Used by postBannerIfNeeded
    // for the initial fire and by the snooze timer for re-fires. Request
    // identifier is a fresh UUID each time (macOS replaces by identifier);
    // event.id stays in userInfo so click handlers can find the source.
    // Banner title with session label appended when we can resolve one.
    // Default project name is suppressed (already implied by the title);
    // only meaningful custom/claudeName labels are shown.
    private func bannerTitle(for event: NudgeEvent) -> String {
        guard let id = event.claudeSessionID else { return event.title }
        guard let session = sessions.sessions.first(where: { $0.claudeSessionID == id })
        else { return event.title }
        let custom = session.customName?.trimmingCharacters(in: .whitespaces)
        let claude = session.liveTitle?.trimmingCharacters(in: .whitespaces)
        let label: String?
        if let custom, !custom.isEmpty {
            label = custom
        } else if let claude, !claude.isEmpty, claude != "main-agent" {
            label = claude
        } else {
            label = nil
        }
        guard let label else { return event.title }
        return "\(event.title) — \(label)"
    }

    private func postBanner(for event: NudgeEvent) {
        let content = UNMutableNotificationContent()
        content.title = bannerTitle(for: event)
        content.body  = event.message
        content.categoryIdentifier = event.kind == .permission ? "PERMISSION" : "STOP"
        content.userInfo = ["eventID": event.id.uuidString]

        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    // Snooze: mark the event, schedule a Timer to clear the snooze flag and
    // re-post a fresh banner after `seconds`. The hook stays blocked on the
    // FIFO the whole time. If the event is removed (resolved or dismissed)
    // before the timer fires, the timer becomes a no-op via the lookup.
    private func snoozeEvent(_ event: NudgeEvent, for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        store.setSnoozedUntil(id: event.id, until)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self,
                  let current = self.store.events.first(where: { $0.id == event.id })
            else { return }
            self.store.setSnoozedUntil(id: current.id, nil)
            self.postBanner(for: current.with(snoozedUntil: nil))
        }
    }

    // Called when the user clicks the banner or its action button.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        // Veto the deferred panel-show that applicationShouldHandleReopen
        // queued: we know this activation came from a banner click, not
        // a user re-opening the app.
        bannerActivationUntil = Date().addingTimeInterval(0.5)
        guard let eventID = response.notification.request.content.userInfo["eventID"] as? String,
              let event = store.events.first(where: { $0.id.uuidString == eventID })
        else { return }

        // Snooze: don't write the FIFO, don't remove the event. Just mark
        // it as snoozed and schedule a re-fire of the banner after the
        // chosen duration. The hook stays blocked the whole time.
        switch response.actionIdentifier {
        case "SNOOZE_5M":
            snoozeEvent(event, for: 5 * 60)
            return
        case "SNOOZE_15M":
            snoozeEvent(event, for: 15 * 60)
            return
        default:
            break
        }

        // Resolve a blocking permission's FIFO from the chosen action so the
        // agent never hangs to its 550s timeout: Allow → "allow"; Deny or a
        // swipe-away dismiss → "deny". A plain body-tap (DEFAULT) on a blocking
        // permission is left in the panel to decide there (not removed), so it
        // falls through to focus the editor without resolving the decision.
        if let fifo = event.fifoPath {
            switch response.actionIdentifier {
            case "ALLOW":
                store.remove(id: event.id)
                DispatchQueue.global(qos: .userInitiated).async { Self.writeFIFO(fifo, "allow") }
                return
            case "DENY", UNNotificationDismissActionIdentifier:
                store.remove(id: event.id)
                DispatchQueue.global(qos: .userInitiated).async { Self.writeFIFO(fifo, "deny") }
                return
            default:
                break  // body tap: keep the event in the panel, focus editor below
            }
        } else {
            store.remove(id: event.id)
        }

        let approve = response.actionIdentifier == "ALLOW"
        guard let bundleID = event.bundleID else { return }

        // Hide the app first so the system restores focus to the previous
        // frontmost app before AppActivator tries to raise the target window.
        // Without this the brief activation of stack-nudge interferes with
        // window detection in AppActivator.
        NSApp.hide(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.15)
            AppActivator.activate(bundleID: bundleID,
                                  windowTitle: event.windowTitle,
                                  ipcHook: event.ipcHook,
                                  projectPath: event.projectPath,
                                  sessionID: event.sessionID,
                                  sendApproval: approve,
                                  agent: event.agent)
        }
    }

    // Write a decision string to the hook's FIFO. The source notify.sh
    // is blocked on `select`, so this returns immediately after writing.
    private static func writeFIFO(_ path: String, _ decision: String) {
        let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        let line = decision + "\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    // Show banners even when the app is frontmost (needed for accessory apps).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    @discardableResult
    private func registerHotkey(spec: String) -> Bool {
        let new = Hotkey(spec: spec) { [weak self] in self?.toggle() }
        guard let new else {
            FileHandle.standardError.write(Data(
                "stack-nudge-panel: failed to register hotkey '\(spec)'\n".utf8))
            return false
        }
        hotkey = new  // releasing the old instance unregisters it via deinit
        return true
    }


    // MARK: - Config file watcher

    private var configWatcher: DispatchSourceFileSystemObject?

    // Watches ~/.stack-nudge/config for writes so that edits made via "Open
    // config file…" or any external editor flow back into the running panel
    // without needing a daemon restart. Most macOS editors save by writing to
    // a temp file and renaming, which would orphan a vanilla file watcher; we
    // re-arm on .rename/.delete so subsequent edits keep firing.
    private func startConfigWatcher() {
        configWatcher?.cancel()
        configWatcher = nil

        let fd = open(ConfigFile.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet during install — try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startConfigWatcher()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            self.reloadConfigFromDisk()
            if flags.contains(.rename) || flags.contains(.delete) {
                // Atomic-save replaced the inode under us; re-open against
                // the new file. Small delay lets the editor finish its swap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.startConfigWatcher()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func reloadConfigFromDisk() {
        let config = PanelConfig.load()
        if config.hotkeySpec != nav.hotkeyDisplay {
            if registerHotkey(spec: config.hotkeySpec) {
                nav.hotkeyDisplay = config.hotkeySpec
            }
        }
    }

    func showPermissions() {
        // Defer to next runloop tick so we're not constructing a new
        // NSHostingView in the middle of the current SwiftUI/event-handling
        // pass — re-entrant construction surfaced as a deadlock.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.permissionsWC == nil {
                self.permissionsWC = PermissionsWindowController()
            }
            self.permissionsWC?.showAndRaise()
            self.panel.orderOut(nil)
            self.nav.mode = .events
        }
    }

    // Fired when the user re-opens the app while it's already running —
    // double-click from Finder, `open -a StackNudge`, Spotlight — AND
    // (less obviously) as part of the system activation sequence that
    // accompanies a notification-banner click. In the banner-click case
    // this delegate fires BEFORE userNotificationCenter(_:didReceive:),
    // so calling showPanel() here flashes the panel up just before
    // didReceive's NSApp.hide() takes it back down.
    //
    // Defer the show so didReceive can veto. If a banner-click delegate
    // arrives within the window, it bumps bannerActivationUntil and we
    // skip. For a true app-icon reopen, no banner delegate fires and
    // the panel appears after the brief delay.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // Compact mode: the pill is the resting state and is always
            // visible. Unsolicited reopen events (Dock click, Spotlight,
            // AppleEvent activations from other apps, banner side-effects
            // not caught by the bannerActivationUntil veto) used to expand
            // the pill into the full panel — surfacing as "panel randomly
            // appears for a few seconds before collapsing." Keep the pill
            // at rest; just raise it in case another full-screen app
            // covered it.
            if self.nav.compactMode, !self.nav.compactExpanded {
                self.panel.orderFront(nil)
                return
            }
            if Date() < self.bannerActivationUntil { return }
            // Suppress if a banner just posted — macOS sometimes routes a
            // reopen through us as a side effect of the notification arriving,
            // and the user did not actually ask for the panel.
            if Date().timeIntervalSince(self.lastEventArrivalAt) < 2 { return }
            self.showPanel()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener?.stop()
        quotaTimer?.invalidate()
        quotaTimer = nil
        // Stop any in-flight afplay/stackvox children so Quit silences
        // audio that was triggered by us — the original bug that motivated
        // moving the bell from notify.sh into the app.
        Speaker.stopAllAudio()
    }

    // MARK: - PanelKeyDelegate

    func panelHandlesKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        let blockingMods: NSEvent.ModifierFlags = [.control, .option]
        let cmdOnly = mods.intersection([.command, .control, .option, .shift]) == .command

        // From the pill (compact-not-expanded), M expands to full panel.
        // Mirrors the M-to-collapse shortcut shown in the full panel's
        // footer. Gated on compactMode so the shortcut quietly no-ops
        // when the user has turned off the widget.
        if nav.compactMode, !nav.compactExpanded,
           event.keyCode == KeyCode.mKey,
           mods.intersection([.command, .control, .option, .shift]).isEmpty {
            expandFromCompact()
            return true
        }

        // While recording a hotkey, capture the next combo. Arrow keys / Tab
        // bail out gracefully — otherwise users who entered record mode by
        // mistake would be stuck on row 0 with all their keypresses swallowed.
        if nav.recordingHotkey {
            let plainNav = mods.intersection([.command, .control, .option, .shift]).isEmpty
            if plainNav {
                switch event.keyCode {
                case KeyCode.escape:
                    nav.cancelRecordingHotkey()
                    return true
                case KeyCode.upArrow:
                    nav.cancelRecordingHotkey()
                    nav.selectPrevRow()
                    return true
                case KeyCode.downArrow, KeyCode.tab:
                    nav.cancelRecordingHotkey()
                    nav.selectNextRow()
                    return true
                default:
                    break
                }
            }
            let captured = mods.intersection([.command, .control, .option, .shift])
            // Need at least one modifier — Carbon RegisterEventHotKey rejects
            // bare keys, and we don't want to bind plain "n" by accident.
            guard !captured.isEmpty else { return true }
            if let spec = Hotkey.encode(eventModifiers: mods.rawValue, keyCode: event.keyCode) {
                nav.commitHotkey(spec)
            }
            return true
        }

        // Cmd+1/2/3/4 jump directly between modes; the in-panel tab strip is
        // the discoverable mouse equivalent. Cmd+←/→ steps through the same
        // ordered tab list without wrapping.
        if cmdOnly {
            switch event.keyCode {
            case KeyCode.one:
                nav.mode = .events; return true
            case KeyCode.two:
                nav.mode = .sessions; return true
            case KeyCode.three:
                nav.mode = .usage; return true
            case KeyCode.four:
                nav.mode = .outcomes; return true
            case KeyCode.five:
                nav.mode = .settings; return true
            case KeyCode.leftArrow, KeyCode.rightArrow:
                let tabs: [PanelMode] = [.events, .sessions, .usage, .outcomes, .settings]
                if let idx = tabs.firstIndex(of: nav.mode) {
                    let next = event.keyCode == KeyCode.leftArrow ? idx - 1 : idx + 1
                    if tabs.indices.contains(next) {
                        nav.mode = tabs[next]
                    }
                    return true
                }
            case KeyCode.upArrow, KeyCode.downArrow:
                // Cmd+↑/↓ jump the current page to its first / last item (the
                // scroll follows selection). Returns false for screens with
                // nothing to jump, so the key passes through untouched.
                return jumpToEdge(top: event.keyCode == KeyCode.upArrow)
            default:
                break
            }
        }

        // Bootstrap experience:
        //   .idle:       Enter → install, Esc → quit (user opting out)
        //   .installing: Enter/Esc both no-op (install is running)
        //   .done:       Enter → continue to events, Esc also → continue
        //                (the install already happened; Esc shouldn't quit)
        //   .failed:     Enter no-op, Esc → quit (user gives up)
        if nav.mode == .bootstrap {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape:
                switch nav.bootstrapPhase {
                case .done:
                    nav.mode = .events
                case .idle, .failed:
                    NSApp.terminate(nil)
                case .installing:
                    break  // ignore while running
                }
                return true
            case KeyCode.returnKey, KeyCode.numpadEnter:
                switch nav.bootstrapPhase {
                case .idle:
                    nav.actions?.runBootstrap()
                case .done:
                    nav.mode = .events
                case .installing, .failed:
                    break
                }
                return true
            default:
                return true  // swallow other keys; wizard is single-purpose
            }
        }

        // Uninstall flow: Enter confirms (when on the confirm step),
        // Esc cancels back to settings (only when not mid-run).
        if nav.mode == .uninstall {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape:
                if nav.uninstallPhase == .confirm {
                    nav.mode = .settings
                }
                return true
            case KeyCode.returnKey, KeyCode.numpadEnter:
                if nav.uninstallPhase == .confirm {
                    nav.actions?.runUninstall()
                }
                return true
            default:
                return true
            }
        }

        // Post-update view: Enter or Esc both dismiss to the events tab.
        // Mirrors WelcomeView's keyboard contract — single-purpose screen, two
        // keys to exit, no other navigation allowed while it's up.
        if nav.mode == .postUpdate {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return true }
            switch event.keyCode {
            case KeyCode.escape, KeyCode.returnKey, KeyCode.numpadEnter:
                nav.postUpdateVersion = nil
                nav.postUpdateNotes = nil
                nav.mode = .events
                return true
            default:
                return true
            }
        }

        // Update-confirm: Enter triggers install, Esc cancels back to Settings.
        if nav.mode == .updateConfirm {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape:
                nav.mode = .settings
                return true
            case KeyCode.returnKey, KeyCode.numpadEnter:
                nav.actions?.runUpdate()
                return true
            default:
                return false
            }
        }

        // Updating: only Esc, and only after a failure (so the user can't
        // accidentally abandon a live install). Space toggles the log.
        if nav.mode == .updating {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape where nav.updaterPhase == .failed:
                nav.mode = .settings
                return true
            case KeyCode.space:
                nav.updaterShowLog.toggle()
                return true
            default:
                return false
            }
        }

        // Sessions mode: ↑/↓ select, Enter focus, ⌫/R kill, N rename.
        // While the rename TextField is active, every key flows through to
        // SwiftUI; the field handles Enter via .onSubmit and Esc via
        // .onExitCommand.
        if nav.mode == .sessions {
            if sessions.renamingPID != nil { return false }
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            switch event.keyCode {
            case KeyCode.escape where plain:
                hidePanel()
            case KeyCode.upArrow where plain:
                selectPrevSession()
            case KeyCode.downArrow where plain:
                selectNextSession()
            case KeyCode.returnKey, KeyCode.numpadEnter:
                guard plain else { return false }
                focusSelectedSession()
            case KeyCode.delete, KeyCode.forwardDelete, KeyCode.rKey:
                guard plain else { return false }
                killSelectedSession()
            case KeyCode.nKey:
                // Accept N regardless of shift (same physical key for n / N).
                guard mods.intersection([.command, .control, .option]).isEmpty else { return false }
                let pid = sessions.selectedPID ?? sessions.sessions.first?.pid
                if let pid { sessions.startRenaming(pid) }
            case KeyCode.mKey where plain:
                toggleMuteSelectedSession()
            default:
                return false
            }
            return true
        }

        // Phrases mode: ↑/↓ navigate every row (defaults + custom),
        // Space toggles the selected default, ⌫ removes the selected
        // custom, Esc returns to Settings. Typing / Tab / Enter for
        // adding still fall through to SwiftUI's TextField.
        if nav.mode == .phrases {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape:
                nav.mode = .settings
                return true
            case KeyCode.upArrow:
                phrases.selectPrevious()
                return true
            case KeyCode.downArrow:
                phrases.selectNext()
                return true
            case KeyCode.space:
                guard let row = phrases.selectedRow, row.isDefault else { return false }
                phrases.toggleSelected()
                return true
            case KeyCode.delete, KeyCode.forwardDelete:
                guard let row = phrases.selectedRow, !row.isDefault else { return false }
                phrases.removeSelected()
                return true
            default:
                return false
            }
        }

        // In settings mode, the controller drives row selection and value
        // cycling on PanelNav so the SettingsView stays a pure renderer.
        if nav.mode == .settings {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            let shiftOnly = mods.intersection([.command, .control, .option, .shift]) == .shift
            switch event.keyCode {
            case KeyCode.escape where plain:
                hidePanel()
            case KeyCode.upArrow where plain:
                nav.selectPrevRow()
            case KeyCode.downArrow where plain:
                nav.selectNextRow()
            case KeyCode.tab where plain:
                nav.selectNextRow()
            case KeyCode.tab where shiftOnly:
                nav.selectPrevRow()
            case KeyCode.leftArrow where plain:
                nav.cycleBackward()
            case KeyCode.rightArrow where plain:
                nav.cycleForward()
            case KeyCode.returnKey, KeyCode.numpadEnter, KeyCode.space:
                guard plain else { return false }
                nav.activate()
            default:
                return false
            }
            return true
        }

        // Usage tab: two focus levels. In the client list, ↑/↓ switch the
        // connected client and →/Enter steps into the detail pane. Inside the
        // detail, ↑/↓ scroll it and ←/Esc step back out. Other keys are
        // swallowed so they don't leak through to the events store.
        if nav.mode == .usage {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            if nav.usageDetailFocused {
                switch event.keyCode {
                case KeyCode.escape:
                    hidePanel()
                case KeyCode.leftArrow:
                    nav.usageDetailFocused = false
                case KeyCode.upArrow:
                    scrollDetailBy(-40)
                case KeyCode.downArrow:
                    scrollDetailBy(40)
                case KeyCode.rKey:
                    syncQuotaNow()
                case KeyCode.pKey:
                    nav.toggleQuotaTracking()
                    if nav.quotaTrackingEnabled { syncQuotaNow() }
                default:
                    break
                }
                return true
            }
            switch event.keyCode {
            case KeyCode.escape:
                hidePanel()
            case KeyCode.upArrow:
                nav.selectPrevUsageClient()
            case KeyCode.downArrow:
                nav.selectNextUsageClient()
            case KeyCode.rightArrow, KeyCode.returnKey, KeyCode.numpadEnter:
                nav.usageDetailFocused = true
            case KeyCode.rKey:
                syncQuotaNow()
            case KeyCode.pKey:
                nav.toggleQuotaTracking()
                // Immediate probe on resume so the user sees fresh data right
                // after the keystroke — otherwise they'd wait for the next
                // scheduled tick (up to the configured poll interval).
                if nav.quotaTrackingEnabled { syncQuotaNow() }
            default:
                break
            }
            return true
        }

        // Tickets tab: ↑/↓ move the row selection, →/Enter open the selected
        // row's ticket/PR link, Esc hides. Other keys are swallowed so they
        // don't leak through to the events store.
        if nav.mode == .outcomes {
            let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
            guard plain else { return false }
            switch event.keyCode {
            case KeyCode.escape:
                hidePanel()
            case KeyCode.upArrow:
                nav.moveOutcomeSelection(-1)
            case KeyCode.downArrow:
                nav.moveOutcomeSelection(1)
            case KeyCode.rightArrow, KeyCode.returnKey, KeyCode.numpadEnter:
                nav.activateSelectedOutcome()
            case KeyCode.delete, KeyCode.forwardDelete:
                nav.dismissSelectedOutcome()
            default:
                break
            }
            return true
        }

        // Events mode: filter out cmd/ctrl/opt-modified keys so app-level
        // shortcuts pass through to the responder chain. Shift is allowed
        // since we use Shift+S for the longer snooze.
        guard mods.intersection(blockingMods.union([.command])).isEmpty else {
            return false
        }
        let shifted = mods.contains(.shift)

        // S/Shift+S handled before the no-shift switch since both variants
        // are valid; everything else requires no shift.
        if event.keyCode == KeyCode.sKey {
            snoozeSelected(for: shifted ? 15 * 60 : 5 * 60)
            return true
        }
        guard !shifted else { return false }

        switch event.keyCode {
        case KeyCode.escape:
            hidePanel()
        case KeyCode.upArrow:
            store.selectPrevious()
        case KeyCode.downArrow:
            store.selectNext()
        case KeyCode.returnKey, KeyCode.numpadEnter:
            actOnSelected(approve: true)
        case KeyCode.oKey:
            actOnSelected(approve: false)
        case KeyCode.rKey, KeyCode.delete, KeyCode.forwardDelete:
            dismissSelected()
        default:
            return false
        }
        return true
    }

    private func snoozeSelected(for seconds: TimeInterval) {
        guard let event = store.selectedEvent,
              event.kind == .permission,
              event.hasActionButton
        else { return }
        snoozeEvent(event, for: seconds)
    }

    // MARK: - Actions

    // Acting on a nudge: hide the app (so system frontmost reverts naturally),
    // then dispatch AppActivator to bring the target app forward and optionally
    // send the approval keystroke. Hiding *before* the dispatch matters — if we
    // stayed active, the Enter keystroke can land in our process instead of the
    // target's key window.
    private func actOnSelected(approve: Bool) {
        guard let event = store.selectedEvent else { return }
        let sendApproval = approve && event.hasActionButton

        // A blocking permission opened via 'O' (approve:false, "Open editor")
        // must stay in the panel so the user can still resolve it (Dismiss →
        // deny); removing it would orphan the hook for ~550s with no recovery
        // path. Approvals — and any event without a pending FIFO — are removed
        // as before. Stay on the panel if other events remain; otherwise close
        // so the system frontmost reverts naturally and the approval keystroke
        // lands in the target app's key window (see comment above re: hiding).
        if sendApproval || event.fifoPath == nil {
            store.remove(id: event.id)
            if store.events.isEmpty { hidePanel() }
        }

        // Approve a blocking permission by writing "allow" to its FIFO; the agent
        // then skips its own prompt. Deny is the Dismiss gesture (see
        // dismissSelected), NOT this path — so 'O' (approve:false, "Open editor")
        // falls through to focusing the editor without resolving the decision.
        if sendApproval, let fifo = event.fifoPath {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.writeFIFO(fifo, "allow")
            }
            return
        }

        guard let bundleID = event.bundleID else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            AppActivator.activate(
                bundleID: bundleID,
                windowTitle: event.windowTitle,
                ipcHook: event.ipcHook,
                projectPath: event.projectPath,
                sessionID: event.sessionID,
                sendApproval: sendApproval,
                agent: event.agent
            )
        }
    }

    private func dismissSelected() {
        guard let event = store.selectedEvent else { return }
        // Dismissing a permission the hook is blocking on = deny it, so the
        // agent gets an answer instead of hanging to its 550s timeout.
        if let fifo = event.fifoPath {
            DispatchQueue.global(qos: .userInitiated).async {
                Self.writeFIFO(fifo, "deny")
            }
        }
        store.remove(id: event.id)
        // Auto-close once the list empties, unless the user opted to keep the
        // panel open (Settings → Keep open when empty).
        if store.events.isEmpty, !nav.keepOpenWhenEmpty { hidePanel() }
    }

    // MARK: - Sessions actions

    private func selectNextSession() {
        guard !sessions.sessions.isEmpty else { return }
        let pids = sessions.sessions.map(\.pid)
        let idx = sessions.selectedPID.flatMap(pids.firstIndex(of:)) ?? -1
        sessions.selectedPID = pids[min(idx + 1, pids.count - 1)]
    }

    private func selectPrevSession() {
        guard !sessions.sessions.isEmpty else { return }
        let pids = sessions.sessions.map(\.pid)
        let idx = sessions.selectedPID.flatMap(pids.firstIndex(of:)) ?? 0
        sessions.selectedPID = pids[max(idx - 1, 0)]
    }

    // ⌘↑/↓ — jump to the first / last session.
    private func selectFirstSession() { sessions.selectedPID = sessions.sessions.first?.pid }
    private func selectLastSession()  { sessions.selectedPID = sessions.sessions.last?.pid }

    // Dispatch ⌘↑/↓ to the current page's "jump to first/last". Selection-driven
    // pages move their selection (the viewport follows); the Usage detail pane
    // has no selection, so it scrolls to the edge. Returns false on screens with
    // nothing to jump so the keystroke passes through.
    private func jumpToEdge(top: Bool) -> Bool {
        switch nav.mode {
        case .events:
            top ? store.selectFirst() : store.selectLast()
        case .sessions:
            guard sessions.renamingPID == nil else { return false }
            top ? selectFirstSession() : selectLastSession()
        case .usage:
            if nav.usageDetailFocused {
                scrollDetailToEdge(top: top)
            } else {
                top ? nav.selectFirstUsageClient() : nav.selectLastUsageClient()
            }
        case .outcomes:
            nav.jumpOutcomeSelection(toLast: !top)
        case .settings:
            top ? nav.selectFirstRow() : nav.selectLastRow()
        case .phrases:
            top ? phrases.selectFirst() : phrases.selectLast()
        default:
            return false  // modal / single-purpose screens have nothing to jump
        }
        return true
    }

    private func focusSelectedSession() {
        guard let pid = sessions.selectedPID,
              let session = sessions.sessions.first(where: { $0.pid == pid }),
              let bundleID = bundleID(for: session.terminalApp) else { return }
        hidePanel()
        DispatchQueue.global(qos: .userInitiated).async {
            AppActivator.activate(
                bundleID: bundleID,
                windowTitle: session.projectName,
                ipcHook: nil,
                projectPath: session.projectPath,
                sendApproval: false,
                agent: session.agent
            )
        }
    }

    private func killSelectedSession() {
        guard let pid = sessions.selectedPID else { return }
        sessions.killSession(pid)
    }

    private func toggleMuteSelectedSession() {
        guard let pid = sessions.selectedPID,
              let session = sessions.sessions.first(where: { $0.pid == pid }) else { return }
        nav.toggleMute(for: session)
    }

    // Map a terminal/IDE process name to the launch-services bundle ID so
    // AppActivator can talk to the right app.
    private func bundleID(for terminalApp: String?) -> String? {
        guard let app = terminalApp else { return nil }
        if app.hasPrefix("Code") { return "com.microsoft.VSCode" }
        if app.hasPrefix("Cursor") { return "com.todesktop.230313mzl4w4u92" }
        switch app {
        case "iTerm2", "iTerm":     return "com.googlecode.iterm2"
        case "Warp", "WarpTerminal": return "dev.warp.Warp-Stable"
        case "Ghostty", "ghostty":   return "com.mitchellh.ghostty"
        case "Terminal":             return "com.apple.Terminal"
        default:                     return nil
        }
    }

    // MARK: - Show / hide

    // Toggle behaves on focus, not visibility: hotkey while panel is key hides it;
    // hotkey while the panel is hidden OR visible-but-defocused brings it forward.
    // In compact mode, hotkey toggles the expand state instead of show/hide so
    // the pill is always visible — that's the whole point of compact mode.
    private func toggle() {
        if nav.compactMode {
            if nav.compactExpanded {
                nav.compactExpanded = false
                applyCompactLayout()
            } else {
                expandFromCompact()
            }
            return
        }
        if panel.isKeyWindow {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        // In compact mode, "show" means "expand" — bringing back the full
        // panel rather than just raising the pill (which is already visible).
        if nav.compactMode {
            if !nav.compactExpanded { expandFromCompact() }
            else {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        positionPanel()  // re-resolve in case the user moved to a different display
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // NSApp.hide hides all our windows AND deactivates the app, so the system
    // frontmost reverts to whatever was active before the panel was summoned.
    private func hidePanel() {
        // Compact mode: "hide" means "collapse back to the pill," never
        // make the user lose their widget entirely. Esc / hotkey / focus
        // loss all funnel through here.
        if nav.compactMode {
            if nav.compactExpanded {
                nav.compactExpanded = false
                applyCompactLayout()
            }
            return
        }
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    // MARK: - Setup helpers

    // Restore the user's saved position if it still falls inside an attached
    // screen; otherwise fall back to top-right of whichever screen the
    // cursor's on. Re-arranged monitors or laptops opening lidless can leave
    // a saved origin pointing nowhere, so the validation is important.
    private func positionPanel() {
        let savedOrigin = Self.loadSavedPanelOrigin()
        if let origin = savedOrigin,
           NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
            panel.setFrameOrigin(origin)
            return
        }
        let screen = activeScreen()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Panel size + origin persistence

    static func loadSavedPanelSize() -> NSSize {
        guard let dict = UserDefaults.standard.dictionary(forKey: panelSizeKey),
              let w = dict["width"] as? CGFloat,
              let h = dict["height"] as? CGFloat
        else { return panelDefaultSize }
        // Floor at the panel's minimum to defend against pathological values
        // — and to bump returning users with a saved size below the (now
        // larger) minimum up to a layout the footer hints actually fit in.
        return NSSize(width: max(w, panelMinWidth), height: max(h, panelMinHeight))
    }

    static func loadSavedPanelOrigin() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: panelOriginKey),
              let x = dict["x"] as? CGFloat,
              let y = dict["y"] as? CGFloat
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    // Observe NSWindow resize/move so the user's preference is preserved
    // across launches, app updates, and reinstalls (UserDefaults lives at
    // ~/Library/Preferences/com.stackonehq.stack-nudge.plist).
    private func observePanelFrameChanges() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel as NSWindow? else { return }
            // Don't persist the compact-widget frame as the user's panel
            // size — they'd lose their full-panel size every time they
            // switched modes.
            if self.nav.compactMode, !self.nav.compactExpanded { return }
            UserDefaults.standard.set(
                ["width": panel.frame.width, "height": panel.frame.height],
                forKey: Self.panelSizeKey
            )
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel as NSWindow? else { return }
            // Compact widget: don't persist the moved origin (the corner
            // is the source of truth). The actual snap fires from the
            // mouse-up event monitor. Here we just record that movement
            // happened during the current mouse-down so the monitor
            // knows whether to snap.
            if self.ignoringProgrammaticMove { return }
            if self.nav.compactMode, !self.nav.compactExpanded {
                self.compactMovedSinceMouseDown = true
                return
            }
            UserDefaults.standard.set(
                ["x": panel.frame.origin.x, "y": panel.frame.origin.y],
                forKey: Self.panelOriginKey
            )
        }
    }

    // Pick the screen the user is most likely looking at: the one under
    // the mouse cursor. Falls back to NSScreen.main if for some reason we
    // can't resolve a screen (e.g., headless or screens just being
    // reconfigured). Cursor location works regardless of which app or
    // window has focus, and is what most multi-screen mac apps use.
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let match = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first ?? panel.screen ?? NSScreen()
    }

    private func startListener() {
        let installDir = ("~/.stack-nudge" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: installDir, withIntermediateDirectories: true)
        let socketPath = (installDir as NSString)
            .appendingPathComponent("panel.sock")
        listener = EventListener(store: store, socketPath: socketPath)
        do {
            try listener?.start()
            nav.listenerError = nil
        } catch {
            FileHandle.standardError.write(Data(
                "stack-nudge-panel: listener failed: \(error)\n".utf8))
            nav.listenerError =
                "Event socket failed to start — agent notifications won't arrive. "
                + "Restart StackNudge to retry. (\(error))"
        }
    }
}
