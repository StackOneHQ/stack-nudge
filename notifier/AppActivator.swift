import AppKit
import ApplicationServices

struct AppActivator {

    private static let processName: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.microsoft.VSCode":           "Code",
        "com.googlecode.iterm2":          "iTerm2",
        "dev.warp.Warp-Stable":           "Warp",
        "com.mitchellh.ghostty":          "Ghostty",
        "com.apple.Terminal":             "Terminal",
    ]

    private static let cliName: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.microsoft.VSCode":           "code",
    ]

    static func activate(bundleID: String, windowTitle: String? = nil,
                         ipcHook: String? = nil, projectPath: String? = nil,
                         sendApproval: Bool = false) {
        let folder = windowTitle ?? projectPath.map { ($0 as NSString).lastPathComponent }
        let proc = processName[bundleID]

        // Cursor/VSCode: use the CLI to switch the internal active window, then bring it
        // to front. Two separate AppleScripts because `do shell script` doesn't need
        // Automation permission while `tell application "System Events"` does.
        if let path = projectPath, !path.isEmpty,
           let cli = findCLI(for: bundleID),
           let procName = proc {
            let escapedCLI  = cli.replacingOccurrences(of: "'", with: "'\\''")
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            let trusted = AXIsProcessTrusted()

            // Step 1: activate app + switch window via CLI (no Automation needed)
            var err: NSDictionary?
            NSAppleScript(source: """
                tell application "\(procName)" to activate
                delay 0.4
                do shell script "'\(escapedCLI)' --reuse-window '\(escapedPath)'"
            """)?.executeAndReturnError(&err)

            // Step 2: set frontmost + optionally press Enter (requires Automation for System Events)
            let pressEnter = sendApproval && trusted
            var err2: NSDictionary?
            NSAppleScript(source: """
                tell application "System Events"
                    set frontmost of process "\(procName)" to true
                    \(pressEnter ? "delay 0.3\nkey code 36" : "")
                end tell
            """)?.executeAndReturnError(&err2)
            return
        }

        // Fallback: activate then AXRaise with retries (works for native terminal apps).
        // Retry schedule from claude-notifications-go: 150ms → 250ms → 400ms.
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate(options: [.activateIgnoringOtherApps])

        if let title = folder, !title.isEmpty {
            let pid = app.processIdentifier
            for delay in [0.15, 0.25, 0.40] {
                Thread.sleep(forTimeInterval: delay)
                if raiseWindow(pid: pid, containingTitle: title) { break }
            }
        }
    }

    // MARK: - CLI discovery

    private static func findCLI(for bundleID: String) -> String? {
        guard let name = cliName[bundleID] else { return nil }
        let searchPaths = [
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
        ]
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - AX window raise (native terminal apps / fallback)

    @discardableResult
    private static func raiseWindow(pid: pid_t, containingTitle title: String) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window,
                                                kAXTitleAttribute as CFString,
                                                &titleRef) == .success,
                  let windowTitle = titleRef as? String,
                  windowTitle.contains(title) else { continue }

            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(appElement,
                                         kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue)
            return true
        }
        return false
    }
}
