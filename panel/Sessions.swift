import AppKit
import SwiftUI

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
        .onAppear  { store.startPolling() }
        .onDisappear { store.stopPolling() }
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
                        SessionRow(
                            session: session,
                            selected: store.selectedPID == session.pid,
                            isEditing: store.renamingPID == session.pid,
                            renameBuffer: $store.renameBuffer,
                            activeNudgeCount: nudgeCount(for: session),
                            lastNudgeAt: lastNudgeAt(for: session),
                            transcriptStats: transcriptStats(for: session),
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
                FooterHint(label: "Cancel", keys: ["esc"])
            } else {
                FooterHint(label: "Select", keys: ["↑", "↓"])
                FooterHint(label: "Focus",  keys: ["⏎"])
                FooterHint(label: "Rename", keys: ["n"])
                FooterHint(label: "Kill",   keys: ["⌫"])
                FooterHint(label: "Back",   keys: ["esc"])
            }
        }
    }

    // Count of currently-active (undismissed, unsnoozed-or-elapsed-snooze)
    // nudges that match this session's (agent, projectPath). The plan
    // deliberately scopes this to "in the store right now" — lifetime
    // totals across restarts would be fuzzy and aren't asked for.
    private func nudgeCount(for session: Session) -> Int {
        events.events.filter { matches(event: $0, session: session) }.count
    }

    private func lastNudgeAt(for session: Session) -> Date? {
        events.events
            .filter { matches(event: $0, session: session) }
            .map(\.timestamp)
            .max()
    }

    // Find the most recent NudgeEvent matching this session that carries a
    // claudeSessionID, then look up its TranscriptStats in nav. Returns nil
    // when the session has no Claude Code event yet (e.g. a Gemini-only
    // session, or a Claude session that hasn't fired a hook this run).
    private func transcriptStats(for session: Session) -> TranscriptStats? {
        guard let id = events.events
            .filter({ matches(event: $0, session: session) })
            .compactMap(\.claudeSessionID)
            .last
        else { return nil }
        return nav.claudeSessionStats[id]
    }

    private func matches(event: NudgeEvent, session: Session) -> Bool {
        guard Agent.canonical(event.agent) == Agent.canonical(session.agent),
              event.projectPath == session.projectPath else { return false }
        // When both sides know which tab/window they belong to, demand
        // they agree — that's how a permission nudge for tab A doesn't
        // count toward tab B's nudge counter. Each terminal contributes
        // its own identifier (iTerm: sessionID; VSCode: ipcHook), so
        // we accept either as the event-side tabId.
        let eventTab = (event.sessionID?.isEmpty == false ? event.sessionID : event.ipcHook)
        if let sessionTab = session.tabId, let eventTab,
           !sessionTab.isEmpty, !eventTab.isEmpty {
            return sessionTab == eventTab
        }
        return true
    }
}

private struct SessionRow: View {

    let session: Session
    let selected: Bool
    let isEditing: Bool
    @Binding var renameBuffer: String
    let activeNudgeCount: Int
    let lastNudgeAt: Date?
    let transcriptStats: TranscriptStats?
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

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
        .opacity(isActive ? 1.0 : 0.6)
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
        let tokens = Self.formatTokens(stats.tokens)
        if let limit = ModelLimits.limit(for: stats.model) {
            let pct = Int((Double(stats.tokens) / Double(limit) * 100).rounded())
            return "\(tokens) · \(pct)%"
        }
        return tokens
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000 {
            return String(format: "%.0fK tokens", Double(n) / 1_000.0)
        }
        return "\(n) tokens"
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
        if let custom = session.customName, !custom.isEmpty { return custom }
        return session.projectName ?? "(no project)"
    }

    // Full cwd with $HOME replaced by ~ for compactness. Falls back to
    // pid when there's no path at all — so the row never shows nothing.
    private var displayPath: String {
        guard let path = session.projectPath else { return "pid \(session.pid)" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private var glyph: String {
        switch session.status {
        case .active:   return "circle.fill"
        case .finished: return "circle"
        }
    }

    private var glyphColor: Color {
        switch session.status {
        case .active:   return .green
        case .finished: return .secondary
        }
    }

    // "active 14m" while the process is running, "ended 5m ago" once it
    // exits. We use ps etime for the former since it's already in hand;
    // RelativeDateTimeFormatter for the latter.
    private var statusLabel: String {
        switch session.status {
        case .active:
            let elapsed = session.elapsed?.trimmingCharacters(in: .whitespaces) ?? ""
            return elapsed.isEmpty ? "active" : "active · \(elapsed)"
        case .finished(let at):
            return "ended " + Self.timeFormatter.localizedString(for: at, relativeTo: Date())
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
        let when = Self.timeFormatter.localizedString(for: last, relativeTo: Date())
        return "\(countLabel) · last \(when)"
    }
}
