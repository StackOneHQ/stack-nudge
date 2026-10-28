import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

enum PermissionStatus {
    case granted, denied, unknown
}

// Probes for the two permissions stack-nudge-panel needs at runtime.
// AX is straightforward; Automation→System Events checks via AEDetermine
// with askUserIfNeeded=false so we never accidentally prompt.
enum Permissions {

    static let bundleID = "com.stackonehq.stack-nudge"

    static func accessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func automation(target bundleID: String = "com.apple.systemevents") -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:                              return .granted
        case OSStatus(errAEEventNotPermitted):   return .denied
        default:                                 return .unknown
        }
    }

    // tmux focus selects the iTerm2 tab over AppleScript, a grant separate from
    // System Events. nil while iTerm2 isn't running: the grant can only be
    // probed against a live target.
    static func iTermAutomation() -> PermissionStatus? {
        guard !NSRunningApplication
            .runningApplications(withBundleIdentifier: AppActivator.iTermBundleID).isEmpty
        else { return nil }
        return automation(target: AppActivator.iTermBundleID)
    }

    static func openSettings(_ target: SettingsPane) {
        NSWorkspace.shared.open(target.url)
    }

    // UNUserNotificationCenter authorization status. Async, so we hop on
    // the main queue to deliver the result for SwiftUI consumption.
    static func notifications(_ completion: @escaping (PermissionStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: completion(.granted)
                case .denied:                                completion(.denied)
                case .notDetermined:                         completion(.unknown)
                @unknown default:                            completion(.unknown)
                }
            }
        }
    }

    // Triggers the system notification permission dialog. Once the user has
    // chosen (allow/deny), subsequent calls are no-ops — they have to manage
    // the toggle in System Settings → Notifications.
    static func promptNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    // Non-destructive prompt — surfaces the system dialog that asks the user
    // to grant the permission and offers a button into System Settings, but
    // does NOT clear the existing TCC entry first (unlike resetAndPrompt).
    // Use this for first-run onboarding; resetAndPrompt is for dev-time
    // recovery after rebuilds change the cdhash.
    static func prompt(_ pane: SettingsPane) {
        switch pane {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: kCFBooleanTrue!] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .automation:
            triggerAutomationPrompt()
        case .automationITerm2:
            triggerITermAutomationPrompt()
        case .notifications:
            promptNotifications()
        }
    }

    // Clear the TCC entry for this app + service, then trigger the system
    // prompt so a fresh entry is bound to the current cdhash. This is the
    // dev-time recovery for the ad-hoc-rebuild stale-grant problem: each
    // rebuild changes the cdhash, but Settings keeps showing the old entry
    // as "on" until you remove + re-add.
    static func resetAndPrompt(_ pane: SettingsPane) {
        if let service = pane.tccService {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, bundleID]
            let err = Pipe()
            task.standardError = err
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data(
                    "stack-nudge: tccutil reset \(service) failed (\(task.terminationStatus)): \(msg)\n".utf8))
            }
        }

        switch pane {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: kCFBooleanTrue!] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .automation:
            triggerAutomationPrompt()
        case .automationITerm2:
            // The reset clears every AppleEvents target, System Events included.
            triggerAutomationPrompt()
            triggerITermAutomationPrompt()
        case .notifications:
            promptNotifications()
        }
    }

    // Force the TCC Automation prompt for System Events by actually sending
    // an AppleEvent — AEDeterminePermissionToAutomateTarget often returns
    // the cached decision without dispatching the dialog, so we send a
    // harmless command instead. macOS shows the prompt the first time an
    // app sends events to a new target, regardless of prior denial state
    // (after a tccutil reset clears the decision).
    private static func triggerAutomationPrompt() {
        let source = "tell application \"System Events\" to count processes"
        guard let script = NSAppleScript(source: source) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
        }
    }

    // Only while iTerm2 runs, so asking never launches it.
    private static func triggerITermAutomationPrompt() {
        guard iTermAutomation() != nil,
              let script = NSAppleScript(source: "tell application id \"\(AppActivator.iTermBundleID)\" to get name")
        else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
        }
    }
}

enum SettingsPane {
    case accessibility
    case automation
    case automationITerm2
    case notifications

    var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .automation, .automationITerm2:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        }
    }

    var tccService: String? {
        switch self {
        case .accessibility: return "Accessibility"
        case .automation, .automationITerm2: return "AppleEvents"
        case .notifications: return nil  // notifications aren't a TCC service
        }
    }

    // Short human label for the Settings "Permissions needed" banner.
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .automation:    return "Automation"
        case .automationITerm2: return "Automation (iTerm2)"
        case .notifications: return "Notifications"
        }
    }
}

// The grants on the Permissions page and which one is selected. The page is a
// Settings sub-page rather than a window of its own, so the panel's key handler
// drives it through here.
final class PermissionsModel: ObservableObject {

    struct Row: Equatable {
        let pane: SettingsPane
        let status: PermissionStatus
    }

    @Published private(set) var rows: [Row] = []
    // Held by pane rather than position: the iTerm2 row comes and goes with
    // iTerm2, and an index would quietly slide onto a different grant, which
    // ⏎ would then reset.
    @Published var selected: SettingsPane = .notifications

    // Called after every probe, so the Settings tab dot and the "Permissions
    // needed" banner clear as soon as this page sees a grant.
    var onRefresh: (() -> Void)?

    var selectedRow: Row? { rows.first { $0.pane == selected } }

    // Notifications answer asynchronously, so the other grants are probed in
    // its callback and every row lands at once, in the order the page lists them.
    func refresh() {
        Permissions.notifications { [weak self] notifications in
            guard let self else { return }
            var rows = [Row(pane: .notifications, status: notifications),
                        Row(pane: .accessibility, status: Permissions.accessibility()),
                        Row(pane: .automation, status: Permissions.automation())]
            if let iTerm = Permissions.iTermAutomation() {
                rows.append(Row(pane: .automationITerm2, status: iTerm))
            }
            if rows != self.rows { self.rows = rows }
            // Only iTerm2's row can go, and System Events sits above it.
            if !rows.contains(where: { $0.pane == self.selected }) { self.selected = .automation }
            self.onRefresh?()
        }
    }

    func selectPrevious() { step(-1) }
    func selectNext() { step(1) }

    func selectEdge(top: Bool) {
        if let row = top ? rows.first : rows.last { selected = row.pane }
    }

    private func step(_ delta: Int) {
        guard let index = rows.firstIndex(where: { $0.pane == selected }),
              rows.indices.contains(index + delta)
        else { return }
        selected = rows[index + delta].pane
    }

    // A granted row has nothing to ask for; its ⏎ hint dims to match.
    func promptSelected() {
        guard let row = selectedRow, row.status != .granted else { return }
        prompt(row.pane)
    }

    func prompt(_ pane: SettingsPane) {
        if pane == .notifications {
            Permissions.promptNotifications()
        } else {
            Permissions.resetAndPrompt(pane)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    func openSelectedInSettings() {
        guard let row = selectedRow else { return }
        Permissions.openSettings(row.pane)
    }
}

struct PermissionsView: View {

    @ObservedObject var model: PermissionsModel
    // Settings, or the setup screen when it was opened from there.
    let backLabel: String
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("StackNudge needs these grants to show banners, focus the right window, and send the Enter keystroke when you approve a permission nudge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.rows, id: \.pane) { row in
                            rowView(row, selected: row.pane == model.selected)
                                .id(row.pane)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selected = row.pane }
                        }
                    }
                    .padding(14)
                    .background(ThinScrollers())
                }
                // A short panel shows only a row or two, and ⏎ acts on the
                // selection, so the selection has to stay where it can be seen.
                .onChange(of: model.selected) { pane in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(pane, anchor: .center)
                    }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        // Coming back from System Settings or a system prompt makes the panel
        // key again, which is when a new grant shows up.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text(backLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Permissions")
                .font(.subheadline.weight(.medium))
                .padding(.leading, 6)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func rowView(_ row: PermissionsModel.Row, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(for: row.status))
                .font(.title3)
                .foregroundStyle(color(for: row.status))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(row.pane)).font(.subheadline.weight(.medium))
                Text(description(row.pane)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if row.status != .granted {
                    Button(row.pane == .notifications ? "Prompt" : "Reset & prompt") {
                        model.prompt(row.pane)
                    }
                    .controlSize(.small)
                }
                Button("Settings") { Permissions.openSettings(row.pane) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.12 : 0.05))
        )
    }

    private var footer: some View {
        let canPrompt = model.selectedRow.map { $0.status != .granted } ?? false
        return PageFooter {
            FooterHint(label: "Prompt", keys: ["⏎"], primary: true).opacity(canPrompt ? 1 : 0.35)
            FooterHint(label: "System Settings", keys: ["⌘⏎"])
            FooterHint(label: "Refresh", keys: ["⌘R"])
            FooterHint(label: backLabel, keys: ["←"])
        }
    }

    private func title(_ pane: SettingsPane) -> String {
        switch pane {
        case .notifications:    return "Notifications"
        case .accessibility:    return "Accessibility"
        case .automation:       return "Automation → System Events"
        case .automationITerm2: return "Automation → iTerm2"
        }
    }

    private func description(_ pane: SettingsPane) -> String {
        switch pane {
        case .notifications:
            return "Required for the macOS banner to appear when an agent finishes or pauses for approval."
        case .accessibility:
            return "Required for the Enter-to-approve keystroke. AXIsProcessTrusted() is false until you grant this."
        case .automation:
            return "Required for AppleScript to focus the right window when you act on a nudge."
        case .automationITerm2:
            return "Required to bring the exact iTerm2 tab forward for a tmux-hosted agent."
        }
    }

    private func glyph(for status: PermissionStatus) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied:  return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied:  return .red
        case .unknown: return .orange
        }
    }
}
