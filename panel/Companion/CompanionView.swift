import AppKit
import Combine
import SwiftUI

// Everything the character view draws from. CompanionController updates it
// only when a value actually changes, so the view re-renders on a change of
// mood or size rather than on every event, session poll or setting.
@MainActor
final class CompanionModel: ObservableObject {
    @Published var mode: SkinMode = .idle
    @Published var size: CompanionSize = .medium
}

struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject private var gate = CompanionGate.shared

    var body: some View {
        let size = model.size.points
        CharacterLayerHost(skin: CompanionSkins.skin(id: CompanionSkins.defaultID), mode: model.mode,
                           still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                           size: size, active: gate.active)
            .frame(width: size.width, height: size.height)
    }
}
