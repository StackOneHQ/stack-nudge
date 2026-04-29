import AppKit
import SwiftUI

protocol PanelKeyDelegate: AnyObject {
    func panelHandlesKey(_ event: NSEvent) -> Bool
}

private enum KeyCode {
    static let escape:    UInt16 = 53
    static let upArrow:   UInt16 = 126
    static let downArrow: UInt16 = 125
    static let returnKey: UInt16 = 36
    static let numpadEnter: UInt16 = 76
    static let oKey:      UInt16 = 31
    static let rKey:      UInt16 = 15
    static let delete:    UInt16 = 51
    static let forwardDelete: UInt16 = 117
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if store.events.isEmpty {
                emptyState
            } else {
                eventList
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("stack-nudge")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            if !store.events.isEmpty {
                Text("\(store.events.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.08))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Image(systemName: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if store.events.isEmpty {
                FooterHint(label: "Hide", keys: ["esc"])
            } else {
                if let primary = primaryActionLabel {
                    FooterHint(label: primary, keys: ["⏎"], primary: true)
                    FooterDivider()
                }
                FooterHint(label: "Select", keys: ["↑", "↓"])
                FooterHint(label: "Dismiss", keys: ["⌫"])
                FooterHint(label: "Hide", keys: ["esc"])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                Color.primary.opacity(0.05)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
    }

    private var primaryActionLabel: String? {
        guard let event = store.selectedEvent else { return nil }
        return event.kind == .permission ? "Approve" : "Open editor"
    }
}

private struct FooterHint: View {
    let label: String
    let keys: [String]
    var primary: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(primary ? Color.primary : Color.secondary)
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { KeyCapView(symbol: $0) }
            }
        }
        .padding(.leading, 10)
    }
}

private struct KeyCapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(minWidth: 14, minHeight: 16)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            )
    }
}

private struct FooterDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 14)
            .padding(.leading, 14)
            .padding(.trailing, 4)
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
final class PanelController: NSObject, NSApplicationDelegate, PanelKeyDelegate {

    private var panel: FloatingPanel!
    private var hotkey: Hotkey?
    private let store = EventStore()
    private var listener: EventListener?
    private var menuBar: MenuBarController?

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

        let host = NSHostingView(rootView: PanelContentView(store: store))
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
        hotkey = Hotkey(spec: config.hotkeySpec) { [weak self] in
            self?.toggle()
        }
        if hotkey == nil {
            FileHandle.standardError.write(Data(
                "stack-nudge-panel: failed to register hotkey '\(config.hotkeySpec)'\n".utf8))
        }

        startListener()
        menuBar = MenuBarController(panelController: self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener?.stop()
    }

    // MARK: - PanelKeyDelegate

    func panelHandlesKey(_ event: NSEvent) -> Bool {
        let blockingMods: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockingMods).isEmpty else {
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
                sendApproval: sendApproval
            )
        }
    }

    private func dismissSelected() {
        guard let id = store.selectedID else { return }
        store.remove(id: id)
        if store.events.isEmpty { hidePanel() }
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
