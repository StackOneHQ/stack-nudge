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
            categorySplit

            aboutFooter
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            PageFooter {
                if nav.recordingHotkey || nav.recordingSpeakHotkey {
                    FooterHint(label: "Press a combo with ⌘ / ⇧ / ⌥ / ⌃", keys: [], primary: true)
                    FooterHint(label: "Cancel", keys: ["Esc"])
                } else {
                    if nav.settingsDetailFocused {
                        FooterHint(label: "Move", keys: ["↑", "↓"])
                        // Works at both levels, but only worth advertising
                        // here — on the sidebar it duplicates plain ↑↓.
                        FooterHint(label: "Category", keys: ["⌘↑↓"])
                        // Always rendered so the footer doesn't reflow as
                        // selection moves, dimmed on the rows where ←/→ do
                        // nothing — the same treatment the events page gives
                        // its Snooze hint. Enter acts on every row, so "Act"
                        // never dims.
                        FooterHint(label: "Cycle", keys: ["←", "→"])
                            .opacity(nav.selectedRowRespondsToArrows ? 1.0 : 0.35)
                        FooterHint(label: "Act", keys: ["⏎"])
                    } else {
                        FooterHint(label: "Category", keys: ["↑", "↓"])
                        FooterHint(label: "Open", keys: ["→"])
                    }
                    // One Esc hint, naming where it actually goes from here.
                    FooterHint(label: nav.settingsDetailFocused ? "Categories" : "Hide",
                               keys: ["Esc"])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Matching UsageView: never land back inside the detail from a
            // previous visit, where ↑↓ move rows rather than categories and the
            // attention-row count may have changed while away.
            nav.settingsDetailFocused = false
            nav.selectFirstCategoryRow()
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

    // One renderer over nav.rows(in:), rather than eight hand-kept lists beside
    // nav's eight. They agreed, but nothing made them: a row present in
    // rows(in:) and missing from its group would be keyboard-selectable and
    // invisible, and no test could see it. Exhaustive, so a new row has to be
    // given a home here too.
    // Both numbers, not one instead of the other. Three working extensions and
    // one stale directory used to read "1 not loaded", with no sign the other
    // three existed.
    private var extensionsRowValue: String {
        let installed = nav.extensionTabs.count
        let refused = nav.refusedExtensionCount
        let installedLabel = installed == 0 ? "None" : "\(installed) installed"
        return refused == 0 ? installedLabel : "\(installedLabel) · \(refused) not loaded"
    }

    @ViewBuilder private func extensionCard(_ id: String) -> some View {
        if let extensionRow = nav.installedExtensions.first(where: { $0.id == id }) {
            let selected = nav.settingsDetailFocused
                && nav.selectedSettingIndex == nav.index(of: .installedExtension(id))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: extensionRow.refusedReason == nil
                      ? "puzzlepiece.extension.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(extensionRow.refusedReason == nil ? Color.green : Color.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(extensionRow.name).font(.callout.weight(.medium)).lineLimit(1)
                        if let version = extensionRow.installedVersion {
                            Text(version).font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let reason = extensionRow.refusedReason {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !extensionRow.description.isEmpty {
                        Text(extensionRow.description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !extensionRow.config.isEmpty {
                        Text("Reads \(extensionRow.configKeyList)")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    if !extensionRow.requires.isEmpty {
                        Text("Needs \(extensionRow.requires.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(extensionRow.refusedReason == nil
                      ? Color.primary.opacity(selected ? 0.12 : 0.05)
                      : Color.orange.opacity(selected ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
            // Moves the keyboard selection too, exactly as the shared row()
            // helper does. Without it a click left selectedSettingIndex parked
            // on whatever was selected before — and if the click removed an
            // extension, that index then pointed past the end of a shorter
            // list, so nothing was highlighted while ⏎ still acted on a row.
            .onTapGesture {
                nav.selectedSettingIndex = nav.index(of: .installedExtension(id))
                nav.actions?.openExtension(id)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .id(nav.index(of: .installedExtension(id)))
        }
    }

    @ViewBuilder private func settingRow(_ id: SettingsRow) -> some View {
        switch id {
        // Notifications
        case .banner:           row(.banner, label: "Banner notifications", kind: .toggle, value: nav.bannerEnabled ? "On" : "Off")
        case .muteWhenFocused:  row(.muteWhenFocused, label: "Mute when focused", kind: .toggle, value: nav.muteWhenFocused ? "On" : "Off")
        case .mute:             row(.mute, label: nav.isMuted ? "Resume notifications" : "Mute notifications", kind: .mute, value: muteRowValue)
        case .muteDuration:     row(.muteDuration, label: "Mute duration", kind: .cycle, value: "\(nav.muteDurationMinutes) min")
        case .remindUnanswered: row(.remindUnanswered, label: "Remind unanswered", kind: .cycle, value: AttentionPolicy.minuteLabel(nav.remindMinutes))
        case .stalledSessions:  row(.stalledSessions, label: "Flag stalled after", kind: .cycle, value: AttentionPolicy.minuteLabel(nav.stalledMinutes))
        case .soundEnabled:     row(.soundEnabled, label: "Sound enabled", kind: .toggle, value: nav.soundEnabled ? "On" : "Off")
        case .agentDoneSound:   row(.agentDoneSound, label: "Agent done", kind: .cycle, value: nav.soundStop, enabled: nav.soundEnabled)
        case .permissionSound:  row(.permissionSound, label: "Permission", kind: .cycle, value: nav.soundPermission, enabled: nav.soundEnabled)

        // Voice
        case .voiceEnabled: row(.voiceEnabled, label: "Voice notifications", kind: .toggle, value: nav.voiceEnabled ? "On" : "Off")
        case .speakHotkey:
            row(.speakHotkey, label: "Read aloud shortcut", kind: .cycle,
                value: nav.recordingSpeakHotkey ? "Press combo…" : nav.speakHotkeyDisplay)
            if let error = nav.speakHotkeyError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.top, 2)
            }
        case .voice:      row(.voice, label: "Voice", kind: .cycle, value: voiceLabel, enabled: nav.voiceEnabled)
        case .voiceSpeed: row(.voiceSpeed, label: "Speed", kind: .cycle, value: String(format: "%.2f×", nav.voiceSpeed), enabled: nav.voiceEnabled)
        case .downloadVoiceModel: voiceModelDownloadRow(index: nav.index(of: .downloadVoiceModel))

        // Appearance
        case .widget:        row(.widget, label: "Widget", kind: .toggle, value: nav.compactMode ? "On" : "Off")
        case .snapToCorners: row(.snapToCorners, label: "Snap to corners", kind: .toggle, value: nav.compactSnap ? "On" : "Off", enabled: nav.compactMode)
        case .widgetCorner:  row(.widgetCorner, label: "Widget corner", kind: .cycle, value: nav.compactCorner.label, enabled: nav.compactMode && nav.compactSnap)
        case .widgetOpacity: row(.widgetOpacity, label: "Widget opacity", kind: .cycle, value: "\(Int(nav.compactAlpha * 100))%", enabled: nav.compactMode)
        case .widgetContent: row(.widgetContent, label: "Widget type", kind: .cycle, value: nav.compactContent.label, enabled: nav.compactMode)
        case .mascot:        row(.mascot, label: "Mascot", kind: .cycle, value: nav.mascot.label, enabled: nav.compactMode)
        case .theme:         row(.theme, label: "Accent color", kind: .cycle, value: nav.theme.label, enabled: nav.compactMode)

        // Usage
        case .quotaTracking:  row(.quotaTracking, label: "Quota tracking", kind: .toggle, value: nav.quotaTrackingEnabled ? "On" : "Off")
        case .quotaAlerts:    row(.quotaAlerts, label: "Quota alerts", kind: .toggle, value: nav.quotaAlertsEnabled ? "On" : "Off", enabled: nav.quotaTrackingEnabled)
        case .alertThreshold: row(.alertThreshold, label: "Alert threshold", kind: .cycle, value: "\(nav.quotaAlertThreshold)%", enabled: nav.quotaTrackingEnabled && nav.quotaAlertsEnabled)
        case .pollFrequency:  row(.pollFrequency, label: "Poll frequency", kind: .cycle, value: "\(nav.quotaPollMinutes) min", enabled: nav.quotaTrackingEnabled)
        case .contextAlert:   row(.contextAlert, label: "Context alert at", kind: .cycle, value: contextAlertLabel)
        case .showRemaining:  row(.showRemaining, label: "Show remaining", kind: .toggle, value: nav.quotaShowRemaining ? "On" : "Off", enabled: nav.quotaTrackingEnabled)

        // Integrations
        case .slackPaste:      row(.slackPaste, label: "Paste Slack setup", kind: .action, value: slackPasteValue)
        case .slackIdentity:   row(.slackIdentity, label: "Slack user", kind: .action, value: slackUserValue, enabled: nav.slackTokenPresent)
        case .slackTest:       row(.slackTest, label: "Send test message", kind: .action, value: "", enabled: slackReady)
        case .slackEnabled:    row(.slackEnabled, label: "Slack notifications", kind: .toggle, value: nav.slackEnabled ? "On" : "Off", enabled: slackReady)
        case .slackIdle:       row(.slackIdle, label: "Notify when idle", kind: .cycle, value: SlackDelivery.idleLabel(nav.slackIdleMinutes), enabled: slackReady && nav.slackEnabled)
        case .slackDetail:     row(.slackDetail, label: "Include message text", kind: .toggle, value: nav.slackIncludeDetail ? "On" : "Off", enabled: slackReady && nav.slackEnabled)
        case .slackStop:       row(.slackStop, label: "Also notify on finished turns", kind: .toggle, value: nav.slackNotifyOnStop ? "On" : "Off", enabled: slackReady && nav.slackEnabled)
        case .githubLinks:     row(.githubLinks, label: "GitHub PR links", kind: .toggle, value: nav.githubLinkingEnabled ? "On" : "Off")
        case .hideShipped:     row(.hideShipped, label: "Hide shipped", kind: .toggle, value: nav.hideShippedTickets ? "On" : "Off", enabled: nav.githubLinkingEnabled)
        case .disconnectGithub: row(.disconnectGithub, label: "Disconnect GitHub…", kind: .action, value: nav.githubSignedIn ? "Signed in" : "", enabled: nav.githubSignedIn)

        // Panel
        case .hotkey:
            row(.hotkey, label: "Panel shortcut", kind: .cycle,
                value: nav.recordingHotkey ? "Press combo…" : nav.hotkeyDisplay)
            if let error = nav.hotkeyError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.top, 2)
            }
        case .pinPanel:          row(.pinPanel, label: "Pin panel", kind: .toggle, value: nav.panelPinned ? "On" : "Off")
        case .keepOpenWhenEmpty: row(.keepOpenWhenEmpty, label: "Keep open when empty", kind: .toggle, value: nav.keepOpenWhenEmpty ? "On" : "Off")
        case .launchAtLogin:     row(.launchAtLogin, label: "Launch at login", kind: .toggle, value: nav.launchAtLogin ? "On" : "Off")
        case .tabTitleNames:     row(.tabTitleNames, label: "Name from tab titles", kind: .toggle, value: nav.tabTitleNames ? "On" : "Off")

        // Events
        case .historyPerSession: row(.historyPerSession, label: "History per session", kind: .cycle, value: "\(nav.eventsPerSession)")
        case .eventHistory:      row(.eventHistory, label: "Event history", kind: .toggle, value: nav.eventHistoryEnabled ? "On" : "Off")
        case .clearHistory:      row(.clearHistory, label: "Clear event history", kind: .action, value: nav.historyRecords.isEmpty ? "empty" : "\(nav.historyRecords.count) kept")

        // One card per installed extension, rather than the flat label/value
        // row every other category uses. The card carries version, description,
        // the keys it reads and what it needs, and none of that fits a value
        // column — but it is still a SettingsRow, so the selection ring, the
        // scroll-to-index and the arrow keys work on it unchanged.
        case .installedExtension(let id): extensionCard(id)

        // Actions
        case .editPhrases:      row(.editPhrases, label: "Edit phrases…", kind: .action, value: "")
        // The count is the useful part at a glance; a refusal is worth surfacing
        // here too, since the whole point of the sub-page is that it explains one.
        case .browseExtensions: row(.browseExtensions, label: "Browse extensions…", kind: .action,
                                    value: extensionsRowValue)
        case .checkPermissions: row(.checkPermissions, label: "Check permissions…", kind: .action, value: "")
        case .openConfig:       row(.openConfig, label: "Open config file…", kind: .action, value: "")
        case .releaseNotes:     row(.releaseNotes, label: "View release notes…", kind: .action, value: "")
        case .checkUpdates:     row(.checkUpdates, label: "Check for updates…", kind: .action, value: checkForUpdatesStatus)
        case .uninstall:        row(.uninstall, label: "Uninstall StackNudge…", kind: .action, value: "")
        case .quit:             row(.quit, label: "Quit panel", kind: .action, value: "")

        // Drawn by settingsBanners, above the category's rows.
        case .wireAgents, .dismissAgents, .permissions, .update:
            EmptyView()
        }
    }

    // Attention items stay above the split and outside any category, so they're
    // visible whichever one you're in. They index first, matching that order.
    @ViewBuilder private var settingsBanners: some View {
        VStack(alignment: .leading, spacing: 10) {
            muteBanner
            if !nav.unwiredAgents.isEmpty {
                unwiredAgentsRow(nav.unwiredAgents)
            } else if !nav.recentlyWiredAgents.isEmpty {
                wiredConfirmationRow(nav.recentlyWiredAgents)
            }
            if !nav.missingPermissions.isEmpty {
                permissionsRow(nav.missingPermissions)
            }
            if let version = nav.updateAvailable {
                updateRow(version: version)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // Categories left, the selected one's rows right — the Usage tab's split,
    // so the two-level keyboard model is the one already in the app.
    private var categorySplit: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsCategory.allCases, id: \.self) { category in
                    categoryRow(category)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 124)
            .padding(.vertical, 10)
            .padding(.leading, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // Inside the scroller, not pinned above it: on first
                        // launch the unwired-agents and permissions banners
                        // together are taller than the pane, and pinned they
                        // left two rows visible with no way to scroll past.
                        // They index ahead of the category's rows, so this is
                        // also the order the keyboard walks.
                        settingsBanners
                        detailRows
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(ThinScrollers())
                }
                .onChange(of: nav.selectedSettingIndex) { newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                // Entering a category always lands on its first row, so the
                // index is the same number every time and onChange above never
                // fires. Without this the pane keeps the previous category's
                // scroll offset and a short category opens part-scrolled.
                .onChange(of: nav.settingsCategory) { _ in
                    proxy.scrollTo(0, anchor: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                // Same focus ring the Usage tab uses when you step into its detail.
                if nav.settingsDetailFocused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        let selected = nav.settingsCategory == category
        return Text(category.label)
            .font(.caption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
            // Selecting, not entering. The Usage tab's two-level model is the
            // precedent: clicking a row in the list picks it, and →/Enter is
            // what steps inside. Focusing the detail here meant a click on the
            // sidebar silently repurposed ↑/↓ from categories to rows.
            .onTapGesture { nav.settingsCategory = category }
    }

    private var detailRows: some View {
        ForEach(nav.rows(in: nav.settingsCategory), id: \.self) { id in
            settingRow(id)
        }
    }


    @ViewBuilder
    private func row(_ id: SettingsRow, label: String, kind: SettingsKind, value: String, enabled: Bool = true) -> some View {
        SettingsRowView(
            label: label,
            value: value,
            kind: kind,
            selected: nav.settingsDetailFocused && nav.selectedSettingIndex == nav.index(of: id)
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
