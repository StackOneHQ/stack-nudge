import SwiftUI

// One-time welcome shown the first time the panel opens after install.
// Replaces the tab strip + content until the user presses Enter / clicks
// "Got it"; PanelNav.dismissWelcome() persists the dismissal.
struct WelcomeView: View {

    @ObservedObject var nav: PanelNav
    let hotkeyDisplay: String
    let onGrantPermissions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    Text("Notifications for AI coding agents. Banners, voice, and a keyboard-driven panel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    hotkeyHint

                    tabsSummary

                    permissionsHint
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background(ThinScrollers())
            }

            actionBar
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
                   detail: "Recent nudges; approve and focus with the keyboard")
            tabRow(systemImage: "list.bullet.rectangle",
                   title: "Sessions",
                   detail: "Running agents you can focus, rename, or terminate")
            tabRow(systemImage: "gearshape.fill",
                   title: "Settings",
                   detail: "Hotkey, sounds, voice, and more")
        }
    }

    private var permissionsHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.callout)
                .foregroundStyle(Color.orange.opacity(0.8))
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)
            Text("Notifications and Accessibility permissions are needed for banners and 'Allow' approvals. You can grant them now or later from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                onGrantPermissions()
            } label: {
                Text("Grant permissions")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )

            Spacer()

            Button {
                nav.dismissWelcome()
            } label: {
                HStack(spacing: 6) {
                    Text("Got it")
                        .font(.subheadline.weight(.medium))
                    KeyCapView(symbol: "⏎")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
            )
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
