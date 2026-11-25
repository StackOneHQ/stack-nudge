import AppKit
import SwiftUI

// Every character as a live card under Settings > Companion. Hovering a card
// shows it on the companion itself without saving it; a click picks it. The
// Character row above stays the keyboard's way to do the same.
struct CompanionSkinGrid: View {
    @ObservedObject var nav: PanelNav
    // The pose the cards act out, so each skin can be judged in every state
    // without waiting for an agent to need you.
    @State private var pose: SkinMode = .idle

    private static let cardSize = CGSize(width: 72, height: 80)
    private static let poses: [(SkinMode, String)] = [
        (.idle, "Idle"), (.polling, "Watching"), (.thinking, "Busy"), (.pending, "Waiting"),
        (.alert, "Alert"), (.error, "Error"), (.sleeping, "Asleep"), (.muted, "Muted"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Characters").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("Pose", selection: $pose) {
                    ForEach(Self.poses, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(CompanionSkins.all, id: \.id) { skin in card(skin) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .opacity(nav.companionEnabled ? 1 : 0.4)
        // Leaving the page must never strand a preview on the companion.
        .onDisappear { nav.companionPreviewSkin = nil }
    }

    private func card(_ skin: LayeredSkin) -> some View {
        let chosen = nav.companionSkin == skin.id
        return VStack(spacing: 4) {
            CharacterLayerHost(skin: skin, mode: pose,
                               still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                               size: Self.cardSize, active: true)
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            Text(skin.fullName)
                .font(.caption)
                .foregroundStyle(chosen ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(chosen ? 0.10 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(chosen ? nav.theme.color : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { inside in
            guard nav.companionEnabled else { return }
            if inside { nav.companionPreviewSkin = skin.id }
            else if nav.companionPreviewSkin == skin.id { nav.companionPreviewSkin = nil }
        }
        .onTapGesture {
            guard nav.companionEnabled else { return }
            nav.selectCompanionSkin(skin.id)
        }
    }
}
