import AppKit
import SwiftUI

// A session's slice of the event store: how many nudges match it and when the
// newest one fired. `.empty` is what unselected rows get: they don't render the
// nudge line, so they never scan the event list.
struct NudgeSummary: Equatable {
    let count: Int
    let lastAt: Date?

    static let empty = NudgeSummary(count: 0, lastAt: nil)
}

struct SessionsView: View {

    @ObservedObject var store: SessionStore
    @ObservedObject var events: EventStore
    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The widget uses a low-frequency background scan. Tighten it while
        // this tab is visible, then return to the energy-friendly cadence.
        .onAppear { store.startForegroundPolling() }
        .onDisappear { store.startPolling() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(store.didFirstScan ? "No active agent sessions" : "Checking for sessions…")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Text("claude · gemini · codex")
                .foregroundStyle(.tertiary)
                .font(.caption2.monospaced())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var sessionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.sessions) { session in
                        let selected = store.selectedPID == session.pid
                        // Only the selected row renders the nudge line, so only
                        // the selected row pays for the event scan. Every row
                        // scanning the list (twice: once for the count, once for
                        // the timestamp) also made every row's inputs change
                        // whenever any nudge arrived, forcing a rebuild.
                        let nudges = selected ? nudgeSummary(for: session) : .empty
                        SessionRow(
                            session: session,
                            selected: selected,
                            isEditing: store.renamingPID == session.pid,
                            renameBuffer: $store.renameBuffer,
                            activeNudgeCount: nudges.count,
                            lastNudgeAt: nudges.lastAt,
                            transcriptStats: transcriptStats(for: session),
                            isMuted: nav.isMuted(session),
                            onCommit: { store.commitRename() },
                            onCancel: { store.cancelRename() }
                        )
                        .id(session.pid)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedPID = session.pid }
                    }
                }
                .padding(.vertical, 4)
                .background(ThinScrollers())
            }
            .frame(maxHeight: .infinity)
            .onChange(of: store.selectedPID) { newValue in
                guard let pid = newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(pid, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        PageFooter {
            if store.renamingPID != nil {
                FooterHint(label: "Save",   keys: ["⏎"])
                FooterHint(label: "Cancel", keys: ["Esc"])
            } else {
                FooterHint(label: "Select",  keys: ["↑", "↓"])
                FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
                FooterHint(label: "Focus",   keys: ["⏎"])
                FooterHint(label: "Rename",  keys: ["N"])
                FooterHint(label: "Mute",    keys: ["M"])
                FooterHint(label: "Kill",    keys: ["⌫"])
                FooterHint(label: "Back",    keys: ["Esc"])
            }
        }
    }

    // Count of currently-active (undismissed, unsnoozed-or-elapsed-snooze)
    // nudges that match this session's (agent, projectPath), plus when the most
    // recent one fired. The plan deliberately scopes this to "in the store right
    // now"; lifetime totals across restarts would be fuzzy and aren't asked for.
    // One pass: count and newest-timestamp come off the same walk.
    private func nudgeSummary(for session: Session) -> NudgeSummary {
        var count = 0
        var lastAt: Date?
        for event in events.events where matches(event: event, session: session) {
            count += 1
            if let current = lastAt, current >= event.timestamp { continue }
            lastAt = event.timestamp
        }
        return NudgeSummary(count: count, lastAt: lastAt)
    }

    // Find the most recent NudgeEvent matching this session that carries a
    // claudeSessionID, then look up its TranscriptStats in nav. Returns nil
    // when the session has no Claude Code event yet (e.g. a Gemini-only
    // session, or a Claude session that hasn't fired a hook this run).
    private func transcriptStats(for session: Session) -> TranscriptStats? {
        // Primary: direct lookup via the sidecar-supplied sessionId.
        // This populates immediately on panel open — no hook required.
        if let id = session.claudeSessionID,
           let stats = nav.claudeSessionStats[id] {
            return stats
        }
        // Non-sidecar agents (Codex): resolve via the PID→transcript cache.
        // This persists across navigation and EventStore pruning, so the row
        // doesn't vanish once the source event ages out of the event list.
        if let ref = nav.transcriptRefByPID[session.pid],
           let stats = nav.claudeSessionStats[ref.sessionID] {
            return stats
        }
        // Fallback for sessions whose sidecar isn't readable (e.g. pre-2.1
        // Claude Code): infer from the most recent matching event that
        // carried a claudeSessionID. events array is newest-first. Lazy so the
        // walk stops at the first hit instead of filtering the whole list.
        guard let id = events.events.lazy
            .filter({ matches(event: $0, session: session) })
            .compactMap(\.claudeSessionID)
            .first
        else { return nil }
        return nav.claudeSessionStats[id]
    }

    private func matches(event: NudgeEvent, session: Session) -> Bool {
        sessionMatches(event: event, session: session)
    }
}

// Top-level so PanelNav can reuse this when gating per-session mute.
func sessionMatches(event: NudgeEvent, session: Session) -> Bool {
    guard Agent.canonical(event.agent) == Agent.canonical(session.agent) else {
        return false
    }
    // Strongest disambiguator: notify.sh's walk_session_chain captures
    // the agent process PID; SessionStore.pid is the same number. Trust
    // it over projectPath because the event's project path (= shell
    // $PWD when notify.sh ran) can disagree with the session's project
    // path (= lsof cwd of the claude process). Zed sessions exhibit
    // this — claude cwd stays at the workspace root while the user's
    // shell can cd into a subdirectory.
    if let eventPID = event.agentPID, eventPID > 0 {
        return eventPID == session.pid
    }
    // Without a PID, fall back to projectPath + terminal-tab
    // disambiguator. Same path required; tabId narrows when both have it.
    guard event.projectPath == session.projectPath else { return false }
    let eventTab = (event.sessionID?.isEmpty == false ? event.sessionID : event.ipcHook)
    if let sessionTab = session.tabId, let eventTab,
       !sessionTab.isEmpty, !eventTab.isEmpty {
        return sessionTab == eventTab
    }
    return true
}

private struct SessionRow: View {

    let session: Session
    let selected: Bool
    let isEditing: Bool
    @Binding var renameBuffer: String
    let activeNudgeCount: Int
    let lastNudgeAt: Date?
    let transcriptStats: TranscriptStats?
    let isMuted: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool


    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.body)
                .foregroundStyle(glyphColor)
                .frame(width: 20, alignment: .center)
                // Keep the glyph anchored to the title's baseline even when
                // the card expands with extra rows below.
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                titleRow
                metaRow
                if let stats = transcriptStats {
                    contextRow(stats)
                }
                if showNudgeRow {
                    nudgeRow
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .padding(.horizontal, 6)
        // Dormant sessions get the same recede as finished ones: the process
        // is still there to focus or kill, but it hasn't done anything for a
        // day, so it shouldn't read as live work.
        .opacity(isActive && !session.isDormant() ? 1.0 : 0.6)
    }

    // Background composes the selection tint with a 3pt accent bar in the
    // session's stable color. ZStack with clip to the rounded shape so
    // the bar gets the same corner radius as the row.
    private var rowBackground: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
            if let accent = SessionColor.color(
                agent: session.agent,
                projectPath: session.projectPath,
                tabId: session.tabId
            ) {
                Rectangle()
                    .fill(accent.opacity(isActive ? 0.85 : 0.45))
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Subviews

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isEditing {
                TextField("Session name", text: $renameBuffer)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.15))
                    )
                    .focused($nameFieldFocused)
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel)
                    .onAppear {
                        DispatchQueue.main.async { nameFieldFocused = true }
                    }
            } else {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            agentTag
            if isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Muted — press M to unmute")
            }
            Spacer(minLength: 8)
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let term = session.terminalApp {
                Text(term)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let tab = session.tabName, !tab.isEmpty, tab != displayName {
                Text(tab)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(displayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // Context-window usage row. Shows absolute tokens always; appends a
    // percentage only when the model's context limit is in ModelLimits.
    // The icon is intentionally muted — this is informational, not an
    // alert (alerts come later, in Phase 2).
    private func contextRow(_ stats: TranscriptStats) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(contextLabel(stats))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 1)
    }

    private func contextLabel(_ stats: TranscriptStats) -> String {
        // Absolute tokens only. We dropped the %-of-limit display in
        // Phase 1 after discovering that the 4.x family's context window
        // varies (Opus/Sonnet on 1M context; Haiku on 200K; Sonnet 1M is
        // opt-in beta), and there's no reliable way to disambiguate from
        // the model ID. Showing the model name keeps the row honest.
        let tokens = "\(TokenFormat.short(stats.tokens)) tokens"
        if let model = stats.model {
            return "\(tokens) · \(Self.shortModel(model))"
        }
        return tokens
    }

    // Strip the date suffix Anthropic appends to model IDs
    // (e.g. "claude-opus-4-7-20250606" → "opus-4-7") and the
    // redundant "claude-" prefix.
    private static func shortModel(_ id: String) -> String {
        var s = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        if let dash = s.range(of: "-2", options: .backwards),
           s[dash.lowerBound...].dropFirst().allSatisfy(\.isNumber) {
            s = String(s[..<dash.lowerBound])
        }
        return s
    }


    private var nudgeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(nudgeSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 1)
    }

    private var agentTag: some View {
        Text(session.agent)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.primary.opacity(0.08))
            )
    }

    // MARK: - Derived state

    private var rowBackgroundColor: Color {
        if isEditing { return Color.accentColor.opacity(0.30) }
        if selected  { return Color.accentColor.opacity(0.22) }
        return Color.clear
    }

    private var isActive: Bool { session.status == .active }

    private var displayName: String {
        SessionLabel.displayName(for: session, fallback: "(no project)")
    }

    // Full cwd with $HOME replaced by ~ for compactness. Falls back to
    // pid when there's no path at all — so the row never shows nothing.
    private var displayPath: String {
        guard let path = session.projectPath else { return "pid \(session.pid)" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private var glyph: String {
        switch session.status {
        case .active:   return session.isDormant() ? "circle.dotted" : "circle.fill"
        case .finished: return "circle"
        }
    }

    private var glyphColor: Color {
        switch session.status {
        case .finished: return .secondary
        case .active where session.isDormant(): return .secondary
        case .active:
            // For claude sessions we get a live busy/idle signal from the
            // ~/.claude/sessions/<pid>.json sidecar; reflect it in the dot
            // so a glance at the panel tells the user which agents are
            // working vs. waiting. Other agents / unknown status default
            // to the existing green.
            switch session.liveStatus {
            case "busy": return .yellow
            case "idle": return .green
            case nil:    return .green
            default:     return .green
            }
        }
    }

    // "active 14m" while the process is running, "ended 5m ago" once it
    // exits. We use ps etime for the former since it's already in hand;
    // RelativeDateTimeFormatter for the latter.
    private var statusLabel: String {
        switch session.status {
        case .active:
            // Lead with claude's live status (busy / idle), or "dormant" once
            // there's been no activity for a day — at that point "idle" reads
            // as "waiting on me right now", which it isn't. Append "last
            // activity Nm ago" from the sidecar's updatedAt when available
            // — more useful than process elapsed time, which only tells
            // you how long ago the process was spawned.
            let head = session.isDormant() ? "dormant" : (session.liveStatus ?? "active")
            if let updated = session.lastActivityAt {
                return "\(head) · \(RelativeTime.string(updated))"
            }
            let elapsed = session.elapsed?.trimmingCharacters(in: .whitespaces) ?? ""
            return elapsed.isEmpty ? head : "\(head) · \(elapsed)"
        case .finished(let at):
            return "ended " + RelativeTime.string(at)
        }
    }

    // Show the nudge row only on the selected card AND when there's
    // something interesting to report. Keeps non-selected rows compact.
    private var showNudgeRow: Bool {
        selected && activeNudgeCount > 0
    }

    private var nudgeSummary: String {
        let countLabel = activeNudgeCount == 1 ? "1 nudge" : "\(activeNudgeCount) nudges"
        guard let last = lastNudgeAt else { return countLabel }
        let when = RelativeTime.string(last)
        return "\(countLabel) · last \(when)"
    }
}
