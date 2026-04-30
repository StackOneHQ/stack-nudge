import AppKit
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
    static let tab:       UInt16 = 48
    static let oKey:      UInt16 = 31
    static let rKey:      UInt16 = 15
    static let delete:    UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let comma:     UInt16 = 43
    static let one:       UInt16 = 18
    static let two:       UInt16 = 19
    static let three:     UInt16 = 20
    static let nKey:      UInt16 = 45
}

// Floating, non-activating panel. Shown via global hotkey; receives key
// events without activating the parent app, so the user's editor stays
// frontmost in the system sense while the panel captures keystrokes.
final class FloatingPanel: NSPanel {

    weak var keyDelegate: PanelKeyDelegate?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabStrip
            Divider().opacity(0.4)

            switch nav.mode {
            case .events:   eventsBody
            case .sessions: SessionsView(store: sessions)
            case .settings: SettingsView(nav: nav)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)

            tab(.events,   label: "Events",   count: store.events.count)
            tab(.sessions, label: "Sessions", count: sessions.sessions.filter { $0.status == .active }.count)
            tab(.settings, label: "Settings", count: 0)

            Spacer()

            // One combined hint instead of per-tab keycaps — keeps the strip
            // uncluttered while still surfacing the shortcut range.
            HStack(spacing: 2) {
                KeyCapView(symbol: "⌘")
                KeyCapView(symbol: "1-3")
            }
            .opacity(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tab(_ mode: PanelMode, label: String, count: Int) -> some View {
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
            if store.events.isEmpty {
                emptyState
            } else {
                eventList
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.events) { event in
                    EventRow(event: event,
                             selected: store.selectedID == event.id)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedID = event.id }
                }
            }
            .padding(.vertical, 4)
            .background(ThinScrollers())
        }
    }

    private var footer: some View {
        PageFooter {
            if store.events.isEmpty {
                FooterHint(label: "Hide", keys: ["esc"])
            } else {
                if let primary = primaryActionLabel {
                    FooterHint(label: primary, keys: ["⏎"], primary: true)
                    FooterDivider()
                }
                FooterHint(label: "Select",  keys: ["↑", "↓"])
                FooterHint(label: "Dismiss", keys: ["⌫"])
                FooterHint(label: "Hide",    keys: ["esc"])
            }
        }
    }

    private var primaryActionLabel: String? {
        guard let event = store.selectedEvent else { return nil }
        return event.kind == .permission ? "Approve" : "Open editor"
    }
}


struct EventRow: View {

    let event: NudgeEvent
    let selected: Bool

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

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
                    if let project = event.projectPath {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text((project as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(Self.timeFormatter.localizedString(for: event.timestamp, relativeTo: Date()))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .padding(.horizontal, 6)
    }

    private var glyph: String {
        event.kind == .permission ? "questionmark.circle.fill" : "checkmark.circle.fill"
    }

    private var glyphColor: Color {
        event.kind == .permission ? .orange : .green
    }
}

// Owns the panel + hotkey + listener + menu bar.
final class PanelController: NSObject, NSApplicationDelegate, PanelKeyDelegate,
                             UNUserNotificationCenterDelegate {

    private var panel: FloatingPanel!
    private var hotkey: Hotkey?
    private let store = EventStore()
    private let sessions = SessionStore()
    private let nav = PanelNav()
    private var listener: EventListener?
    private var menuBar: MenuBarController?
    private var permissionsWC: PermissionsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 280)
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

        let host = NSHostingView(rootView: PanelContentView(store: store, sessions: sessions, nav: nav))
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
            quit:             { NSApp.terminate(nil) }
        )
        nav.setHotkey = { [weak self] spec in
            self?.registerHotkey(spec: spec) ?? false
        }

        startConfigWatcher()
        setupNotificationCenter()
        store.onAppend = { [weak self] event in self?.postBannerIfNeeded(event) }
    }

    // MARK: - UNUserNotificationCenter

    private func setupNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Request permission (shows the system dialog once; subsequent calls are no-ops).
        center.requestAuthorization(options: [.alert]) { _, _ in }

        // Register categories: STOP (no actions) and PERMISSION (Allow button).
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [])
        let permCategory = UNNotificationCategory(identifier: "PERMISSION",
                                                   actions: [allow],
                                                   intentIdentifiers: [],
                                                   options: [])
        let stopCategory = UNNotificationCategory(identifier: "STOP",
                                                   actions: [],
                                                   intentIdentifiers: [],
                                                   options: [])
        center.setNotificationCategories([permCategory, stopCategory])
    }

    // Post a UNUserNotification when STACKNUDGE_BANNER is enabled.
    // Sound is omitted — afplay fires independently in notify.sh so we
    // don't double-cue when the macOS banner is also shown.
    // If STACKNUDGE_ACTIVATE_IMMEDIATELY is set, focus the source editor
    // right away without waiting for the user to click.
    private func postBannerIfNeeded(_ event: NudgeEvent) {
        let config = PanelConfig.load()

        if config.activateImmediately, let bundleID = event.bundleID {
            DispatchQueue.global(qos: .userInitiated).async {
                AppActivator.activate(bundleID: bundleID,
                                      windowTitle: event.windowTitle,
                                      ipcHook: event.ipcHook,
                                      projectPath: event.projectPath,
                                      sendApproval: false,
                                      agent: event.agent)
            }
            return
        }

        guard config.bannerEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body  = event.message
        content.categoryIdentifier = event.kind == .permission ? "PERMISSION" : "STOP"
        content.userInfo = ["eventID": event.id.uuidString]

        let center = UNUserNotificationCenter.current()
        // Remove stale delivered notifications so they don't pile up.
        center.removeAllDeliveredNotifications()
        let req = UNNotificationRequest(identifier: event.id.uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    // Called when the user clicks the banner or its action button.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let eventID = response.notification.request.content.userInfo["eventID"] as? String,
              let event = store.events.first(where: { $0.id.uuidString == eventID })
        else { return }

        store.remove(id: event.id)
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
                                  sendApproval: approve,
                                  agent: event.agent)
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        listener?.stop()
    }

    // MARK: - PanelKeyDelegate

    func panelHandlesKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags
        let blockingMods: NSEvent.ModifierFlags = [.control, .option]
        let cmdOnly = mods.intersection([.command, .control, .option, .shift]) == .command

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

        // Cmd+1/2/3 jump directly between modes; the in-panel tab strip is
        // the discoverable mouse equivalent.
        if cmdOnly {
            switch event.keyCode {
            case KeyCode.one:
                nav.mode = .events; return true
            case KeyCode.two:
                nav.mode = .sessions; return true
            case KeyCode.three:
                nav.mode = .settings; return true
            default:
                break
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
            default:
                return false
            }
            return true
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
            case KeyCode.returnKey, KeyCode.numpadEnter:
                guard plain else { return false }
                nav.activate()
            default:
                return false
            }
            return true
        }

        // Events mode: filter out cmd/ctrl/opt-modified keys so app-level
        // shortcuts pass through to the responder chain.
        guard mods.intersection(blockingMods.union([.command])).isEmpty else {
            return false
        }
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

    // MARK: - Actions

    // Acting on a nudge: hide the app (so system frontmost reverts naturally),
    // then dispatch AppActivator to bring the target app forward and optionally
    // send the approval keystroke. Hiding *before* the dispatch matters — if we
    // stayed active, the Enter keystroke can land in our process instead of the
    // target's key window.
    private func actOnSelected(approve: Bool) {
        guard let event = store.selectedEvent else { return }
        store.remove(id: event.id)
        hidePanel()

        guard let bundleID = event.bundleID else { return }
        let sendApproval = approve && event.hasActionButton
        DispatchQueue.global(qos: .userInitiated).async {
            AppActivator.activate(
                bundleID: bundleID,
                windowTitle: event.windowTitle,
                ipcHook: event.ipcHook,
                projectPath: event.projectPath,
                sendApproval: sendApproval,
                agent: event.agent
            )
        }
    }

    private func dismissSelected() {
        guard let id = store.selectedID else { return }
        store.remove(id: id)
        if store.events.isEmpty { hidePanel() }
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
    private func toggle() {
        if panel.isKeyWindow {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // NSApp.hide hides all our windows AND deactivates the app, so the system
    // frontmost reverts to whatever was active before the panel was summoned.
    private func hidePanel() {
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    // MARK: - Setup helpers

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
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
        } catch {
            FileHandle.standardError.write(Data(
                "stack-nudge-panel: listener failed: \(error)\n".utf8))
        }
    }
}
