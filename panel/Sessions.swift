import AppKit
import SwiftUI

struct SessionsView: View {

    @ObservedObject var store: SessionStore

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
                            onCommit: { store.commitRename() },
                            onCancel: { store.cancelRename() }
                        )
                        .id(session.pid)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedPID = session.pid }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: store.selectedPID) { newValue in
                guard let pid = newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(pid, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Image(systemName: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
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
}

private struct SessionRow: View {

    let session: Session
    let selected: Bool
    let isEditing: Bool
    @Binding var renameBuffer: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.body)
                .foregroundStyle(glyphColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
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
                                // Defer focus by one tick — SwiftUI's @FocusState
                                // binding inside an NSHostingView sometimes needs
                                // the run-loop to settle before it accepts the
                                // assignment.
                                DispatchQueue.main.async {
                                    nameFieldFocused = true
                                }
                            }
                    } else {
                        Text(displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    }
                    Text(session.agent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(rightMeta)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    if let term = session.terminalApp {
                        Text(term)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("pid \(session.pid)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .padding(.horizontal, 6)
        .opacity(isActive ? 1.0 : 0.55)
    }

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

    private var rightMeta: String {
        switch session.status {
        case .active:
            return session.elapsed ?? ""
        case .finished(let at):
            let interval = Int(Date().timeIntervalSince(at))
            return "ended \(interval)s ago"
        }
    }
}
