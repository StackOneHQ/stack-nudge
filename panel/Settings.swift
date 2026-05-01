import AppKit
import SwiftUI

enum SettingsKind {
    case toggle, cycle, action
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
                            row(1, label: "Banner notifications", kind: .toggle, value: nav.bannerEnabled   ? "On" : "Off")
                            row(2, label: "Voice notifications",  kind: .toggle, value: nav.voiceEnabled    ? "On" : "Off")
                            row(3, label: "Mute when focused",    kind: .toggle, value: nav.muteWhenFocused ? "On" : "Off")
                            row(4, label: "Pin panel",            kind: .toggle, value: nav.panelPinned     ? "On" : "Off")
                        }

                        section("Sounds") {
                            row(5, label: "Agent done", kind: .cycle, value: nav.soundStop)
                            row(6, label: "Permission", kind: .cycle, value: nav.soundPermission)
                        }

                        section("Voice") {
                            row(7, label: "Voice",  kind: .cycle, value: voiceLabel)
                            row(8, label: "Speed",  kind: .cycle, value: String(format: "%.2f×", nav.voiceSpeed))
                        }

                        section("Actions") {
                            row(9,  label: "Check permissions…", kind: .action, value: "")
                            row(10, label: "Open config file…",  kind: .action, value: "")
                            row(11, label: "Quit panel",         kind: .action, value: "")
                        }

                        aboutFooter
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                .onChange(of: nav.selectedSettingIndex) { newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            PageFooter {
                if nav.recordingHotkey {
                    FooterHint(label: "Press a combo with ⌘ / ⇧ / ⌥ / ⌃", keys: [], primary: true)
                    FooterHint(label: "Cancel", keys: ["esc"])
                } else {
                    FooterHint(label: "Move",  keys: ["↑", "↓"])
                    FooterHint(label: "Cycle", keys: ["←", "→"])
                    FooterHint(label: "Act",   keys: ["⏎"])
                    FooterHint(label: "Back",  keys: ["esc"])
                }
            }
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

    // Non-navigable footer with version info. Sits below the action rows so
    // keyboard nav (rowCount=12) doesn't need to know about it. Clicking the
    // GitHub link opens the repo in the user's browser.
    private var aboutFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return VStack(spacing: 4) {
            Text("stack-nudge v\(version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button {
                if let url = URL(string: "https://github.com/StackOneHQ/stack-nudge") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("github.com/StackOneHQ/stack-nudge")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
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
