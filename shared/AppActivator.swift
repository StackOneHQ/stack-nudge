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
                         sessionID: String? = nil,
                         sendApproval: Bool = false, agent: String? = nil) {
        // For matching windows/tabs we want a LOOSE fragment that survives
        // the user switching tabs between event time and click time:
        //   - Tab titles in standalone terminals (Ghostty/iTerm/Terminal)
        //     include the cwd basename plus other dynamic bits ("claude
        //     ~/projA — Ghostty"). The exact captured windowTitle won't
        //     match the current title if the user moved tabs.
        //   - The project basename (eg "projA") is stable and almost
        //     always present in the tab title format.
        // Prefer the basename when we have a projectPath, fall back to
        // the captured windowTitle otherwise.
        let folder = projectPath.map { ($0 as NSString).lastPathComponent } ?? windowTitle
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

            // When ipcHook is set (captured from VSCODE_IPC_HOOK_CLI at hook
            // time), prefix the CLI invocation with it so the command talks
            // to that specific window's IPC server. Without this, --reuse-window
            // picks the most-recently-focused matching window — which is the
            // wrong one when the user has multiple editor windows open for
            // the same project.
            let envPrefix: String
            if let hook = ipcHook, !hook.isEmpty {
                let escapedHook = hook.replacingOccurrences(of: "'", with: "'\\''")
                envPrefix = "VSCODE_IPC_HOOK_CLI='\(escapedHook)' "
            } else {
                envPrefix = ""
            }

            // Step 1: activate app + switch window via CLI (no Automation needed)
            var err: NSDictionary?
            NSAppleScript(source: """
                tell application "\(procName)" to activate
                delay 0.4
                do shell script "\(envPrefix)'\(escapedCLI)' --reuse-window '\(escapedPath)'"
            """)?.executeAndReturnError(&err)

            // Step 2: set frontmost (requires Automation for System Events)
            var err2: NSDictionary?
            NSAppleScript(source: """
                tell application "System Events" to set frontmost of process "\(procName)" to true
            """)?.executeAndReturnError(&err2)

            // Step 2.5: AX-raise the specific window. --reuse-window routes
            // the open request to the right window's IPC server (when
            // ipcHook is set), but the CLI doesn't raise that window —
            // the app's most-recently-focused window pops to front
            // instead. The captured windowTitle has the open filename and
            // is window-specific, so AX-matching it pins activation to
            // the correct window.
            if let title = windowTitle, !title.isEmpty,
               let runningApp = NSRunningApplication
                   .runningApplications(withBundleIdentifier: bundleID).first {
                Thread.sleep(forTimeInterval: 0.15)
                _ = raiseWindow(pid: runningApp.processIdentifier,
                                containingTitle: title)
            }

            // Step 3: focus the agent's terminal pane via AX before sending Enter,
            // so the keystroke lands in the right pane instead of whatever was
            // last focused in VS Code. After AX press of the tab, dwell briefly
            // for the xterm canvas to take focus, then send Enter routed
            // explicitly to the Code/Cursor process.
            if pressEnter {
                Thread.sleep(forTimeInterval: 0.3)
                if let runningApp = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleID).first {
                    _ = focusEditorTerminal(
                        pid: runningApp.processIdentifier,
                        agent: terminalLabelHint(for: agent)
                    )
                    Thread.sleep(forTimeInterval: 0.3)
                }
                var err3: NSDictionary?
                NSAppleScript(source: """
                    tell application "System Events"
                        tell process "\(procName)"
                            key code 36
                        end tell
                    end tell
                """)?.executeAndReturnError(&err3)
            }
            return
        }

        // Ghostty doesn't implement NSAccessibility on its Metal-rendered
        // windows — `kAXWindowsAttribute` returns empty, so the AX walk
        // below would never find anything. Ghostty 1.3.1+ ships a real
        // AppleScript dictionary instead; use that to switch tabs by
        // exact working-directory match. Falls through to standard
        // activation if the scripting bridge doesn't respond (older
        // Ghostty, or `tell application` permission denied).
        if bundleID == "com.mitchellh.ghostty",
           let path = projectPath, !path.isEmpty {
            focusGhosttyTab(projectPath: path)
            return
        }

        // iTerm2: each tab/pane has a unique session id (captured as
        // ITERM_SESSION_ID by notify.sh). Walking via AppleScript and
        // selecting that exact session disambiguates between multiple
        // tabs in the same project folder, which title-fragment matching
        // can't resolve. Falls through to the AX-based path if the
        // session id is missing or the scripting bridge errors.
        if bundleID == "com.googlecode.iterm2",
           let sid = sessionID, !sid.isEmpty,
           focusIterm2Session(sessionID: sid) {
            return
        }

        // Fallback: activate then AXRaise with retries (works for native terminal apps).
        // Retry schedule from claude-notifications-go: 150ms → 250ms → 400ms.
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate(options: [.activateIgnoringOtherApps])

        if let title = folder, !title.isEmpty {
            let pid = app.processIdentifier
            // Two passes per retry tick:
            //   1. raiseWindow: bring the OS-window containing the project
            //      to front (no-op when the project's tab is in the same
            //      window the user is already looking at).
            //   2. focusTabContaining: walk that app's AX tree for a tab
            //      element whose title contains the project name and
            //      AXPress it. This is what actually switches tabs.
            // Run #2 regardless of #1's outcome — when both tabs share the
            // same OS-window, raiseWindow has nothing to do but the tab
            // still needs selecting.
            for delay in [0.15, 0.25, 0.40] {
                Thread.sleep(forTimeInterval: delay)
                let raised = raiseWindow(pid: pid, containingTitle: title)
                let tabbed = focusTabContaining(pid: pid, fragment: title)
                if raised || tabbed { break }
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
        // AX press is the click-equivalent — for terminal tab radio buttons,
        // it both selects the tab and lets VS Code's own JS focus handlers
        // run, which is what moves keyboard focus into the xterm canvas.
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

    // MARK: - Ghostty (AppleScript bridge)

    // Ghostty exposes a scripting dictionary (windows → tabs → terminals)
    // since 1.3.0; 1.3.1 added the activation-on-select fix so the .app
    // actually comes to front. We can't use AX on Ghostty (it doesn't
    // implement NSAccessibility on its Metal windows), so AppleScript is
    // the supported external-control surface.
    //
    // Strategy: enumerate all tabs in all windows, find the one whose
    // terminal.workingDirectory matches the event's projectPath exactly,
    // and `select` it. Working directory is more reliable than title
    // since titles include the running command + variable formatting.
    private static func focusGhosttyTab(projectPath: String) {
        let escaped = projectPath.replacingOccurrences(of: "\"", with: "\\\"")
        // Two matching attempts in descending strictness:
        //   1. Exact `is` after coercing both sides to text — Ghostty's
        //      `working directory` returns a URL/alias type, which `is`
        //      compares unequal to plain strings even when they print
        //      identically. `as text` makes it a string-string compare.
        //   2. `contains` either direction — handles Unicode-normalisation
        //      drift (NFC vs NFD) and trailing-slash differences.
        // First match wins. `tell w to select tab t` is what actually
        // switches the tab; the outer `activate` brings Ghostty to front.
        let script = """
        tell application "Ghostty"
          activate
          set target to "\(escaped)" as text
          repeat with w in windows
            repeat with t in tabs of w
              try
                set wd to (working directory of terminal of t) as text
                if wd is target then
                  tell w to select tab t
                  return "matched-exact"
                end if
                if wd contains target or target contains wd then
                  tell w to select tab t
                  return "matched-contains"
                end if
              end try
            end repeat
          end repeat
          return "no-match"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    // MARK: - iTerm2 (AppleScript bridge)

    // iTerm2 sets ITERM_SESSION_ID on every shell. Walk windows -> tabs ->
    // sessions to find the session whose id matches and select it. The
    // returned bool tells the caller whether to fall through to the AX
    // path: false means scripting bridge errored or the id didn't match
    // any open session (closed since the event fired).
    @discardableResult
    private static func focusIterm2Session(sessionID: String) -> Bool {
        // ITERM_SESSION_ID is "w0t0p0:UUID" (window-tab-pane prefix + UUID).
        // iTerm2's AppleScript exposes the UUID as `id of session`, so strip
        // the prefix when present.
        let uuid = sessionID.split(separator: ":").last.map(String.init) ?? sessionID
        let escaped = uuid.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
          activate
          set target to "\(escaped)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  -- Match on `unique id` (the persistent session GUID that
                  -- both ITERM_SESSION_ID and our tab enrichment carry);
                  -- keep `id` as a fallback for iTerm2 versions where the
                  -- two properties diverge.
                  if ((unique id of s) as text) is target or ((id of s) as text) is target then
                    tell w to select
                    tell t to select
                    tell s to select
                    return "matched"
                  end if
                end try
              end repeat
            end repeat
          end repeat
          return "no-match"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard err == nil else { return false }
        return result?.stringValue == "matched"
    }

    // MARK: - AX tab switching (standalone terminal apps)

    // For tabbed terminals where the OS-window is already frontmost but
    // the event's source tab isn't the selected one. Walks the focused
    // window's AX subtree (skipping the window node itself, since its
    // title mirrors the currently-selected tab and would be a false
    // match) for an element whose title or description contains the
    // project-name fragment. AXPress on the match selects the tab —
    // same mechanism as focusEditorTerminal uses for VS Code panes.
    @discardableResult
    private static func focusTabContaining(pid: pid_t, fragment: String) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        // Try every window of the app, not just the focused one — the
        // project's tab may live in a different OS-window the user has
        // open but isn't currently looking at.
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXWindowsAttribute as CFString,
                                            &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for win in windows {
            // Walk window children directly (not the window itself) so we
            // never match the window's own title — that mirrors the
            // currently-selected tab and would be a false positive when
            // the project we want is sitting in a different tab.
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win,
                                                kAXChildrenAttribute as CFString,
                                                &children) == .success,
                  let kids = children as? [AXUIElement] else { continue }

            for child in kids {
                if let match = findElement(in: child, depth: 0, matching: { node in
                    axStringContains(node, attribute: kAXTitleAttribute as CFString, fragment: fragment) ||
                    axStringContains(node, attribute: kAXDescriptionAttribute as CFString, fragment: fragment)
                }) {
                    // Raise the containing window so the tab actually
                    // becomes visible after AXPress.
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(appElement,
                                                 kAXFrontmostAttribute as CFString,
                                                 kCFBooleanTrue)
                    return focus(match)
                }
            }
        }
        return false
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
