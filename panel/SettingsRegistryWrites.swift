import Foundation

// How an MCP client changes a setting: the value checked against what the
// setting takes, then written through the same code its Settings row runs, so
// side effects happen as they would from the panel (the floating widget
// re-laying out, event history attaching, the update channel re-checking).
// Main thread only, like nav.
extension SettingsRegistry {

    enum WriteFailure: Error, Equatable {
        case unknownKey(String)
        case readOnly(String)
        case writesOff
        case invalidValue(String)

        var message: String {
            switch self {
            case .unknownKey(let key):
                return "No setting \(key). settings_list names them all."
            case .readOnly(let reason):
                return reason
            case .writesOff:
                return "Changing settings from MCP is off. Turn on Settings → Actions → MCP clients can change settings."
            case .invalidValue(let message):
                return message
            }
        }
    }

    // Checks `raw` against the setting and writes it. Returns the setting as
    // it now stands.
    static func write(key: String, raw: Any, nav: PanelNav) -> Result<SettingSnapshot, WriteFailure> {
        guard let spec = spec(key) else { return .failure(.unknownKey(key)) }
        if let reason = spec.readOnlyReason { return .failure(.readOnly(reason)) }
        guard nav.mcpWritesEnabled else { return .failure(.writesOff) }
        guard let writer = writers[key] else { return .failure(.readOnly("This setting can't be changed from MCP.")) }
        let value: SettingValue
        switch coerce(raw, to: spec.kind, key: key, nav: nav) {
        case .success(let coerced): value = coerced
        case .failure(let failure): return .failure(failure)
        }
        if let refusal = writer(nav, value) { return .failure(.invalidValue(refusal)) }
        return .success(snapshot(nav).first { $0.key == key }!)
    }

    // A JSON value as the kind the setting takes, or why it isn't one.
    static func coerce(_ raw: Any, to kind: SettingSpec.Kind, key: String,
                       nav: PanelNav) -> Result<SettingValue, WriteFailure> {
        switch kind {
        case .toggle:
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .success(.bool(number.boolValue))
            }
            switch (raw as? String)?.lowercased() {
            case "true", "on":   return .success(.bool(true))
            case "false", "off": return .success(.bool(false))
            default:             return .failure(.invalidValue("\(key) takes true or false."))
            }
        case .choice(let options):
            guard let string = raw as? String, options.contains(string) else {
                return .failure(.invalidValue("\(key) takes one of: \(options.joined(separator: ", "))."))
            }
            return .success(.string(string))
        case .integer(let options):
            let number = (raw as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }
                ?? (raw as? String).flatMap(Int.init)
            guard let number, options.contains(number) else {
                return .failure(.invalidValue("\(key) takes one of: \(options.map(String.init).joined(separator: ", "))."))
            }
            return .success(.int(number))
        case .number(let min, let max, let step):
            let number = (raw as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
                ?? (raw as? String).flatMap(Double.init)
            guard let number, number >= min - 1e-9, number <= max + 1e-9 else {
                return .failure(.invalidValue("\(key) takes a number from \(min) to \(max)."))
            }
            let stepped = ((number - min) / step).rounded() * step + min
            return .success(.double((stepped * 100).rounded() / 100))
        case .text:
            guard let string = raw as? String, !string.isEmpty else {
                return .failure(.invalidValue("\(key) takes a string."))
            }
            return .success(.string(string))
        }
    }

    // How each setting a client may change gets changed. A writer returns a
    // refusal for a value that's valid in form but not right now.
    private typealias Writer = (PanelNav, SettingValue) -> String?

    private static func toggle(_ key: String, _ set: @escaping (PanelNav, Bool) -> Void) -> Writer {
        { nav, value in
            guard case .bool(let on) = value else { return "\(key) takes true or false." }
            set(nav, on)
            ConfigFile.write(key: key, value: on ? "true" : "false")
            return nil
        }
    }

    private static func integer(_ key: String, _ set: @escaping (PanelNav, Int) -> Void) -> Writer {
        { nav, value in
            guard case .int(let number) = value else { return "\(key) takes a whole number." }
            set(nav, number)
            ConfigFile.write(key: key, value: String(number))
            return nil
        }
    }

    private static func string(_ key: String, _ set: @escaping (PanelNav, String) -> Void) -> Writer {
        { nav, value in
            guard case .string(let string) = value else { return "\(key) takes a string." }
            set(nav, string)
            ConfigFile.write(key: key, value: string)
            return nil
        }
    }

    // Writers that go through one of nav's own methods do their own saving.
    private static let writers: [String: Writer] = [
        "STACKNUDGE_MUTE_DURATION_MIN": integer("STACKNUDGE_MUTE_DURATION_MIN") { $0.muteDurationMinutes = $1 },
        "STACKNUDGE_STALLED_MIN": integer("STACKNUDGE_STALLED_MIN") { nav, minutes in
            nav.stalledMinutes = minutes
            // As the Settings row does: nothing re-evaluates the flags once
            // the rule is off.
            if minutes == 0 { nav.stalledSessionKeys = [] }
        },
        "STACKNUDGE_SOUND": toggle("STACKNUDGE_SOUND") { $0.soundEnabled = $1 },
        "STACKNUDGE_SOUND_STOP": string("STACKNUDGE_SOUND_STOP") { $0.soundStop = $1 },
        "STACKNUDGE_SOUND_PERMISSION": string("STACKNUDGE_SOUND_PERMISSION") { $0.soundPermission = $1 },
        "STACKNUDGE_VOICE": toggle("STACKNUDGE_VOICE") { $0.voiceEnabled = $1 },
        "STACKNUDGE_VOICE_NAME": { nav, value in
            guard case .string(let name) = value else { return "STACKNUDGE_VOICE_NAME takes a voice's name." }
            if nav.voicesAvailable.isEmpty {
                return "The voices haven't loaded yet. Turn voice on, or try again in a moment."
            }
            guard nav.voicesAvailable.contains(name) else {
                return "No voice \(name). Voices: \(nav.voicesAvailable.joined(separator: ", "))."
            }
            nav.voice = name
            ConfigFile.write(key: "STACKNUDGE_VOICE_NAME", value: name)
            return nil
        },
        "STACKNUDGE_VOICE_SPEED": { nav, value in
            guard case .double(let speed) = value else { return "STACKNUDGE_VOICE_SPEED takes a number." }
            nav.voiceSpeed = speed
            ConfigFile.write(key: "STACKNUDGE_VOICE_SPEED", value: String(format: "%.2f", speed))
            return nil
        },
        "STACKNUDGE_FLOATING_WIDGET": { nav, value in
            guard case .string(let raw) = value, let choice = FloatingWidget(rawValue: raw) else {
                return "STACKNUDGE_FLOATING_WIDGET takes one of: \(FloatingWidget.allCases.map(\.rawValue).joined(separator: ", "))."
            }
            nav.setFloatingWidget(choice)
            return nil
        },
        "STACKNUDGE_COMPACT_SNAP": toggle("STACKNUDGE_COMPACT_SNAP") { $0.compactSnap = $1 },
        "STACKNUDGE_COMPACT_CORNER": { nav, value in
            guard case .string(let raw) = value, let corner = CompactCorner(rawValue: raw) else { return "Unknown corner." }
            nav.compactCorner = corner
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CORNER", value: corner.rawValue)
            return nil
        },
        "STACKNUDGE_COMPACT_ALPHA": { nav, value in
            guard case .double(let alpha) = value, PanelNav.compactAlphaOptions.contains(alpha) else {
                return "STACKNUDGE_COMPACT_ALPHA takes one of: "
                    + PanelNav.compactAlphaOptions.map { String($0) }.joined(separator: ", ") + "."
            }
            nav.compactAlpha = alpha
            ConfigFile.write(key: "STACKNUDGE_COMPACT_ALPHA", value: String(format: "%.2f", alpha))
            return nil
        },
        "STACKNUDGE_COMPACT_CONTENT": { nav, value in
            guard case .string(let raw) = value, let content = CompactContent(rawValue: raw) else { return "Unknown widget type." }
            nav.compactContent = content
            ConfigFile.write(key: "STACKNUDGE_COMPACT_CONTENT", value: content.rawValue)
            return nil
        },
        "STACKNUDGE_MASCOT": { nav, value in
            guard case .string(let raw) = value, let mascot = MascotKind(rawValue: raw) else { return "Unknown mascot." }
            nav.mascot = mascot
            ConfigFile.write(key: "STACKNUDGE_MASCOT", value: mascot.rawValue)
            return nil
        },
        "STACKNUDGE_THEME": { nav, value in
            guard case .string(let raw) = value, let theme = AccentTheme(rawValue: raw) else { return "Unknown accent color." }
            nav.theme = theme
            ConfigFile.write(key: "STACKNUDGE_THEME", value: theme.rawValue)
            return nil
        },
        "STACKNUDGE_COMPANION_SIZE": { nav, value in
            guard case .string(let raw) = value, let size = CompanionSize(rawValue: raw) else { return "Unknown size." }
            nav.setCompanionSize(size)
            return nil
        },
        "STACKNUDGE_COMPANION_BADGE": toggle("STACKNUDGE_COMPANION_BADGE") { $0.companionBadge = $1 },
        "STACKNUDGE_QUOTA_TRACKING": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_QUOTA_TRACKING takes true or false." }
            if nav.quotaTrackingEnabled != on { nav.toggleQuotaTracking() }
            return nil
        },
        "STACKNUDGE_QUOTA_ALERTS": toggle("STACKNUDGE_QUOTA_ALERTS") { $0.quotaAlertsEnabled = $1 },
        "STACKNUDGE_QUOTA_THRESHOLD": integer("STACKNUDGE_QUOTA_THRESHOLD") { $0.quotaAlertThreshold = $1 },
        "STACKNUDGE_USAGE_POLL_MIN": integer("STACKNUDGE_USAGE_POLL_MIN") { $0.quotaPollMinutes = $1 },
        "STACKNUDGE_CONTEXT_ALERT_THRESHOLD": integer("STACKNUDGE_CONTEXT_ALERT_THRESHOLD") { $0.contextAlertThresholdK = $1 },
        "STACKNUDGE_QUOTA_SHOW_REMAINING": toggle("STACKNUDGE_QUOTA_SHOW_REMAINING") { $0.quotaShowRemaining = $1 },
        "STACKNUDGE_SLACK": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_SLACK takes true or false." }
            // As the Settings row is greyed out until both halves of the setup
            // are there: on with neither sends nothing.
            if on, !nav.slackReady {
                return "Slack isn't set up yet: paste the setup in Settings → Integrations → Slack first."
            }
            nav.slackEnabled = on
            ConfigFile.write(key: "STACKNUDGE_SLACK", value: on ? "true" : "false")
            return nil
        },
        "STACKNUDGE_SLACK_IDLE_MIN": integer("STACKNUDGE_SLACK_IDLE_MIN") { $0.slackIdleMinutes = $1 },
        "STACKNUDGE_SLACK_DETAIL": toggle("STACKNUDGE_SLACK_DETAIL") { $0.slackIncludeDetail = $1 },
        "STACKNUDGE_SLACK_STOP": toggle("STACKNUDGE_SLACK_STOP") { $0.slackNotifyOnStop = $1 },
        "STACKNUDGE_GITHUB": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_GITHUB takes true or false." }
            // Turning it on may start the sign-in, on the GitHub page.
            if nav.githubLinkingEnabled != on { nav.toggleGithubLinking() }
            return nil
        },
        "STACKNUDGE_GITHUB_ACTIVITY": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_GITHUB_ACTIVITY takes true or false." }
            nav.githubActivityEnabled = on
            ConfigFile.write(key: "STACKNUDGE_GITHUB_ACTIVITY", value: on ? "true" : "false")
            nav.refreshGitHubCLILogin()
            return nil
        },
        "STACKNUDGE_HIDE_SHIPPED": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_HIDE_SHIPPED takes true or false." }
            if nav.hideShippedTickets != on { nav.toggleHideShipped() }
            return nil
        },
        "STACKNUDGE_PANEL_PIN": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_PANEL_PIN takes true or false." }
            nav.panelPinned = on
            ConfigFile.write(key: "STACKNUDGE_PANEL_PIN", value: on ? "true" : "false")
            if on, nav.compactMode, !nav.compactExpanded { nav.compactExpanded = true }
            return nil
        },
        "STACKNUDGE_KEEP_OPEN_WHEN_EMPTY": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_KEEP_OPEN_WHEN_EMPTY takes true or false." }
            if nav.keepOpenWhenEmpty != on { nav.toggleKeepOpenWhenEmpty() }
            return nil
        },
        "STACKNUDGE_TAB_TITLE_NAMES": toggle("STACKNUDGE_TAB_TITLE_NAMES") { $0.tabTitleNames = $1 },
        "STACKNUDGE_EVENTS_PER_SESSION": integer("STACKNUDGE_EVENTS_PER_SESSION") { $0.eventsPerSession = $1 },
        "STACKNUDGE_EVENT_HISTORY": { nav, value in
            guard case .bool(let on) = value else { return "STACKNUDGE_EVENT_HISTORY takes true or false." }
            nav.eventHistoryEnabled = on
            ConfigFile.write(key: "STACKNUDGE_EVENT_HISTORY", value: on ? "true" : "false")
            nav.actions?.applyEventHistorySetting()
            return nil
        },
        UpdateChannel.configKey: { nav, value in
            guard case .string(let raw) = value, let channel = UpdateChannel(rawValue: raw) else { return "Unknown channel." }
            nav.setUpdateChannel(channel)
            return nil
        },
    ]

    // How an audit line shows a value.
    static func describe(_ value: SettingValue) -> String {
        switch value {
        case .bool(let on):        return on ? "On" : "Off"
        case .int(let number):     return String(number)
        case .double(let number):  return String(format: "%.2f", number)
        case .string(let string):  return string
        }
    }
}
