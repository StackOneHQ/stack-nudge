import AppKit
import Foundation
import SwiftUI

// Owns the install / uninstall of stack-nudge on this Mac. Replaces the
// shell-script install.sh / uninstall.sh paths for end users: the .app
// itself runs the first-launch wizard, wires hooks into agent configs,
// registers launchd agents, and tears all of it down again on uninstall.
//
// install.sh remains for Linux/Windows + source-build devs; the macOS
// flow now centres on this file.

// MARK: - Agent

// Which AI coding agent the user wants stack-nudge wired into. Detected
// by the presence of the agent's config directory under $HOME.
enum BootstrapAgent: String, CaseIterable, Identifiable, Equatable {
    case claude
    case cursor
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        }
    }

    // Filesystem marker that signals the agent is installed locally.
    // Mirrors the directory checks install.sh does.
    var detectionDirectory: String {
        switch self {
        case .claude: return "\(NSHomeDirectory())/.claude"
        case .cursor: return "\(NSHomeDirectory())/.cursor"
        case .gemini: return "\(NSHomeDirectory())/.gemini"
        }
    }

    // Hook config file we write to when installing for this agent. Each
    // agent has its own JSON shape; Bootstrap.install handles the splicing.
    var hookConfigPath: String {
        switch self {
        case .claude: return "\(NSHomeDirectory())/.claude/settings.json"
        case .cursor: return "\(NSHomeDirectory())/.cursor/hooks.json"
        // Gemini hook support is experimental; install.sh writes nothing
        // for it today. We mirror that — Bootstrap.install skips Gemini
        // hook wiring. Selecting it is a no-op aside from acknowledging.
        case .gemini: return "\(NSHomeDirectory())/.gemini/settings.json"
        }
    }
}

// MARK: - Bootstrap

enum Bootstrap {

    // MARK: Constants

    static let installDir       = "\(NSHomeDirectory())/.stack-nudge"
    static let notifyPath       = "\(NSHomeDirectory())/.stack-nudge/notify.sh"
    static let venvSymlinkPath  = "\(NSHomeDirectory())/.stack-nudge/venv"
    static let configPath       = "\(NSHomeDirectory())/.stack-nudge/config"
    static let phrasesDir       = "\(NSHomeDirectory())/.stack-nudge/phrases"

    static let launchAgentsDir  = "\(NSHomeDirectory())/Library/LaunchAgents"
    static let appLabel         = "com.stackonehq.stack-nudge"
    static let daemonLabel      = "com.stackonehq.stack-nudge-daemon"

    // Pattern matching any tinynudge/stack-nudge notify.sh reference in a
    // hook command, including quoted paths. Same regex as uninstall.sh
    // (loosened in #39 to handle quoted forms).
    static let staleHookRegex = try? NSRegularExpression(
        pattern: #"(?:^|/|")\.?(?:tinynudge|stack-nudge)/notify\.sh"#
    )

    // MARK: Detection

    // First-launch detection. Returns true when any of the install
    // artifacts exist — i.e. a previous install (this session or a
    // legacy install.sh run) has happened on this machine.
    //
    // Used at app startup to decide whether to show the bootstrap
    // wizard or skip straight to normal panel operation. Permissive on
    // purpose: any one of these signals is enough, so a partially-
    // installed machine doesn't repeatedly re-trigger the wizard.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: notifyPath) { return true }
        if fm.fileExists(atPath: "\(launchAgentsDir)/\(appLabel).plist") {
            return true
        }
        return false
    }

    // Agents present on this Mac. The bootstrap wizard checks all of these
    // by default; the user can untick to skip wiring any of them.
    static func availableAgents() -> [BootstrapAgent] {
        BootstrapAgent.allCases.filter {
            FileManager.default.fileExists(atPath: $0.detectionDirectory)
        }
    }

    // MARK: Install

    // Install stack-nudge: copy bundled resources to ~/.stack-nudge/,
    // splice hook entries into each selected agent's config, write +
    // load launchd plists for the panel and the voice daemon. Reports
    // progress via the callback (one line per step) so the UI can
    // surface what's happening.
    //
    // Throws BootstrapError on any failure; the wizard surfaces these
    // verbatim. Partial-install state is not rolled back automatically —
    // a re-install will overwrite, and the uninstall path tolerates
    // missing artifacts.
    static func install(
        agents: Set<BootstrapAgent>,
        progress: @escaping (String) -> Void
    ) throws {
        let fm = FileManager.default

        progress("Creating \(installDir)…")
        try fm.createDirectory(atPath: installDir,
                               withIntermediateDirectories: true)

        progress("Copying notify.sh…")
        try copyBundledResource(named: "notify.sh", to: notifyPath)
        _ = chmod(notifyPath, 0o755)

        progress("Copying phrase pools…")
        // Wipe then recopy so reinstalls pick up new phrases.
        try? fm.removeItem(atPath: phrasesDir)
        try copyBundledResource(named: "phrases", to: phrasesDir)

        // Example config only when no live config exists — preserve user
        // edits across re-installs. Matches install.sh's behavior.
        if !fm.fileExists(atPath: configPath) {
            if Bundle.main.url(forResource: "notify.conf.example",
                               withExtension: nil) != nil {
                progress("Seeding default config…")
                try copyBundledResource(
                    named: "notify.conf.example",
                    to: configPath
                )
            }
        }

        // Symlink ~/.stack-nudge/venv → bundle/Contents/Resources/venv if
        // the bundle ships with stackvox. Local-dev builds may not bundle
        // the venv (it's a CI-only step); the symlink step is skipped
        // and voice notifications fall back gracefully.
        try linkBundledVenvIfPresent(progress: progress)

        for agent in agents {
            progress("Wiring hooks for \(agent.displayName)…")
            try wireHooks(for: agent)
        }

        progress("Writing launchd plists…")
        try writePanelPlist()
        try writeDaemonPlistIfVenvPresent()

        progress("Loading launchd agents…")
        try loadLaunchdAgent(label: appLabel)
        if hasBundledVenv() {
            try loadLaunchdAgent(label: daemonLabel)
        }

        progress("Install complete.")
    }

    // MARK: Uninstall

    // Reverse of install. Best-effort: unloads and removes everything
    // it can find, even on partial-install state, so a user uninstalling
    // doesn't get stuck because one piece was already missing. Errors are
    // logged via the progress callback but not thrown unless a critical
    // step (hook-config rewrite) fails.
    static func uninstall(progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default

        progress("Unloading launchd agents…")
        for label in [appLabel, daemonLabel] {
            let plist = "\(launchAgentsDir)/\(label).plist"
            if fm.fileExists(atPath: plist) {
                _ = try? runLaunchctl(["unload", plist])
                try? fm.removeItem(atPath: plist)
            }
        }

        progress("Removing hook entries…")
        for agent in BootstrapAgent.allCases {
            let path = agent.hookConfigPath
            if fm.fileExists(atPath: path) {
                try unwireHooks(at: path)
            }
        }

        progress("Removing \(installDir)…")
        try? fm.removeItem(atPath: installDir)

        progress("Moving stack-nudge.app to Trash…")
        // NSWorkspace.recycle is async; we kick it off and let the
        // current app terminate normally. macOS Finder handles the
        // actual deletion once we exit.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Resource copy helpers

    // Copy a file or directory from the .app's Resources/ into a
    // destination path on disk. Wipes the destination first so the
    // operation is idempotent (re-running install overwrites).
    private static func copyBundledResource(named name: String, to dest: String) throws {
        guard let src = Bundle.main.url(forResource: name, withExtension: nil) else {
            throw BootstrapError.bundleResourceMissing(name)
        }
        let fm = FileManager.default
        try? fm.removeItem(atPath: dest)
        do {
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest))
        } catch {
            throw BootstrapError.copyFailed(name, underlying: error)
        }
    }

    // Bundle resource lookup that tolerates absence — returns the URL
    // when the venv was bundled by CI, nil otherwise (local dev builds).
    private static func bundledVenvURL() -> URL? {
        Bundle.main.url(forResource: "venv", withExtension: nil)
    }

    private static func hasBundledVenv() -> Bool {
        guard let url = bundledVenvURL() else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("bin/stackvox").path
        )
    }

    // Symlink the canonical ~/.stack-nudge/venv path to the bundled
    // venv inside the .app. Notify.sh hardcodes the canonical path, so
    // routing through the symlink keeps that script unchanged.
    private static func linkBundledVenvIfPresent(progress: @escaping (String) -> Void) throws {
        guard let venvURL = bundledVenvURL() else {
            progress("(no bundled voice engine — skip symlink)")
            return
        }
        let fm = FileManager.default
        try? fm.removeItem(atPath: venvSymlinkPath)
        do {
            try fm.createSymbolicLink(
                atPath: venvSymlinkPath,
                withDestinationPath: venvURL.path
            )
            progress("Linked voice engine → \(venvURL.path)")
        } catch {
            throw BootstrapError.writeFailed("venv symlink", underlying: error)
        }
    }

    // MARK: - Hook wiring (per-agent)

    // Splice our hook entry into the agent's JSON config, after removing
    // any stale entries pointing at older tinynudge/stack-nudge installs.
    // Swift port of the inline-Python blocks in install.sh.
    private static func wireHooks(for agent: BootstrapAgent) throws {
        let path = agent.hookConfigPath
        switch agent {
        case .claude:
            try wireClaudeHooks(at: path)
        case .cursor:
            try wireCursorHooks(at: path)
        case .gemini:
            // install.sh just prints "experimental, see README" for
            // Gemini today. Mirror that: no-op, but accept the agent
            // in `agents` so the wizard checkbox does something
            // (acknowledges the user's choice).
            break
        }
    }

    private static func wireClaudeHooks(at path: String) throws {
        var root = try readJSONObject(at: path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Two Claude events: Stop (turn ends, 30s timeout) and
        // PermissionRequest (blocking on user approval, 600s).
        let entries: [(event: String, arg: String, timeout: Int)] = [
            ("Stop",              "stop",       30),
            ("PermissionRequest", "permission", 600),
        ]

        for (event, arg, timeout) in entries {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = pruneStaleHookGroups(groups)
            let ourHook: [String: Any] = [
                "type":    "command",
                "command": "\(notifyPath) claude-code \(arg)",
                "timeout": timeout,
            ]
            // Swift's [String: Any] doesn't preserve key order; the
            // resulting JSON is still valid. Claude Code parses by key.
            groups.append([
                "matcher": "",
                "hooks":   [ourHook],
            ])
            hooks[event] = groups
        }

        root["hooks"] = hooks
        try writeJSONObject(root, to: path)
    }

    private static func wireCursorHooks(at path: String) throws {
        var root = try readJSONObject(at: path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Cursor has a single "stop" event; its shape is a flat array
        // of hook entries (not the matcher-group nesting Claude uses).
        var stops = hooks["stop"] as? [[String: Any]] ?? []
        stops = pruneStaleHookEntries(stops)
        stops.append([
            "type":    "command",
            "command": "\(notifyPath) cursor stop",
        ])
        hooks["stop"] = stops

        root["hooks"] = hooks
        try writeJSONObject(root, to: path)
    }

    // Remove any "group" (Claude's matcher-group shape) whose inner
    // hooks reference a stale tinynudge/stack-nudge notify.sh.
    private static func pruneStaleHookGroups(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            let inner = group["hooks"] as? [[String: Any]] ?? []
            let kept = pruneStaleHookEntries(inner)
            if kept.isEmpty { return nil }
            if kept.count != inner.count {
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            return group
        }
    }

    // Remove individual hook entries (Cursor's flat shape) referencing
    // a stale notify.sh path. Uses the same regex as uninstall.sh.
    private static func pruneStaleHookEntries(_ entries: [[String: Any]]) -> [[String: Any]] {
        entries.filter { entry in
            let command = (entry["command"] as? String) ?? ""
            return !isStaleHook(command: command)
        }
    }

    private static func isStaleHook(command: String) -> Bool {
        guard let regex = staleHookRegex else { return false }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    // Uninstall reverse: strip stale entries (the regex matches both old
    // and current paths) from any agent config that still has them.
    private static func unwireHooks(at path: String) throws {
        var root = try readJSONObject(at: path)
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        // Claude shape: matcher-groups
        for event in ["Stop", "PermissionRequest"] {
            if let groups = hooks[event] as? [[String: Any]] {
                let cleaned = pruneStaleHookGroups(groups)
                if cleaned.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = cleaned
                }
            }
        }
        // Cursor shape: flat array
        if let stops = hooks["stop"] as? [[String: Any]] {
            let cleaned = pruneStaleHookEntries(stops)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: "stop")
            } else {
                hooks["stop"] = cleaned
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeJSONObject(root, to: path)
    }

    // MARK: - JSON helpers

    private static func readJSONObject(at path: String) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        return (parsed as? [String: Any]) ?? [:]
    }

    private static func writeJSONObject(_ root: [String: Any], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        // Trailing newline so the file is well-formed for line-oriented
        // tools (some editors get cranky without it).
        var out = data
        out.append(0x0A)
        do {
            try out.write(to: url, options: [.atomic])
        } catch {
            throw BootstrapError.writeFailed(path, underlying: error)
        }
    }

    // MARK: - Launchd plist generation

    // Write the panel launchd plist (com.stackonehq.stack-nudge). Points
    // at the current bundle's executable so a moved .app naturally
    // re-anchors on next install. KeepAlive + RunAtLoad mirror install.sh.
    private static func writePanelPlist() throws {
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/stack-nudge").path
        let logPath = "\(installDir)/app.log"
        try writePlist(label: appLabel,
                       programArgs: [binary],
                       logPath: logPath)
    }

    // Write the voice-daemon launchd plist only when the bundle ships
    // with stackvox. Points directly at the bundled binary path; no
    // dependency on the venv symlink (which exists for notify.sh's
    // benefit, not the daemon's).
    private static func writeDaemonPlistIfVenvPresent() throws {
        guard let venvURL = bundledVenvURL() else { return }
        let stackvox = venvURL.appendingPathComponent("bin/stackvox").path
        let logPath = "\(installDir)/daemon.log"
        try writePlist(label: daemonLabel,
                       programArgs: [stackvox, "serve"],
                       logPath: logPath)
    }

    // Common plist serialiser: emits the same XML shape install.sh's
    // register_launchd_agent function produces, via PropertyListSerialization.
    private static func writePlist(label: String,
                                   programArgs: [String],
                                   logPath: String) throws {
        let plist: [String: Any] = [
            "Label":             label,
            "ProgramArguments":  programArgs,
            "RunAtLoad":         true,
            "KeepAlive":         true,
            "StandardOutPath":   logPath,
            "StandardErrorPath": logPath,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let path = "\(launchAgentsDir)/\(label).plist"
        try FileManager.default.createDirectory(
            atPath: launchAgentsDir,
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            throw BootstrapError.writeFailed(path, underlying: error)
        }
    }

    // MARK: - Launchctl

    private static func loadLaunchdAgent(label: String) throws {
        let plist = "\(launchAgentsDir)/\(label).plist"
        // Unload first (no-op if not loaded) to handle the re-install case
        // where a previous .plist still has an agent active.
        _ = try? runLaunchctl(["unload", plist])
        let result = try runLaunchctl(["load", plist])
        if result.exitCode != 0 {
            throw BootstrapError.launchctlFailed(
                label: label,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    private struct LaunchctlResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func runLaunchctl(_ args: [String]) throws -> LaunchctlResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()  // discard stdout
        try task.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return LaunchctlResult(
            exitCode: task.terminationStatus,
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Errors

enum BootstrapError: LocalizedError {
    case copyFailed(String, underlying: Error)
    case writeFailed(String, underlying: Error)
    case launchctlFailed(label: String, exitCode: Int32, stderr: String)
    case bundleResourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let what, let err):
            return "Failed to copy \(what): \(err.localizedDescription)"
        case .writeFailed(let what, let err):
            return "Failed to write \(what): \(err.localizedDescription)"
        case .launchctlFailed(let label, let code, let stderr):
            let msg = stderr.isEmpty ? "exit \(code)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl failed for \(label): \(msg)"
        case .bundleResourceMissing(let name):
            return "Bundled resource missing: \(name) (rebuild may be incomplete)"
        }
    }
}
