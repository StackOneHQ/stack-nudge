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
struct SettingsActions {
    let checkPermissions: () -> Void
    let openConfig:       () -> Void
    let editPhrases:      () -> Void
    let beginUpdate:      () -> Void
    let runUpdate:        () -> Void
    let beginUninstall:   () -> Void
    let runUninstall:     () -> Void
    let runBootstrap:     () -> Void
    let quit:             () -> Void
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
    // Threshold-crossing notifications. quotaAlertsEnabled is the master
    // switch; quotaAlertThreshold is the single percent value used across
    // all tiers — banner fires once per period when any tier reaches it.
    @Published var quotaAlertsEnabled:  Bool = true
    @Published var quotaAlertThreshold: Int  = 80
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

    var rowCount: Int { 17 + updateRowOffset }

    // Row layout (kept in one place so the controller, view, and indexing
    // logic all agree on what each row index means). When updateAvailable
    // is non-nil, row 0 becomes "Update to vX.Y.Z" and every following row
    // shifts down by one — use `index - updateRowOffset` when matching:
    //   0  Hotkey                hotkey-record
    //   1  Banner notifications  toggle
    //   2  Voice notifications   toggle
    //   3  Mute when focused     toggle
    //   4  Pin panel             toggle
    //   5  Sound enabled         toggle      (gates rows 6 + 7)
    //   6  Agent done sound      cycle
    //   7  Permission sound      cycle
    //   8  Voice                 cycle       (or "Download model" action)
    //   9  Speed                 cycle
    //  10  Quota alerts          toggle
    //  11  Alert threshold       cycle
    //  12  Edit phrases…         action
    //  13  Check permissions…    action
    //  14  Open config file…     action
    //  15  Uninstall stack-nudge action
    //  16  Quit panel            action

    // MARK: - Disk I/O

    func loadFromConfig() {
        let config = ConfigFile.read()
        hotkeyDisplay   = config["STACKNUDGE_PANEL_HOTKEY"]    ?? "cmd+opt+n"
        bannerEnabled   = ConfigFile.bool(config, "STACKNUDGE_BANNER",    default: true)
        soundEnabled    = ConfigFile.bool(config, "STACKNUDGE_SOUND",     default: true)
        voiceEnabled    = ConfigFile.bool(config, "STACKNUDGE_VOICE",     default: false)
        muteWhenFocused = ConfigFile.bool(config, "STACKNUDGE_MUTE_WHEN_FOCUSED", default: true)
        panelPinned     = ConfigFile.bool(config, "STACKNUDGE_PANEL_PIN", default: true)
        soundStop       = config["STACKNUDGE_SOUND_STOP"]       ?? "Glass"
        soundPermission = config["STACKNUDGE_SOUND_PERMISSION"] ?? "Ping"
        voice           = config["STACKNUDGE_VOICE_NAME"]       ?? "af_aoede"
        voiceSpeed      = Double(config["STACKNUDGE_VOICE_SPEED"] ?? "") ?? 1.1
        quotaAlertsEnabled  = ConfigFile.bool(config, "STACKNUDGE_QUOTA_ALERTS", default: true)
        // Coerce out-of-list values to the nearest valid threshold so a
        // hand-edited config can't desync the cycle row's selection.
        let rawThreshold = Int(config["STACKNUDGE_QUOTA_THRESHOLD"] ?? "") ?? 80
        quotaAlertThreshold = Self.quotaThresholds.min(by: { abs($0 - rawThreshold) < abs($1 - rawThreshold) }) ?? 80
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
        let stackvox = "\(NSHomeDirectory())/.stack-nudge/venv/bin/stackvox"
        guard FileManager.default.isExecutableFile(atPath: stackvox) else { return [] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: stackvox)
        task.arguments = ["voices"]
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
        case 8 where !voiceModelCached:
            // Pre-download state: index 8 is the "Download voice model"
            // action, not a cycle. Enter triggers (or cancels) the
            // download.
            if voiceModelDownloading {
                cancelVoiceModelDownload()
            } else {
                startVoiceModelDownload()
            }
        case 12: actions?.editPhrases()
        case 13: actions?.checkPermissions()
        case 14: actions?.openConfig()
        case 15: actions?.beginUninstall()
        case 16: actions?.quit()
        default: applyCycle(forward: true)
        }
    }

    func cycleForward()  { applyCycle(forward: true) }
    func cycleBackward() { applyCycle(forward: false) }

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
            voiceEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_VOICE", value: voiceEnabled ? "true" : "false")
        case 3:
            muteWhenFocused.toggle()
            ConfigFile.write(key: "STACKNUDGE_MUTE_WHEN_FOCUSED", value: muteWhenFocused ? "true" : "false")
        case 4:
            panelPinned.toggle()
            ConfigFile.write(key: "STACKNUDGE_PANEL_PIN", value: panelPinned ? "true" : "false")
        case 5:
            soundEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_SOUND", value: soundEnabled ? "true" : "false")
        case 6:
            soundStop = step(soundStop, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_STOP", preview: true)
        case 7:
            soundPermission = step(soundPermission, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_PERMISSION", preview: true)
        case 8:
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
        case 9:
            let next = forward ? voiceSpeed + Self.speedStep : voiceSpeed - Self.speedStep
            voiceSpeed = max(Self.speedMin, min(Self.speedMax, (next * 100).rounded() / 100))
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", voiceSpeed))
        case 10:
            quotaAlertsEnabled.toggle()
            ConfigFile.write(key: "STACKNUDGE_QUOTA_ALERTS",
                             value: quotaAlertsEnabled ? "true" : "false")
        case 11:
            // Cycle through the static thresholds list. Index wraps in both
            // directions so the user can dial in either way.
            let list = Self.quotaThresholds
            let idx = list.firstIndex(of: quotaAlertThreshold) ?? 2
            let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
            quotaAlertThreshold = list[next]
            ConfigFile.write(key: "STACKNUDGE_QUOTA_THRESHOLD",
                             value: String(quotaAlertThreshold))
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
