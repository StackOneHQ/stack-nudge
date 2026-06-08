import AppKit
import SwiftUI

enum PanelMode {
    case events
    case sessions
    case usage
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
    @Published var bannerEnabled:   Bool = true
    @Published var soundEnabled:    Bool = true
    @Published var voiceEnabled:    Bool = false
    @Published var muteWhenFocused: Bool = true
    @Published var panelPinned:     Bool = true
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
    // Latest /api/oauth/usage snapshot. Driven by the QuotaProbe poller in
    // PanelController. nil before the first probe completes, or when the
    // probe failed (e.g. user denied keychain access, 401, 429).
    @Published var quota:            QuotaSnapshot?
    @Published var quotaLastUpdated: Date?
    // True while a probe is in-flight. Set by PanelController around the
    // fetch call so the UI can swap the footer status to "Syncing…".
    @Published var quotaSyncing:     Bool = false
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
    // Usage tab: which connected client's quota is shown (index into
    // availableUsageClients). ↑/↓ move it; read through clampedUsageClientIndex
    // so a client losing its data can't strand the selection out of range.
    @Published var usageClientIndex: Int = 0
    // When true, keyboard focus is inside the Usage detail pane: ↑/↓ scroll it
    // rather than switching client. →/Enter steps in; ←/Esc steps back out.
    @Published var usageDetailFocused: Bool = false

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
    @Published var mascot:        MascotKind = .robot
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

    // +1 when an update is available and the "Update to vX.Y.Z" row is
    // pinned at the top of the Settings list. All other indices shift down
    // when the offset is 1.
    var updateRowOffset: Int { updateAvailable != nil ? 1 : 0 }

    // 29 rows in the body: hotkey (1) + Toggles (4) + Widget (4) + Sounds (3)
    // + Voice (2 — Voice + Speed, or 1 Download row with an unused index 14)
    // + Usage (6) + Events (1) + Actions (7) = indices 0…28. Must be kept
    // in sync with the row(...) calls in Settings.swift and the case bodies
    // in applyCycle/activate; off-by-one here makes the last rows wrap to 0
    // on the down-arrow.
    var rowCount: Int { 29 + updateRowOffset }

    // Row layout (kept in one place so the controller, view, and indexing
    // logic all agree on what each row index means). When updateAvailable
    // is non-nil, row 0 becomes "Update to vX.Y.Z" and every following row
    // shifts down by one — use `index - updateRowOffset` when matching:
    //   0  Hotkey                hotkey-record
    //   1  Banner notifications  toggle
    //   2  Mute when focused     toggle
    //   3  Pin panel             toggle
    //   4  Launch at login       toggle
    //   5  Widget                toggle      (gates rows 6-8; off = classic show/hide-panel mode)
    //   6  Widget corner         cycle
    //   7  Mascot                cycle
    //   8  Widget opacity        cycle       (40/60/80/100%; applied window-level)
    //   9  Sound enabled         toggle      (gates rows 10 + 11)
    //  10  Agent done sound      cycle
    //  11  Permission sound      cycle
    //  12  Voice notifications   toggle      (gates rows 13 + 14)
    //  13  Voice                 cycle       (or "Download model" action)
    //  14  Speed                 cycle
    //  15  Quota tracking        toggle      (master; gates rows 16-18)
    //  16  Quota alerts          toggle
    //  17  Alert threshold       cycle
    //  18  Poll frequency        cycle
    //  19  Context alert at      cycle       (per-session token thresholds)
    //  20  Show remaining        toggle      (invert gauge readout: 70% left vs 30% used)
    //  21  Edit phrases…         action
    //  22  Check permissions…    action
    //  23  Open config file…     action
    //  24  View release notes…   action
    //  25  Check for updates…    action
    //  26  Uninstall stack-nudge action
    //  27  Quit panel            action

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
        bannerEnabled   = ConfigFile.bool(config, "STACKNUDGE_BANNER",    default: true)
        soundEnabled    = ConfigFile.bool(config, "STACKNUDGE_SOUND",     default: true)
        voiceEnabled    = ConfigFile.bool(config, "STACKNUDGE_VOICE",     default: false)
        muteWhenFocused = ConfigFile.bool(config, "STACKNUDGE_MUTE_WHEN_FOCUSED", default: true)
        panelPinned     = ConfigFile.bool(config, "STACKNUDGE_PANEL_PIN", default: true)
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
        mascot        = MascotKind(rawValue: config["STACKNUDGE_MASCOT"] ?? "") ?? .robot
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

    private static let dismissedAgentsPath =
        "\(NSHomeDirectory())/.stack-nudge/dismissed-agents.json"

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
        var next = (selectedSettingIndex + 1) % rowCount
        // When the voice model isn't cached we collapse Voice + Speed
        // into a single "Download voice model" action at index 7. Index 8
        // (Speed) doesn't render; skip it during keyboard nav.
        if !voiceModelCached, next - updateRowOffset == 9 {
            next = (next + 1) % rowCount
        }
        selectedSettingIndex = next
    }

    func selectPrevRow() {
        guard rowCount > 0 else { return }
        var prev = (selectedSettingIndex - 1 + rowCount) % rowCount
        if !voiceModelCached, prev - updateRowOffset == 9 {
            prev = (prev - 1 + rowCount) % rowCount
        }
        selectedSettingIndex = prev
    }

    // MARK: - Cycle / activate

    // Enter: toggles flip, cycle rows step forward, actions fire, hotkey
    // row enters record mode.
    func activate() {
        if updateRowOffset == 1, selectedSettingIndex == 0 {
            actions?.beginUpdate()
            return
        }
        switch selectedSettingIndex - updateRowOffset {
        case 0: startRecordingHotkey()
        case 11 where !voiceModelCached:
            // Pre-download state: index 11 is the "Download voice model"
            // action, not a cycle. Enter triggers (or cancels) the
            // download.
            if voiceModelDownloading {
                cancelVoiceModelDownload()
            } else {
                startVoiceModelDownload()
            }
        case 22: actions?.editPhrases()
        case 23: actions?.checkPermissions()
        case 24: actions?.openConfig()
        case 25: actions?.openReleaseNotes()
        case 26: actions?.checkForUpdates()
        case 27: actions?.beginUninstall()
        case 28: actions?.quit()
        default: applyCycle(forward: true)
        }
    }

    func cycleForward()  { applyCycle(forward: true) }
    func cycleBackward() { applyCycle(forward: false) }

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
        }
    }

    private func applyCycle(forward: Bool) {
        // Update row (when present at index 0) treats left/right arrows the
        // same as Enter — there's nothing to cycle, so just begin update.
        if updateRowOffset == 1, selectedSettingIndex == 0 {
            actions?.beginUpdate()
            return
        }
        switch selectedSettingIndex - updateRowOffset {
        case 0:
            // Cycle on the hotkey row also enters record mode.
            startRecordingHotkey()
        case 1:
            bannerEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_BANNER", value: bannerEnabled ? "true" : "false")
        case 2:
            muteWhenFocused.toggle()
            ConfigFile.write(key: "STACKNUDGE_MUTE_WHEN_FOCUSED", value: muteWhenFocused ? "true" : "false")
        case 3:
            panelPinned.toggle()
            ConfigFile.write(key: "STACKNUDGE_PANEL_PIN", value: panelPinned ? "true" : "false")
            // Pin + Widget: Pin wins. Toggling Pin on from the widget pill
            // should bring the full panel forward so the user sees what
            // they just pinned.
            if panelPinned, compactMode, !compactExpanded {
                compactExpanded = true
            }
        case 4:
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
        case 5:
            // Widget on/off. The user is in the full panel (that's where
            // the Settings row lives). On toggle-on we set compactExpanded
            // so the panel stays open at full size; the pill only appears
            // when the user dismisses (Esc / focus-out). On toggle-off we
            // clear compactExpanded so the next applyCompactLayout commits
            // the saved full-panel frame cleanly.
            compactMode.toggle()
            ConfigFile.write(key: "STACKNUDGE_COMPACT_MODE",
                             value: compactMode ? "true" : "false")
            if compactMode {
                compactExpanded = true
            } else {
                compactExpanded = false
            }
        case 6:
            let list = CompactCorner.allCases
            let idx = list.firstIndex(of: compactCorner) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            compactCorner = list[next]
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CORNER",
                             value: compactCorner.rawValue)
        case 7:
            let list = Self.compactAlphaOptions
            let idx = list.firstIndex(of: compactAlpha) ?? (list.count - 1)
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            compactAlpha = list[next]
            ConfigFile.write(key: "STACKNUDGE_COMPACT_ALPHA",
                             value: String(format: "%.2f", compactAlpha))
        case 8:
            let list = MascotKind.allCases
            let idx = list.firstIndex(of: mascot) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            mascot = list[next]
            ConfigFile.write(key: "STACKNUDGE_MASCOT", value: mascot.rawValue)
        case 9:
            soundEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_SOUND", value: soundEnabled ? "true" : "false")
        case 10:
            soundStop = step(soundStop, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_STOP", preview: true)
        case 11:
            soundPermission = step(soundPermission, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_PERMISSION", preview: true)
        case 12:
            voiceEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_VOICE", value: voiceEnabled ? "true" : "false")
        case 13:
            // Pre-download: the row is an action, not a cycle. Treat
            // left/right arrow as a trigger so a user discovering the
            // row keyboard-only can still start the download.
            if !voiceModelCached {
                if !voiceModelDownloading { startVoiceModelDownload() }
                return
            }
            guard !voicesLoading, !voicesAvailable.isEmpty else { return }
            voice = step(voice, in: voicesAvailable, forward: forward, key: "STACKNUDGE_VOICE_NAME", preview: false)
            let phrase = Self.voicePreviewPhrases.randomElement() ?? "Hello."
            Speaker.speak(phrase, voice: voice, speed: String(format: "%.2f", voiceSpeed))
        case 14:
            let next = forward ? voiceSpeed + Self.speedStep : voiceSpeed - Self.speedStep
            voiceSpeed = max(Self.speedMin, min(Self.speedMax, (next * 100).rounded() / 100))
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", voiceSpeed))
        case 15:
            toggleQuotaTracking()
        case 16:
            quotaAlertsEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_QUOTA_ALERTS",
                             value: quotaAlertsEnabled ? "true" : "false")
        case 17:
            // Cycle through the static thresholds list. Index wraps in both
            // directions so the user can dial in either way.
            let list = Self.quotaThresholds
            let idx = list.firstIndex(of: quotaAlertThreshold) ?? 2
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            quotaAlertThreshold = list[next]
            ConfigFile.write(key: "STACKNUDGE_QUOTA_THRESHOLD",
                             value: String(quotaAlertThreshold))
        case 18:
            let list = Self.quotaPollMinuteOptions
            let idx = list.firstIndex(of: quotaPollMinutes) ?? 2
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            quotaPollMinutes = list[next]
            ConfigFile.write(key: "STACKNUDGE_USAGE_POLL_MIN",
                             value: String(quotaPollMinutes))
        case 19:
            let list = Self.contextAlertThresholdOptions
            let idx = list.firstIndex(of: contextAlertThresholdK) ?? 0
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            contextAlertThresholdK = list[next]
            ConfigFile.write(key: "STACKNUDGE_CONTEXT_ALERT_THRESHOLD",
                             value: String(contextAlertThresholdK))
        case 20:
            quotaShowRemaining.toggle()
            ConfigFile.write(key: "STACKNUDGE_QUOTA_SHOW_REMAINING",
                             value: quotaShowRemaining ? "true" : "false")
        case 21:
            let list = Self.eventsPerSessionOptions
            let idx = list.firstIndex(of: eventsPerSession) ?? 1
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            eventsPerSession = list[next]
            ConfigFile.write(key: "STACKNUDGE_EVENTS_PER_SESSION",
                             value: String(eventsPerSession))
        default:
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
}
