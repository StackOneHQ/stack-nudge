import Foundation

// A look for the companion. Skins own their art and motion as Core Animation
// layers (see LayeredSkin in LayerRig.swift), so the app does no per-frame work.
// Only building a rig needs the main actor; ids and names are plain values the
// settings code reads from anywhere.
protocol Skin: Sendable {
    var id: String { get }
    var displayName: String { get }
}

// The skins this build ships, in picker order. Any id not listed here falls
// back to the default, so a config written by a newer build still shows a
// character.
enum CompanionSkins {
    static let defaultID = "stacky"

    static let all: [LayeredSkin] = [StackySkin()]

    static func skin(id: String?) -> LayeredSkin {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID } ?? all[0]
    }

    static func ids() -> [String] { all.map(\.id) }
}

// Width in points; the height follows the 90:100 frame every skin is drawn in.
enum CompanionSize: String, CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    var points: CGSize {
        let width: CGFloat
        switch self {
        case .small:  width = 90
        case .medium: width = 130
        case .large:  width = 180
        }
        return CGSize(width: width, height: (width * 100 / 90).rounded())
    }
}
