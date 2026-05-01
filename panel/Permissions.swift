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

    static func automation() -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:                              return .granted
        case OSStatus(errAEEventNotPermitted):   return .denied
        default:                                 return .unknown
        }
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
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, true)
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
            try? task.run()
            task.waitUntilExit()
        }

        switch pane {
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: kCFBooleanTrue!] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .automation:
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, true)
        case .notifications:
            promptNotifications()
        }
    }
}

enum SettingsPane {
    case accessibility
    case automation
    case notifications

    var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        }
    }

    var tccService: String? {
        switch self {
        case .accessibility: return "Accessibility"
        case .automation:    return "AppleEvents"
        case .notifications: return nil  // notifications aren't a TCC service
        }
    }
}

struct PermissionsView: View {

    @State private var accessibility: PermissionStatus = .unknown
    @State private var automation:    PermissionStatus = .unknown
    @State private var notifications: PermissionStatus = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions")
                    .font(.title3.weight(.semibold))
                Text("stack-nudge needs these grants to show banners, focus the right window, and send the Enter keystroke when you approve a permission nudge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(title: "Notifications",
                description: "Required for the macOS banner to appear when an agent finishes or pauses for approval.",
                status: notifications,
                pane: .notifications)

            row(title: "Accessibility",
                description: "Required for the Enter-to-approve keystroke. AXIsProcessTrusted() is false until you grant this.",
                status: accessibility,
                pane: .accessibility)

            row(title: "Automation → System Events",
                description: "Required for AppleScript to focus the right window when you act on a nudge.",
                status: automation,
                pane: .automation)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Refresh") { refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
    }

    private func row(title: String, description: String,
                     status: PermissionStatus, pane: SettingsPane) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(for: status))
                .font(.title3)
                .foregroundStyle(color(for: status))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if status != .granted {
                    Button(pane == .notifications ? "Prompt" : "Reset & prompt") {
                        if pane == .notifications {
                            Permissions.promptNotifications()
                        } else {
                            Permissions.resetAndPrompt(pane)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refresh() }
                    }
                    .controlSize(.small)
                }
                Button("Settings") {
                    Permissions.openSettings(pane)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func refresh() {
        accessibility = Permissions.accessibility()
        automation    = Permissions.automation()
        Permissions.notifications { notifications = $0 }
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

final class PermissionsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "stack-nudge — Permissions"
        window.isReleasedWhenClosed = false
        window.center()
        // .moveToActiveSpace follows the user to whatever Space they're on,
        // which is what we want for an on-demand permissions window. We do
        // NOT raise the window's level — when the user clicks a button that
        // triggers a system dialog (Accessibility prompt) or opens System
        // Settings, those should be the focused, frontmost window. With
        // .modalPanel level, our window stayed on top and clipped them.
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = NSHostingView(rootView: PermissionsView())
        self.init(window: window)
    }

    func showAndRaise() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.orderFrontRegardless()
    }
}
