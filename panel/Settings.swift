import AppKit
import SwiftUI

enum SettingsKind {
    case toggle, cycle, action
    // Like .action (acts in place) but renders a bell instead of the
    // navigation chevron — the chevron would wrongly imply a drill-in.
    // Trailing reflects mute state: a plain bell when idle, bell.slash +
    // countdown while muted, matching the header bell / menu-bar glyph.
    case mute
    // An action that can't be undone: drawn in the warning colour with its
    // shortcut, and no chevron, since it opens nothing.
    case destructive
}

struct SettingsView: View {

    // Scroll target for the top of the detail pane. A String so it can't
    // collide with the Int row indices the rows themselves are keyed by.
    private static let scrollTopID = "settings-detail-top"

    @ObservedObject var nav: PanelNav
    // False only for ScreenshotRenderer's fixtures: appearing reads the
    // config file and probes the machine, which a fixture must not.
    var runsOnAppear = true

    // Hook-script freshness, sampled on appear (two small file reads) rather than
    // recomputed every render. Surfaced in hookScriptRow.
    @State private var installedHookVersion: String?
    @State private var hookScriptStale = false

    // The bundled changelog entry for this build, read and parsed on appear for
    // the same reason: it is a file read plus a scan of ~700 lines, and the
    // answer cannot change while the panel is open.
    @State private var changelogEntry: ChangelogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            categorySplit

            PageFooter {
                if nav.recordingHotkey || nav.recordingSpeakHotkey {
                    // Esc cancels it too; PageFooter shows that as its last hint.
                    FooterHint(label: "Press a combo with ⌘ / ⇧ / ⌥ / ⌃", keys: [], primary: true)
                    FooterHint(label: "Cancel and move", keys: ["↑", "↓"])
                } else if nav.pickingValue {
                    FooterHint(label: "Choose", keys: ["←", "→"], primary: true)
                    FooterHint(label: "Done", keys: ["␣", "⏎"])
                    // Also settles the pick where it stands.
                    FooterHint(label: "Move", keys: ["↑", "↓"])
                } else {
                    if nav.settingsDetailFocused {
                        let onPage: Bool = { if case .extensionPage = nav.settingsCategory { return true }; return false }()
                        let hints = Self.detailFooterHints(
                            picker: nav.selectedRowIsPicker,
                            opensPage: nav.selectedRowOpensOnRight,
                            removeRow: { if case .extensionRemove? = nav.selectedRow { return true }; return false }(),
                            removable: nav.selectedRemovableExtension != nil,
                            inExtensions: onPage || nav.settingsCategory == .extensions,
                            onPage: onPage,
                            editingText: nav.extensionTextEdit != nil)
                        ForEach(hints.indices, id: \.self) { FooterHintRow(spec: hints[$0]) }
                    } else {
                        FooterHint(label: "Category", keys: ["↑", "↓"])
                        FooterHint(label: "Open", keys: ["→"])
                            .opacity(nav.canEnterSettingsCategory ? 1 : 0.35)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: nav.extensionTextFocusRequests) { _ in extensionFieldFocused = true }
        .onChange(of: nav.extensionTextEdit == nil) { ended in if ended { extensionFieldFocused = false } }
        .onAppear {
            guard runsOnAppear else { return }
            // Matching UsageView: never land back inside the detail from a
            // previous visit, where ↑↓ move rows rather than categories and the
            // attention-row count may have changed while away, unless this is
            // a return from one of this page's own sub-pages, which resumes on
            // the row that opened it. See PanelNav.resumeSettingsSelection.
            nav.resumeSettingsSelection()
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
            if changelogEntry == nil, let source = Changelog.bundledSource() {
                changelogEntry = Changelog.entry(for: appVersion, in: source)
            }
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
    // opens the Permissions page. Orange (not accent) to read as "needs
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

    // Hook-script staleness, pinned above every category like the permission and
    // update nudges. The app rewrites a stale script at launch, so a mismatch
    // that survives to here means the rewrite failed (read-only dotdir, wrong
    // owner) and hook payloads may be missing fields the panel needs — which
    // shows up as nudges quietly not firing, so it has to be visible wherever
    // the user happens to be rather than only on the About page.
    //
    // No chevron and no keyboard index: unlike the other two there is nothing to
    // open. The automatic repair has already failed, and the fix is a reinstall
    // outside the panel. Same orange as the permissions nudge, which is also
    // "something here is not working".
    private var hookScriptRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hook script is out of date")
                    .font(.subheadline.weight(.medium))
                Text("\(installedHookVersion.map { "v\($0)" } ?? "Unstamped") installed · reinstall StackNudge to refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.18))
        )
    }

    // Bundle version, rendered at the foot of the category sidebar and again at
    // the head of the About category.
    // The bar while a category's rows have the keyboard, as data so it can be
    // asserted. Every hint stays in place as the selection moves, dimmed where
    // it doesn't apply, so the bar never reflows.
    //
    // On the Extensions list and an extension's page: → opens a list row's
    // page as ⏎ does, ⌘⌫ removes the extension whose row or Remove row is
    // selected, and ← goes back to the list from a page. ⏎ and Space do
    // nothing on the Remove row, which takes ⌘⌫ alone, so Act dims there.
    // While a text row is being typed into, the field has the keyboard and
    // only ⏎ (save) is its own; PageFooter adds Esc.
    static func detailFooterHints(picker: Bool, opensPage: Bool, removeRow: Bool,
                                  removable: Bool, inExtensions: Bool, onPage: Bool,
                                  editingText: Bool) -> [FooterHintSpec] {
        if editingText { return [FooterHintSpec(label: "Save", keys: ["⏎"], primary: true)] }
        var hints = [
            FooterHintSpec(label: "Move", keys: ["↑", "↓"]),
            // Works at both levels, but only worth advertising here — on the
            // sidebar it duplicates plain ↑↓.
            FooterHintSpec(label: "Category", keys: ["⌘↑↓"]),
        ]
        if opensPage {
            hints.append(FooterHintSpec(label: "Open", keys: ["→", "⏎"], primary: true))
        } else {
            hints.append(FooterHintSpec(label: picker ? "Pick" : "Act", keys: ["␣", "⏎"],
                                        dimmed: removeRow))
        }
        if inExtensions {
            hints.append(FooterHintSpec(label: "Remove", keys: ["⌘⌫"], dimmed: !removable))
        }
        hints.append(FooterHintSpec(label: onPage ? "Extensions" : "Categories", keys: ["←"]))
        return hints
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // The head of an extension's own page: what it last reported, as a
    // readout rather than a row, for the same reason About's version is one:
    // there's nothing to activate, and a row that ignores ⏎ reads as broken.
    // When this extension holds presence, it also says that the lock row at
    // the bottom is StackNudge's, not the extension's.
    private func extensionPageHeader(_ id: String) -> some View {
        let row = nav.installedExtensions.first { $0.id == id }
        let status = row?.refusedReason ?? nav.extensionStatus[id]
        // The page's title and its status, as the list row showed them, so
        // stepping in reads as the same thing opened up.
        // One line, so a page of rows fits the panel's default height.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(nav.label(for: .extensionPage(id)))
                .font(.subheadline.weight(.semibold))
            Text(status ?? "No status yet")
                .font(.caption)
                .foregroundStyle(row?.refusedReason != nil ? Color.orange : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(status ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    // Read-only lines under a page's rows: what it was allowed, in plain
    // words, and where else it appears.
    private func extensionPageTrailer(_ id: String) -> some View {
        return Text(Self.extensionPageTrailerText(nav.extensionSettingsPages.first { $0.id == id }))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // One line: what it was allowed, and where else it appears only when that
    // is somewhere (a tab). Pure, so the wording is testable.
    static func extensionPageTrailerText(_ page: ExtensionSettingsPage?) -> String {
        let allowed = page?.allowed ?? []
        var text = "Allowed: " + (allowed.isEmpty ? "nothing beyond running" : allowed.joined(separator: " \u{00B7} "))
        if let tab = page?.tab {
            let shortcut = tab.replacingOccurrences(of: "Tab", with: "").trimmingCharacters(in: .whitespaces)
            text += shortcut.isEmpty ? " \u{00B7} Also a tab" : " \u{00B7} Also a tab \u{00B7} \(shortcut)"
        }
        return text
    }

    // A text key being typed into, in place of its row.
    @FocusState private var extensionFieldFocused: Bool

    @ViewBuilder private func extensionTextField(_ id: String, _ label: String, placeholder: String,
                                                 help: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(label).font(.subheadline)
                TextField(placeholder, text: Binding(get: { nav.extensionTextEdit?.value ?? "" },
                                            set: { nav.updateExtensionTextEdit($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .focused($extensionFieldFocused)
                    // Saved on ⏎; a value that's refused keeps the field so it
                    // can be fixed.
                    .onSubmit { if nav.commitExtensionTextEdit() { extensionFieldFocused = false } }
            }
            if let problem = nav.extensionTextProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if let help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(0.22)))
    }

    // Non-navigable readouts at the head of the About category: the version, and
    // the changelog entry for it. Neither is a row — there is nothing to
    // activate, and a selectable row that ignores Enter reads as broken.
    //
    // The version line carries a row's padding and font deliberately: the pane's
    // first line has to land where every other category's first line lands, or
    // stepping Actions → About shifts the text and reads as the page twitching.
    private var aboutHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("StackNudge v\(appVersion)")
                .font(.subheadline.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            if let entry = changelogEntry {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.date.map { "What's new in \(entry.version) · \($0)" }
                         ?? "What's new in \(entry.version)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MarkdownNotesView(source: entry.body)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    // One renderer over nav.rows(in:), rather than eight hand-kept lists beside
    // nav's eight. They agreed, but nothing made them: a row present in
    // rows(in:) and missing from its group would be keyboard-selectable and
    // invisible, and no test could see it. Exhaustive, so a new row has to be
    // given a home here too.

    // One line per installed extension: icon, name, its one-line
    // description, and a short status on the right (see ExtensionListStatus).
    // → or ⏎ opens its page, where everything else about it lives.
    @ViewBuilder private func extensionCard(_ id: String) -> some View {
        if let extensionRow = nav.installedExtensions.first(where: { $0.id == id }) {
            let selected = nav.settingsDetailFocused
                && nav.selectedSettingIndex == nav.index(of: .installedExtension(id))
            let refused = extensionRow.refusedReason != nil
            HStack(spacing: 10) {
                Image(systemName: refused ? "exclamationmark.triangle.fill" : "puzzlepiece.extension.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(refused ? Color.orange : Color.green)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(extensionRow.name).font(.subheadline).lineLimit(1)
                    let line = extensionRow.refusedReason ?? extensionRow.description
                    if !line.isEmpty {
                        Text(line).font(.caption)
                            .foregroundStyle(refused ? Color.orange : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let status = nav.extensionListStatus[id], !status.isEmpty {
                    Text(status).font(.caption.monospacedDigit())
                        .foregroundStyle(status.hasPrefix("Update") ? Color.accentColor
                                         : ["Broken", "Not loaded"].contains(status) ? Color.orange
                                         : .secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(selected ? 0.22 : 0)))
            .contentShape(Rectangle())
            // Moves the keyboard selection too, exactly as the shared row()
            // helper does, then opens the page as ⏎ would.
            .onTapGesture {
                nav.selectedSettingIndex = nav.index(of: .installedExtension(id))
                nav.openExtensionPage(id)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .id(nav.index(of: .installedExtension(id)))
        }
    }

    // Not a row: nothing to select. The Browse row follows it.
    private var noExtensionsNote: some View {
        Text("No extensions installed \u{2014} Browse to add one")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
        // The companion stands in for the pill while it is on.
        case .widget:        row(.widget, label: "Widget", kind: .toggle, value: nav.companionEnabled ? "Companion" : (nav.widgetPreferred ? "On" : "Off"), enabled: !nav.companionEnabled)
        case .snapToCorners: row(.snapToCorners, label: "Snap to corners", kind: .toggle, value: nav.compactSnap ? "On" : "Off", enabled: nav.compactMode)
        case .widgetCorner:  row(.widgetCorner, label: "Widget corner", kind: .cycle, value: nav.compactCorner.label, enabled: nav.compactMode && nav.compactSnap)
        case .widgetOpacity: row(.widgetOpacity, label: "Widget opacity", kind: .cycle, value: "\(Int(nav.compactAlpha * 100))%", enabled: nav.compactMode)
        case .widgetContent: row(.widgetContent, label: "Widget type", kind: .cycle, value: nav.compactContent.label, enabled: nav.compactMode)
        case .mascot:        row(.mascot, label: "Mascot", kind: .cycle, value: nav.mascot.label, enabled: nav.compactMode)
        case .theme:         row(.theme, label: "Accent color", kind: .cycle, value: nav.theme.label, enabled: nav.compactMode)

        // Companion
        case .companion:     row(.companion, label: "Companion", kind: .toggle, value: nav.companionEnabled ? "On" : "Off")
        case .companionSize: row(.companionSize, label: "Size", kind: .cycle, value: nav.companionSize.label, enabled: nav.companionEnabled)
        case .companionBadge: row(.companionBadge, label: "Count badge", kind: .toggle, value: nav.companionBadge ? "On" : "Off", enabled: nav.companionEnabled)
        case .companionPreviewPose: row(.companionPreviewPose, label: "Preview pose", kind: .cycle, value: nav.companionPreviewPose?.label ?? "Live", enabled: nav.companionEnabled)
        case .companionResetPosition: row(.companionResetPosition, label: "Reset position", kind: .action, value: "", enabled: nav.companionEnabled)

        // Usage
        case .quotaTracking:  row(.quotaTracking, label: "Quota tracking", kind: .toggle, value: nav.quotaTrackingEnabled ? "On" : "Off")
        case .quotaAlerts:    row(.quotaAlerts, label: "Quota alerts", kind: .toggle, value: nav.quotaAlertsEnabled ? "On" : "Off", enabled: nav.quotaTrackingEnabled)
        case .alertThreshold: row(.alertThreshold, label: "Alert threshold", kind: .cycle, value: "\(nav.quotaAlertThreshold)%", enabled: nav.quotaTrackingEnabled && nav.quotaAlertsEnabled)
        case .pollFrequency:  row(.pollFrequency, label: "Poll frequency", kind: .cycle, value: "\(nav.quotaPollMinutes) min", enabled: nav.quotaTrackingEnabled)
        case .contextAlert:   row(.contextAlert, label: "Context alert at", kind: .cycle, value: contextAlertLabel)
        case .showRemaining:  row(.showRemaining, label: "Show remaining", kind: .toggle, value: nav.quotaShowRemaining ? "On" : "Off", enabled: nav.quotaTrackingEnabled)
        // Pi enforces no quota, so these are the user's own daily allowances and
        // the Usage tab bars them against nothing else. The week is seven of them.
        case .piApiBudget:    row(.piApiBudget, label: "Pi API budget / day", kind: .cycle, value: PiBudget.label(nav.piApiBudgetDaily), enabled: nav.quotaTrackingEnabled)
        case .piLocalBudget:  row(.piLocalBudget, label: "Pi local budget / day", kind: .cycle, value: PiBudget.label(nav.piLocalBudgetDaily), enabled: nav.quotaTrackingEnabled)

        // An extension's own page. The lock row is the app's, shown on the
        // page of whichever extension holds presence.
        case .awayLock:       row(.awayLock, label: "Lock screen when away", kind: .toggle, value: nav.awayLock ? "On" : "Off",
                                  detail: "StackNudge's own setting, applied when this extension says you've gone.")
        case .extensionSetting(let id, let key):
            if let declared = nav.extensionConfigKey(id, key) {
                if let edit = nav.extensionTextEdit, edit.id == id, edit.key == key {
                    extensionTextField(id, declared.displayLabel, placeholder: declared.placeholder ?? "",
                                       help: nav.extensionRowDetail(id, key))
                        .id(nav.index(of: .extensionSetting(id, key)))
                } else {
                    row(.extensionSetting(id, key), label: declared.displayLabel,
                        kind: declared.kind == .toggle ? .toggle : declared.kind.isPicker ? .cycle : .action,
                        value: nav.extensionValueLabel(id, key),
                        detail: nav.extensionRowDetail(id, key))
                }
            }
        case .extensionUpdate(let id):
            // The read-only lines sit above the actions, which come last.
            extensionPageTrailer(id)
            let version = nav.installedExtensions.first { $0.id == id }?.availableVersion ?? ""
            row(.extensionUpdate(id),
                label: nav.extensionConfirming == id ? "Confirm update to \(version)" : "Update to \(version)",
                kind: .action, value: "",
                detail: nav.extensionConfirming == id
                    ? "Press ⏎ again to update." : nil)
        // ⌘⌫, not ⏎: see PanelNav.activate. The value says so.
        case .extensionRemove(let id):
            if !nav.settingsRows.contains(.extensionUpdate(id)) { extensionPageTrailer(id) }
            row(.extensionRemove(id), label: "Remove", kind: .destructive, value: "⌘⌫")

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
        case .disconnectGithub:
            row(.disconnectGithub, label: "Disconnect GitHub…", kind: .action, value: nav.githubSignedIn ? "Signed in" : "", enabled: nav.githubSignedIn)
            if let note = nav.githubSignInNote {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.top, 2)
            }

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
        case .browseExtensions: row(.browseExtensions, label: "Browse extensions", kind: .action,
                                    value: nav.browseExtensionsValue)
        case .checkPermissions: row(.checkPermissions, label: "Check permissions…", kind: .action, value: "")
        case .openConfig:       row(.openConfig, label: "Open config file…", kind: .action, value: "")
        case .releaseNotes:     row(.releaseNotes, label: "View release notes…", kind: .action, value: "")
        case .checkUpdates:     row(.checkUpdates, label: "Check for updates…", kind: .action, value: checkForUpdatesStatus)
        case .uninstall:        row(.uninstall, label: "Uninstall StackNudge…", kind: .action, value: "")
        case .quit:             row(.quit, label: "Quit panel", kind: .action, value: "")

        // About
        case .openRepo:
            row(.openRepo, label: "GitHub repo", kind: .action,
                value: PanelNav.repositoryURL.replacingOccurrences(of: "https://", with: ""))

        // Drawn by settingsBanners, above the category's rows.
        case .wireAgents, .dismissAgents, .permissions, .update:
            EmptyView()
        }
    }

    // Attention items stay above the split and outside any category, so they're
    // visible whichever one you're in. The ones that lead somewhere index first,
    // matching this order; the mute and hook-script notices are readouts with
    // nothing to open, so they render here without taking a keyboard slot.
    @ViewBuilder private var settingsBanners: some View {
        let any = nav.isMuted || !nav.unwiredAgents.isEmpty || !nav.recentlyWiredAgents.isEmpty
            || !nav.missingPermissions.isEmpty || nav.updateAvailable != nil || hookScriptStale
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
            if hookScriptStale {
                hookScriptRow
            }
        }
        .padding(.horizontal, 14)
        // No room taken when there's nothing to say, so every category's
        // first row sits at the same height.
        .padding(.top, any ? 12 : 0)
    }

    // Left column: the category list, with the version pinned under it.
    //
    // The list scrolls. It used to be a plain VStack, which cannot shrink below
    // the height of its rows — ~248pt for the ten categories, against the ~190pt
    // this column gets at the panel's 260pt minimum. The overflow did not clip
    // at the bottom, where it would at least have been obvious: the enclosing
    // frame centred it, so the first categories went off the top with no way to
    // reach them, and the footer hints were pushed off the bottom. Scrolling
    // bounds the column to whatever height it is given, whether that is a short
    // panel, an eleventh category, or a larger system font.
    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(nav.settingsCategories, id: \.self) { category in
                            categoryRow(category)
                                .id(category)
                        }
                    }
                    .background(ThinScrollers())
                }
                // ⌘↑↓ and the sidebar's own ↑↓ move the selection without
                // touching the scroll offset, so a category picked while the
                // list is scrolled can sit off-screen.
                .onChange(of: nav.settingsCategory) { category in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(category, anchor: nil)
                    }
                }
            }

            Text("v\(appVersion)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        }
        .frame(width: 124)
        .padding(.vertical, 10)
        .padding(.leading, 6)
    }

    // Categories left, the selected one's rows right — the Usage tab's split,
    // so the two-level keyboard model is the one already in the app.
    private var categorySplit: some View {
        HStack(alignment: .top, spacing: 0) {
            categorySidebar

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
                        if nav.settingsCategory == .about { aboutHeader }
                        if nav.settingsCategory == .extensions, nav.installedExtensions.isEmpty {
                            noExtensionsNote
                        }
                        if case .extensionPage(let id) = nav.settingsCategory {
                            extensionPageHeader(id)
                        }
                        detailRows
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // The id sits on the padded container, not on the first row,
                    // so scrolling here lands on the true top of the content.
                    // Anchoring on row 0 aligned that row's own top edge with the
                    // viewport and scrolled the 12pt inset away, which is why a
                    // category tall enough to scroll opened flush against the
                    // divider while a short one kept its inset.
                    .id(Self.scrollTopID)
                    .background(ThinScrollers())
                }
                // Nearest-edge, not centred. Centring re-scrolled the whole list
                // on every ↑/↓ to park the selection mid-pane, so rows slid under
                // the cursor in a category tall enough to scroll and sat still in
                // one that wasn't. A nil anchor scrolls the least it can to bring
                // the selection into view, leaving the list where the user put it.
                .onChange(of: nav.selectedSettingIndex) { newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: nil)
                    }
                }
                // Entering a category always lands on its first row, so the
                // index is the same number every time and onChange above never
                // fires. Without this the pane keeps the previous category's
                // scroll offset and a short category opens part-scrolled.
                .onChange(of: nav.settingsCategory) { _ in
                    proxy.scrollTo(Self.scrollTopID, anchor: .top)
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
        let selected = nav.sidebarCategory == category
        return Text(nav.label(for: category))
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
    private func row(_ id: SettingsRow, label: String, kind: SettingsKind, value: String,
                     enabled: Bool = true, detail: String? = nil) -> some View {
        SettingsRowView(
            label: label,
            value: value,
            kind: kind,
            selected: nav.settingsDetailFocused && nav.selectedSettingIndex == nav.index(of: id),
            picking: nav.pickingValue && nav.selectedRow == id,
            detail: detail
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
            // Remove is the exception: ⏎ never removes, but a click on the
            // row is as deliberate as the old page's Remove button was.
            if case .extensionRemove(let extensionID) = id {
                nav.onRemoveExtension(extensionID)
            } else if kind == .action || kind == .toggle || kind == .mute || kind == .destructive {
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
    // A value row being picked shows ‹ › either side of its value, the keys
    // that now step it.
    var picking = false
    // A secondary line under the label: an extension key's help text.
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(kind == .destructive ? Color.orange
                                     : selected ? Color.primary : Color.primary.opacity(0.85))
                // Only on the selected row, where it's being read: every
                // other row stays one line, like the built-in ones, so a page
                // of them fits the panel.
                if selected, let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
            HStack(spacing: 6) {
                if picking { Image(systemName: "chevron.left").font(.caption.weight(.semibold)) }
                Text(value)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if picking { Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(picking ? Color.accentColor : selected ? Color.primary : .secondary)
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
        case .destructive:
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
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
