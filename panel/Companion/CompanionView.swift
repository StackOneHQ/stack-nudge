import AppKit
import Combine
import SwiftUI

// Everything the character view draws from. CompanionController updates it
// only when a value actually changes, so the view re-renders on a change of
// mood, size or count rather than on every event, session poll or setting.
@MainActor
final class CompanionModel: ObservableObject {
    @Published var mode: SkinMode = .idle
    @Published var size: CompanionSize = .medium
    // Events waiting on you; 0 hides the badge, which is also how the setting
    // that turns it off reaches the view.
    @Published var badgeCount = 0
    // Grey while muted, so the count reads as held back.
    @Published var badgeMuted = false
    // Bumped to play one nod; the view reacts to the change.
    @Published var nods = 0
}

// A small nod about the bottom centre: tilt, overshoot the other way, settle.
// It is applied to the whole view, so every skin gets it and nothing runs
// while the character is still.
@MainActor
private final class NodMotion: ObservableObject {
    @Published var tilt: Double = 0

    func nod() {
        withAnimation(.easeOut(duration: 0.14)) { tilt = 5 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            withAnimation(.easeInOut(duration: 0.2)) { self?.tilt = -3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            withAnimation(.interpolatingSpring(stiffness: 120, damping: 9)) { self?.tilt = 0 }
        }
    }
}

struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var gate = CompanionGate.shared
    @StateObject private var nod = NodMotion()

    var body: some View {
        let size = model.size.points
        CharacterLayerHost(skin: CompanionSkins.skin(id: CompanionSkins.defaultID), mode: model.mode,
                           still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                           size: size, active: gate.active)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(nod.tilt), anchor: .bottom)
            .onChange(of: model.nods) { _ in
                if gate.active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { nod.nod() }
            }
            .overlay(alignment: .topTrailing) {
                // Inset: flush with the corner, the window edge cut off its outline.
                if model.badgeCount > 0 { CompanionCountBadge(count: model.badgeCount, muted: model.badgeMuted).padding(3) }
            }
    }
}

// App-icon style count at the character's top-right corner. Drawn still: it
// changes only when the count does.
struct CompanionCountBadge: View {
    let count: Int
    let muted: Bool

    static func text(_ count: Int) -> String { count > 99 ? "99+" : String(count) }

    var body: some View {
        Text(Self.text(count))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(muted ? Color.gray : Color.red))
            .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
            .help("\(count) waiting")
    }
}
