import Foundation

// Single source of truth for "what do we call this session".
//
// Three surfaces used to answer that question three different ways and
// disagreed with each other: the Sessions row read the process list, the
// Events row read only the on-disk name store (so it never saw a name set
// inside the agent), and the banner joined events to sessions on Claude's
// session UUID alone (so a Codex / Gemini / Antigravity banner could never
// pick up a rename at all). The spoken nudge didn't resolve anything — the
// hook baked the cwd basename into the phrase before the app ever saw it.
//
// Priority is by provenance, strongest intent first:
//   1. customName — the user renamed it in the Sessions pane.
//   2. a name the user set inside the agent (Claude Code's sidecar `name`).
//   3. the terminal tab title, but only when the caller opts in.
//   4. the cwd basename, which nobody chose, so callers that need a name
//      rather than a label ask for `chosenName` and get nil here.
//
// Which to call: on-screen surfaces (Events row, Sessions row, banner title) want
// `displayName`. Only speech wants `chosenName` — the hook already baked the cwd
// into its phrase, so nil there means "nothing better to say", not "no label".
//
// Off by default, opt-in: the terminal tab name. On iTerm2 a manual rename, an
// OSC title escape and the profile name all write the same `autoName` variable,
// so there is no way to read "the user chose this" back out — and Claude Code
// rewrites the tab title every turn, so a manual tab rename doesn't survive
// anyway. tmux is no better: #{pane_title} is the same OSC signal, and the one
// option that records a real rename can't be read without a subprocess per
// window (see TmuxIntegration).
//
// So it can't be trusted as *intent*, but plenty of people title their tabs
// deliberately and want that name back. `allowTabTitle` is that choice, wired to
// the "Name sessions from tab titles" setting and false everywhere by default.
// It sits below both real signals — a rename in the Sessions pane and a name set
// inside the agent still win — and above the cwd, which nobody chose either.
// The pane's meta row shows the tab name regardless, where churn is harmless.
enum SessionLabel {

    // Agent-assigned names that carry no user intent. "main-agent" is what
    // pre-2.1 Claude Code called every session. 2.1+ derives a per-cwd name
    // instead ("stackone-89") and stamps a nameSource, which is why matching
    // the old literal alone stopped being enough: every session suddenly had
    // a plausible-looking name, and banners started reading
    // "Claude Code — stackone-89" whether or not anyone had renamed anything.
    static let placeholderNames: Set<String> = ["main-agent"]

    // nameSource values that mean "the agent made this up". A source we don't
    // recognise counts as user intent: the failure we care about is dropping a
    // real rename, and a new source string is far more likely to be a way for
    // the user to set a name than another kind of auto-generation.
    static let generatedNameSources: Set<String> = [
        "derived", "default", "auto", "generated",
    ]

    // MARK: - Sessions

    // The name a human chose for this session, or nil if nobody has.
    //
    // `allowTabTitle` admits the terminal tab title as a last resort before
    // giving up. Defaulted to false so a new call site can't opt in by
    // forgetting to think about it — the setting is off for most people, and a
    // caller that silently inherited "on" would be the wrong default twice.
    static func chosenName(for session: Session, allowTabTitle: Bool = false) -> String? {
        if let custom = session.customName?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return custom
        }
        if let live = userSetLiveTitle(of: session) { return live }
        guard allowTabTitle else { return nil }
        return tabTitle(of: session)
    }

    // What a row/pill shows as its title.
    static func displayName(for session: Session, fallback: String,
                            allowTabTitle: Bool = false) -> String {
        chosenName(for: session, allowTabTitle: allowTabTitle)
            ?? session.projectName ?? fallback
    }

    // The terminal's tab title, trimmed, or nil when there isn't one. Kept
    // separate from userSetLiveTitle so the placeholder rules stay attached to
    // the signal they describe: "main-agent" is a Claude Code artefact and has
    // no business filtering what someone typed into a tab.
    //
    // VS Code and its forks are excluded, because their `tabName` is not a tab
    // title at all — VSCodeIntegration fills it from the OS *window* title that
    // notify.sh captures ("Panel.swift — stackone — Cursor"), which names the
    // file you happen to be looking at and changes every time you switch tabs in
    // the editor. That is fine for the meta row it was built for, and unusable
    // as a name: it would churn, and it would be read aloud em-dashes and all.
    // The window title stays visible in the row; it just can't title a Slack DM.
    private static func tabTitle(of session: Session) -> String? {
        guard !VSCodeIntegration.isVSCodeHosted(session.terminalApp),
              let tab = session.tabName?.trimmingCharacters(in: .whitespaces),
              !tab.isEmpty
        else { return nil }
        return tab
    }

    // The agent's own session name, but only when the agent tells us a human
    // set it. nil source means the agent doesn't report one (older Claude Code,
    // other agents), so we keep the pre-existing behaviour of trusting the name
    // and only filtering the known placeholder.
    private static func userSetLiveTitle(of session: Session) -> String? {
        guard let title = session.liveTitle?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty,
              !placeholderNames.contains(title)
        else { return nil }
        if let source = session.liveTitleSource?.trimmingCharacters(in: .whitespaces).lowercased(),
           generatedNameSources.contains(source) {
            return nil
        }
        return title
    }

    // MARK: - Events

    // The name a human chose for the session this event came from.
    //
    // Prefers the live session, which is where a rename made inside the agent
    // shows up, and matches it the same way the Events tab does — agent PID
    // first, falling back to project path plus tab id. Then falls back to the
    // disk-backed store, which is the only source left once the session's
    // process is gone.
    //
    // `allowTabTitle` only reaches the live-session branch. The disk-backed
    // store holds names people typed, never tab titles — once the process is
    // gone there is no tab left to read one from.
    static func chosenName(for event: NudgeEvent,
                           in sessions: [Session],
                           persistence: SessionPersistence,
                           allowTabTitle: Bool = false) -> String? {
        if let session = sessions.first(where: { sessionMatches(event: event, session: $0) }),
           let name = chosenName(for: session, allowTabTitle: allowTabTitle) {
            return name
        }
        return persistence.customName(
            agent: event.agent,
            projectPath: event.projectPath,
            tabId: tabIdentifier(for: event)
        )
    }

    // What a nudge row shows as its session chip: a chosen name, else the
    // project folder.
    static func displayName(for event: NudgeEvent,
                            in sessions: [Session],
                            persistence: SessionPersistence,
                            allowTabTitle: Bool = false) -> String? {
        if let name = chosenName(for: event, in: sessions, persistence: persistence,
                                 allowTabTitle: allowTabTitle) {
            return name
        }
        guard let project = event.projectPath else { return nil }
        return (project as NSString).lastPathComponent
    }

    // First non-empty of [terminal session id, VSCode IPC hook]. Each terminal
    // contributes whatever it has; the lookup layer doesn't care which one
    // fired as long as it's stable per tab/window.
    static func tabIdentifier(for event: NudgeEvent) -> String? {
        if let sid = event.sessionID, !sid.isEmpty { return sid }
        if let hook = event.ipcHook, !hook.isEmpty { return hook }
        return nil
    }
}

// Builds the spoken phrase. The hook picks a phrase template at random and
// used to substitute the cwd basename itself, which meant speech could never
// say a renamed session's name. It now sends the template with its `%s`
// placeholder intact (plus the already-substituted string for older installs)
// and we fill in whichever label resolved.
enum VoicePhrase {

    // nil when there's nothing better to say than what the hook already
    // substituted — caller falls back to event.voiceMessage.
    static func spoken(template: String?, label: String?) -> String? {
        guard let template, template.contains("%s"),
              let label, !label.isEmpty
        else { return nil }
        return template.replacingOccurrences(of: "%s", with: expandForSpeech(label))
    }

    // Light expansion so a slug reads as words. Mirrors notify.sh's
    // repo_name_raw, which still handles the hook-side fallback phrase; the
    // two only need to agree in behaviour, not implementation, and this side
    // is the one that sees user-chosen names.
    static func expandForSpeech(_ name: String) -> String {
        let words = name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word -> String in
                switch word.lowercased() {
                case "cli":      return "C L I"
                case "api":      return "A P I"
                case "mcp":      return "M C P"
                case "hris":     return "H R I S"
                case "ai":       return "A I"
                case "stackone": return "stack one"
                default:         return String(word)
                }
            }
        return words.joined(separator: " ")
    }
}
