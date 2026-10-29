import Foundation

/// Pedro, a cream chibi dog with a Yorkie face, baked from a design sheet.
struct PedroSkin: Skin {
    let id = "pedro"
    let displayName = "Pedro"
    let family = "Pedro"
}

extension PedroSkin: LayeredSkin {
    @MainActor func makeRig(size: CGSize, backing: CGFloat) -> SkinRig {
        PedroRig(size: size, backing: backing, assets: BakedRig.bundled(id))
    }
}

/// Pedro as layers built from the baked manifest. The bake records the sheet's CSS motion (blinks included),
/// so the rig has no pose code.
@MainActor
final class PedroRig: BakedRig {
    init(size: CGSize, backing: CGFloat, assets: URL) {
        super.init(size: size, backing: backing, assets: assets, name: "pedro", fallbackBox: [-26, -64, 252, 268])
    }
}
