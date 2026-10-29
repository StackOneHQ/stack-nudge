import Foundation

// Stacky: layers cut from one reference sheet and animated with transforms.
// The art is baked into PNG parts and a manifest under assets/skins/stacky.
struct StackySkin: Skin {
    let id = "stacky"
    let displayName = "Stacky"
}

extension StackySkin: LayeredSkin {
    @MainActor func makeRig(size: CGSize, backing: CGFloat) -> SkinRig {
        StackyRig(size: size, backing: backing, assets: BakedRig.bundled(id))
    }
}

// The bake records each group's CSS keyframes as samples, so the rig adds no
// motion code of its own.
@MainActor
final class StackyRig: BakedRig {
    init(size: CGSize, backing: CGFloat, assets: URL) {
        super.init(size: size, backing: backing, assets: assets, name: "stacky", fallbackBox: [0, 0, 860, 922])
    }
}
