import AppKit

// The options of a value row, in one place for both ways of changing it: the
// arrow keys step through them, and a click opens them as a menu to pick from.
// A row with ten options is one click away from any of them, not ten.
struct SettingChoices {
    let labels: [String]
    // Index of the current value; nil when it isn't one of the options
    // (a hand-edited config), in which case nothing is ticked.
    let current: Int?
    // Where an arrow starts from when the current value isn't in the list.
    let fallback: Int
    let pick: (Int) -> Void

    func step(forward: Bool) {
        guard !labels.isEmpty else { return }
        let idx = current ?? fallback
        pick(forward ? (idx + 1) % labels.count : (idx - 1 + labels.count) % labels.count)
    }
}

extension PanelNav {

    // nil for rows that aren't a list: toggles, actions, the hotkey recorders,
    // and the ranges (voice speed, pi budgets), which keep stepping by arrow.
    func choices(for row: SettingsRow) -> SettingChoices? {
        switch row {
        case .muteDuration:
            return list(Self.muteDurationOptions, current: muteDurationMinutes, fallback: 1, label: { "\($0) min" }) {
                self.muteDurationMinutes = $0
                ConfigFile.write(key: "STACKNUDGE_MUTE_DURATION_MIN", value: String($0))
            }
        case .remindUnanswered:
            return list(AttentionPolicy.reminderMinuteOptions, current: remindMinutes, label: AttentionPolicy.minuteLabel) {
                self.remindMinutes = $0
                ConfigFile.write(key: "STACKNUDGE_REMIND_MIN", value: String($0))
            }
        case .stalledSessions:
            return list(AttentionPolicy.stalledMinuteOptions, current: stalledMinutes, label: AttentionPolicy.minuteLabel) {
                self.stalledMinutes = $0
                ConfigFile.write(key: "STACKNUDGE_STALLED_MIN", value: String($0))
                // Clearing the threshold must clear the flags too — nothing else
                // recomputes them once the tick stops evaluating.
                if $0 == 0 { self.stalledSessionKeys = [] }
            }
        case .widgetCorner:
            return list(CompactCorner.allCases, current: compactCorner, label: \.label) {
                self.compactCorner = $0
                ConfigFile.write(key: "STACKNUDGE_COMPACT_CORNER", value: $0.rawValue)
            }
        case .widgetOpacity:
            let options = Self.compactAlphaOptions
            return list(options, current: compactAlpha, fallback: options.count - 1, label: { "\(Int($0 * 100))%" }) {
                self.compactAlpha = $0
                ConfigFile.write(key: "STACKNUDGE_COMPACT_ALPHA", value: String(format: "%.2f", $0))
            }
        case .widgetContent:
            return list(CompactContent.allCases, current: compactContent, label: \.label) {
                self.compactContent = $0
                ConfigFile.write(key: "STACKNUDGE_COMPACT_CONTENT", value: $0.rawValue)
            }
        case .mascot:
            return list(MascotKind.allCases, current: mascot, label: \.label) {
                self.mascot = $0
                ConfigFile.write(key: "STACKNUDGE_MASCOT", value: $0.rawValue)
            }
        case .theme:
            return list(AccentTheme.allCases, current: theme, label: \.label) {
                self.theme = $0
                ConfigFile.write(key: "STACKNUDGE_THEME", value: $0.rawValue)
            }
        case .agentDoneSound:
            return list(Self.macSounds, current: soundStop, label: { $0 }) {
                self.soundStop = $0
                ConfigFile.write(key: "STACKNUDGE_SOUND_STOP", value: $0)
                NSSound(named: NSSound.Name($0))?.play()
            }
        case .permissionSound:
            return list(Self.macSounds, current: soundPermission, label: { $0 }) {
                self.soundPermission = $0
                ConfigFile.write(key: "STACKNUDGE_SOUND_PERMISSION", value: $0)
                NSSound(named: NSSound.Name($0))?.play()
            }
        case .voice:
            // Only reachable when the model is cached (otherwise the row is
            // .downloadVoiceModel); nothing to offer while voices load.
            guard !voicesLoading, !voicesAvailable.isEmpty else { return nil }
            return list(voicesAvailable, current: voice, label: { $0 }) {
                self.voice = $0
                ConfigFile.write(key: "STACKNUDGE_VOICE_NAME", value: $0)
                let phrase = Self.voicePreviewPhrases.randomElement() ?? "Hello."
                Speaker.speak(phrase, voice: $0, speed: String(format: "%.2f", self.voiceSpeed))
            }
        case .alertThreshold:
            return list(Self.quotaThresholds, current: quotaAlertThreshold, fallback: 2, label: { "\($0)%" }) {
                self.quotaAlertThreshold = $0
                ConfigFile.write(key: "STACKNUDGE_QUOTA_THRESHOLD", value: String($0))
            }
        case .pollFrequency:
            return list(Self.quotaPollMinuteOptions, current: quotaPollMinutes, fallback: 2, label: { "\($0) min" }) {
                self.quotaPollMinutes = $0
                ConfigFile.write(key: "STACKNUDGE_USAGE_POLL_MIN", value: String($0))
            }
        case .contextAlert:
            return list(Self.contextAlertThresholdOptions, current: contextAlertThresholdK,
                        label: { $0 == 0 ? "Off" : "\($0)K" }) {
                self.contextAlertThresholdK = $0
                ConfigFile.write(key: "STACKNUDGE_CONTEXT_ALERT_THRESHOLD", value: String($0))
            }
        case .slackIdle:
            return list(SlackDelivery.idleMinuteOptions, current: slackIdleMinutes, fallback: 1,
                        label: SlackDelivery.idleLabel) {
                self.slackIdleMinutes = $0
                ConfigFile.write(key: "STACKNUDGE_SLACK_IDLE_MIN", value: String($0))
            }
        case .historyPerSession:
            return list(Self.eventsPerSessionOptions, current: eventsPerSession, fallback: 1, label: { "\($0)" }) {
                self.eventsPerSession = $0
                ConfigFile.write(key: "STACKNUDGE_EVENTS_PER_SESSION", value: String($0))
            }
        case .updateChannel:
            return list(UpdateChannel.allCases, current: updateChannel, label: \.label) {
                self.setUpdateChannel($0)
            }
        default:
            return nil
        }
    }

    private func list<T: Equatable>(_ options: [T], current: T, fallback: Int = 0,
                                    label: (T) -> String, set: @escaping (T) -> Void) -> SettingChoices {
        SettingChoices(labels: options.map(label), current: options.firstIndex(of: current),
                       fallback: fallback, pick: { set(options[$0]) })
    }
}

// The click side: a value row's options as a menu at the pointer, the current
// one ticked. NSMenu rather than a SwiftUI Menu so the row keeps its look and
// the whole row, not just the value, opens it.
enum SettingChoicesMenu {
    static func show(_ choices: SettingChoices) {
        let menu = NSMenu()
        let targets = choices.labels.indices.map { index in ChoiceTarget { choices.pick(index) } }
        for (index, label) in choices.labels.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(ChoiceTarget.fire), keyEquivalent: "")
            item.target = targets[index]
            item.state = index == choices.current ? .on : .off
            menu.addItem(item)
        }
        // popUp blocks until the menu closes, which keeps `targets` alive for
        // as long as an item can still fire.
        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class ChoiceTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
