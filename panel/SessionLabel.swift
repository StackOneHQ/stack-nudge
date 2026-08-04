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
//   3. the cwd basename, which nobody chose, so callers that need a name
//      rather than a label ask for `chosenName` and get nil here.
//
// Deliberately excluded: the terminal tab name. On iTerm2 a manual rename,
// an OSC title escape and the profile name all write the same `autoName`
// variable, so there is no way to read "the user chose this" back out — and
// Claude Code rewrites the tab title every turn, so a manual tab rename
// doesn't survive anyway. The pane still shows the tab name in its meta row,
// where churn is harmless.
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
    static func chosenName(for session: Session) -> String? {
        if let custom = session.customName?.trimmingCharacters(in: .whitespaces),
           !custom.isEmpty {
            return custom
        }
        return userSetLiveTitle(of: session)
    }

    // What a row/pill shows as its title.
    static func displayName(for session: Session, fallback: String) -> String {
        chosenName(for: session) ?? session.projectName ?? fallback
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
    static func chosenName(for event: NudgeEvent,
                           in sessions: [Session],
                           persistence: SessionPersistence) -> String? {
        if let session = sessions.first(where: { sessionMatches(event: event, session: $0) }),
           let name = chosenName(for: session) {
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
                            persistence: SessionPersistence) -> String? {
        if let name = chosenName(for: event, in: sessions, persistence: persistence) {
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
