import AppKit
import SwiftUI

enum SettingsKind {
    case toggle, cycle, action
    // Like .action (acts in place) but renders a bell instead of the
    // navigation chevron — the chevron would wrongly imply a drill-in.
    // Trailing reflects mute state: a plain bell when idle, bell.slash +
    // countdown while muted, matching the header bell / menu-bar glyph.
    case mute
}

struct SettingsView: View {

    @ObservedObject var nav: PanelNav

    // Hook-script freshness, sampled on appear (two small file reads) rather than
    // recomputed every render. Surfaced in aboutFooter.
    @State private var installedHookVersion: String?
    @State private var hookScriptStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Timed-mute status banner — pinned at the very top
                        // only while a mute is active, so landing in Settings
                        // mid-mute makes it obvious (and one-click undoable).
                        // Mouse-only like the reconciliation banner; keyboard
                        // users toggle mute via the .mute row in Toggles, so
                        // this isn't part of the settingsRows index.
                        muteBanner
                        // Reconciliation banner — appears above all other
                        // rows when one or more detected agents lack our
                        // notify.sh hook. Its two buttons are keyboard-indexed
                        // (.wireAgents / .dismissAgents, pinned ahead of
                        // .permissions to match this render order). After Set
                        // up is actioned, the success state takes over the slot
                        // for a few seconds before disappearing — that state is
                        // inert, so it isn't indexed.
                        if !nav.unwiredAgents.isEmpty {
                            unwiredAgentsRow(nav.unwiredAgents)
                        } else if !nav.recentlyWiredAgents.isEmpty {
                            wiredConfirmationRow(nav.recentlyWiredAgents)
                        }
                        // Runtime-permission nudge. nav.settingsRows puts
                        // .permissions ahead of .update, so it renders (and
                        // keyboard-indexes) above the update row when both are
                        // present.
                        if !nav.missingPermissions.isEmpty {
                            permissionsRow(nav.missingPermissions)
                        }
                        // Shown only when an update is pending.
                        if let version = nav.updateAvailable {
                            updateRow(version: version)
                        }

                        section("Hotkey") {
                            row(.hotkey, label: "Panel shortcut",
                                kind: .cycle,
                                value: nav.recordingHotkey ? "Press combo…" : nav.hotkeyDisplay)
                            if let error = nav.hotkeyError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 2)
                            }
                        }

                        section("Toggles") {
                            row(.banner,           label: "Banner notifications", kind: .toggle, value: nav.bannerEnabled    ? "On" : "Off")
                            row(.muteWhenFocused,  label: "Mute when focused",    kind: .toggle, value: nav.muteWhenFocused  ? "On" : "Off")
                            row(.mute,             label: nav.isMuted ? "Resume notifications" : "Mute notifications", kind: .mute, value: muteRowValue)
                            row(.muteDuration,     label: "Mute duration",        kind: .cycle,  value: "\(nav.muteDurationMinutes) min")
                            row(.remindUnanswered, label: "Remind unanswered",    kind: .cycle,  value: AttentionPolicy.minuteLabel(nav.remindMinutes))
                            row(.stalledSessions,  label: "Flag stalled after",   kind: .cycle,  value: AttentionPolicy.minuteLabel(nav.stalledMinutes))
                            row(.pinPanel,         label: "Pin panel",            kind: .toggle, value: nav.panelPinned      ? "On" : "Off")
                            row(.keepOpenWhenEmpty, label: "Keep open when empty", kind: .toggle, value: nav.keepOpenWhenEmpty ? "On" : "Off")
                            row(.launchAtLogin,    label: "Launch at login",      kind: .toggle, value: nav.launchAtLogin    ? "On" : "Off")
                        }

                        section("Widget") {
                            row(.widget,        label: "Widget",          kind: .toggle, value: nav.compactMode ? "On" : "Off")
                            row(.snapToCorners, label: "Snap to corners", kind: .toggle, value: nav.compactSnap ? "On" : "Off",   enabled: nav.compactMode)
                            row(.widgetCorner,  label: "Widget corner",   kind: .cycle,  value: nav.compactCorner.label,           enabled: nav.compactMode && nav.compactSnap)
                            row(.widgetOpacity, label: "Widget opacity",  kind: .cycle,  value: "\(Int(nav.compactAlpha * 100))%", enabled: nav.compactMode)
                            row(.widgetContent, label: "Widget type",     kind: .cycle,  value: nav.compactContent.label,          enabled: nav.compactMode)
                            row(.mascot,        label: "Mascot",          kind: .cycle,  value: nav.mascot.label,                  enabled: nav.compactMode)
                            row(.theme,         label: "Accent color",    kind: .cycle,  value: nav.theme.label,                   enabled: nav.compactMode)
                        }

                        section("Sounds") {
                            row(.soundEnabled,    label: "Sound enabled", kind: .toggle, value: nav.soundEnabled ? "On" : "Off")
                            row(.agentDoneSound,  label: "Agent done",    kind: .cycle,  value: nav.soundStop,       enabled: nav.soundEnabled)
                            row(.permissionSound, label: "Permission",    kind: .cycle,  value: nav.soundPermission, enabled: nav.soundEnabled)
                        }

                        section("Voice") {
                            row(.voiceEnabled, label: "Voice notifications", kind: .toggle, value: nav.voiceEnabled ? "On" : "Off")
                            row(.speakHotkey, label: "Read aloud shortcut", kind: .cycle,
                                value: nav.recordingSpeakHotkey ? "Press combo…" : nav.speakHotkeyDisplay)
                            if let error = nav.speakHotkeyError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 2)
                            }
                            if nav.voiceModelCached {
                                row(.voice,      label: "Voice", kind: .cycle, value: voiceLabel,                              enabled: nav.voiceEnabled)
                                row(.voiceSpeed, label: "Speed", kind: .cycle, value: String(format: "%.2f×", nav.voiceSpeed), enabled: nav.voiceEnabled)
                            } else {
                                voiceModelDownloadRow(index: nav.index(of: .downloadVoiceModel))
                            }
                        }

                        section("Usage") {
                            row(.quotaTracking, label: "Quota tracking",  kind: .toggle, value: nav.quotaTrackingEnabled ? "On" : "Off")
                            row(.quotaAlerts,   label: "Quota alerts",    kind: .toggle, value: nav.quotaAlertsEnabled    ? "On" : "Off", enabled: nav.quotaTrackingEnabled)
                            row(.alertThreshold, label: "Alert threshold", kind: .cycle,  value: "\(nav.quotaAlertThreshold)%",            enabled: nav.quotaTrackingEnabled && nav.quotaAlertsEnabled)
                            row(.pollFrequency, label: "Poll frequency",  kind: .cycle,  value: "\(nav.quotaPollMinutes) min",            enabled: nav.quotaTrackingEnabled)
                            row(.contextAlert,  label: "Context alert at", kind: .cycle, value: contextAlertLabel)
                            row(.showRemaining, label: "Show remaining",   kind: .toggle, value: nav.quotaShowRemaining ? "On" : "Off", enabled: nav.quotaTrackingEnabled)
                        }

                        section("Tickets") {
                            row(.githubLinks,     label: "GitHub PR links",  kind: .toggle, value: nav.githubLinkingEnabled ? "On" : "Off")
                            row(.hideShipped,     label: "Hide shipped",     kind: .toggle, value: nav.hideShippedTickets ? "On" : "Off", enabled: nav.githubLinkingEnabled)
                            row(.disconnectGithub, label: "Disconnect GitHub…", kind: .action, value: nav.githubSignedIn ? "Signed in" : "", enabled: nav.githubSignedIn)
                        }

                        section("Events") {
                            row(.historyPerSession, label: "History per session", kind: .cycle, value: "\(nav.eventsPerSession)")
                            row(.eventHistory,  label: "Event history",  kind: .toggle, value: nav.eventHistoryEnabled ? "On" : "Off")
                            row(.clearHistory,  label: "Clear event history", kind: .action, value: nav.historyRecords.isEmpty ? "empty" : "\(nav.historyRecords.count) kept")
                        }

                        section("Slack") {
                            row(.slackPaste,    label: "Paste Slack setup",   kind: .action, value: slackPasteValue)
                            row(.slackIdentity, label: "Slack user",          kind: .action, value: slackUserValue,  enabled: nav.slackTokenPresent)
                            row(.slackTest,     label: "Send test message",   kind: .action, value: "",              enabled: slackReady)
                            row(.slackEnabled,  label: "Slack notifications", kind: .toggle, value: nav.slackEnabled ? "On" : "Off",       enabled: slackReady)
                            row(.slackIdle,     label: "Notify when idle",    kind: .cycle,  value: SlackDelivery.idleLabel(nav.slackIdleMinutes), enabled: slackReady && nav.slackEnabled)
                            row(.slackDetail,   label: "Include message text", kind: .toggle, value: nav.slackIncludeDetail ? "On" : "Off", enabled: slackReady && nav.slackEnabled)
                            row(.slackStop,     label: "Also notify on finished turns", kind: .toggle, value: nav.slackNotifyOnStop ? "On" : "Off", enabled: slackReady && nav.slackEnabled)
                        }

                        section("Actions") {
                            row(.editPhrases,      label: "Edit phrases…",         kind: .action, value: "")
                            row(.checkPermissions, label: "Check permissions…",    kind: .action, value: "")
                            row(.openConfig,       label: "Open config file…",     kind: .action, value: "")
                            row(.releaseNotes,     label: "View release notes…",   kind: .action, value: "")
                            row(.checkUpdates,     label: "Check for updates…",    kind: .action, value: checkForUpdatesStatus)
                            row(.uninstall,        label: "Uninstall StackNudge…", kind: .action, value: "")
                            row(.quit,             label: "Quit panel",            kind: .action, value: "")
                        }

                        aboutFooter
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                .onChange(of: nav.selectedSettingIndex) { newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            PageFooter {
                if nav.recordingHotkey || nav.recordingSpeakHotkey {
                    FooterHint(label: "Press a combo with ⌘ / ⇧ / ⌥ / ⌃", keys: [], primary: true)
                    FooterHint(label: "Cancel", keys: ["Esc"])
                } else {
                    FooterHint(label: "Move",  keys: ["↑", "↓"])
                    FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
                    // Always rendered so the footer doesn't reflow as selection
                    // moves, dimmed on the rows where ←/→ do nothing (the
                    // banner's buttons and the action rows) — same treatment
                    // the events page gives its Snooze hint. Enter acts on
                    // every row, so "Act" never dims.
                    FooterHint(label: "Cycle", keys: ["←", "→"])
                        .opacity(nav.selectedRowRespondsToArrows ? 1.0 : 0.35)
                    FooterHint(label: "Act",   keys: ["⏎"])
                    FooterHint(label: "Back",  keys: ["Esc"])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            nav.loadFromConfig()
            nav.refreshVoiceModelCached()
            if nav.voiceModelCached, nav.voicesAvailable.isEmpty {
                nav.loadVoices()
            }
            // Re-scan agent configs on every Settings open so the
            // "unwired agent" banner reflects current disk state
            // (covers: user just installed Codex; user manually edited
            //  a hook file; old install lacks events added in a recent
            //  StackNudge release).
            nav.refreshUnwiredAgents()
            // Re-probe grants on every open so the banner/dot clear right
            // after the user grants a permission in System Settings and
            // returns to the panel.
            nav.refreshPermissions()
            installedHookVersion = Bootstrap.installedNotifyVersion()
            hookScriptStale = Bootstrap.notifyScriptOutdated(
                bundled: Bootstrap.bundledNotifyScript(),
                installedPath: Bootstrap.notifyPath)
        }
    }

    // Trailing value for the .mute action row: the live countdown while
    // muted (re-rendered by nav.muteTick every 30s), empty otherwise so the
    // row reads as a plain "Mute notifications" affordance.
    private var muteRowValue: String {
        guard nav.isMuted, let until = nav.muteUntil else { return "" }
        return PanelNav.muteRemainingLabel(until: until) + " left"
    }

    // Pinned status banner shown only while a timed mute is active. Accent
    // tint + bell.slash to match the header bell's muted state; the Resume
    // button reuses the same resumeNotifications action. nav.muteTick drives
    // the countdown refresh (bumped by the controller's 30s ticker).
    @ViewBuilder
    private var muteBanner: some View {
        let _ = nav.muteTick
        if nav.isMuted, let until = nav.muteUntil {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notifications muted")
                        .font(.subheadline.weight(.semibold))
                    Text("\(PanelNav.muteRemainingLabel(until: until)) left · banners, sounds & voice paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    nav.actions?.resumeNotifications()
                } label: {
                    Text("Resume")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .transition(.opacity)
        }
    }

    // Transient success confirmation that takes the reconciliation
    // banner's slot for ~3 s after the user clicks Set up. Disappears
    // by itself once `recentlyWiredAgents` clears.
    @ViewBuilder
    private func wiredConfirmationRow(_ agents: [BootstrapAgent]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(agents.count == 1
                     ? "\(agents[0].displayName) is set up."
                     : "\(agents.count) agents are set up.")
                    .font(.subheadline.weight(.semibold))
                Text("New banners will fire when the agent finishes a turn or waits for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.green.opacity(0.12))
        )
        .transition(.opacity)
    }

    // Reconciliation banner. Shown above all other settings rows when one
    // or more detected agents lack a notify.sh hook entry. Two targets:
    // "Set up" (wire every unwired agent) and "Not now" (dismiss for
    // this/future launches until the agent's state changes again). Each takes
    // a keyboard index of its own, so ↑/↓ steps through them and Enter acts;
    // clicking routes through the same nav methods and syncs the selection so
    // mouse and keyboard don't disagree about what's focused.
    @ViewBuilder
    private func unwiredAgentsRow(_ agents: [BootstrapAgent]) -> some View {
        let setUpIndex   = nav.index(of: .wireAgents)
        let dismissIndex = nav.index(of: .dismissAgents)
        let setUpSelected   = nav.selectedSettingIndex == setUpIndex
        let dismissSelected = nav.selectedSettingIndex == dismissIndex
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(agents.count == 1
                     ? "Wire up \(agents[0].displayName)?"
                     : "Wire up \(agents.count) agents?")
                    .font(.subheadline.weight(.semibold))
                Text(agents.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Detected on this Mac without StackNudge hooks. Set up to start getting banners.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        nav.selectedSettingIndex = setUpIndex
                        nav.wireAllUnwiredAgents()
                    } label: {
                        Text("Set up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                            // Already accent-filled, so it can't deepen its own
                            // fill the way the plain rows do — a ring reads as
                            // focus without restating the fill.
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(setUpSelected ? 0.7 : 0), lineWidth: 2)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .id(setUpIndex)
                    Button {
                        nav.selectedSettingIndex = dismissIndex
                        nav.dismissAllUnwiredAgents()
                    } label: {
                        Text("Not now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(dismissSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .id(dismissIndex)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    // Replaces the Voice + Speed rows when the Kokoro model hasn't been
    // fetched yet. Click (or Enter on the row) kicks off
    // PanelNav.startVoiceModelDownload(); while in flight the row shows
    // a determinate progress bar that flips back to Voice + Speed
    // automatically once Speaker.voiceModelCached() flips true.
    @ViewBuilder
    private func voiceModelDownloadRow(index: Int) -> some View {
        let selected = nav.selectedSettingIndex == index

        HStack(spacing: 10) {
            Image(systemName: nav.voiceModelDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.body)
                .foregroundStyle(nav.voiceModelDownloading ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(nav.voiceModelDownloading ? "Downloading voice model…" : "Voice model not downloaded")
                    .font(.subheadline.weight(.medium))
                if nav.voiceModelDownloading {
                    if nav.voiceModelProgress < 0 {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        ProgressView(value: nav.voiceModelProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                        Text("\(Int((nav.voiceModelProgress * 100).rounded()))% · ~325 MB total")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                } else if let err = nav.voiceModelError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("~325 MB · downloads from GitHub on first run")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if nav.voiceModelDownloading {
                Text("Cancel")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red.opacity(0.85))
            } else {
                Text("Download")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .id(index)
        .onTapGesture {
            nav.selectedSettingIndex = index
            nav.activate()
        }
    }

    private var voiceLabel: String {
        if nav.voicesLoading { return "Loading…" }
        if nav.voicesAvailable.isEmpty { return "Voices unavailable" }
        return nav.voice
    }

    private var contextAlertLabel: String {
        nav.contextAlertThresholdK == 0 ? "Off" : "\(nav.contextAlertThresholdK)K"
    }

    // Delivery needs both halves, so every row past setup keys off this rather
    // than the token alone.
    private var slackReady: Bool {
        nav.slackTokenPresent && nav.slackMemberID != nil
    }

    // The paste row doubles as the status line for the whole section: the last
    // paste/lookup/test outcome wins, then a delivery error, then the resting
    // state. A stale "token stored" next to a broken integration would be worse
    // than saying nothing.
    private var slackPasteValue: String {
        if let note = nav.slackSetupNote { return note }
        if let error = nav.slackError { return error }
        return nav.slackTokenPresent ? "token stored" : "not configured"
    }

    // Names who we'd DM and where that came from, because a wrong id would send
    // your prompts to a colleague and the source is the tell.
    private var slackUserValue: String {
        guard let id = nav.slackMemberID else { return "not set — press ⏎ to detect" }
        let who = nav.slackMemberLabel.map { "\($0) · \(id)" } ?? id
        return nav.slackIdentityFromEmail ? "\(who) (from git email)" : who
    }

    private var checkForUpdatesStatus: String {
        switch nav.updateCheckStatus {
        case .idle:             return ""
        case .checking:         return "Checking…"
        case .upToDate:         return "Up to date"
        case .updateAvailable:  return "Update available"
        case .failed:           return "Failed"
        }
    }

    // Conditional top-of-list row. Pinned at index 0 when an update is
    // available — visually distinct (accent fill always-on) so the user's
    // eye lands on it first. Acts on click or Enter; opens the GitHub
    // releases page via the openReleasePage action.
    @ViewBuilder
    private func updateRow(version: String) -> some View {
        let selected = nav.selectedSettingIndex == nav.index(of: .update)
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.subheadline.weight(.medium))
                Text("v\(version)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(selected ? 0.32 : 0.18))
        )
        .contentShape(Rectangle())
        .id(nav.index(of: .update))
        .onTapGesture {
            nav.selectedSettingIndex = nav.index(of: .update)
            nav.activate()
        }
    }

    // Runtime-permission nudge pinned above the settings sections when one or
    // more grants (Accessibility / Automation / Notifications) aren't set.
    // Keyboard-navigable like the update row — selecting + Enter, or a click,
    // opens the Permissions window. Orange (not accent) to read as "needs
    // attention" rather than the update affordance.
    private func permissionsRow(_ missing: [SettingsPane]) -> some View {
        let selected = nav.selectedSettingIndex == nav.index(of: .permissions)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(missing.count == 1 ? "Permission needed" : "Permissions needed")
                    .font(.subheadline.weight(.medium))
                Text(missing.map(\.title).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(selected ? 0.32 : 0.18))
        )
        .contentShape(Rectangle())
        .id(nav.index(of: .permissions))
        .onTapGesture {
            nav.selectedSettingIndex = nav.index(of: .permissions)
            nav.activate()
        }
    }

    // Non-navigable footer with version info. Sits below the action rows so
    // keyboard nav (rowCount=12) doesn't need to know about it. Clicking the
    // GitHub link opens the repo in the user's browser.
    private var aboutFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return VStack(spacing: 4) {
            Text("StackNudge v\(version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            // The app rewrites a stale hook script at launch, so a mismatch that
            // survives to here means the rewrite failed (read-only dotdir, wrong
            // owner) and hook payloads may be missing fields the panel needs.
            // Read on appear, not per render, to keep this off the render path.
            if hookScriptStale {
                Text("Hook script \(installedHookVersion.map { "v\($0)" } ?? "unstamped") is out of date; reinstall to refresh")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let url = URL(string: "https://github.com/StackOneHQ/stack-nudge") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("github.com/StackOneHQ/stack-nudge")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            VStack(spacing: 2) { content() }
        }
    }

    @ViewBuilder
    private func row(_ id: SettingsRow, label: String, kind: SettingsKind, value: String, enabled: Bool = true) -> some View {
        SettingsRowView(
            label: label,
            value: value,
            kind: kind,
            selected: nav.selectedSettingIndex == nav.index(of: id)
        )
        // Visual-only dimming when a row is gated by another setting
        // (Sound section's deps when Sound is off; Usage deps when
        // Quota tracking is off). Keyboard navigation still lands on
        // these rows so muscle memory isn't disrupted — the user just
        // sees that the row is currently inert.
        .opacity(enabled ? 1.0 : 0.4)
        .id(nav.index(of: id))
        .onTapGesture {
            nav.selectedSettingIndex = nav.index(of: id)
            // For actions, single-click is enough. For toggles/cycles a click
            // on the row also acts so mouse users don't have to keyboard. The
            // mute row acts in place too, so it clicks like an action.
            if kind == .action || kind == .toggle || kind == .mute {
                nav.activate()
            }
        }
    }
}

private struct SettingsRowView: View {

    let label: String
    let value: String
    let kind: SettingsKind
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .toggle:
            Image(systemName: value == "On" ? "checkmark.circle.fill" : "circle")
                .font(.callout)
                .foregroundStyle(value == "On" ? Color.green : Color.secondary)
        case .cycle:
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(selected ? Color.primary : .secondary)
        case .mute:
            // value is non-empty ("27m left") only while muted, so it doubles
            // as the muted flag for the glyph/tint — no separate state needed.
            HStack(spacing: 8) {
                if !value.isEmpty {
                    Text(value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: value.isEmpty ? "bell" : "bell.slash.fill")
                    .font(.callout)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.accentColor)
            }
        case .action:
            HStack(spacing: 8) {
                if !value.isEmpty {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
