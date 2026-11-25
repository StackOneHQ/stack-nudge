import Foundation

/// The clay wizard, as Core Animation layers of PNGs baked from a design sheet.
struct WizardSkin: Skin {
    let id = "wizard"
    let displayName = "Clay"
    let family = "Wizard"

    /// The pixel-art wizard (one palette for now).
    static let pixel = FrameSkin(id: "wizard-grey", displayName: "Pixel", family: "Wizard")
}

extension WizardSkin: LayeredSkin {
    @MainActor func makeRig(size: CGSize, backing: CGFloat) -> SkinRig {
        WizardRig(size: size, backing: backing, assets: BakedRig.bundled(id))
    }
}

/// The wizard as layers built from the baked manifest; its motion is the pose code in WizardPose.swift.
@MainActor
final class WizardRig: BakedRig {
    init(size: CGSize, backing: CGFloat, assets: URL) {
        super.init(size: size, backing: backing, assets: assets, name: "wizard", fallbackBox: [-20, -30, 240, 240])
    }

    override func motion(_ classes: [String], mode: SkinMode, vars: (dx: Double, dy: Double)?) -> BakedMotion? {
        WizardPose.motion(classes, mode: mode, vars: vars)
    }

    override func blink(mode: SkinMode) -> BakedMotion? { WizardPose.blink(mode: mode) }
}

/// A pixel skin baked into sprite sheets. Its assets are
/// the bundle's `skins/<id>` folder.
struct FrameSkin: Skin {
    let id: String
    let displayName: String
    let family: String
}

extension FrameSkin: LayeredSkin {
    @MainActor func makeRig(size: CGSize, backing: CGFloat) -> SkinRig {
        FrameRig(size: size, backing: backing, assets: BakedRig.bundled(id))
    }
}
