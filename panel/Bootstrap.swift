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
    static let userQuitMarker   = "\(NSHomeDirectory())/.stack-nudge/user-quit"
    // Which manifest events have been reconciled into each agent, so a hook the
    // user deleted by hand isn't put back on the next launch.
    static let hooksAppliedPath = "\(NSHomeDirectory())/.stack-nudge/hooks-applied.json"

    static let launchAgentsDir  = "\(NSHomeDirectory())/Library/LaunchAgents"
    static let appLabel         = "com.stackonehq.stack-nudge"
    static let daemonLabel      = "com.stackonehq.stack-nudge-daemon"

    // Pattern matching any tinynudge/stack-nudge notify.sh reference in a
    // hook command, including quoted paths. Same regex as uninstall.sh
    // (loosened in #39 to handle quoted forms).
    static let staleHookRegex = try? NSRegularExpression(
        pattern: #"(?:^|/|")\.?(?:tinynudge|stack-nudge)/notify\.sh"#
    )

    // MARK: Managed-script freshness

    // notify.sh carries `# stack-nudge-version: <x.y.z>`, bumped by
    // release-please alongside panel/Info.plist.
    static let notifyVersionPattern = #"^#\s*stack-nudge-version:\s*([0-9]+\.[0-9]+\.[0-9]+)"#

    // Read the stamp out of a script's text. Pure so the matrix of shapes
    // (stamped, unstamped, malformed) is testable without touching disk.
    // Scans only the header: the stamp is a top-of-file comment, and a later
    // line mentioning the key in prose must not win.
    static func notifyVersion(inScript script: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: notifyVersionPattern,
                                                  options: [.anchorsMatchLines])
        else { return nil }
        let header = script.split(separator: "\n", maxSplits: 40,
                                  omittingEmptySubsequences: false)
            .prefix(40).joined(separator: "\n")
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = regex.firstMatch(in: header, range: range),
              let captured = Range(match.range(at: 1), in: header)
        else { return nil }
        return String(header[captured])
    }

    // Stamp of the hook script the agents actually invoke, nil when it's missing
    // or predates stamping.
    static func installedNotifyVersion() -> String? {
        guard let script = try? String(contentsOfFile: notifyPath, encoding: .utf8)
        else { return nil }
        return notifyVersion(inScript: script)
    }

    // The hook script this bundle ships, nil on a build that didn't bundle it.
    static func bundledNotifyScript() -> String? {
        guard let url = Bundle.main.url(forResource: "notify.sh", withExtension: nil)
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // Stamp of the script this bundle ships, nil on an unstamped local build.
    static func bundledNotifyVersion() -> String? {
        bundledNotifyScript().flatMap { notifyVersion(inScript: $0) }
    }

    // Whether the installed script should be replaced by the bundled one.
    //
    // Compares the two scripts' own stamps rather than the installed stamp
    // against CFBundleShortVersionString: same source of truth on both sides, so
    // a dev build whose Info.plist and script disagree can't trigger a pointless
    // rewrite. nil `installed` means a copy from before stamping existed (every
    // install that predates v1.26.x), which is exactly the drift to repair. nil
    // `bundled` means we can't tell (an unstamped local build), so leave the
    // user's file alone.
    static func needsNotifyRefresh(installed: String?, bundled: String?) -> Bool {
        guard let bundled else { return false }
        return installed != bundled
    }

    // Replace ~/.stack-nudge/notify.sh when the bundle ships a different version.
    //
    // Exists because the hook script is half of the wire protocol with the panel
    // (it builds the socket payload) but is not part of the .app that updates
    // swap, so a self-updating install pins whatever version first installed it.
    // A stale script silently omits newer payload fields: a pre-1.12 copy sends
    // no claude_session_id, which drops every handoff record and leaves the
    // Tickets tab permanently empty.
    //
    // Returns the version it wrote, or nil when nothing needed doing. Cheap
    // enough for every launch: one small read, and a write only on drift.
    @discardableResult
    static func refreshNotifyScriptIfNeeded() -> String? {
        refreshNotifyScript(bundled: bundledNotifyScript(), installedPath: notifyPath)
    }

    // The decision plus the write, with both sides injected so the whole path is
    // testable (Bundle.main in a test process ships no Resources/notify.sh).
    // Skips a machine with no installed script at all: that's a pre-install or
    // mid-uninstall state, and planting one there would wire nothing up anyway.
    @discardableResult
    static func refreshNotifyScript(bundled bundledScript: String?,
                                    installedPath: String) -> String? {
        guard let bundledScript,
              notifyScriptOutdated(bundled: bundledScript, installedPath: installedPath)
        else { return nil }
        let installed = (try? String(contentsOfFile: installedPath, encoding: .utf8))
            .flatMap { notifyVersion(inScript: $0) }
        let bundled = notifyVersion(inScript: bundledScript)
        do {
            try writeNotifyScript(bundledScript, to: installedPath)
            log("refreshed notify.sh: \(installed ?? "unstamped") -> \(bundled ?? "unstamped")")
            return bundled
        } catch {
            log("failed to refresh notify.sh: \(error.localizedDescription)")
            return nil
        }
    }

    // Whether the refresh above would actually rewrite the installed script.
    // Two gates: the stamp must differ (a matching stamp means "same protocol,
    // leave local tweaks alone"), AND the logic must have genuinely changed. The
    // second gate is why a stamp-only release (release-please bumps the stamp on
    // every version) does NOT rewrite: rewriting would reset Codex's hook-trust
    // hash, silently disabling codex capture until the user re-trusts via /hooks.
    // Shared with the Settings "hook script stale" footer so the two agree.
    static func notifyScriptOutdated(bundled bundledScript: String?,
                                     installedPath: String) -> Bool {
        guard let bundledScript,
              let installedScript = try? String(contentsOfFile: installedPath, encoding: .utf8)
        else { return false }
        guard needsNotifyRefresh(installed: notifyVersion(inScript: installedScript),
                                 bundled: notifyVersion(inScript: bundledScript))
        else { return false }
        return functionalContent(bundledScript) != functionalContent(installedScript)
    }

    // notify.sh with the release-please version-stamp line neutralised and
    // trailing newlines trimmed, so two copies that differ only by their version
    // (or a stray trailing newline) compare equal.
    static func functionalContent(_ script: String) -> String {
        script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.contains("stack-nudge-version:") ? "" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // Write the hook script and make it executable, swapping it in atomically:
    // agents are live while the app runs, and a hook firing during a
    // remove-then-copy would find no script at all. Written to a sibling temp
    // path so the replace is a same-volume rename.
    // `to:` is injectable for tests only; every caller writes the real path.
    static func writeNotifyScript(_ script: String, to path: String = notifyPath) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: path)
        let temp = dest.deletingLastPathComponent()
            .appendingPathComponent(".notify.sh.\(UUID().uuidString)")
        do {
            try script.write(to: temp, atomically: false, encoding: .utf8)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: dest)
            }
            // After the swap, not before: replaceItemAt deliberately carries the
            // *original* file's attributes over to the replacement, so a mode set
            // on the temp file is discarded. A copy that arrived non-executable
            // (0644 from a hand-edit or an odd umask) would otherwise stay that
            // way and every hook would fail with "permission denied".
            _ = chmod(dest.path, 0o755)
        } catch {
            try? fm.removeItem(at: temp)
            throw BootstrapError.writeFailed(path, underlying: error)
        }
    }

    // Diagnostics go to stderr, which launchd redirects to
    // ~/.stack-nudge/app.log (see writePanelPlist).
    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("stack-nudge: \(message)\n".utf8))
    }

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
    // The Updater leaves `~/Applications/StackNudge.app.old` behind after a
    // successful swap as a rollback safety net. By the time we're running,
    // launchd has already brought up the new bundle and the user is
    // interacting with it — the .old is now just dead weight that Spotlight
    // indexes, producing a confusing duplicate hit. Trash it so future
    // searches only find the live app.
    //
    // Idempotent: no-op when the .old doesn't exist (steady state for users
    // who installed fresh or who already had it cleaned up).
    static func cleanupPostUpdateBackup() {
        let backup = URL(fileURLWithPath: Updater.installedAppPath + ".old")
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        // Recycle (not rm -rf) so the user can restore from Trash if they
        // somehow notice a regression we don't.
        NSWorkspace.shared.recycle([backup]) { _, _ in }
    }

    // User-initiated Quit: drop a marker file so notify.sh's ensure_app_running
    // gate doesn't relaunch us on the next hook event. Cleared by
    // clearUserQuitMarker() on the next manual app launch.
    static func userQuit() {
        _ = try? "".write(toFile: userQuitMarker, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static func clearUserQuitMarker() {
        try? FileManager.default.removeItem(atPath: userQuitMarker)
    }

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
        migrateKeepAliveIfNeeded(label: appLabel)
    }

    // Older installs wrote KeepAlive: true, so launchd respawned the panel
    // even after an explicit user Quit. Rewrite to the dict form that
    // restarts on crash only.
    private static func migrateKeepAliveIfNeeded(label: String) {
        guard crashOnlyKeepAliveOnDisk(label: label, agentsDir: launchAgentsDir) else { return }
        let plistPath = "\(launchAgentsDir)/\(label).plist"
        _ = try? runLaunchctl(["unload", plistPath])
        _ = try? runLaunchctl(["load",   plistPath])
    }

    // The disk half of migrateKeepAliveIfNeeded, split out so the updater can
    // apply it without the reload. Returns whether it changed anything.
    //
    // Panel agent only — the daemon's `KeepAlive: true` is deliberate.
    @discardableResult
    static func crashOnlyKeepAliveOnDisk(label: String,
                                         agentsDir: String) -> Bool {
        let plistPath = "\(agentsDir)/\(label).plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              (plist["KeepAlive"] as? Bool) == true
        else { return false }
        plist["KeepAlive"] = ["SuccessfulExit": false]
        guard let updated = try? PropertyListSerialization.data(
                  fromPropertyList: plist, format: .xml, options: 0),
              (try? updated.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])) != nil
        else { return false }
        return true
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

    // MARK: - Retarget on update

    // The launch agents record absolute paths into whichever bundle ran the
    // setup wizard (writePanelPlist uses Bundle.main), and nothing on the
    // update path used to correct them. Two ways that goes wrong:
    //
    //   - A pre-1.7 user. The v1.6 updater installed into `stack-nudge.app`
    //     whatever .app it extracted, so modern code has been running from
    //     the old-named folder ever since, and migrateBundleNameIfNeeded
    //     (gated on running from `StackNudge.app`) never fires for them.
    //   - The wizard run from a copy that later moves or is deleted, e.g. an
    //     extracted tarball in ~/Downloads.
    //
    // Either way the plist points somewhere the update never touches. At
    // best launchd keeps starting the old version at login; at worst the
    // program is gone and `kickstart` never returns, which is #205.
    //
    // The rule: a path inside some `.app` bundle that is NOT `installed` is
    // re-pointed at the same location inside `installed` — but only if that
    // file exists there. A path into a bundle that no longer contains it is
    // left alone rather than swapped for a second missing path. Pure, so the
    // rule is testable without a plist or a filesystem.
    //
    // `isSuperseded` decides whether the bundle a path currently points into
    // is one the update should move it AWAY from. Without it, a developer
    // whose plist deliberately points at `build/StackNudge.app` would be
    // silently re-pointed at the release on their next in-app update. See
    // bundleIsSuperseded for the production rule.
    static func retargetedBundlePath(_ path: String,
                                     toBundle installed: String,
                                     exists: (String) -> Bool,
                                     isSuperseded: (String) -> Bool) -> String? {
        // The OUTERMOST bundle: a path into a helper nested inside the app
        // belongs to the app.
        guard let marker = path.range(of: ".app/") else { return nil }
        let root = (String(path[..<marker.lowerBound]) + ".app" as NSString).standardizingPath
        let target = (installed as NSString).standardizingPath
        guard root != target, !sameDirectory(root, target) else { return nil }
        // Only OUR bundles, under any name they have shipped or been saved
        // as: `StackNudge.app`, the pre-1.7 `stack-nudge.app`, and Finder's
        // duplicate-download `StackNudge 2.app`. Existence alone isn't a
        // guard here, because directories pass it: another app's
        // `Contents/Resources` exists inside ours too, so without this a
        // path into a foreign app would be re-pointed into stack-nudge.
        let name = (root as NSString).lastPathComponent.lowercased()
        guard name.hasPrefix("stacknudge") || name.hasPrefix("stack-nudge") else { return nil }
        guard isSuperseded(root) else { return nil }
        let candidate = target + "/" + String(path[marker.upperBound...])
        return exists(candidate) ? candidate : nil
    }

    // Whether two paths name the same directory on disk, by device and inode.
    // standardizingPath compares spelling, not identity: it doesn't resolve
    // a symlinked parent, and APFS is case-insensitive by default, so the
    // installed bundle reached by another spelling would otherwise look like
    // a different bundle and trigger a spurious retarget — skipping the app
    // kickstart and retiring a perfectly good job. False when either path is
    // missing, which is the case retargeting exists for.
    static func sameDirectory(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    // Applies retargetedBundlePath to a plist's ProgramArguments and its
    // EnvironmentVariables — the daemon's ESPEAK_DATA_PATH points into the
    // bundle too, and a corrected binary reading a stale data dir is the
    // same bug one level down. Nil when nothing would change.
    static func retargetedLaunchSpec(arguments: [String],
                                     environment: [String: String],
                                     toBundle installed: String,
                                     exists: (String) -> Bool,
                                     isSuperseded: (String) -> Bool)
        -> (arguments: [String], environment: [String: String])? {
        var changed = false
        let arguments = arguments.map { argument -> String in
            guard let moved = retargetedBundlePath(argument, toBundle: installed, exists: exists,
                                                   isSuperseded: isSuperseded)
            else { return argument }
            changed = true
            return moved
        }
        var environment = environment
        for (key, value) in environment {
            if let moved = retargetedBundlePath(value, toBundle: installed, exists: exists,
                                                isSuperseded: isSuperseded) {
                environment[key] = moved
                changed = true
            }
        }
        return changed ? (arguments, environment) : nil
    }

    // Rewrite one agent's plist on disk to point into `installed`. Returns
    // whether it changed anything.
    //
    // Disk only — deliberately no reload. The caller is the updater, which
    // may itself be the process this agent launched, and how to treat the
    // stale loaded copy is the caller's decision (see
    // Updater.restartSequence for why it retires the job rather than
    // reloading it). The file is what launchd reads at next login.
    @discardableResult
    static func retargetLaunchAgentOnDisk(label: String,
                                          toBundle installed: String,
                                          agentsDir: String) -> Bool {
        let plistPath = "\(agentsDir)/\(label).plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              var plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return false }
        let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]

        guard let spec = retargetedLaunchSpec(
            arguments: arguments, environment: environment, toBundle: installed,
            exists: { FileManager.default.fileExists(atPath: $0) },
            isSuperseded: { bundleIsSuperseded($0, by: installed) })
        else { return false }

        plist["ProgramArguments"] = spec.arguments
        if !spec.environment.isEmpty {
            plist["EnvironmentVariables"] = spec.environment
        }
        guard let updated = try? PropertyListSerialization.data(
                  fromPropertyList: plist, format: .xml, options: 0),
              (try? updated.write(to: URL(fileURLWithPath: plistPath), options: [.atomic])) != nil
        else { return false }
        return true
    }

    // Whether an update should move a launch agent away from `root`:
    //
    //   - it no longer exists (the ~/Downloads copy that was deleted),
    //   - it is the pre-1.7 `stack-nudge.app`, or
    //   - its version is older than the bundle just installed (a stale
    //     ~/Downloads or /Applications copy).
    //
    // A current developer build is none of these. It carries the
    // release-please version, so it is never older than the release that
    // was just installed unless the checkout is behind, and then it IS
    // stale. A bundle whose version can't be read counts as superseded: it
    // can't be confirmed current, and a damaged bundle is a worse thing to
    // keep pointing at than the one that was just installed.
    static func bundleIsSuperseded(_ root: String, by installed: String) -> Bool {
        guard FileManager.default.fileExists(atPath: root) else { return true }
        if (root as NSString).lastPathComponent.lowercased() == "stack-nudge.app" { return true }
        guard let rootVersion = bundleVersion(root),
              let installedVersion = bundleVersion(installed)
        else { return true }
        return UpdateChecker.isNewer(installedVersion, than: rootVersion)
    }

    static func bundleVersion(_ bundle: String) -> String? {
        let info = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    // The `~/.stack-nudge/venv` symlink has the plists' problem one level
    // down: linkBundledVenvIfPresent points it into whichever bundle ran the
    // wizard, and notify.sh and Speaker reach the voice engine through it.
    // Same rule, applied to the link's destination. Replaced atomically, by
    // renaming a fresh link over it, so a reader never finds no link at all.
    @discardableResult
    static func retargetVenvSymlink(toBundle installed: String, symlinkPath: String) -> Bool {
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath),
              let moved = retargetedBundlePath(
                  destination, toBundle: installed,
                  exists: { fm.fileExists(atPath: $0) },
                  isSuperseded: { bundleIsSuperseded($0, by: installed) })
        else { return false }
        let staging = symlinkPath + ".retarget-\(getpid())"
        try? fm.removeItem(atPath: staging)
        guard (try? fm.createSymbolicLink(atPath: staging, withDestinationPath: moved)) != nil
        else { return false }
        guard rename(staging, symlinkPath) == 0 else {
            try? fm.removeItem(atPath: staging)
            return false
        }
        return true
    }

    // Everything the updater does to the launch agents on disk, in one
    // testable place: re-point both, and bring the app agent's KeepAlive up
    // to crash-only (see Updater for why). Returns the labels re-pointed.
    //
    // App only for KeepAlive — the daemon's `KeepAlive: true` is deliberate.
    static func retargetAgentsAfterUpdate(toBundle installed: String,
                                          agentsDir: String,
                                          venvSymlinkPath: String) -> Set<String> {
        // Not in the returned set: the set drives launchd handling, and the
        // symlink involves none.
        retargetVenvSymlink(toBundle: installed, symlinkPath: venvSymlinkPath)
        var retargeted: Set<String> = []
        for label in [appLabel, daemonLabel]
        where retargetLaunchAgentOnDisk(label: label, toBundle: installed, agentsDir: agentsDir) {
            retargeted.insert(label)
        }
        if retargeted.contains(appLabel) {
            crashOnlyKeepAliveOnDisk(label: appLabel, agentsDir: agentsDir)
        }
        return retargeted
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
    // the full bootstrap. Idempotent: our existing entries are replaced, not
    // duplicated.
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
        guard let notifyURL = Bundle.main.url(forResource: "notify.sh", withExtension: nil),
              let notifyScript = try? String(contentsOf: notifyURL, encoding: .utf8)
        else { throw BootstrapError.bundleResourceMissing("notify.sh") }
        try writeNotifyScript(notifyScript)

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
        let manifest = HookManifest.bundled()
        var unwritable: [String] = []
        for agent in BootstrapAgent.allCases {
            let path = agent.hookConfigPath
            guard fm.fileExists(atPath: path) else { continue }
            // An unreadable config (not JSON, or not an object) is skipped: there's
            // nothing in it we could safely strip, and it can't fire our hooks.
            let root: [String: Any]
            do {
                root = try readJSONObject(at: path)
            } catch {
                progress("Skipped \((path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
                continue
            }
            // A readable config we failed to rewrite (root-owned after a sudo
            // run, locked) still points at notify.sh, so finish the other agents
            // but stop before deleting the script, and say how to get past it.
            do {
                try unwireHooks(root, at: path, agent: agent, spec: manifest?.agents[agent])
            } catch {
                progress("Couldn't update \((path as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
                unwritable.append((path as NSString).abbreviatingWithTildeInPath)
            }
        }
        if !unwritable.isEmpty { throw BootstrapError.hooksNotRemoved(unwritable) }

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

    // Put every hook the manifest lists for `agent` in place: the wizard and
    // the Settings "Set up" action. Replaces our entries under the manifest's
    // events (older paths, args, timeouts, matchers) with exactly the manifest's,
    // removes ones it dropped, and leaves everyone else's alone.
    private static func wireHooks(for agent: BootstrapAgent) throws {
        guard let manifest = HookManifest.bundled() else { throw BootstrapError.bundleResourceMissing("hook-manifest.json") }
        try reconcileHooks(for: agent, manifest: manifest, everything: true)
    }

    // Launch-time pass over every agent that's already wired: adds hooks this
    // version introduced, drops ones it no longer lists, and rewrites our
    // commands to the current path and arg. Timeouts and matchers stay as the
    // user has them, so a manifest timeout change needs "Set up" to land. It
    // writes nothing when the config already matches. An agent the user
    // never wired stays unwired (the Settings banner offers that), and a
    // config that doesn't parse is left untouched.
    // Returns the agents whose config it rewrote.
    @discardableResult
    static func reconcileWiredAgents() -> [BootstrapAgent] {
        guard isInstalled(), let manifest = HookManifest.bundled() else { return [] }
        // An older build than the one that last reconciled stays out of it.
        guard manifest.version >= readHooksApplied().version else { return [] }
        return availableAgents().filter { isAgentWired($0) }.filter { agent in
            do {
                return try reconcileHooks(for: agent, manifest: manifest, everything: false)
            } catch {
                log("left \(agent.rawValue) hooks alone: \(error.localizedDescription)")
                return false
            }
        }
    }

    @discardableResult
    private static func reconcileHooks(for agent: BootstrapAgent, manifest: HookManifest, everything: Bool) throws -> Bool {
        guard let spec = manifest.agents[agent] else { return false }
        let path = agent.hookConfigPath
        var root = try readJSONObject(at: path)
        // A `hooks` value that isn't an object is someone else's shape: refuse
        // rather than overwrite it with ours.
        if let existing = root["hooks"], !(existing is [String: Any]) {
            throw BootstrapError.writeFailed(path, underlying: CocoaError(.fileReadCorruptFile))
        }
        var record = readHooksApplied()
        let before = record
        let outcome: HookReconciler.Outcome
        do {
            outcome = try HookReconciler.reconcile(
                hooks: root["hooks"] as? [String: Any] ?? [:], spec: spec,
                applied: record.agents[agent.rawValue].map(Set.init),
                notifyPath: notifyPath, ourScript: isOurScript(_:), everything: everything)
        } catch {
            throw BootstrapError.writeFailed(path, underlying: error)
        }
        if let hooks = outcome.hooks {
            root["hooks"] = hooks
            try writeJSONObject(root, to: path)
            log("reconciled \(agent.rawValue) hooks with this version's manifest")
        }
        record.agents[agent.rawValue] = outcome.applied.sorted()
        record.version = max(record.version, manifest.version)
        // Written after the config: a record ahead of the config would read a
        // never-added hook as deleted by hand. A failed write is logged, not
        // thrown: the config is already written (Codex still needs its re-trust
        // banner), and a lost record only falls back to the legacy set.
        if record != before {
            do { try writeHooksApplied(record) } catch { log("hooks-applied record not saved: \(error.localizedDescription)") }
        }
        return outcome.hooks != nil
    }

    private struct HooksApplied: Equatable {
        var version = 0
        var agents: [String: [String]] = [:]
    }

    // A missing or unreadable record reads as "nothing applied yet", which falls
    // back to the legacy hooks: the conservative side, adding only new ones.
    private static func readHooksApplied() -> HooksApplied {
        guard let data = FileManager.default.contents(atPath: hooksAppliedPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HooksApplied() }
        return HooksApplied(version: object["manifest_version"] as? Int ?? 0,
                            agents: object["agents"] as? [String: [String]] ?? [:])
    }

    private static func writeHooksApplied(_ record: HooksApplied) throws {
        let object: [String: Any] = ["manifest_version": record.version, "agents": record.agents]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: hooksAppliedPath), options: [.atomic])
        } catch {
            throw BootstrapError.writeFailed(hooksAppliedPath, underlying: error)
        }
    }

    // A command's first token is our installed notify.sh: ~/.stack-nudge, or the
    // legacy ~/.tinynudge, optionally quoted. Installs always live in a dot
    // directory, so a developer's checkout (…/src/stack-nudge/notify.sh) wired
    // by hand isn't ours to repoint.
    static let ourScriptRegex = try? NSRegularExpression(
        pattern: #"^"?(?:.*/)?\.(?:tinynudge|stack-nudge)/notify\.sh"?$"#
    )

    static func isOurScript(_ token: String) -> Bool {
        guard let regex = ourScriptRegex else { return false }
        return regex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    private static func isStaleHook(command: String) -> Bool {
        guard let regex = staleHookRegex else { return false }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    // The events uninstall always stripped broadly, for a build that somehow
    // lacks its manifest.
    private static let legacyHookEvents: Set<String> = ["Stop", "PermissionRequest", "AfterAgent", "Notification", "stop"]

    // Uninstall reverse. Under the manifest's events, every entry the stale-path
    // regex matches goes, as before; under any other event (one a newer version
    // wired before a downgrade, say) only our exact form does.
    private static func unwireHooks(_ root: [String: Any], at path: String,
                                    agent: BootstrapAgent, spec: AgentHookSpec?) throws {
        var root = root
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        let agentArg = spec?.agentArg ?? (agent == .claude ? "claude-code" : agent.rawValue)
        let cleaned = HookReconciler.pruned(
            hooks, broadEvents: spec.map { Set($0.hooks.map(\.event)) } ?? legacyHookEvents,
            isBroadlyOurs: isStaleHook(command:),
            isExactlyOurs: { HookReconciler.isExactlyOurs($0, agentArg: agentArg, ourScript: isOurScript) })
        // Nothing of ours: not written, so a config we couldn't write anyway
        // doesn't stop the uninstall.
        if NSDictionary(dictionary: cleaned).isEqual(to: hooks) { return }
        if cleaned.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = cleaned
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
        // Anything but an object is refused rather than read as empty: the
        // caller writes the result back, and that would wipe the file.
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BootstrapError.writeFailed(path, underlying: CocoaError(.fileReadCorruptFile))
        }
        return parsed
    }

    private static func writeJSONObject(_ root: [String: Any], to path: String) throws {
        // Write through a symlink (dotfile managers link these files) rather
        // than replacing it, and keep the file's permissions: the atomic write
        // below renames a fresh file into place.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        // Trailing newline so the file is well-formed for line-oriented
        // tools (some editors get cranky without it).
        var out = data
        out.append(0x0A)
        do {
            try out.write(to: url, options: [.atomic])
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
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
        // Daemon mirrors install.sh's "always" mode — if stackvox serve ever
        // exits 0 launchd should still bring it back. Only the panel uses the
        // SuccessfulExit:false form so a user Quit actually quits.
        try writePlist(label: daemonLabel,
                       programArgs: [python, stackvox, "serve"],
                       logPath: logPath,
                       keepAlive: true,
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
    //
    // `keepAlive` mirrors install.sh's "always" vs "on_crash" modes:
    //   true                       → restart unconditionally
    //   ["SuccessfulExit": false]  → restart on crash only (Quit means quit)
    private static func writePlist(label: String,
                                   programArgs: [String],
                                   logPath: String,
                                   keepAlive: Any = ["SuccessfulExit": false],
                                   env: [String: String] = [:]) throws {
        var plist: [String: Any] = [
            "Label":             label,
            "ProgramArguments":  programArgs,
            "RunAtLoad":         true,
            "KeepAlive":         keepAlive,
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
                FooterHint(label: "Cancel", keys: ["←"])
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
    case hooksNotRemoved([String])
    case launchctlFailed(label: String, exitCode: Int32, stderr: String)
    case bundleResourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .copyFailed(let what, let err):
            return "Failed to copy \(what): \(err.localizedDescription)"
        case .writeFailed(let what, let err):
            return "Failed to write \(what): \(err.localizedDescription)"
        case .hooksNotRemoved(let paths):
            return "Couldn't remove StackNudge's hooks from \(paths.joined(separator: ", ")). StackNudge's "
                + "background agents are stopped, but ~/.stack-nudge and the app are still here, since "
                + "those hooks still run ~/.stack-nudge/notify.sh. Make the folder holding each file "
                + "writable (it may be owned by root after a sudo run), or delete the hook lines that "
                + "run .stack-nudge/notify.sh yourself, then run Uninstall again."
        case .launchctlFailed(let label, let code, let stderr):
            let msg = stderr.isEmpty ? "exit \(code)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl failed for \(label): \(msg)"
        case .bundleResourceMissing(let name):
            return "Bundled resource missing: \(name) (rebuild may be incomplete)"
        }
    }
}
