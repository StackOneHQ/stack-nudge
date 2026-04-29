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
                         sendApproval: Bool = false, agent: String? = nil) {
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
            let pressEnter = sendApproval && trusted

            // Step 1: activate app + switch window via CLI (no Automation needed)
            var err: NSDictionary?
            NSAppleScript(source: """
                tell application "\(procName)" to activate
                delay 0.4
                do shell script "'\(escapedCLI)' --reuse-window '\(escapedPath)'"
            """)?.executeAndReturnError(&err)

            // Step 2: set frontmost (requires Automation for System Events)
            var err2: NSDictionary?
            NSAppleScript(source: """
                tell application "System Events" to set frontmost of process "\(procName)" to true
            """)?.executeAndReturnError(&err2)

            // Step 3: focus the agent's terminal pane via AX before sending Enter,
            // so the keystroke lands in the right pane instead of whatever was
            // last focused in VS Code.
            if pressEnter {
                Thread.sleep(forTimeInterval: 0.3)
                if let runningApp = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first {
                    _ = focusEditorTerminal(
                        pid: runningApp.processIdentifier,
                        agent: terminalLabelHint(for: agent)
                    )
                    Thread.sleep(forTimeInterval: 0.1)
                }
                var err3: NSDictionary?
                NSAppleScript(source: """
                    tell application "System Events" to key code 36
                """)?.executeAndReturnError(&err3)
            }
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

        // Press Enter to approve the permission prompt (requires Accessibility permission)
        if sendApproval && AXIsProcessTrusted(), let procName = proc {
            var err: NSDictionary?
            NSAppleScript(source: """
                tell application "System Events"
                    tell process "\(procName)"
                        delay 0.3
                        key code 36
                    end tell
                end tell
            """)?.executeAndReturnError(&err)
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

    // MARK: - AX terminal-pane focus (VS Code / Cursor)

    // Map the agent identifier we get from notify.sh to the binary name that
    // VS Code's shell-integrated terminal tab title would expose. Cursor's
    // own IDE-embedded agent isn't a separate process and doesn't apply.
    private static func terminalLabelHint(for agent: String?) -> String? {
        switch agent?.lowercased() {
        case "claude-code", "claude":  return "claude"
        case "gemini", "gemini-cli":   return "gemini"
        case "codex",  "codex-cli":    return "codex"
        default:                       return nil
        }
    }

    // Walk VS Code's accessibility tree and focus the terminal pane that hosts
    // the running agent. Identifies the right pane via the AXTitle/AXDescription
    // exposed by xterm.js — with shell integration on (default), the tab label
    // reflects the running command name so a CC tab shows "claude". Falls back
    // to the first terminal-shaped element if the labelled match misses.
    @discardableResult
    private static func focusEditorTerminal(pid: pid_t, agent: String?) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              CFGetTypeID(window!) == AXUIElementGetTypeID() else { return false }
        let win = window as! AXUIElement

        // First pass: look for an element that names the agent — most reliable
        // when shell integration sets the tab title to the running command.
        if let agent {
            if let match = findElement(in: win, depth: 0, matching: { node in
                axStringContains(node, attribute: kAXTitleAttribute as CFString, fragment: agent) ||
                axStringContains(node, attribute: kAXDescriptionAttribute as CFString, fragment: agent)
            }) {
                return focus(match)
            }
        }

        // Fallback: any element whose label contains "terminal".
        if let match = findElement(in: win, depth: 0, matching: { node in
            axStringContains(node, attribute: kAXTitleAttribute as CFString, fragment: "terminal") ||
            axStringContains(node, attribute: kAXDescriptionAttribute as CFString, fragment: "terminal")
        }) {
            return focus(match)
        }
        return false
    }

    private static func focus(_ element: AXUIElement) -> Bool {
        // Prefer an explicit press (terminal tab elements respond to it the
        // same way a click would, which both selects the tab and focuses the
        // xterm canvas inside). Fall back to setting the focused attribute
        // for elements that don't accept a press.
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        return AXUIElementSetAttributeValue(element,
                                            kAXFocusedAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    private static func axStringContains(_ element: AXUIElement,
                                          attribute: CFString,
                                          fragment: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let str = value as? String else { return false }
        return str.range(of: fragment, options: .caseInsensitive) != nil
    }

    // Bounded recursive search through the AX tree. VS Code's tree can be
    // 15+ levels deep; cap at 25 so we don't blow the stack on pathological
    // accessibility trees and don't burn time on deep walks.
    private static func findElement(in element: AXUIElement,
                                     depth: Int,
                                     matching test: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 25 else { return nil }
        if test(element) { return element }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXChildrenAttribute as CFString,
                                            &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }
        for child in kids {
            if let found = findElement(in: child, depth: depth + 1, matching: test) {
                return found
            }
        }
        return nil
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
