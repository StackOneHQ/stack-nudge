import AppKit
import SwiftUI

enum PanelMode {
    case events
    case sessions
    case usage
    case outcomes
    case settings
    case phrases
    // Confirmation step after the user clicks the "Update available" row.
    // Shows release notes (when available) + Cancel / Update Now buttons.
    case updateConfirm
    // Live install progress driven by Updater. Replaces the panel content
    // until the install completes or fails — at which point the panel is
    // typically pkilled and respawned by launchd, so this mode is short
    // lived in the happy path.
    case updating
    // Welcome-style "what shipped" view shown automatically on first launch
    // after a successful update. Driven by the status file the runner wrote
    // before the previous instance died.
    case postUpdate
    // First-launch wizard shown when Bootstrap.isInstalled() returns false.
    // User picks which detected agents to wire up; Install runs Bootstrap.install.
    case bootstrap
    // Two-step uninstall reachable from Settings → "Uninstall stack-nudge…".
    // Confirmation alert, then progress, then app quits.
    case uninstall
}

// Action callbacks the controller wires into nav so settings rows like
// "Check permissions" / "Open config" / "Quit" can fire effects without the
// SwiftUI view needing to know about windows or app-level state.
enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case failed
}

enum CompactCorner: String, CaseIterable {
    case topLeft = "tl"
    case topRight = "tr"
    case bottomLeft = "bl"
    case bottomRight = "br"

    var label: String {
        switch self {
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum CompactContent: String, CaseIterable {
    case sessions
    case usage

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .usage:    return "Usage"
        }
    }
}

enum MascotKind: String, CaseIterable {
    case robot
    case cat
    case eye
    case ghost

    var label: String {
        switch self {
        case .robot: return "Robot"
        case .cat:   return "Cat"
        case .eye:   return "Sentinel"
        case .ghost: return "Ghost"
        }
    }
}

// Pill accent color preset. Drives the cyan-tinted surfaces in CompactView
// (pill border at <75% utilization, gauge tracks, gauge fill under 50%,
// mascot accents, inner-glow halo, spinner dot, sweat-drop). Urgency
// colors (.orange ≥75%, .red ≥90%) and the gauge's .yellow 50–75% band
// are deliberately untouched — they are semantic, not aesthetic.
//
// Orange and yellow are excluded from the palette because they collide
// with the urgency bands and would muddy the at-a-glance read.
enum AccentTheme: String, CaseIterable {
    case cyan
    case violet
    case mint
    case rose
    case system

    var label: String {
        switch self {
        case .cyan:   return "Cyan"
        case .violet: return "Violet"
        case .mint:   return "Mint"
        case .rose:   return "Rose"
        case .system: return "System"
        }
    }

    var color: Color {
        switch self {
        case .cyan:   return Color(red: 0.40, green: 0.85, blue: 1.00)
        case .violet: return Color(red: 0.72, green: 0.55, blue: 1.00)
        case .mint:   return Color(red: 0.50, green: 0.95, blue: 0.78)
        case .rose:   return Color(red: 1.00, green: 0.55, blue: 0.78)
        case .system: return Color.accentColor
        }
    }
}

// In-panel GitHub device-flow sign-in state. `awaitingApproval` carries the
// one-time code + verification URL to show while we poll in the background.
enum GithubSignIn: Equatable {
    case idle
    case requesting
    case awaitingApproval(userCode: String, verificationURI: String)
    case failed(String)
}

// Every Settings row, as a stable identity rather than a numeric index. The
// ordered list (PanelNav.settingsRows) is the single source of truth for both
// rendering and keyboard nav, so adding/removing/reordering a row is a one-line
// change with no renumbering — and the applyCycle switch over this is
// exhaustive, so the compiler flags any row left unhandled.
enum SettingsRow: Hashable {
    // One slot per button in the agent-reconciliation banner, so both are
    // keyboard-reachable rather than mouse-only.
    case wireAgents, dismissAgents
    case permissions, update, hotkey
    case banner, muteWhenFocused, mute, muteDuration, pinPanel, keepOpenWhenEmpty, launchAtLogin
    case widget, widgetCorner, widgetOpacity, widgetContent, mascot, theme
    case soundEnabled, agentDoneSound, permissionSound
    case voiceEnabled, voice, voiceSpeed, speakHotkey, downloadVoiceModel
    case quotaTracking, quotaAlerts, alertThreshold, pollFrequency, contextAlert, showRemaining
    case githubLinks, hideShipped, disconnectGithub
    case historyPerSession
    case editPhrases, checkPermissions, openConfig, releaseNotes, checkUpdates, uninstall, quit
}

struct SettingsActions {
    let checkPermissions: () -> Void
    let openConfig:       () -> Void
    let editPhrases:      () -> Void
    let openReleaseNotes: () -> Void
    let checkForUpdates:  () -> Void
    let beginUpdate:      () -> Void
    let runUpdate:        () -> Void
    let beginUninstall:   () -> Void
    let runUninstall:     () -> Void
    let runBootstrap:     () -> Void
    let quit:             () -> Void
    // Compact widget callbacks — wired by PanelController so the window
    // resize happens synchronously before SwiftUI re-renders.
    let expandFromCompact: () -> Void
    let exitCompactMode:   () -> Void
    // Timed global mute — muteFor takes a duration in minutes. Both are wired
    // by PanelController, which owns the expiry timer and the menu-bar badge.
    let muteFor:             (Int) -> Void
    let resumeNotifications: () -> Void
}

// Owns the panel's navigation state plus the live values the Settings page
// renders and mutates. Lives outside Settings.swift because the navigation
// model (mode, selected row, hotkey state) is read across all pages — only
// the settings field set is settings-page-specific.
final class PanelNav: ObservableObject {

    @Published var mode: PanelMode = .events
    @Published var selectedSettingIndex: Int = 0

    @Published var hotkeyDisplay:   String = "cmd+opt+n"
    @Published var recordingHotkey: Bool = false
    @Published var hotkeyError:     String?
    @Published var speakHotkeyDisplay:   String = "cmd+opt+s"
    @Published var recordingSpeakHotkey: Bool = false
    @Published var speakHotkeyError:     String?
    @Published var bannerEnabled:   Bool = true
    @Published var soundEnabled:    Bool = true
    @Published var voiceEnabled:    Bool = false
    @Published var muteWhenFocused: Bool = true
    // Timed global mute. When `muteUntil` is a future date, PanelController
    // suppresses ALL banner/sound/voice output (permission prompts included)
    // until it passes, then auto-lifts. Deliberately transient — never read
    // in loadFromConfig and never written to disk, so it resets on relaunch.
    // `muteTick` is bumped by PanelController's 30s countdown timer purely to
    // re-render the tab-strip/pill countdown while muted (the SwiftUI views
    // reference it so a value-less change still refreshes them).
    @Published var muteUntil: Date?
    @Published var muteTick: Int = 0
    // Persistent default duration (minutes) the bell button and menu use.
    @Published var muteDurationMinutes: Int = 30
    static let muteDurationOptions: [Int] = [15, 30, 60, 120]
    var isMuted: Bool {
        guard let until = muteUntil else { return false }
        return until > Date()
    }
    // "14m" style remainder for the menu-bar badge, tab-strip bell, and menu.
    static func muteRemainingLabel(until: Date) -> String {
        let mins = Int(ceil(max(0, until.timeIntervalSinceNow) / 60))
        return "\(mins)m"
    }
    @Published var panelPinned:     Bool = true
    // When true, clearing the last event leaves the panel open instead of
    // auto-hiding (STACKNUDGE_KEEP_OPEN_WHEN_EMPTY). Default off = prior behaviour.
    @Published var keepOpenWhenEmpty: Bool = false
    @Published var launchAtLogin:   Bool = true
    @Published var soundStop:       String = "Glass"
    @Published var soundPermission: String = "Ping"
    @Published var voice:           String = "af_aoede"
    @Published var voiceSpeed:      Double = 1.1
    @Published var voicesAvailable: [String] = []
    @Published var voicesLoading:   Bool = true
    // Kokoro voice model is fetched on first synthesis (~325 MB to
    // ~/.cache/huggingface/). UI hides Voice + Speed rows behind a
    // "Download voice model" action until the cache directory appears.
    @Published var voiceModelCached:      Bool    = false
    @Published var voiceModelDownloading: Bool    = false
    @Published var voiceModelProgress:    Double  = 0  // 0…1; -1 = indeterminate
    @Published var voiceModelError:       String?
    private var voiceModelDownloadProcess: Process?
    // The latest release tag from GitHub when newer than this bundle's
    // CFBundleShortVersionString — nil otherwise. Drives both the Settings
    // tab dot badge and the conditional "Update available" row at the top
    // of the Settings list. Populated by UpdateChecker.
    @Published var updateAvailable: String?
    // Runtime permissions (Accessibility / Automation / Notifications) that
    // aren't granted yet — empty means all set. Drives the orange dot on the
    // Settings tab and the "Permissions needed" banner pinned above the
    // Settings sections. Both denied and not-yet-determined count as missing:
    // the app can't fully function without the grant either way. Refreshed on
    // launch and every Settings.onAppear (see refreshPermissions) so granting
    // a permission and coming back clears it. Populated by refreshPermissions.
    @Published var missingPermissions: [SettingsPane] = []
    // Release notes body (markdown) for the available update — shown in the
    // confirmation step. nil before notes have loaded or when fetch failed
    // (e.g. private repo without auth).
    @Published var updateReleaseNotes: String?
    // Live updater state. updaterPhase advances as install.sh emits STAGE
    // markers; updaterLog accumulates the raw install output for the
    // expandable "Show output" detail in UpdatingView.
    @Published var updaterPhase: UpdatePhase = .idle
    @Published var updaterLog: String = ""
    @Published var updaterShowLog: Bool = false
    // Post-update screen state. Populated on launch when the status file
    // from a previous in-flight update is found; drives the welcome-style
    // PostUpdateView (mode = .postUpdate). Cleared on dismiss.
    @Published var postUpdateVersion: String?
    @Published var postUpdateNotes:   String?
    // Latest quota snapshot from `claude /usage`. Driven by the CLI probe
    // poller in PanelController. nil before the first probe completes, or
    // when the probe failed (no `claude` on PATH, not signed in, parse error).
    @Published var quota:            QuotaSnapshot?
    @Published var quotaLastUpdated: Date?
    // True while a probe is in-flight. Set by PanelController around the
    // fetch call so the UI can swap the footer status to "Syncing…".
    @Published var quotaSyncing:     Bool = false
    // Set when a probe had a token but the request/parse failed (vs. simply
    // having no Claude Code session). Drives the Usage tab's "quota unavailable"
    // state so a silently-changed endpoint isn't read as "still loading".
    // Cleared on the next successful probe.
    @Published var quotaError:       String?
    // Set when the event socket failed to bind at startup — the panel is then
    // deaf to every agent notification. Drives the banner at the top of the
    // Events tab so the failure isn't silent. Cleared when the socket binds.
    @Published var listenerError:    String?
    // Per-Claude-session context-window stats. Keyed by Claude's
    // session_id UUID (NudgeEvent.claudeSessionID), populated by
    // PanelController whenever an event arrives with a transcript_path.
    // Sessions.swift renders entries from this map alongside matched
    // sessions in the Sessions tab.
    @Published var claudeSessionStats: [String: TranscriptStats] = [:]
    // Agents without a per-pid session sidecar (Codex) learn their transcript
    // (session id + path) from the first hook event; we cache it by agent PID
    // so the Sessions/Compact views can resolve stats by PID instead of
    // scanning the prunable event list, and so the poll refresh can re-read it.
    @Published var transcriptRefByPID: [Int: TranscriptRef] = [:]
    // Codex (ChatGPT-plan) rate limits for the Usage tab, populated by
    // CodexQuotaProbe — the Codex analogue of `quota` above.
    @Published var codexQuota: CodexQuotaSnapshot?
    // Antigravity (agy) usage from the running CLI's loopback RPC, populated by
    // AntigravityUsageProbe — the agy analogue of `quota`/`codexQuota`.
    @Published var antigravityQuota: AntigravityQuotaSnapshot?
    // Bumped by PanelController after a handoff is upserted into the ledger so
    // the Tickets tab (OutcomesView) and its tab-strip count re-read the
    // in-memory HandoffLedger and reflect the new session live. The ledger
    // isn't itself observable; this is the single change-signal that drives it.
    @Published var handoffsRevision: Int = 0 { didSet { cachedOutcomeGroups = nil } }
    // Memoized grouping of the ledger (the expensive part: regex ticket
    // attribution + branch breakdown + sorts). Invalidated only when the ledger
    // changes (handoffsRevision) — NOT on selection moves, so holding ↑/↓ on the
    // Tickets tab doesn't re-derive every keystroke. The hideShipped filter is
    // applied per call on top, since it reads live outcome/PR state.
    private var cachedOutcomeGroups: [TicketGroup]?
    // Derived "did it ship?" status per repo+branch, computed off-main by
    // PanelController's outcome pass and read by the Tickets tab. Keyed by
    // `outcomeKey(repoRoot, branch)`. Empty until the first pass completes.
    @Published var outcomeByBranch: [String: OutcomeStatus] = [:]
    // Wired by PanelController; OutcomesView calls it on appear to recompute
    // outcomes for the branches in the ledger. Kept as a closure so the view
    // doesn't need to know about git/process work.
    var refreshOutcomes: (() -> Void)?
    // Opt-in GitHub PR/CI state per repo+branch (STACKNUDGE_GITHUB), fetched via
    // `gh` by PanelController and read by the Tickets tab. Supersedes the local
    // outcome when present — a PR reporting MERGED closes the squash gap. Keyed
    // by `outcomeKey`. Empty when the feature is off or `gh` is absent.
    @Published var pullRequestByBranch: [String: PullRequestInfo] = [:]
    // Rate-limited: safe to call on every appearance of the tab, may be deferred.
    var refreshPullRequests: (() -> Void)?
    // Same fetch, bypassing the rate limit. For explicit user actions only.
    var refreshPullRequestsNow: (() -> Void)?
    // Mirror of STACKNUDGE_GITHUB; gates the PR fetch. Off by default — local
    // git tracking stays fully functional without a GitHub token.
    @Published var githubLinkingEnabled: Bool = false
    // STACKNUDGE_HIDE_SHIPPED — drop groups whose PR reads merged so the tab
    // focuses on in-flight work. Needs GitHub linking to know "merged".
    @Published var hideShippedTickets: Bool = false
    // True when a GitHub token is stored (signed in). Drives whether the Tickets
    // tab shows PR chips or the "Connect GitHub" card. Set from the Keychain on
    // load and after the device flow completes.
    @Published var githubSignedIn: Bool = false
    // Live device-flow state for the in-panel "Connect GitHub" card.
    @Published var githubSignIn: GithubSignIn = .idle
    // Wired by PanelController — start/cancel the device-flow sign-in.
    var startGithubSignIn:  (() -> Void)?
    var cancelGithubSignIn: (() -> Void)?

    static func outcomeKey(_ repoRoot: String?, _ branch: String?) -> String {
        "\(repoRoot ?? "")\n\(branch ?? "")"
    }

    // Tickets-tab keyboard selection (↑/↓ move, Enter/→ opens the row's link),
    // mirroring the Usage tab. Indexes a flat list of rows in render order:
    // each group header, then its branch sub-rows (ticket groups only).
    @Published var outcomeSelectedIndex: Int = 0

    // The groups the Tickets tab renders, after the hide-shipped filter. Single
    // source of truth so the view and the keyboard indexing never disagree.
    func visibleOutcomeGroups() -> [TicketGroup] {
        let groups: [TicketGroup]
        if let cached = cachedOutcomeGroups {
            groups = cached
        } else {
            groups = OutcomesView.groups(from: HandoffLedger.shared.all())
            cachedOutcomeGroups = groups
        }
        guard hideShippedTickets else { return groups }
        return groups.filter { !isShipped($0) }
    }

    // "Shipped" = every branch in the group reads merged (PR state preferred,
    // else the local outcome). Empty groups aren't shipped.
    func isShipped(_ group: TicketGroup) -> Bool {
        !group.branches.isEmpty && group.branches.allSatisfy {
            let key = Self.outcomeKey($0.repoRoot, $0.branch)
            if let pr = pullRequestByBranch[key] { return pr.state == .merged }
            return outcomeByBranch[key] == .merged
        }
    }

    // Row count for clamping — header + branch sub-rows for every group, same
    // order the view renders. No config/network, so cheap to call per keystroke.
    func outcomeRowCount() -> Int {
        visibleOutcomeGroups().reduce(0) { total, group in
            total + 1 + group.branches.count
        }
    }

    func moveOutcomeSelection(_ delta: Int) {
        let count = outcomeRowCount()
        guard count > 0 else { return }
        outcomeSelectedIndex = min(max(0, outcomeSelectedIndex + delta), count - 1)
    }
    // ⌘↑/↓ — jump to the first / last Tickets row.
    func jumpOutcomeSelection(toLast: Bool) {
        let count = outcomeRowCount()
        guard count > 0 else { return }
        outcomeSelectedIndex = toLast ? count - 1 : 0
    }

    // Open the selected row's link: a ticket header → its tracker URL
    // (STACKNUDGE_TICKET_URL); a branch sub-row → its PR. Repo headers don't
    // link anywhere (no single PR for a repo) — their branches carry the links.
    func activateSelectedOutcome() {
        let template = ConfigFile.read()["STACKNUDGE_TICKET_URL"]
        var urls: [String?] = []
        for group in visibleOutcomeGroups() {
            urls.append(headerURL(group, template: template))
            for branch in group.branches {
                urls.append(pullRequestByBranch[Self.outcomeKey(branch.repoRoot, branch.branch)]?.url)
            }
        }
        guard !urls.isEmpty else { return }
        let index = min(max(0, outcomeSelectedIndex), urls.count - 1)
        if let url = urls[index], let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }

    private func headerURL(_ group: TicketGroup, template: String?) -> String? {
        guard group.isTicket, let template, template.contains("{key}") else { return nil }
        return template.replacingOccurrences(of: "{key}", with: group.label)
    }

    // Remove the selected row's records: a group header (ticket or repo) drops
    // the whole group (every branch); a branch sub-row drops just that branch.
    // Matched by (repoRoot, branch), which lives on each record.
    func dismissSelectedOutcome() {
        let records = HandoffLedger.shared.all()
        let rowKeys = branchKeysForRows(visibleOutcomeGroups())
        guard !rowKeys.isEmpty else { return }
        let index = min(max(0, outcomeSelectedIndex), rowKeys.count - 1)
        let targets = Set(rowKeys[index])
        guard !targets.isEmpty else { return }
        let ids = records
            .filter { targets.contains(Self.outcomeKey($0.repoRoot, $0.branch)) }
            .map(\.id)
        HandoffLedger.shared.remove(ids: ids)
        let newCount = outcomeRowCount()
        if outcomeSelectedIndex >= newCount { outcomeSelectedIndex = max(0, newCount - 1) }
        handoffsRevision += 1
    }

    // Per-row branch keys in render order, matching outcomeRowCount: a header
    // (drops all the group's branches), then one row per branch sub-row (drops
    // just that branch). Same for ticket and repo groups.
    private func branchKeysForRows(_ groups: [TicketGroup]) -> [[String]] {
        var rows: [[String]] = []
        for group in groups {
            rows.append(group.branches.map { Self.outcomeKey($0.repoRoot, $0.branch) })
            rows.append(contentsOf: group.branches.map { [Self.outcomeKey($0.repoRoot, $0.branch)] })
        }
        return rows
    }

    // Settings "Disconnect GitHub": wipe the local token + PR state, then open
    // GitHub's authorized-apps page so the user can fully revoke there too
    // (clearing locally stops us using it but doesn't revoke server-side).
    func disconnectGithub() {
        GitHubAuth.clearToken()
        githubSignedIn = false
        githubSignIn = .idle
        pullRequestByBranch = [:]
        if let url = URL(string: "https://github.com/settings/applications") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleHideShipped() {
        hideShippedTickets.toggle()
        ConfigFile.write(key: "STACKNUDGE_HIDE_SHIPPED",
                         value: hideShippedTickets ? "true" : "false")
    }
    // Usage tab: which connected client's quota is shown (index into
    // availableUsageClients). ↑/↓ move it; read through clampedUsageClientIndex
    // so a client losing its data can't strand the selection out of range.
    @Published var usageClientIndex: Int = 0
    // When true, keyboard focus is inside the Usage detail pane: ↑/↓ scroll it
    // rather than switching client. →/Enter steps in; ←/Esc steps back out.
    @Published var usageDetailFocused: Bool = false
    // Which pane of the detail carousel is showing. While the detail holds
    // focus, → steps forward through the panes and ← steps back — stepping back
    // off the first pane hands focus to the client list, so the carousel reads
    // as one more press of the same key rather than a separate focus level.
    @Published var usagePane: UsagePane = .quota
    // Series metric the history pane plots. ↑/↓ cycle it (that pane has nothing
    // to scroll, unlike the quota pane).
    @Published var usageMetric: UsageMetric = .outputTokens
    // Window the history pane covers. W cycles it. Narrower windows are a
    // re-bucket of the same cached entries, so switching costs no I/O.
    @Published var usageWindow: UsageWindow = .widest
    // Long-lived parse cache. Owned per-nav rather than global so nothing leaks
    // between instances, and so tests can drive a clean one.
    private let usageStore = UsageHistoryStore()
    // Replayed transcript history for the selected client, keyed so switching
    // client doesn't show another client's numbers while a scan is in flight.
    @Published var usageSeries: UsageSeries?
    @Published var usageSeriesClient: UsageClient?
    @Published var usageSeriesLoading: Bool = false
    private var usageSeriesScannedAt: Date?
    private var usageSeriesScanning = false

    // Connected clients that currently have quota to show, in display order.
    var availableUsageClients: [UsageClient] {
        var clients: [UsageClient] = []
        if let claude = quota,
           !(claude.fiveHour == nil && claude.sevenDay == nil
             && claude.sevenDayOpus == nil && claude.sevenDaySonnet == nil) {
            clients.append(.claude)
        }
        if let codex = codexQuota, codex.primary != nil || codex.secondary != nil {
            clients.append(.codex)
        }
        if let agy = antigravityQuota, !agy.models.isEmpty {
            clients.append(.antigravity)
        }
        return clients
    }

    var clampedUsageClientIndex: Int {
        let count = availableUsageClients.count
        guard count > 0 else { return 0 }
        return max(0, min(usageClientIndex, count - 1))
    }

    func selectNextUsageClient() {
        let count = availableUsageClients.count
        guard count > 1 else { return }
        usageClientIndex = min(clampedUsageClientIndex + 1, count - 1)
    }

    func selectPrevUsageClient() {
        guard availableUsageClients.count > 1 else { return }
        usageClientIndex = max(clampedUsageClientIndex - 1, 0)
    }

    // ⌘↑/↓ — jump to the first / last connected client.
    func selectFirstUsageClient() { guard !availableUsageClients.isEmpty else { return }; usageClientIndex = 0 }
    func selectLastUsageClient()  { let count = availableUsageClients.count; guard count > 0 else { return }; usageClientIndex = count - 1 }

    // MARK: - Usage detail carousel

    var selectedUsageClient: UsageClient? {
        let clients = availableUsageClients
        guard !clients.isEmpty else { return nil }
        return clients[clampedUsageClientIndex]
    }

    // The cached series, but only when it belongs to the client on screen — a
    // scan that finished for a previous selection must not render under a new one.
    func usageSeries(for client: UsageClient) -> UsageSeries? {
        guard usageSeriesClient == client else { return nil }
        return usageSeries
    }

    // → while the detail holds focus. Returns false when already on the last
    // pane so the caller knows the keystroke had nothing to do.
    @discardableResult
    func advanceUsagePane() -> Bool {
        let panes = UsagePane.allCases
        guard let index = panes.firstIndex(of: usagePane), index + 1 < panes.count else { return false }
        usagePane = panes[index + 1]
        if usagePane == .history { refreshUsageSeries() }
        return true
    }

    // ← while the detail holds focus. Returns false on the first pane, which is
    // the caller's signal to hand focus back to the client list.
    @discardableResult
    func retreatUsagePane() -> Bool {
        let panes = UsagePane.allCases
        guard let index = panes.firstIndex(of: usagePane), index > 0 else { return false }
        usagePane = panes[index - 1]
        return true
    }

    func cycleUsageMetric(forward: Bool) {
        let metrics = UsageMetric.allCases
        let index = metrics.firstIndex(of: usageMetric) ?? 0
        let next = forward ? (index + 1) % metrics.count
                           : (index - 1 + metrics.count) % metrics.count
        usageMetric = metrics[next]
    }

    // W on the history pane. Re-buckets the cached entries for the new window
    // rather than re-reading anything, so this is synchronous and instant — the
    // store always retains the widest window for exactly this reason.
    func cycleUsageWindow() {
        let windows = UsageWindow.allCases
        let index = windows.firstIndex(of: usageWindow) ?? 0
        usageWindow = windows[(index + 1) % windows.count]
        guard let client = selectedUsageClient,
              let source = client.historySource,
              usageSeries(for: client) != nil
        else { return }
        usageSeries = usageStore.series(source: source, window: usageWindow)
    }

    // Replay the selected client's transcripts on a background queue. The store
    // skips files that haven't changed and resumes mid-file for those that have,
    // so a repeat call costs the directory walk (~94 ms) rather than a full parse
    // (~1050 ms). The freshness gate is therefore short — just enough to stop key
    // repeat from queueing work. `force` is the R key, which always re-reads.
    func refreshUsageSeries(force: Bool = false) {
        guard let client = selectedUsageClient, let source = client.historySource else {
            usageSeries = nil
            usageSeriesClient = selectedUsageClient
            return
        }
        guard !usageSeriesScanning else { return }
        if !force,
           usageSeriesClient == client,
           let scannedAt = usageSeriesScannedAt,
           Date().timeIntervalSince(scannedAt) < Self.usageSeriesFreshness {
            return
        }

        // Only show the spinner on a first read; a warm re-read lands fast enough
        // that flashing a loading state would just be a flicker.
        let isFirstRead = usageSeries == nil || usageSeriesClient != client
        usageSeriesScanning = true
        usageSeriesLoading = isFirstRead
        let store = usageStore

        DispatchQueue.global(qos: .utility).async {
            // Only the I/O happens off-main. Bucketing is deliberately left to the
            // completion below rather than done here against a captured window:
            // pressing W during an in-flight scan would otherwise have its
            // re-bucket silently reverted by this completion, leaving the header
            // claiming one window while the chart showed another.
            store.refresh(source: source, retaining: .widest)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Pure computation over entries already in memory (~1 ms), so
                // running it on main is cheaper than the risk of a stale window.
                self.usageSeries = store.series(source: source, window: self.usageWindow)
                self.usageSeriesClient = client
                self.usageSeriesScannedAt = Date()
                self.usageSeriesLoading = false
                self.usageSeriesScanning = false
            }
        }
    }

    // Short enough that the graph feels live, long enough that holding a key
    // down doesn't queue redundant walks. The incremental store is what makes
    // this affordable — it was 60s when every refresh meant a full re-parse.
    private static let usageSeriesFreshness: TimeInterval = 5
    // Transient feedback for the "Check for updates…" action row.
    // Set by PanelController around UpdateChecker.check(); cleared
    // back to .idle a few seconds after a terminal result so the
    // row reads "Check for updates…" again on subsequent visits.
    @Published var updateCheckStatus: UpdateCheckStatus = .idle
    // Threshold-crossing notifications. quotaAlertsEnabled is the master
    // switch; quotaAlertThreshold is the single percent value used across
    // all tiers — banner fires once per period when any tier reaches it.
    @Published var quotaTrackingEnabled: Bool = true
    @Published var quotaAlertsEnabled:   Bool = true
    @Published var quotaShowRemaining:   Bool = false
    @Published var quotaAlertThreshold:  Int  = 80
    // Background poll interval in minutes when the panel is hidden.
    // Visible-panel polling is fixed at 60s (see Panel.swift). Cycle
    // values intentionally constrained — finer granularity isn't
    // useful for a usage gauge that updates server-side every minute.
    @Published var quotaPollMinutes:     Int  = 5
    static let quotaPollMinuteOptions: [Int] = [1, 2, 5, 10, 15, 30]
    // Threshold for per-Claude-session context-window alerts, in thousands
    // of tokens. 0 = off (no banner ever). When a session's tokens cross
    // this value, PanelController fires a one-shot banner; dedup re-arms
    // when the session's tokens drop by ≥20K (compact signal). Absolute
    // tokens (not %) because Claude 4.x context windows vary by model.
    @Published var contextAlertThresholdK: Int = 0
    static let contextAlertThresholdOptions: [Int] = [0, 100, 150, 175, 200, 300, 500, 750]
    // Per-session cap on Events history. Each Claude session (or
    // agent+project bucket for non-Claude agents) keeps the newest N
    // events; a global ceiling of 100 in EventStore caps total growth.
    @Published var eventsPerSession: Int = 5
    static let eventsPerSessionOptions: [Int] = [3, 5, 10, 20, 50]
    // Compact widget mode. Shrinks the panel to a glance-only widget pinned
    // to a screen corner; clicking it expands back to the full panel.
    // Compact mode is always-on now. The compactMode field is kept (and
    // forced to true in loadFromConfig) to avoid threading the rest of
    // the controller's compact-aware code; just don't expose a toggle.
    @Published var compactMode:   Bool = true
    @Published var compactCorner: CompactCorner = .topRight
    @Published var compactContent: CompactContent = .sessions
    @Published var mascot:        MascotKind = .robot
    @Published var theme:         AccentTheme = .cyan
    // Pill window alpha when at rest. 1.0 = fully opaque; lower values
    // let the desktop show through so the widget recedes. Applied
    // window-level so the NSVisualEffectView blur fades with it. Only
    // takes effect while in pill mode (compact + !expanded).
    @Published var compactAlpha:  Double = 1.0
    static let compactAlphaOptions: [Double] = [0.4, 0.6, 0.8, 1.0]
    // Transient: true when the widget was clicked → render full panel
    // at full size; resignKey resets this. Not persisted — purely a
    // session-local "the user wants details right now" flag.
    @Published var compactExpanded: Bool = false
    // Transient: true between mouseDown and mouseUp while dragging the
    // pill. CompactView reads this to skip its decorative TimelineView
    // animations so the main thread can keep up with AppKit's drag
    // handler. Reset by the controller's mouse-event monitor.
    @Published var compactDragging: Bool = false
    // Most recent NudgeKind for the mascot to react to. Set by
    // reactToEvent(_:) when EventStore appends a new event; cleared back to
    // nil after 0.8s so the reaction is a one-shot pulse rather than a
    // sticky state. Read by the per-mascot views in CompactView.
    @Published var lastEventReaction: NudgeKind?
    private var eventReactionClearTimer: Timer?
    // First-launch bootstrap wizard state. Populated by PanelController
    // on launch when Bootstrap.isInstalled() returns false; drives
    // BootstrapView (mode = .bootstrap).
    @Published var bootstrapAvailableAgents: [BootstrapAgent] = []
    @Published var bootstrapSelectedAgents:  Set<BootstrapAgent> = []
    @Published var bootstrapPhase:           BootstrapPhase = .idle
    @Published var bootstrapLog:             String = ""
    // Uninstall flow state. Reachable from Settings → "Uninstall stack-nudge…".
    @Published var uninstallPhase: UninstallPhase = .confirm
    @Published var uninstallLog:   String = ""

    // Reconciliation state. `unwiredAgents` is the live list of detected
    // agents whose hook configs don't reference our notify.sh. Drives the
    // "Set up X" banner at the top of Settings. Refreshed on app launch
    // and every Settings.onAppear so post-update / post-agent-install
    // scenarios surface naturally.
    //
    // `dismissedAgents` holds rawValue strings the user clicked away on;
    // persisted to ~/.stack-nudge/dismissed-agents.json so the banner
    // doesn't re-pester them between launches. An agent re-appears in
    // the banner if it leaves and re-enters the unwired set — eg they
    // wire it manually, then delete the entry; or upgrade lands new
    // event types we should wire.
    @Published var unwiredAgents:    [BootstrapAgent] = []
    @Published var dismissedAgents:  Set<String>      = []
    // Transient confirmation state. When the user clicks Set up on the
    // reconciliation banner, `recentlyWiredAgents` holds the agents we
    // just wired so the Settings view can flash a "✓ Wired up X" message
    // in place of the now-empty unwired banner. Cleared automatically
    // a few seconds later.
    @Published var recentlyWiredAgents: [BootstrapAgent] = []

    var actions: SettingsActions?
    // Wired by PanelController so nav can re-register the global hotkey
    // without owning the Hotkey instance directly. Returns true if the
    // new spec registered successfully.
    var setHotkey: ((String) -> Bool)?
    var setSpeakHotkey: ((String) -> Bool)?

    // Selectable thresholds for the Usage "Alert threshold" cycle row.
    // Sorted ascending so left/right arrows feel intuitive.
    static let quotaThresholds: [Int] = [50, 70, 80, 90, 95]

    static let macSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static let speedMin = 0.60
    static let speedMax = 1.60
    static let speedStep = 0.05

    // Conversational, agent-flavoured preview phrases. Picked at random each
    // time the user cycles voices so they hear varied cadence and intonation
    // rather than the same word over and over.
    static let voicePreviewPhrases = [
        "Oh, I have a question.",
        "Could you take a look at this?",
        "I need your approval to continue.",
        "Just finished that task — want to review?",
        "Hey, I've got something to show you.",
        "Quick question before I move on.",
        "Hmm, this one's tricky. Mind helping?",
        "All done. Ready when you are.",
        "Should I proceed with this change?",
        "I'd love your input on this.",
    ]

    // Settings rows in render order — the single source of truth for both the
    // view (Settings.swift looks up indices from this) and keyboard nav
    // (selectedRow indexes into it). The conditionals keep render + dispatch in
    // sync automatically: the permissions row appears only when a grant is
    // missing and the update row only when an update is pending (both pin to the
    // top, permissions first), and Voice collapses to a single Download row
    // until the model is cached — no hand-maintained indices, no off-by-one to
    // chase.
    var settingsRows: [SettingsRow] {
        var rows: [SettingsRow] = []
        // The reconciliation banner renders above the permissions and update
        // rows, so it indexes above them too — Set up first, then Not now.
        if !unwiredAgents.isEmpty { rows += [.wireAgents, .dismissAgents] }
        if !missingPermissions.isEmpty { rows.append(.permissions) }
        if updateAvailable != nil { rows.append(.update) }
        rows += [.hotkey,
                 .banner, .muteWhenFocused, .mute, .muteDuration, .pinPanel, .keepOpenWhenEmpty, .launchAtLogin,
                 .widget, .widgetCorner, .widgetOpacity, .widgetContent, .mascot, .theme,
                 .soundEnabled, .agentDoneSound, .permissionSound,
                 .voiceEnabled, .speakHotkey]
        rows += voiceModelCached ? [.voice, .voiceSpeed] : [.downloadVoiceModel]
        rows += [.quotaTracking, .quotaAlerts, .alertThreshold, .pollFrequency, .contextAlert, .showRemaining,
                 .githubLinks, .hideShipped, .disconnectGithub,
                 .historyPerSession,
                 .editPhrases, .checkPermissions, .openConfig, .releaseNotes, .checkUpdates, .uninstall, .quit]
        return rows
    }

    var rowCount: Int { settingsRows.count }

    // The row the keyboard selection currently points at (clamped to range).
    var selectedRow: SettingsRow? {
        let rows = settingsRows
        guard !rows.isEmpty else { return nil }
        return rows[min(max(0, selectedSettingIndex), rows.count - 1)]
    }

    // Flat index of a row in the current layout, so Settings.swift never
    // hard-codes a number.
    func index(of row: SettingsRow) -> Int { settingsRows.firstIndex(of: row) ?? 0 }

    // MARK: - Disk I/O

    // Trigger a one-shot mascot reaction tied to the kind of event that
    // just arrived. The pill mascot picks this up via @Published and runs
    // an 800ms animation specific to .stop / .permission / .other; we
    // clear it back to nil after the same window so the next event can
    // re-trigger (Published only re-fires on change).
    func reactToEvent(_ kind: NudgeKind) {
        lastEventReaction = kind
        eventReactionClearTimer?.invalidate()
        eventReactionClearTimer = Timer.scheduledTimer(withTimeInterval: 0.8,
                                                       repeats: false) { [weak self] _ in
            self?.lastEventReaction = nil
        }
    }

    func loadFromConfig() {
        let config = ConfigFile.read()
        hotkeyDisplay   = config["STACKNUDGE_PANEL_HOTKEY"]    ?? "cmd+opt+n"
        speakHotkeyDisplay = config["STACKNUDGE_SPEAK_HOTKEY"] ?? "cmd+opt+s"
        bannerEnabled   = ConfigFile.bool(config, "STACKNUDGE_BANNER",    default: true)
        soundEnabled    = ConfigFile.bool(config, "STACKNUDGE_SOUND",     default: true)
        voiceEnabled    = ConfigFile.bool(config, "STACKNUDGE_VOICE",     default: false)
        muteWhenFocused = ConfigFile.bool(config, "STACKNUDGE_MUTE_WHEN_FOCUSED", default: true)
        // Persistent default only — the live `muteUntil` is transient and
        // intentionally left untouched here so config reloads never clear it.
        let rawMuteDuration = Int(config["STACKNUDGE_MUTE_DURATION_MIN"] ?? "") ?? 30
        muteDurationMinutes = Self.muteDurationOptions.min(by: { abs($0 - rawMuteDuration) < abs($1 - rawMuteDuration) }) ?? 30
        panelPinned     = ConfigFile.bool(config, "STACKNUDGE_PANEL_PIN", default: true)
        keepOpenWhenEmpty = ConfigFile.bool(config, "STACKNUDGE_KEEP_OPEN_WHEN_EMPTY", default: false)
        // Source of truth for the toggle is the plist's presence on disk
        // (Bootstrap.isLaunchAtLoginEnabled) — the config key is just a
        // mirror used for parity with the other toggles. If the two ever
        // disagree (e.g. plist removed manually), trust the disk and
        // re-sync the config the next time the user touches the toggle.
        launchAtLogin   = Bootstrap.isLaunchAtLoginEnabled()
        soundStop       = config["STACKNUDGE_SOUND_STOP"]       ?? "Glass"
        soundPermission = config["STACKNUDGE_SOUND_PERMISSION"] ?? "Ping"
        voice           = config["STACKNUDGE_VOICE_NAME"]       ?? "af_aoede"
        voiceSpeed      = Double(config["STACKNUDGE_VOICE_SPEED"] ?? "") ?? 1.1
        githubLinkingEnabled = ConfigFile.bool(config, "STACKNUDGE_GITHUB", default: false)
        hideShippedTickets = ConfigFile.bool(config, "STACKNUDGE_HIDE_SHIPPED", default: false)
        githubSignedIn = GitHubAuth.token() != nil
        quotaTrackingEnabled = ConfigFile.bool(config, "STACKNUDGE_QUOTA_TRACKING", default: true)
        quotaAlertsEnabled   = ConfigFile.bool(config, "STACKNUDGE_QUOTA_ALERTS",   default: true)
        quotaShowRemaining   = ConfigFile.bool(config, "STACKNUDGE_QUOTA_SHOW_REMAINING", default: false)
        // Coerce out-of-list values to the nearest valid threshold so a
        // hand-edited config can't desync the cycle row's selection.
        let rawThreshold = Int(config["STACKNUDGE_QUOTA_THRESHOLD"] ?? "") ?? 80
        quotaAlertThreshold = Self.quotaThresholds.min(by: { abs($0 - rawThreshold) < abs($1 - rawThreshold) }) ?? 80
        // Same coercion for poll interval — snap to nearest valid option.
        let rawPoll = Int(config["STACKNUDGE_USAGE_POLL_MIN"] ?? "") ?? 5
        quotaPollMinutes = Self.quotaPollMinuteOptions.min(by: { abs($0 - rawPoll) < abs($1 - rawPoll) }) ?? 5
        let rawCtx = Int(config["STACKNUDGE_CONTEXT_ALERT_THRESHOLD"] ?? "") ?? 0
        contextAlertThresholdK = Self.contextAlertThresholdOptions.min(by: { abs($0 - rawCtx) < abs($1 - rawCtx) }) ?? 0
        compactMode   = ConfigFile.bool(config, "STACKNUDGE_COMPACT_MODE", default: true)
        compactCorner = CompactCorner(rawValue: config["STACKNUDGE_COMPACT_CORNER"] ?? "")
            ?? .topRight
        compactContent = CompactContent(rawValue: config["STACKNUDGE_COMPACT_CONTENT"] ?? "")
            ?? .sessions
        mascot        = MascotKind(rawValue: config["STACKNUDGE_MASCOT"] ?? "") ?? .robot
        theme         = AccentTheme(rawValue: config["STACKNUDGE_THEME"] ?? "") ?? .cyan
        let rawAlpha = Double(config["STACKNUDGE_COMPACT_ALPHA"] ?? "") ?? 1.0
        compactAlpha = Self.compactAlphaOptions.min(by: { abs($0 - rawAlpha) < abs($1 - rawAlpha) }) ?? 1.0
        let rawPerSession = Int(config["STACKNUDGE_EVENTS_PER_SESSION"] ?? "") ?? 5
        eventsPerSession = Self.eventsPerSessionOptions.min(by: { abs($0 - rawPerSession) < abs($1 - rawPerSession) }) ?? 5
    }

    // MARK: - Agent reconciliation

    // Re-scan the on-disk agent configs and surface anything our
    // notify.sh isn't wired into yet. Dismissed agents stay hidden
    // until either the file goes back to "wired" or the dismissal
    // file is deleted.
    func refreshUnwiredAgents() {
        loadDismissedAgents()
        let detected = Bootstrap.unwiredAgents()
        let visible = detected.filter { !dismissedAgents.contains($0.rawValue) }
        if visible != unwiredAgents { unwiredAgents = visible }
    }

    // Wire one agent in-place, then refresh the unwired list so the
    // row disappears immediately on success. Records the agent in
    // recentlyWiredAgents so the Settings view can show a transient
    // "✓ Wired up X" confirmation; cleared after a few seconds.
    func wireSingleAgent(_ agent: BootstrapAgent) {
        do {
            try Bootstrap.wireSingleAgent(agent)
            recentlyWiredAgents.append(agent)
            // Auto-clear so the confirmation doesn't linger forever.
            // Re-dispatching is harmless: each new wire extends the
            // visible window, then the latest scheduler clears the list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.recentlyWiredAgents.removeAll { $0 == agent }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "stack-nudge: wire \(agent.rawValue) failed: \(error)\n".utf8))
        }
        // Always refresh — even on error the file state may have partly
        // changed and we want the UI to reflect reality.
        refreshUnwiredAgents()
    }

    // Click "Not now" on the banner. Persist to ~/.stack-nudge/
    // dismissed-agents.json so the user isn't pestered next launch.
    // We re-show only if the agent leaves the unwired set (eg user
    // manually adds a hook then deletes it) — see refreshUnwiredAgents.
    func dismissUnwiredAgent(_ agent: BootstrapAgent) {
        dismissedAgents.insert(agent.rawValue)
        saveDismissedAgents()
        refreshUnwiredAgents()
    }

    // Keyboard/click entry points for the banner's two buttons, wiring or
    // dismissing every agent the banner lists. Both snapshot `unwiredAgents`
    // first: wireSingleAgent and dismissUnwiredAgent each re-run
    // refreshUnwiredAgents, which rewrites the array mid-loop.
    func wireAllUnwiredAgents() {
        for agent in unwiredAgents { wireSingleAgent(agent) }
        resetSelectionIfBannerCleared()
    }

    func dismissAllUnwiredAgents() {
        for agent in unwiredAgents { dismissUnwiredAgent(agent) }
        resetSelectionIfBannerCleared()
    }

    // Both banner rows vanish the instant it's actioned, so a stale index would
    // leave the keyboard highlight on whichever row slid up into that slot.
    // Selection stays put if a wire failed and the banner is still showing.
    private func resetSelectionIfBannerCleared() {
        if unwiredAgents.isEmpty { selectedSettingIndex = 0 }
    }

    private static let dismissedAgentsPath =
        "\(NSHomeDirectory())/.stack-nudge/dismissed-agents.json"

    func toggleMute(for session: Session) {
        SessionPersistence.shared.toggleMuted(session)
        objectWillChange.send()
    }

    func isMuted(_ session: Session) -> Bool {
        SessionPersistence.shared.isMuted(session)
    }

    // Unmatched events fall through unmuted — better to notify on
    // something we can't classify than to silently drop it.
    func isSessionMuted(event: NudgeEvent, in sessions: [Session]) -> Bool {
        guard let match = sessions.first(where: { sessionMatches(event: event, session: $0) }) else {
            return false
        }
        return isMuted(match)
    }

    private func loadDismissedAgents() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.dismissedAgentsPath)),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return }
        dismissedAgents = Set(arr)
    }

    private func saveDismissedAgents() {
        let arr = Array(dismissedAgents).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted])
        else { return }
        let url = URL(fileURLWithPath: Self.dismissedAgentsPath)
        // ~/.stack-nudge/ may not yet exist if reconciliation runs before
        // the bootstrap wizard completes. Create the parent on demand.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    // MARK: - Permissions

    // Probe the three runtime grants and record which aren't set yet.
    // Notifications is async, so the ordered list is assembled in its callback
    // (same order the Permissions window renders them). denied and
    // not-yet-determined both count as missing — the panel can't fully
    // function without the grant either way.
    func refreshPermissions() {
        let accessibility = Permissions.accessibility()
        let automation    = Permissions.automation()
        Permissions.notifications { [weak self] notifications in
            guard let self else { return }
            var missing: [SettingsPane] = []
            if notifications != .granted { missing.append(.notifications) }
            if accessibility != .granted { missing.append(.accessibility) }
            if automation    != .granted { missing.append(.automation) }
            if missing != self.missingPermissions { self.missingPermissions = missing }
        }
    }

    func refreshVoiceModelCached() {
        voiceModelCached = Speaker.voiceModelCached()
    }

    func startVoiceModelDownload() {
        guard !voiceModelDownloading else { return }
        voiceModelError = nil
        voiceModelProgress = -1   // indeterminate until first tqdm line
        voiceModelDownloading = true
        voiceModelDownloadProcess = Speaker.downloadVoiceModel(
            progress: { [weak self] value in
                self?.voiceModelProgress = value
            },
            completion: { [weak self] error in
                guard let self else { return }
                self.voiceModelDownloading = false
                self.voiceModelDownloadProcess = nil
                if let error {
                    self.voiceModelError = error.localizedDescription
                    self.voiceModelCached = Speaker.voiceModelCached()
                } else {
                    self.voiceModelProgress = 1
                    self.voiceModelCached = true
                    // Now that the model is present, populate the voice
                    // list so the dropdown is ready when SwiftUI re-renders.
                    self.loadVoices()
                }
            }
        )
    }

    func cancelVoiceModelDownload() {
        voiceModelDownloadProcess?.terminate()
    }

    func loadVoices() {
        // Flip into loading state immediately so the UI shows "Loading…"
        // instead of a stale "Voices unavailable" while the Process call
        // is in flight. Common when called right after a model download.
        voicesLoading = true
        Task.detached(priority: .userInitiated) {
            let names = Self.runStackvoxVoices()
            await MainActor.run { [weak self] in
                self?.voicesAvailable = names
                self?.voicesLoading = false
            }
        }
    }

    private nonisolated static func runStackvoxVoices() -> [String] {
        // Invoke python3 with stackvox as a script argument rather than
        // executing the stackvox script directly. pip stamps an absolute
        // shebang at install time pointing at the build machine's python3
        // path — CI-built bundles end up with /Users/runner/... shebangs
        // that don't exist on user machines, so direct execution fails
        // with "bad interpreter". Calling python3 directly bypasses it.
        let venvBin = "\(NSHomeDirectory())/.stack-nudge/venv/bin"
        let python = "\(venvBin)/python3"
        let stackvox = "\(venvBin)/stackvox"
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.isReadableFile(atPath: stackvox)
        else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [stackvox, "voices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
    }

    // MARK: - Row movement

    func selectNextRow() {
        guard rowCount > 0 else { return }
        selectedSettingIndex = (selectedSettingIndex + 1) % rowCount
    }

    func selectPrevRow() {
        guard rowCount > 0 else { return }
        selectedSettingIndex = (selectedSettingIndex - 1 + rowCount) % rowCount
    }

    // ⌘↑/↓ — jump to the first / last settings row.
    func selectFirstRow() { guard rowCount > 0 else { return }; selectedSettingIndex = 0 }
    func selectLastRow()  { guard rowCount > 0 else { return }; selectedSettingIndex = rowCount - 1 }

    // MARK: - Cycle / activate

    // Enter: toggles flip, cycle rows step forward, actions fire, hotkey
    // row enters record mode.
    func activate() {
        switch selectedRow {
        case .wireAgents:    wireAllUnwiredAgents()
        case .dismissAgents: dismissAllUnwiredAgents()
        case .permissions: actions?.checkPermissions()
        case .update: actions?.beginUpdate()
        case .hotkey: startRecordingHotkey()
        case .speakHotkey: startRecordingSpeakHotkey()
        case .downloadVoiceModel:
            // The pre-download row is an action: Enter triggers (or cancels)
            // the model download.
            if voiceModelDownloading { cancelVoiceModelDownload() } else { startVoiceModelDownload() }
        case .disconnectGithub: disconnectGithub()
        case .editPhrases:      actions?.editPhrases()
        case .checkPermissions: actions?.checkPermissions()
        case .openConfig:       actions?.openConfig()
        case .releaseNotes:     actions?.openReleaseNotes()
        case .checkUpdates:     actions?.checkForUpdates()
        case .uninstall:        actions?.beginUninstall()
        case .quit:             actions?.quit()
        // Toggles + cycles flip/step on Enter, same as left/right.
        default: applyCycle(forward: true)
        }
    }

    func cycleForward()  { applyCycle(forward: true) }
    func cycleBackward() { applyCycle(forward: false) }

    // Whether ←/→ do anything on the selected row — mirrors applyCycle's no-op
    // branch so the Settings footer can dim the Cycle hint instead of
    // advertising a key the row ignores. Exhaustive over SettingsRow for the
    // same reason applyCycle is: a new row can't silently inherit a wrong hint.
    var selectedRowRespondsToArrows: Bool {
        switch selectedRow {
        case .wireAgents, .dismissAgents,
             .disconnectGithub, .editPhrases, .checkPermissions, .openConfig,
             .releaseNotes, .checkUpdates, .uninstall, .quit, .none:
            return false
        case .permissions, .update, .hotkey, .speakHotkey,
             .banner, .muteWhenFocused, .mute, .muteDuration, .pinPanel,
             .keepOpenWhenEmpty, .launchAtLogin,
             .widget, .widgetCorner, .widgetOpacity, .widgetContent, .mascot, .theme,
             .soundEnabled, .agentDoneSound, .permissionSound,
             .voiceEnabled, .voice, .voiceSpeed, .downloadVoiceModel,
             .quotaTracking, .quotaAlerts, .alertThreshold, .pollFrequency,
             .contextAlert, .showRemaining,
             .githubLinks, .hideShipped,
             .historyPerSession:
            return true
        }
    }

    // Shared by Settings row 11 and the Usage tab's 'p' keystroke. On
    // pause, drop the cached snapshot so the Usage tab doesn't sit on
    // stale data; on resume, the caller is responsible for kicking off
    // an immediate probe (so the user sees fresh data right after the
    // shortcut, not after the next scheduled tick).
    func toggleQuotaTracking() {
        quotaTrackingEnabled.toggle()
        ConfigFile.write(key: "STACKNUDGE_QUOTA_TRACKING",
                         value: quotaTrackingEnabled ? "true" : "false")
        if !quotaTrackingEnabled {
            quota = nil
            quotaLastUpdated = nil
            quotaError = nil
        }
    }

    func toggleKeepOpenWhenEmpty() {
        keepOpenWhenEmpty.toggle()
        ConfigFile.write(key: "STACKNUDGE_KEEP_OPEN_WHEN_EMPTY",
                         value: keepOpenWhenEmpty ? "true" : "false")
    }

    // Settings "GitHub PR links" toggle. Persists STACKNUDGE_GITHUB; on enable
    // kicks an immediate PR fetch so chips appear without waiting for the next
    // tab visit, on disable drops cached PR state so chips revert to the local
    // outcome.
    func toggleGithubLinking() {
        githubLinkingEnabled.toggle()
        ConfigFile.write(key: "STACKNUDGE_GITHUB",
                         value: githubLinkingEnabled ? "true" : "false")
        if githubLinkingEnabled {
            if githubSignedIn { refreshPullRequestsNow?() } else { startGithubSignIn?() }
        } else {
            pullRequestByBranch = [:]
            githubSignIn = .idle
        }
    }

    private func applyCycle(forward: Bool) {
        switch selectedRow {
        case .permissions:
            // Nothing to cycle — arrows open the Permissions window, like Enter.
            actions?.checkPermissions()
        case .update:
            // Nothing to cycle — arrows behave like Enter.
            actions?.beginUpdate()
        case .hotkey:
            // Cycle on the hotkey row also enters record mode.
            startRecordingHotkey()
        case .speakHotkey:
            startRecordingSpeakHotkey()
        case .banner:
            bannerEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_BANNER", value: bannerEnabled ? "true" : "false")
        case .muteWhenFocused:
            muteWhenFocused.toggle()
            ConfigFile.write(key: "STACKNUDGE_MUTE_WHEN_FOCUSED", value: muteWhenFocused ? "true" : "false")
        case .mute:
            // Action row: Enter and ←/→ both toggle the timed global mute.
            // Nothing persists — the controller owns the expiry timer + the
            // menu-bar badge (muteFor / resumeNotifications). Uses the current
            // default duration, same as the header bell and the M shortcut.
            if isMuted { actions?.resumeNotifications() } else { actions?.muteFor(muteDurationMinutes) }
        case .muteDuration:
            let list = Self.muteDurationOptions
            let idx = list.firstIndex(of: muteDurationMinutes) ?? 1
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            muteDurationMinutes = list[next]
            ConfigFile.write(key: "STACKNUDGE_MUTE_DURATION_MIN", value: String(muteDurationMinutes))
        case .pinPanel:
            panelPinned.toggle()
            ConfigFile.write(key: "STACKNUDGE_PANEL_PIN", value: panelPinned ? "true" : "false")
            // Pin + Widget: Pin wins. Toggling Pin on from the widget pill
            // should bring the full panel forward so the user sees what
            // they just pinned.
            if panelPinned, compactMode, !compactExpanded {
                compactExpanded = true
            }
        case .keepOpenWhenEmpty:
            toggleKeepOpenWhenEmpty()
        case .launchAtLogin:
            // Optimistic UI flip; revert if launchctl fails so the toggle
            // never reports a state that disagrees with the plist on disk.
            let target = !launchAtLogin
            launchAtLogin = target
            do {
                try Bootstrap.setLaunchAtLogin(target)
            } catch {
                launchAtLogin = !target
                FileHandle.standardError.write(Data(
                    "stack-nudge: setLaunchAtLogin(\(target)) failed: \(error)\n".utf8))
            }
        case .widget:
            // Widget on/off. On toggle-on we set compactExpanded so the panel
            // stays open at full size; the pill only appears when the user
            // dismisses. On toggle-off we clear it so the next layout commits
            // the saved full-panel frame cleanly.
            compactMode.toggle()
            ConfigFile.write(key: "STACKNUDGE_COMPACT_MODE",
                             value: compactMode ? "true" : "false")
            compactExpanded = compactMode
        case .widgetCorner:
            let list = CompactCorner.allCases
            let idx = list.firstIndex(of: compactCorner) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            compactCorner = list[next]
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CORNER", value: compactCorner.rawValue)
        case .widgetOpacity:
            let list = Self.compactAlphaOptions
            let idx = list.firstIndex(of: compactAlpha) ?? (list.count - 1)
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            compactAlpha = list[next]
            ConfigFile.write(key: "STACKNUDGE_COMPACT_ALPHA", value: String(format: "%.2f", compactAlpha))
        case .widgetContent:
            let list = CompactContent.allCases
            let idx = list.firstIndex(of: compactContent) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            compactContent = list[next]
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CONTENT", value: compactContent.rawValue)
        case .mascot:
            let list = MascotKind.allCases
            let idx = list.firstIndex(of: mascot) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            mascot = list[next]
            ConfigFile.write(key: "STACKNUDGE_MASCOT", value: mascot.rawValue)
        case .theme:
            let list = AccentTheme.allCases
            let idx = list.firstIndex(of: theme) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            theme = list[next]
            ConfigFile.write(key: "STACKNUDGE_THEME", value: theme.rawValue)
        case .soundEnabled:
            soundEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_SOUND", value: soundEnabled ? "true" : "false")
        case .agentDoneSound:
            soundStop = step(soundStop, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_STOP", preview: true)
        case .permissionSound:
            soundPermission = step(soundPermission, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_PERMISSION", preview: true)
        case .voiceEnabled:
            voiceEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_VOICE", value: voiceEnabled ? "true" : "false")
        case .voice:
            // Only reachable when the model is cached (otherwise the row is
            // .downloadVoiceModel), so there's no download branch here.
            guard !voicesLoading, !voicesAvailable.isEmpty else { return }
            voice = step(voice, in: voicesAvailable, forward: forward, key: "STACKNUDGE_VOICE_NAME", preview: false)
            let phrase = Self.voicePreviewPhrases.randomElement() ?? "Hello."
            Speaker.speak(phrase, voice: voice, speed: String(format: "%.2f", voiceSpeed))
        case .voiceSpeed:
            let next = forward ? voiceSpeed + Self.speedStep : voiceSpeed - Self.speedStep
            voiceSpeed = max(Self.speedMin, min(Self.speedMax, (next * 100).rounded() / 100))
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", voiceSpeed))
        case .downloadVoiceModel:
            // Arrow on the pre-download row triggers the download too.
            if !voiceModelDownloading { startVoiceModelDownload() }
        case .quotaTracking:
            toggleQuotaTracking()
        case .quotaAlerts:
            quotaAlertsEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_QUOTA_ALERTS", value: quotaAlertsEnabled ? "true" : "false")
        case .alertThreshold:
            let list = Self.quotaThresholds
            let idx = list.firstIndex(of: quotaAlertThreshold) ?? 2
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            quotaAlertThreshold = list[next]
            ConfigFile.write(key: "STACKNUDGE_QUOTA_THRESHOLD", value: String(quotaAlertThreshold))
        case .pollFrequency:
            let list = Self.quotaPollMinuteOptions
            let idx = list.firstIndex(of: quotaPollMinutes) ?? 2
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            quotaPollMinutes = list[next]
            ConfigFile.write(key: "STACKNUDGE_USAGE_POLL_MIN", value: String(quotaPollMinutes))
        case .contextAlert:
            let list = Self.contextAlertThresholdOptions
            let idx = list.firstIndex(of: contextAlertThresholdK) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            contextAlertThresholdK = list[next]
            ConfigFile.write(key: "STACKNUDGE_CONTEXT_ALERT_THRESHOLD", value: String(contextAlertThresholdK))
        case .showRemaining:
            quotaShowRemaining.toggle()
            ConfigFile.write(key: "STACKNUDGE_QUOTA_SHOW_REMAINING", value: quotaShowRemaining ? "true" : "false")
        case .githubLinks:
            toggleGithubLinking()
        case .hideShipped:
            toggleHideShipped()
        case .historyPerSession:
            let list = Self.eventsPerSessionOptions
            let idx = list.firstIndex(of: eventsPerSession) ?? 1
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            eventsPerSession = list[next]
            ConfigFile.write(key: "STACKNUDGE_EVENTS_PER_SESSION", value: String(eventsPerSession))
        // Action rows have nothing to cycle. The two banner rows deliberately
        // ignore arrows even though .permissions/.update act on them: Set up
        // rewrites agent hook configs and Not now persists a dismissal, so
        // neither should fire on an arrow-key graze. Enter/Space only.
        case .wireAgents, .dismissAgents,
             .disconnectGithub, .editPhrases, .checkPermissions, .openConfig,
             .releaseNotes, .checkUpdates, .uninstall, .quit, .none:
            break
        }
    }

    private func step(_ current: String, in list: [String], forward: Bool, key: String, preview: Bool) -> String {
        guard !list.isEmpty else { return current }
        let idx = list.firstIndex(of: current) ?? 0
        let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
        let value = list[next]
        ConfigFile.write(key: key, value: value)
        if preview { NSSound(named: NSSound.Name(value))?.play() }
        return value
    }

    // MARK: - Hotkey recording

    func startRecordingHotkey() {
        recordingHotkey = true
        hotkeyError = nil
    }

    func cancelRecordingHotkey() {
        recordingHotkey = false
    }

    func commitHotkey(_ spec: String) {
        // Try to register first; only persist if it took. Failing means the
        // combo was rejected by the OS (already-registered global, malformed,
        // etc.) — keep the previous one and surface a message to the user.
        guard let setHotkey, setHotkey(spec) else {
            hotkeyError = "‘\(spec)’ is unavailable — already bound by another app"
            recordingHotkey = false
            return
        }
        hotkeyError = nil
        hotkeyDisplay = spec
        ConfigFile.write(key: "STACKNUDGE_PANEL_HOTKEY", value: spec)
        recordingHotkey = false
    }

    func startRecordingSpeakHotkey() {
        recordingSpeakHotkey = true
        speakHotkeyError = nil
    }

    func cancelRecordingSpeakHotkey() {
        recordingSpeakHotkey = false
    }

    func commitSpeakHotkey(_ spec: String) {
        guard let setSpeakHotkey, setSpeakHotkey(spec) else {
            speakHotkeyError = "‘\(spec)’ is unavailable — already bound by another app"
            recordingSpeakHotkey = false
            return
        }
        speakHotkeyError = nil
        speakHotkeyDisplay = spec
        ConfigFile.write(key: "STACKNUDGE_SPEAK_HOTKEY", value: spec)
        recordingSpeakHotkey = false
    }
}
