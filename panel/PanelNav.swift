import AppKit
import SwiftUI

enum PanelMode {
    case events
    case sessions
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
    @Published var voiceEnabled:    Bool = false
    @Published var muteWhenFocused: Bool = true
    @Published var panelPinned:     Bool = true
    @Published var welcomed:        Bool = true  // default true; install creates a fresh config without it set
    @Published var soundStop:       String = "Glass"
    @Published var soundPermission: String = "Ping"
    @Published var voice:           String = "af_aoede"
    @Published var voiceSpeed:      Double = 1.1
    @Published var voicesAvailable: [String] = []
    @Published var voicesLoading:   Bool = true
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

    var actions: SettingsActions?
    // Wired by PanelController so nav can re-register the global hotkey
    // without owning the Hotkey instance directly. Returns true if the
    // new spec registered successfully.
    var setHotkey: ((String) -> Bool)?

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

    var rowCount: Int { 13 + updateRowOffset }

    // Row layout (kept in one place so the controller, view, and indexing
    // logic all agree on what each row index means). When updateAvailable
    // is non-nil, row 0 becomes "Update to vX.Y.Z" and every following row
    // shifts down by one — use `index - updateRowOffset` when matching:
    //   0  Hotkey                hotkey-record
    //   1  Banner notifications  toggle
    //   2  Voice notifications   toggle
    //   3  Mute when focused     toggle
    //   4  Pin panel             toggle
    //   5  Agent done sound      cycle
    //   6  Permission sound      cycle
    //   7  Voice                 cycle
    //   8  Speed                 cycle
    //   9  Edit phrases…         action
    //  10  Check permissions…    action
    //  11  Open config file…     action
    //  12  Quit panel            action

    // MARK: - Disk I/O

    func loadFromConfig() {
        let config = ConfigFile.read()
        hotkeyDisplay   = config["STACKNUDGE_PANEL_HOTKEY"]    ?? "cmd+opt+n"
        bannerEnabled   = ConfigFile.bool(config, "STACKNUDGE_BANNER",    default: true)
        voiceEnabled    = ConfigFile.bool(config, "STACKNUDGE_VOICE",     default: false)
        muteWhenFocused = ConfigFile.bool(config, "STACKNUDGE_MUTE_WHEN_FOCUSED", default: true)
        panelPinned     = ConfigFile.bool(config, "STACKNUDGE_PANEL_PIN", default: true)
        // Default false on first run so the welcome view shows. We also write
        // STACKNUDGE_WELCOMED=true the first time the user dismisses it.
        welcomed        = ConfigFile.bool(config, "STACKNUDGE_WELCOMED", default: false)
        soundStop       = config["STACKNUDGE_SOUND_STOP"]       ?? "Glass"
        soundPermission = config["STACKNUDGE_SOUND_PERMISSION"] ?? "Ping"
        voice           = config["STACKNUDGE_VOICE_NAME"]       ?? "af_aoede"
        voiceSpeed      = Double(config["STACKNUDGE_VOICE_SPEED"] ?? "") ?? 1.1
    }

    func loadVoices() {
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

    // MARK: - Welcome

    func dismissWelcome() {
        welcomed = true
        ConfigFile.write(key: "STACKNUDGE_WELCOMED", value: "true")
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
        case 9:  actions?.editPhrases()
        case 10: actions?.checkPermissions()
        case 11: actions?.openConfig()
        case 12: actions?.quit()
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
            soundStop = step(soundStop, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_STOP", preview: true)
        case 6:
            soundPermission = step(soundPermission, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_PERMISSION", preview: true)
        case 7:
            guard !voicesLoading, !voicesAvailable.isEmpty else { return }
            voice = step(voice, in: voicesAvailable, forward: forward, key: "STACKNUDGE_VOICE_NAME", preview: false)
            let phrase = Self.voicePreviewPhrases.randomElement() ?? "Hello."
            Speaker.speak(phrase, voice: voice, speed: String(format: "%.2f", voiceSpeed))
        case 8:
            let next = forward ? voiceSpeed + Self.speedStep : voiceSpeed - Self.speedStep
            voiceSpeed = max(Self.speedMin, min(Self.speedMax, (next * 100).rounded() / 100))
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", voiceSpeed))
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
