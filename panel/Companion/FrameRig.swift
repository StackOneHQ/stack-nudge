import AppKit
import QuartzCore

/// What the bake writes next to the sheets of one palette.
struct SpriteManifest: Decodable, Equatable {
    struct State: Decodable, Equatable {
        let frames: Int
        let fps: Double
        let sheet: String
    }

    let skin: String
    let frameWidth: Int
    let frameHeight: Int
    /// Transparent columns after each frame in a sheet.
    let gutter: Int
    let states: [String: State]

    static func parse(_ data: Data) -> SpriteManifest? {
        guard let manifest = try? JSONDecoder().decode(SpriteManifest.self, from: data),
              manifest.frameWidth > 0, manifest.frameHeight > 0, manifest.gutter >= 0,
              manifest.states.values.allSatisfy({ $0.frames > 0 && $0.fps > 0 })
        else { return nil }
        return manifest
    }
}

/// Integer-multiple sizing for pixel art: the largest scale whose device pixels fit `fitting`, never fractional.
enum PixelScale {
    static func choose(frame: CGSize, fitting: CGSize, backing: CGFloat) -> Int {
        let fit = min(fitting.width * backing / frame.width, fitting.height * backing / frame.height)
        return max(1, Int((fit + 1e-6).rounded(.down)))
    }
}

func spriteStateName(_ mode: SkinMode) -> String {
    switch mode {
    case .idle: return "idle"
    case .polling: return "polling"
    case .thinking: return "thinking"
    case .pending: return "pending"
    case .alert: return "alert"
    case .error: return "error"
    case .sleeping: return "sleeping"
    case .muted: return "muted"
    }
}

/// A pixel skin: one layer whose `contents` is the state's sprite sheet (frames in a row). A discrete keyframe
/// animation steps `contentsRect` through the frames, so the render server does the animating.
@MainActor
final class FrameRig: SkinRig {
    static func bundledAssets(_ skin: String) -> URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("skins/\(skin)")
    }

    private let manifest: SpriteManifest?
    private let sheets: [String: CGImage]
    private let spriteLayer = CALayer()

    init(size: CGSize, backing: CGFloat, assets: URL) {
        let decoded = (try? Data(contentsOf: assets.appendingPathComponent("manifest.json")))
            .flatMap(SpriteManifest.parse)
        if decoded == nil { NSLog("stack-nudge: sprite assets missing at \(assets.path)") }
        manifest = decoded
        // Decoded up front so a state change swaps pixels already in memory.
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        var loaded: [String: CGImage] = [:]
        for state in decoded?.states.values ?? [:].values {
            if let source = CGImageSourceCreateWithURL(assets.appendingPathComponent(state.sheet) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, options) {
                loaded[state.sheet] = image
            }
        }
        sheets = loaded
        let frame = CGSize(width: decoded?.frameWidth ?? 1, height: decoded?.frameHeight ?? 1)
        super.init(box: CGRect(origin: .zero, size: size), size: size, backing: backing)
        root.sublayerTransform = CATransform3DIdentity

        let scale = CGFloat(PixelScale.choose(frame: frame, fitting: size, backing: backing))
        let width = frame.width * scale / backing
        let height = frame.height * scale / backing
        spriteLayer.anchorPoint = .zero
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Bottom centre, snapped to device pixels, so the feet stay put when the scale changes.
        spriteLayer.position = CGPoint(x: ((size.width - width) / 2 * backing).rounded() / backing, y: 0)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsScale = backing
        root.addSublayer(spriteLayer)
    }

    override func show(_ mode: SkinMode, still: Bool, now: CFTimeInterval, frozenAt: Double? = nil) {
        guard let manifest, let state = manifest.states[spriteStateName(mode)], let sheet = sheets[state.sheet] else {
            return
        }
        let frames = state.frames
        let stride = CGFloat(manifest.frameWidth + manifest.gutter)
        let rect = { (frame: Int) in
            CGRect(x: CGFloat(frame) * stride / CGFloat(sheet.width), y: 0,
                   width: CGFloat(manifest.frameWidth) / CGFloat(sheet.width), height: 1)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.removeAllAnimations()
        spriteLayer.contents = sheet
        if let frozenAt {
            spriteLayer.contentsRect = rect(Int(frozenAt * state.fps) % frames)
        } else {
            spriteLayer.contentsRect = rect(0)
            if !still && frames > 1 {
                let animation = CAKeyframeAnimation(keyPath: "contentsRect")
                animation.calculationMode = .discrete
                animation.values = (0..<frames).map { NSValue(rect: rect($0)) }
                // Discrete animations take one more key time than values.
                animation.keyTimes = (0...frames).map { NSNumber(value: Double($0) / Double(frames)) }
                animation.duration = Double(frames) / state.fps
                animation.repeatCount = .infinity
                animation.beginTime = spriteLayer.convertTime(now, from: nil)
                spriteLayer.add(animation, forKey: "frames")
            }
        }
        CATransaction.commit()
    }
}
