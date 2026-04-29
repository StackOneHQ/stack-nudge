import AppKit
import SwiftUI

enum PanelMode {
    case events
    case sessions
    case settings
}

// Action callbacks the controller wires into nav so settings rows like
// "Check permissions" / "Open config" / "Quit" can fire effects without the
// SwiftUI view needing to know about windows or app-level state.
struct SettingsActions {
    let checkPermissions: () -> Void
    let openConfig:       () -> Void
    let quit:             () -> Void
}

enum SettingsKind {
    case toggle, cycle, action
}

private struct SettingsItem {
    let id: Int
    let label: String
    let kind: SettingsKind
    let value: String      // "On"/"Off" for toggles, current value for cycle, "" for action
}

// PanelNav owns navigation state and settings state. The controller drives
// it directly from key events; the view is a pure renderer.
final class PanelNav: ObservableObject {

    @Published var mode: PanelMode = .events
    @Published var selectedSettingIndex: Int = 0

    @Published var hotkeyDisplay:   String = "cmd+opt+n"
    @Published var recordingHotkey: Bool = false
    @Published var hotkeyError:     String?
    @Published var bannerEnabled:   Bool = true
    @Published var voiceEnabled:    Bool = false
    @Published var soundStop:       String = "Glass"
    @Published var soundPermission: String = "Ping"
    @Published var voice:           String = "af_heart"
    @Published var voiceSpeed:      Double = 1.1
    @Published var voicesAvailable: [String] = []
    @Published var voicesLoading:   Bool = true

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

    var rowCount: Int { 10 }

    // Row layout (kept in one place so the controller, view, and indexing
    // logic all agree on what each row index means):
    //   0  Hotkey                hotkey-record
    //   1  Banner notifications  toggle
    //   2  Voice notifications   toggle
    //   3  Agent done sound      cycle
    //   4  Permission sound      cycle
    //   5  Voice                 cycle
    //   6  Speed                 cycle
    //   7  Check permissions…    action
    //   8  Open config file…     action
    //   9  Quit panel            action

    // MARK: - Disk I/O

    func loadFromConfig() {
        let config = ConfigFile.read()
        hotkeyDisplay   = config["STACKNUDGE_PANEL_HOTKEY"]    ?? "cmd+shift+n"
        bannerEnabled   = ConfigFile.bool(config, "STACKNUDGE_BANNER", default: true)
        voiceEnabled    = ConfigFile.bool(config, "STACKNUDGE_VOICE",  default: false)
        soundStop       = config["STACKNUDGE_SOUND_STOP"]       ?? "Glass"
        soundPermission = config["STACKNUDGE_SOUND_PERMISSION"] ?? "Ping"
        voice           = config["STACKNUDGE_VOICE_NAME"]       ?? "af_heart"
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

    // ←/→: toggles flip, cycle rows step, actions are no-op.
    func cycleForward()  { applyCycle(forward: true) }
    func cycleBackward() { applyCycle(forward: false) }

    // Enter: toggles flip, cycle rows step forward, actions fire, hotkey
    // row enters record mode.
    func activate() {
        switch selectedSettingIndex {
        case 0: startRecordingHotkey()
        case 7: actions?.checkPermissions()
        case 8: actions?.openConfig()
        case 9: actions?.quit()
        default: applyCycle(forward: true)
        }
    }

    private func applyCycle(forward: Bool) {
        switch selectedSettingIndex {
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
            soundStop = step(soundStop, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_STOP", preview: true)
        case 4:
            soundPermission = step(soundPermission, in: Self.macSounds, forward: forward, key: "STACKNUDGE_SOUND_PERMISSION", preview: true)
        case 5:
            guard !voicesLoading, !voicesAvailable.isEmpty else { return }
            voice = step(voice, in: voicesAvailable, forward: forward, key: "STACKNUDGE_VOICE_NAME", preview: false)
        case 6:
            let next = forward ? voiceSpeed + Self.speedStep : voiceSpeed - Self.speedStep
            voiceSpeed = max(Self.speedMin, min(Self.speedMax, (next * 100).rounded() / 100))
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", voiceSpeed))
        default:
            break
        }
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

    private func step(_ current: String, in list: [String], forward: Bool, key: String, preview: Bool) -> String {
        guard !list.isEmpty else { return current }
        let idx = list.firstIndex(of: current) ?? 0
        let next = forward ? (idx + 1) % list.count : (idx - 1 + list.count) % list.count
        let value = list[next]
        ConfigFile.write(key: key, value: value)
        if preview { NSSound(named: NSSound.Name(value))?.play() }
        return value
    }
}

struct SettingsView: View {

    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Hotkey") {
                            row(0, label: "Panel shortcut",
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
                            row(1, label: "Banner notifications", kind: .toggle, value: nav.bannerEnabled ? "On" : "Off")
                            row(2, label: "Voice notifications",  kind: .toggle, value: nav.voiceEnabled  ? "On" : "Off")
                        }

                        section("Sounds") {
                            row(3, label: "Agent done", kind: .cycle, value: nav.soundStop)
                            row(4, label: "Permission", kind: .cycle, value: nav.soundPermission)
                        }

                        section("Voice") {
                            row(5, label: "Voice",  kind: .cycle, value: voiceLabel)
                            row(6, label: "Speed",  kind: .cycle, value: String(format: "%.2f×", nav.voiceSpeed))
                        }

                        section("Actions") {
                            row(7, label: "Check permissions…", kind: .action, value: "")
                            row(8, label: "Open config file…",  kind: .action, value: "")
                            row(9, label: "Quit panel",         kind: .action, value: "")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .onChange(of: nav.selectedSettingIndex) { newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            nav.loadFromConfig()
            if nav.voicesAvailable.isEmpty { nav.loadVoices() }
        }
    }

    private var voiceLabel: String {
        if nav.voicesLoading { return "Loading…" }
        if nav.voicesAvailable.isEmpty { return "Voices unavailable" }
        return nav.voice
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Image(systemName: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            FooterHint(label: "Move",   keys: ["↑", "↓"])
            FooterHint(label: "Cycle",  keys: ["←", "→"])
            FooterHint(label: "Act",    keys: ["⏎"])
            FooterHint(label: "Back",   keys: ["esc"])
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
    private func row(_ index: Int, label: String, kind: SettingsKind, value: String) -> some View {
        SettingsRowView(
            label: label,
            value: value,
            kind: kind,
            selected: nav.selectedSettingIndex == index
        )
        .id(index)
        .onTapGesture {
            nav.selectedSettingIndex = index
            // For actions, single-click is enough. For toggles/cycles a click
            // on the row also acts so mouse users don't have to keyboard.
            if kind == .action || kind == .toggle {
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
        case .action:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
