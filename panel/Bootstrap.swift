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
    case codex
    case gemini
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex:  return "Codex"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity CLI"
        }
    }

    // Filesystem marker that signals the agent is installed locally.
    // Mirrors the directory checks install.sh does.
    var detectionDirectory: String {
        switch self {
        case .claude: return "\(NSHomeDirectory())/.claude"
        case .cursor: return "\(NSHomeDirectory())/.cursor"
        case .codex:  return "\(NSHomeDirectory())/.codex"
        case .gemini: return "\(NSHomeDirectory())/.gemini"
        case .antigravity: return "\(NSHomeDirectory())/.gemini/antigravity-cli"
        }
    }

    // Hook config file we write to when installing for this agent. Each
    // agent has its own JSON shape; Bootstrap.install handles the splicing.
    var hookConfigPath: String {
        switch self {
        case .claude: return "\(NSHomeDirectory())/.claude/settings.json"
        case .cursor: return "\(NSHomeDirectory())/.cursor/hooks.json"
        // Codex's hooks file shares Claude Code's matcher-group JSON
        // shape and event names (Stop + PermissionRequest). See
        // https://developers.openai.com/codex/hooks.
        case .codex:  return "\(NSHomeDirectory())/.codex/hooks.json"
        // Gemini CLI uses ~/.gemini/settings.json (same path as Claude's
        // settings.json analog), but its events are renamed: AfterAgent
        // (turn end) and Notification (tool-permission alerts). See
        // https://geminicli.com/docs/hooks/.
        case .gemini: return "\(NSHomeDirectory())/.gemini/settings.json"
        // Antigravity CLI uses ~/.gemini/antigravity-cli/settings.json (same
        // structure as Gemini).
        case .antigravity: return "\(NSHomeDirectory())/.gemini/antigravity-cli/settings.json"
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
        // notify.sh is the authoritative marker — Bootstrap.install copies
        // it as one of its first steps, and uninstall removes the whole
        // dotdir. A standalone launchd plist is no longer sufficient
        // (the bundle-rename migration used to write one before install
        // had run, which falsely signalled "installed" on a fresh wizard).
        FileManager.default.fileExists(atPath: notifyPath)
    }

    // Path-level rename migration (pre-1.7 → 1.7+). The .app bundle is
    // now `StackNudge.app` so Finder/Spotlight show the brand name; the
    // CFBundle identifiers and the `~/.stack-nudge/` dotdir are untouched
    // so existing TCC grants and user data carry over. Idempotent.
    //
    // Called from PanelController.applicationDidFinishLaunching when we
    // detect we're running from the new path. Three things to fix up:
    //   1. The old `stack-nudge.app` bundle next to us in ~/Applications/
    //      (recycle it — keeps Finder tidy).
    //   2. The launchd plist's `ProgramArguments[0]` still points at the
    //      old binary path. Rewrite + reload.
    //   3. The agent hook entries reference the old `…/notify.sh` —
    //      already covered by the existing stale-entry regex, which
    //      matches both `tinynudge/` and `stack-nudge/`. Nothing to do.
    static func migrateBundleNameIfNeeded() {
        let fm = FileManager.default
        let runningFromNewPath = Bundle.main.bundleURL.lastPathComponent == "StackNudge.app"
        guard runningFromNewPath else { return }

        let legacy = "\(NSHomeDirectory())/Applications/stack-nudge.app"
        if fm.fileExists(atPath: legacy) {
            NSWorkspace.shared.recycle([URL(fileURLWithPath: legacy)]) { _, _ in }
        }

        // Retarget existing launchd plists whose ProgramArguments still
        // reference the pre-1.7 path. We intentionally do NOT create
        // plists from scratch here — a missing plist means this is a
        // fresh install (no migration needed) and Bootstrap.install will
        // write them when the user finishes the wizard.
        retargetLaunchAgentIfNeeded(label: appLabel)
        retargetLaunchAgentIfNeeded(label: daemonLabel)
    }

    // Read the on-disk launchd plist for `label`; if its first program-
    // argument still references the pre-1.7 path, rewrite that argument
    // to the equivalent path inside the currently-running bundle and
    // reload the agent. No-op when the plist isn't present.
    private static func retargetLaunchAgentIfNeeded(label: String) {
        let fm = FileManager.default
        let plistPath = "\(launchAgentsDir)/\(label).plist"
        guard fm.fileExists(atPath: plistPath) else { return }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              var args = plist["ProgramArguments"] as? [String],
              let first = args.first,
              first.contains("/stack-nudge.app/")
        else { return }

        let newFirst = first.replacingOccurrences(of: "/stack-nudge.app/", with: "/StackNudge.app/")
        args[0] = newFirst
        plist["ProgramArguments"] = args
        guard let updated = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? updated.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])
        _ = try? runLaunchctl(["unload", plistPath])
        _ = try? runLaunchctl(["load", plistPath])
    }

    // Agents present on this Mac. The bootstrap wizard checks all of these
    // by default; the user can untick to skip wiring any of them.
    static func availableAgents() -> [BootstrapAgent] {
        BootstrapAgent.allCases.filter {
            FileManager.default.fileExists(atPath: $0.detectionDirectory)
        }
    }

    // MARK: Reconciliation

    // Agents detected on disk whose hook config has no entry pointing at
    // our notify.sh. Powers the Settings-tab "agent detected without hooks"
    // banner: covers three scenarios in one mechanism —
    //   1. User installs a NEW agent on their Mac after first-run wizard.
    //   2. New StackNudge release adds support for an agent the user already
    //      has installed (eg v1.8 lands Codex support; v1.7 user updates).
    //   3. User manually deleted our hook entry then forgot.
    //
    // Cheap: one JSON parse per detected agent, all on the main thread.
    // Called from app launch + every Settings tab open.
    static func unwiredAgents() -> [BootstrapAgent] {
        availableAgents().filter { !isAgentWired($0) }
    }

    // Looks at the agent's on-disk config for any hook command matching
    // our notify.sh path. The same staleHookRegex used for uninstall does
    // the right thing here — it matches both `tinynudge/notify.sh` and
    // `stack-nudge/notify.sh`, which is what we want for "is *anything*
    // of ours wired?"
    static func isAgentWired(_ agent: BootstrapAgent) -> Bool {
        let path = agent.hookConfigPath
        guard let root = try? readJSONObject(at: path),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            if let groups = value as? [[String: Any]] {
                // Matcher-group shape (Claude / Codex / Gemini).
                if groups.contains(where: { group in
                    let inner = group["hooks"] as? [[String: Any]] ?? []
                    return inner.contains { isStaleHook(command: ($0["command"] as? String) ?? "") }
                }) { return true }
                // Cursor's flat shape (entries directly under the event).
                if groups.contains(where: { isStaleHook(command: ($0["command"] as? String) ?? "") }) {
                    return true
                }
            }
        }
        return false
    }

    // Wire a single agent — used by the reconciliation row's "Set up"
    // action. Same per-agent dispatch as install(agents:) does in its
    // loop, just exposed for one-at-a-time wiring without re-running
    // the full bootstrap. Idempotent: calling on an already-wired agent
    // adds another entry (existing entries are detected by the next
    // unwiredAgents() refresh).
    static func wireSingleAgent(_ agent: BootstrapAgent) throws {
        try wireHooks(for: agent)
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

        progress("Moving StackNudge.app to Trash…")
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
            // Stop (30s) + PermissionRequest (600s); Claude's
            // matcher-group JSON shape.
            try wireClaudeShapedHooks(at: path, agentArg: "claude-code",
                                      events: [("Stop",              "stop",       30),
                                               ("PermissionRequest", "permission", 600)])
        case .cursor:
            try wireCursorHooks(at: path)
        case .codex:
            // Codex's hooks file is structurally identical to Claude's
            // (matcher-groups), with the same event names. Only the
            // file path and the agent-arg differ.
            try wireClaudeShapedHooks(at: path, agentArg: "codex",
                                      events: [("Stop",              "stop",       30),
                                               ("PermissionRequest", "permission", 600)])
        case .gemini:
            // Gemini renames Claude's `Stop` to `AfterAgent` and routes
            // tool-permission prompts through `Notification` (with
            // `notification_type=ToolPermission` on stdin). Same
            // matcher-group JSON shape otherwise.
            //
            // CRITICAL DIFFERENCE FROM CLAUDE/CODEX: Gemini's `timeout`
            // is measured in **milliseconds**, not seconds. Sending 30
            // would kill the hook after 30 ms — before the shell even
            // forks. Multiply by 1000 to match the writer's
            // milliseconds-only convention for Gemini.
            //
            // Note: Notification is observability-only — our hook can
            // surface the banner but can't return an allow/deny
            // decision the way Claude's PermissionRequest can.
            try wireClaudeShapedHooks(at: path, agentArg: "gemini",
                                      events: [("AfterAgent",   "stop",       30_000),
                                               ("Notification", "permission", 30_000)])
        case .antigravity:
            // Antigravity CLI uses the same hook events and millisecond timeout conventions as Gemini.
            try wireClaudeShapedHooks(at: path, agentArg: "antigravity",
                                      events: [("AfterAgent",   "stop",       30_000),
                                               ("Notification", "permission", 30_000)])
        }
    }

    // Generic writer for the matcher-group JSON shape that Claude,
    // Codex, and Gemini all use. Differs from agent to agent only in
    // file path, agent-arg passed to notify.sh, and the set of event
    // names. Cursor uses a flat-array shape and has its own writer.
    private static func wireClaudeShapedHooks(
        at path: String,
        agentArg: String,
        events: [(event: String, arg: String, timeout: Int)]
    ) throws {
        var root = try readJSONObject(at: path)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for (event, arg, timeout) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = pruneStaleHookGroups(groups)
            let ourHook: [String: Any] = [
                "type":    "command",
                "command": "\(notifyPath) \(agentArg) \(arg)",
                "timeout": timeout,
            ]
            // Swift's [String: Any] doesn't preserve key order; the
            // resulting JSON is still valid. All three agents parse
            // by key.
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

        // Matcher-group shape — shared by Claude (Stop/PermissionRequest),
        // Codex (same names), and Gemini (AfterAgent/Notification).
        // Iterating all four event names is harmless: events not present
        // are simply skipped.
        for event in ["Stop", "PermissionRequest", "AfterAgent", "Notification"] {
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
        // Invoke via python3 with stackvox as a script argument. pip
        // stamps an absolute build-time shebang into the stackvox script
        // — CI-built bundles end up with /Users/runner/... which doesn't
        // exist on user machines, so running the script directly fails
        // with "bad interpreter". python3 is a real Mach-O binary that's
        // relocatable; calling it directly bypasses the shebang entirely.
        let python = venvURL.appendingPathComponent("bin/python3").path
        let stackvox = venvURL.appendingPathComponent("bin/stackvox").path
        let logPath = "\(installDir)/daemon.log"
        try writePlist(label: daemonLabel,
                       programArgs: [python, stackvox, "serve"],
                       logPath: logPath,
                       env: stackvoxEnv(venvURL: venvURL))
    }

    // libespeak-ng.dylib inside the bundled espeakng_loader wheel was
    // compiled on the CI runner with its phoneme-data dir baked in
    // (/Users/runner/work/...) — that path doesn't exist on user
    // machines, so phonemization fails before any audio is generated.
    // ESPEAK_DATA_PATH overrides the compile-time path at runtime; point
    // it at the espeak-ng-data dir that ships inside the wheel.
    static func stackvoxEnv(venvURL: URL) -> [String: String] {
        let dataDir = venvURL
            .appendingPathComponent("lib/python3.12/site-packages/espeakng_loader/espeak-ng-data")
            .path
        return ["ESPEAK_DATA_PATH": dataDir]
    }

    // Common plist serialiser: emits the same XML shape install.sh's
    // register_launchd_agent function produces, via PropertyListSerialization.
    private static func writePlist(label: String,
                                   programArgs: [String],
                                   logPath: String,
                                   env: [String: String] = [:]) throws {
        var plist: [String: Any] = [
            "Label":             label,
            "ProgramArguments":  programArgs,
            "RunAtLoad":         true,
            "KeepAlive":         true,
            "StandardOutPath":   logPath,
            "StandardErrorPath": logPath,
        ]
        if !env.isEmpty {
            plist["EnvironmentVariables"] = env
        }
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

    // Toggle the panel LaunchAgent's "launch at login" behavior.
    // Enable: ensure the plist is on disk and loaded into launchd (RunAtLoad
    // makes the next login start the panel automatically). Disable: unload
    // and delete the plist — without it, launchd has no record of the agent
    // and skips it at login. The currently-running panel process is left
    // alone in both cases; this only affects the next login.
    //
    // The daemon plist (com.stackonehq.stack-nudge-daemon) is intentionally
    // untouched — voice playback is an independent concern and its loaded
    // state shouldn't change when the user toggles the panel's auto-launch.
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        let plistPath = "\(launchAgentsDir)/\(appLabel).plist"
        if enabled {
            if !FileManager.default.fileExists(atPath: plistPath) {
                try writePanelPlist()
            }
            try loadLaunchdAgent(label: appLabel)
        } else {
            _ = try? runLaunchctl(["unload", plistPath])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }

    // Whether the panel LaunchAgent plist currently exists on disk —
    // the source of truth for the "Launch at login" toggle. Loaded state
    // (launchctl list) drifts: launchd will report the agent as loaded
    // for the rest of the session even after the plist is deleted.
    static func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: "\(launchAgentsDir)/\(appLabel).plist")
    }

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

// MARK: - Bootstrap UI state

// Phase of the bootstrap install. Drives BootstrapView's rendering.
enum BootstrapPhase: Equatable {
    case idle                 // pre-install: wizard with agent checklist
    case installing           // running Bootstrap.install
    case done                 // install complete; ready to dismiss
    case failed(String)       // install failed with this error message
}

// Phase of the uninstall flow. Drives UninstallView's rendering.
enum UninstallPhase: Equatable {
    case confirm              // confirmation alert with Cancel/Uninstall
    case uninstalling         // running Bootstrap.uninstall
    case failed(String)       // failed mid-uninstall (rare; partial-state allowed)
}

// MARK: - Bootstrap view (first-launch wizard)

// Single-screen first-launch experience. Shown automatically when the app
// detects no prior install (Bootstrap.isInstalled() == false). Walks the
// user through three phases:
//
//   .idle       — pick which detected agents to wire up + Install button
//   .installing — progress streamed from Bootstrap.install's callbacks
//   .done       — onboarding content (hotkey hint, tabs summary, Grant
//                 Permissions button) + Continue to drop into the events tab
//
// Folds in what used to be a separate Welcome.swift screen — the two were
// effectively two consecutive "Welcome to stack-nudge" screens, which felt
// redundant. Now first-launch is one cohesive flow.
struct BootstrapView: View {

    @ObservedObject var nav: PanelNav
    let hotkeyDisplay: String
    let onInstall: () -> Void
    let onGrantPermissions: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    phaseBody
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background(ThinScrollers())
            }
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerIcon)
                .font(.title3)
                .foregroundStyle(headerIconColor)
            Text(headerTitle)
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    private var headerIcon: String {
        switch nav.bootstrapPhase {
        case .done:   return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default:      return "bell.badge.fill"
        }
    }

    private var headerIconColor: Color {
        switch nav.bootstrapPhase {
        case .done:   return .green
        case .failed: return .red
        default:      return .accentColor
        }
    }

    private var headerTitle: String {
        switch nav.bootstrapPhase {
        case .idle:       return "Welcome to StackNudge"
        case .installing: return "Setting up…"
        case .done:       return "You're all set"
        case .failed:     return "Setup failed"
        }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch nav.bootstrapPhase {
        case .idle:
            tagline
            agentList
        case .installing, .failed:
            progress
        case .done:
            completedBlurb
            hotkeyHint
            tabsSummary
            permissionsHint
        }
    }

    private var tagline: some View {
        Text("Notifications for AI coding agents. We'll wire StackNudge into each agent you've selected below, set up background services, and you'll be ready to go in a few seconds.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Post-install onboarding content (was Welcome.swift)

    private var completedBlurb: some View {
        Text("StackNudge runs from your menu bar. Here's how to use it:")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hotkeyHint: some View {
        HStack(spacing: 8) {
            Text("Press")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(hotkeyDisplay.keyCapTokens, id: \.self) { token in
                    KeyCapView(symbol: token)
                }
            }
            Text("anytime to open this panel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var tabsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Four tabs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)

            tabRow(systemImage: "bell.fill",
                   title: "Events",
                   detail: "Recent nudges; approve and focus with the keyboard")
            tabRow(systemImage: "list.bullet.rectangle",
                   title: "Sessions",
                   detail: "Running agents you can focus, rename, or terminate")
            tabRow(systemImage: "chart.bar.fill",
                   title: "Usage",
                   detail: "Claude Code quota — session, weekly, per-model")
            tabRow(systemImage: "gearshape.fill",
                   title: "Settings",
                   detail: "Hotkey, sounds, voice, and more")
        }
    }

    private var permissionsHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.callout)
                .foregroundStyle(Color.orange.opacity(0.8))
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            Text("Notifications and Accessibility permissions are needed for banners and 'Allow' approvals. You can grant them now or later from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tabRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var agentList: some View {
        if nav.bootstrapAvailableAgents.isEmpty {
            Text("No supported agents detected (~/.claude, ~/.cursor, ~/.codex, ~/.gemini, ~/.gemini/antigravity-cli). Install one and restart StackNudge to wire it up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Detected agents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.bottom, 2)
                ForEach(nav.bootstrapAvailableAgents) { agent in
                    agentRow(agent)
                }
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: BootstrapAgent) -> some View {
        let isSelected = nav.bootstrapSelectedAgents.contains(agent)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.callout)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.subheadline.weight(.medium))
                Text("Hooks will be added to \((agent.hookConfigPath as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                nav.bootstrapSelectedAgents.remove(agent)
            } else {
                nav.bootstrapSelectedAgents.insert(agent)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if case .installing = nav.bootstrapPhase {
                    ProgressView().controlSize(.small)
                    Text("Installing StackNudge…").font(.subheadline)
                } else if case .done = nav.bootstrapPhase {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("Install complete").font(.subheadline.weight(.medium))
                } else if case .failed = nav.bootstrapPhase {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                    Text("Install failed").font(.subheadline.weight(.medium))
                }
            }
            // Tail of the progress log — last few lines, monospaced.
            // No full scrollback; this is a transient view.
            Text(nav.bootstrapLog.isEmpty ? "Starting…" : nav.bootstrapLog)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            if case .failed(let msg) = nav.bootstrapPhase {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            // Left-side button: Quit when idle/failed, Grant Permissions when done.
            if nav.bootstrapPhase == .idle || isFailed {
                secondaryButton(label: "Quit", action: onQuit)
            } else if case .done = nav.bootstrapPhase {
                secondaryButton(label: "Grant permissions", action: onGrantPermissions)
            }

            Spacer()

            // Right-side primary: Set up when idle, Continue when done.
            if nav.bootstrapPhase == .idle {
                // Always enabled — even with no agents selected, the install
                // copies bundled resources + registers launchd agents, which
                // is still useful. The user can wire hooks manually later.
                primaryButton(label: "Set up", action: onInstall)
            } else if case .done = nav.bootstrapPhase {
                primaryButton(label: "Continue") { nav.mode = .events }
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

    private func secondaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func primaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.weight(.medium))
                KeyCapView(symbol: "⏎")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.25))
        )
    }

    private var isFailed: Bool {
        if case .failed = nav.bootstrapPhase { return true }
        return false
    }
}

// Split a hotkey spec like "cmd+opt+n" into the key cap tokens BootstrapView
// renders. Modifier names map to the macOS glyphs the rest of the panel
// uses; everything else is uppercased verbatim.
private extension String {
    var keyCapTokens: [String] {
        split(separator: "+").map { part in
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            switch p {
            case "cmd", "command":         return "⌘"
            case "shift":                  return "⇧"
            case "opt", "alt", "option":   return "⌥"
            case "ctrl", "control":        return "⌃"
            default:                       return p.uppercased()
            }
        }
    }
}

// MARK: - Uninstall view

// Two-step uninstall: confirmation alert → progress → app quits.
// Mirrors UpdatingView's spinner+progress pattern for the running phase.
struct UninstallView: View {

    @ObservedObject var nav: PanelNav
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if nav.uninstallPhase == .confirm {
                        confirmCopy
                    } else {
                        progress
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(ThinScrollers())
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "trash.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.uninstallPhase == .confirm
                     ? "Remove StackNudge?"
                     : "Uninstalling…")
                    .font(.headline)
                if nav.uninstallPhase == .confirm {
                    Text("This action is permanent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var confirmCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The following will be removed from your Mac:")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                bullet("Hook entries in your Claude Code / Cursor configs")
                bullet("Background launchd agents (panel + voice daemon)")
                bullet("~/.stack-nudge/ (config, phrases, notify.sh)")
                bullet("StackNudge.app (moved to Trash)")
            }
            Text("Settings, the macOS keychain entry for Claude Code, and the cached Kokoro voice model in ~/.cache/huggingface/ are not touched.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Tearing down…").font(.subheadline)
        }
        Text(nav.uninstallLog.isEmpty ? "Starting…" : nav.uninstallLog)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        if case .failed(let msg) = nav.uninstallPhase {
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        PageFooter {
            if nav.uninstallPhase == .confirm {
                FooterHint(label: "Uninstall", keys: ["⏎"], primary: true)
                FooterDivider()
                FooterHint(label: "Cancel", keys: ["esc"])
            } else {
                FooterHint(label: "Don't quit StackNudge during uninstall", keys: [])
            }
        }
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
