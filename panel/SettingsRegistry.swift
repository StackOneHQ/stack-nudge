import Foundation

// One entry per STACKNUDGE_* setting an MCP client may see: its key, how
// Settings labels and groups it, the values it takes, and how to read it from
// nav. The panel's rows keep their own drawing; this is the machine-readable
// view of the same values (docs/design/local-mcp.md, "Writes").
//
// Secrets never appear: the Slack and GitHub tokens live in the Keychain and
// aren't settings, and the Slack member ID is reported as set or not only.
struct SettingSpec {

    enum Kind {
        case toggle
        case choice([String])
        case integer([Int])
        case number(min: Double, max: Double, step: Double)
        case text
    }

    let key: String
    let label: String
    // SettingsCategory's sidebar name, lowercased.
    let category: String
    let kind: Kind
    let read: (PanelNav) -> SettingValue
    // Why an MCP client may never change it. nil means it may.
    var readOnlyReason: String? = nil
}

enum SettingValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var json: Any {
        switch self {
        case .bool(let value):   return value
        case .int(let value):    return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }
}

// A setting as listed to a client: the spec's description and its value now.
struct SettingSnapshot: Equatable {
    let key: String
    let label: String
    let category: String
    let value: SettingValue
    let kindJSON: [String: AnyHashable]
    let readOnlyReason: String?

    var json: [String: Any] {
        var entry: [String: Any] = ["key": key, "label": label, "category": category,
                                    "value": value.json, "writable": readOnlyReason == nil]
        for (name, value) in kindJSON { entry[name] = value }
        if let readOnlyReason { entry["readOnlyReason"] = readOnlyReason }
        return entry
    }
}

enum SettingsRegistry {

    // Settings an agent must never be able to change: each stops a permission
    // prompt reaching you, or would let a client widen its own reach.
    static let protectsPrompts = "Protects how permission prompts reach you. Change it in Settings."
    static let panelOnly = "Recorded by pressing the shortcut in Settings."
    static let protectsLock = "Part of locking the screen when you're away. Change it in Settings."

    static func snapshot(_ nav: PanelNav) -> [SettingSnapshot] {
        specs.map { spec in
            SettingSnapshot(key: spec.key, label: spec.label, category: spec.category,
                            value: spec.read(nav), kindJSON: kindJSON(spec.kind),
                            readOnlyReason: spec.readOnlyReason)
        }
    }

    static func spec(_ key: String) -> SettingSpec? {
        specs.first { $0.key == key }
    }

    static var categories: [String] {
        var seen = Set<String>()
        return specs.map(\.category).filter { seen.insert($0).inserted }
    }

    static func kindJSON(_ kind: SettingSpec.Kind) -> [String: AnyHashable] {
        switch kind {
        case .toggle:
            return ["type": "boolean"]
        case .choice(let options):
            return ["type": "string", "options": options]
        case .integer(let options):
            return ["type": "integer", "options": options]
        case .number(let min, let max, let step):
            return ["type": "number", "minimum": min, "maximum": max, "step": step]
        case .text:
            return ["type": "string"]
        }
    }

    // In Settings' order: by category, then as each page lists them.
    static let specs: [SettingSpec] = [
        // Notifications
        SettingSpec(key: "STACKNUDGE_BANNER", label: "Banner notifications", category: "notifications",
                    kind: .toggle, read: { .bool($0.bannerEnabled) }, readOnlyReason: protectsPrompts),
        SettingSpec(key: "STACKNUDGE_MUTE_WHEN_FOCUSED", label: "Mute when focused", category: "notifications",
                    kind: .toggle, read: { .bool($0.muteWhenFocused) }, readOnlyReason: protectsPrompts),
        SettingSpec(key: "STACKNUDGE_MUTE_DURATION_MIN", label: "Mute duration (minutes)", category: "notifications",
                    kind: .integer(PanelNav.muteDurationOptions), read: { .int($0.muteDurationMinutes) }),
        SettingSpec(key: "STACKNUDGE_REMIND_MIN", label: "Remind unanswered (minutes)", category: "notifications",
                    kind: .integer(AttentionPolicy.reminderMinuteOptions), read: { .int($0.remindMinutes) },
                    readOnlyReason: protectsPrompts),
        SettingSpec(key: "STACKNUDGE_STALLED_MIN", label: "Flag stalled after (minutes, 0 is off)", category: "notifications",
                    kind: .integer(AttentionPolicy.stalledMinuteOptions), read: { .int($0.stalledMinutes) }),
        SettingSpec(key: "STACKNUDGE_SOUND", label: "Sound enabled", category: "notifications",
                    kind: .toggle, read: { .bool($0.soundEnabled) }),
        SettingSpec(key: "STACKNUDGE_SOUND_STOP", label: "Agent done sound", category: "notifications",
                    kind: .choice(PanelNav.macSounds), read: { .string($0.soundStop) }),
        SettingSpec(key: "STACKNUDGE_SOUND_PERMISSION", label: "Permission sound", category: "notifications",
                    kind: .choice(PanelNav.macSounds), read: { .string($0.soundPermission) }),
        // Voice
        SettingSpec(key: "STACKNUDGE_VOICE", label: "Voice notifications", category: "voice",
                    kind: .toggle, read: { .bool($0.voiceEnabled) }),
        SettingSpec(key: "STACKNUDGE_VOICE_NAME", label: "Voice", category: "voice",
                    kind: .text, read: { .string($0.voice) }),
        SettingSpec(key: "STACKNUDGE_VOICE_SPEED", label: "Speed", category: "voice",
                    kind: .number(min: PanelNav.speedMin, max: PanelNav.speedMax, step: PanelNav.speedStep),
                    read: { .double($0.voiceSpeed) }),
        SettingSpec(key: "STACKNUDGE_SPEAK_HOTKEY", label: "Speak shortcut", category: "voice",
                    kind: .text, read: { .string($0.speakHotkeyDisplay) }, readOnlyReason: panelOnly),
        // Appearance
        SettingSpec(key: "STACKNUDGE_FLOATING_WIDGET", label: "Floating widget", category: "appearance",
                    kind: .choice(FloatingWidget.allCases.map(\.rawValue)), read: { .string($0.floatingWidget.rawValue) }),
        SettingSpec(key: "STACKNUDGE_COMPACT_SNAP", label: "Snap to corners", category: "appearance",
                    kind: .toggle, read: { .bool($0.compactSnap) }),
        SettingSpec(key: "STACKNUDGE_COMPACT_CORNER", label: "Widget corner", category: "appearance",
                    kind: .choice(CompactCorner.allCases.map(\.rawValue)), read: { .string($0.compactCorner.rawValue) }),
        SettingSpec(key: "STACKNUDGE_COMPACT_ALPHA", label: "Widget opacity", category: "appearance",
                    kind: .number(min: 0.4, max: 1.0, step: 0.2), read: { .double($0.compactAlpha) }),
        SettingSpec(key: "STACKNUDGE_COMPACT_CONTENT", label: "Widget type", category: "appearance",
                    kind: .choice(CompactContent.allCases.map(\.rawValue)), read: { .string($0.compactContent.rawValue) }),
        SettingSpec(key: "STACKNUDGE_MASCOT", label: "Mascot", category: "appearance",
                    kind: .choice(MascotKind.allCases.map(\.rawValue)), read: { .string($0.mascot.rawValue) }),
        SettingSpec(key: "STACKNUDGE_THEME", label: "Accent color", category: "appearance",
                    kind: .choice(AccentTheme.allCases.map(\.rawValue)), read: { .string($0.theme.rawValue) }),
        // Companion
        SettingSpec(key: "STACKNUDGE_COMPANION_SIZE", label: "Size", category: "companion",
                    kind: .choice(CompanionSize.allCases.map(\.rawValue)), read: { .string($0.companionSize.rawValue) }),
        SettingSpec(key: "STACKNUDGE_COMPANION_BADGE", label: "Count badge", category: "companion",
                    kind: .toggle, read: { .bool($0.companionBadge) }),
        // Usage
        SettingSpec(key: "STACKNUDGE_QUOTA_TRACKING", label: "Quota tracking", category: "usage",
                    kind: .toggle, read: { .bool($0.quotaTrackingEnabled) }),
        SettingSpec(key: "STACKNUDGE_QUOTA_ALERTS", label: "Quota alerts", category: "usage",
                    kind: .toggle, read: { .bool($0.quotaAlertsEnabled) }),
        SettingSpec(key: "STACKNUDGE_QUOTA_THRESHOLD", label: "Alert threshold (%)", category: "usage",
                    kind: .integer(PanelNav.quotaThresholds), read: { .int($0.quotaAlertThreshold) }),
        SettingSpec(key: "STACKNUDGE_USAGE_POLL_MIN", label: "Poll frequency (minutes)", category: "usage",
                    kind: .integer(PanelNav.quotaPollMinuteOptions), read: { .int($0.quotaPollMinutes) }),
        SettingSpec(key: "STACKNUDGE_CONTEXT_ALERT_THRESHOLD", label: "Context alert at (thousand tokens, 0 is off)",
                    category: "usage", kind: .integer(PanelNav.contextAlertThresholdOptions),
                    read: { .int($0.contextAlertThresholdK) }),
        SettingSpec(key: "STACKNUDGE_QUOTA_SHOW_REMAINING", label: "Show remaining", category: "usage",
                    kind: .toggle, read: { .bool($0.quotaShowRemaining) }),
        // Integrations
        SettingSpec(key: "STACKNUDGE_SLACK", label: "Slack notifications", category: "integrations",
                    kind: .toggle, read: { .bool($0.slackEnabled) }),
        SettingSpec(key: "STACKNUDGE_SLACK_IDLE_MIN", label: "Slack: notify when idle (minutes, 0 is always)",
                    category: "integrations", kind: .integer(SlackDelivery.idleMinuteOptions),
                    read: { .int($0.slackIdleMinutes) }),
        SettingSpec(key: "STACKNUDGE_SLACK_DETAIL", label: "Slack: include message text", category: "integrations",
                    kind: .toggle, read: { .bool($0.slackIncludeDetail) }),
        SettingSpec(key: "STACKNUDGE_SLACK_STOP", label: "Slack: also notify on finished turns", category: "integrations",
                    kind: .toggle, read: { .bool($0.slackNotifyOnStop) }),
        SettingSpec(key: "STACKNUDGE_GITHUB", label: "GitHub PR links", category: "integrations",
                    kind: .toggle, read: { .bool($0.githubLinkingEnabled) }),
        SettingSpec(key: "STACKNUDGE_GITHUB_ACTIVITY", label: "GitHub activity", category: "integrations",
                    kind: .toggle, read: { .bool($0.githubActivityEnabled) }),
        SettingSpec(key: "STACKNUDGE_HIDE_SHIPPED", label: "Hide shipped", category: "integrations",
                    kind: .toggle, read: { .bool($0.hideShippedTickets) }),
        // Panel
        SettingSpec(key: "STACKNUDGE_PANEL_HOTKEY", label: "Panel shortcut", category: "panel",
                    kind: .text, read: { .string($0.hotkeyDisplay) }, readOnlyReason: panelOnly),
        SettingSpec(key: "STACKNUDGE_PANEL_PIN", label: "Pin panel", category: "panel",
                    kind: .toggle, read: { .bool($0.panelPinned) }),
        SettingSpec(key: "STACKNUDGE_KEEP_OPEN_WHEN_EMPTY", label: "Keep open when empty", category: "panel",
                    kind: .toggle, read: { .bool($0.keepOpenWhenEmpty) }),
        SettingSpec(key: "STACKNUDGE_TAB_TITLE_NAMES", label: "Name from tab titles", category: "panel",
                    kind: .toggle, read: { .bool($0.tabTitleNames) }),
        // Events
        SettingSpec(key: "STACKNUDGE_EVENTS_PER_SESSION", label: "History per session", category: "events",
                    kind: .integer(PanelNav.eventsPerSessionOptions), read: { .int($0.eventsPerSession) }),
        SettingSpec(key: "STACKNUDGE_EVENT_HISTORY", label: "Event history", category: "events",
                    kind: .toggle, read: { .bool($0.eventHistoryEnabled) }),
        // Extensions
        SettingSpec(key: "STACKNUDGE_AWAY_LOCK", label: "Lock screen when away", category: "extensions",
                    kind: .toggle, read: { .bool($0.awayLock) }, readOnlyReason: protectsLock),
        // Actions
        SettingSpec(key: UpdateChannel.configKey, label: "Update channel", category: "actions",
                    kind: .choice(UpdateChannel.allCases.map(\.rawValue)), read: { .string($0.updateChannel.rawValue) }),
        SettingSpec(key: "STACKNUDGE_MCP_WRITES", label: "MCP clients can change settings", category: "actions",
                    kind: .toggle, read: { .bool($0.mcpWritesEnabled) },
                    readOnlyReason: "Only you can decide what MCP clients may change. Change it in Settings → Actions."),
    ]
}
