import SwiftUI

// One-time welcome shown the first time the panel opens after install.
// Replaces the tab strip + content until the user presses Enter / clicks
// "Got it"; then PanelNav.dismissWelcome() persists the dismissal.
struct WelcomeView: View {

    @ObservedObject var nav: PanelNav
    let hotkeyDisplay: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    Text("Notifications for AI coding agents — banners, voice, and a keyboard-driven panel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    hotkeyHint

                    tabsSummary
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }

            PageFooter {
                FooterHint(label: "Got it", keys: ["⏎"], primary: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Welcome to stack-nudge")
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    private var hotkeyHint: some View {
        HStack(spacing: 8) {
            Text("Press")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(hotkeyDisplay.keyCapTokens, id: \.self) { token in
                    KeyCapView(symbol: token)
                }
            }
            Text("anytime to open this panel.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var tabsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Three tabs:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)

            tabRow(systemImage: "bell.fill",
                   title: "Events",
                   detail: "Recent nudges, approve / focus with the keyboard")
            tabRow(systemImage: "list.bullet.rectangle",
                   title: "Sessions",
                   detail: "Running agents — focus, rename, terminate")
            tabRow(systemImage: "gearshape.fill",
                   title: "Settings",
                   detail: "Hotkey, sounds, voice, and more")
        }
    }

    private func tabRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private extension String {
    // Split a hotkey spec like "cmd+opt+n" into key cap tokens that match
    // the macOS modifier glyphs the rest of the panel uses.
    var keyCapTokens: [String] {
        split(separator: "+").map { part in
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            switch p {
            case "cmd", "command":         return "⌘"
            case "shift":                  return "⇧"
            case "opt", "alt", "option":   return "⌥"
            case "ctrl", "control":        return "⌃"
            default:                       return p.uppercased()
            }
        }
    }
}
