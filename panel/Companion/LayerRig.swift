import AppKit
import QuartzCore
import SwiftUI

/// One animated property of a layer. `at` is the value `elapsed` seconds into the state.
struct LayerTrack {
    let keyPath: String
    let at: (Double) -> Any
    /// Seconds per loop. Nil means the value never changes, so no animation is attached.
    var period: Double?
    /// Equal slots for step-wise values such as visor images; nil interpolates between dense samples.
    var steps: Int?
    /// Seconds into the state before the first loop starts.
    var delay = 0.0
    var loops = true

    static func transform(period: Double?, _ at: @escaping (Double) -> CGAffineTransform) -> LayerTrack {
        LayerTrack(keyPath: "transform", at: { NSValue(caTransform3D: CATransform3DMakeAffineTransform(at($0))) },
                   period: period)
    }

    func animation(begin: CFTimeInterval) -> CAKeyframeAnimation? {
        guard let period else { return nil }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.duration = period
        animation.beginTime = begin + delay
        animation.repeatCount = loops ? .infinity : 1
        if let steps {
            var values: [Any] = []
            var keyTimes: [NSNumber] = []
            for slot in 0..<steps {
                let value = at(delay + (Double(slot) + 0.5) * period / Double(steps))
                if let last = values.last, (last as AnyObject) === (value as AnyObject) { continue }
                values.append(value)
                keyTimes.append(NSNumber(value: Double(slot) / Double(steps)))
            }
            // Discrete animations take one more key time than values: the last one closes the final interval.
            keyTimes.append(1)
            animation.calculationMode = .discrete
            animation.values = values
            animation.keyTimes = keyTimes
        } else {
            // Sample counts are multiples of 10 so the breakpoints of the 0.1s/0.2s keyframe tables land on samples.
            let count = max(10, Int((period * 120 / 10).rounded(.up)) * 10)
            // The last sample stops just short of the loop point so sawtooth motions (z drift) do not retrace.
            animation.values = (0...count).map {
                at(delay + ($0 == count ? period - 1e-9 : period * Double($0) / Double(count)))
            }
        }
        return animation
    }
}

/// Core Animation scene for one skin. Continuous motion lives in keyframe animations the render server
/// runs, so the app does no per-frame work; the art is baked PNG parts (see BakedRig).
@MainActor
class SkinRig {
    let root = CALayer()
    let box: CGRect
    let size: CGSize
    private let pixelsPerUnit: CGFloat
    private var tracked: [(layer: CALayer, tracks: [LayerTrack])] = []

    init(box: CGRect, size: CGSize, backing: CGFloat) {
        self.box = box
        self.size = size
        let fit = min(size.width / box.width, size.height / box.height)
        pixelsPerUnit = fit * backing
        root.bounds = CGRect(origin: .zero, size: size)
        root.anchorPoint = .zero
        root.position = .zero
        // Art is in y-down viewBox units; the flip lives here so every part layer keeps the sheet's coordinates.
        let placed = CGAffineTransform(translationX: (size.width - box.width * fit) / 2,
                                       y: size.height - (size.height - box.height * fit) / 2)
            .scaledBy(x: fit, y: -fit)
            .translatedBy(x: -box.minX, y: -box.minY)
        root.sublayerTransform = CATransform3DMakeAffineTransform(placed)
    }

    /// Rebuilds the layer tree for `mode`, animating from the moment the state began, or frozen
    /// `frozenAt` seconds into it (for stills and tests).
    func show(_ mode: SkinMode, still: Bool, now: CFTimeInterval, frozenAt: Double? = nil) {
        fatalError("subclass responsibility")
    }

    /// Freezes or resumes every animation, keeping their phase.
    func setPaused(_ paused: Bool) {
        let isPaused = root.speed == 0
        guard paused != isPaused else { return }
        if paused {
            root.timeOffset = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
        } else {
            let frozen = root.timeOffset
            root.speed = 1
            root.timeOffset = 0
            root.beginTime = 0
            root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - frozen
        }
    }

    // MARK: Building

    func beginBuild() {
        root.sublayers = nil
        tracked = []
    }

    /// Container whose transform is animated; it has no pixels of its own.
    func group(_ tracks: [LayerTrack] = [], in parent: CALayer? = nil) -> CALayer {
        let layer = CALayer()
        layer.bounds = box
        layer.anchorPoint = CGPoint(x: -box.minX / box.width, y: -box.minY / box.height)
        layer.position = .zero
        (parent ?? root).addSublayer(layer)
        tracked.append((layer, tracks))
        return layer
    }

    /// A layer showing `image`. Without `crop` it covers the whole viewBox, so its transform is in art coordinates.
    @discardableResult
    func art(_ image: CGImage, crop: CGRect? = nil, tracks: [LayerTrack] = [], in parent: CALayer) -> CALayer {
        let layer: CALayer
        if let crop {
            layer = CALayer()
            layer.bounds = CGRect(origin: .zero, size: crop.size)
            layer.anchorPoint = .zero
            layer.position = crop.origin
            parent.addSublayer(layer)
            tracked.append((layer, tracks))
        } else {
            layer = group(tracks, in: parent)
        }
        layer.contents = image
        return layer
    }

    /// Applies model values and attaches animations. `frozenAt` renders one pose instead of animating.
    func finishBuild(start: CFTimeInterval, frozenAt: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, tracks) in tracked {
            let begin = layer.convertTime(start, from: nil)
            for track in tracks {
                if let frozenAt {
                    layer.setValue(track.at(frozenAt), forKeyPath: track.keyPath)
                    continue
                }
                if track.loops { layer.setValue(track.at(0), forKeyPath: track.keyPath) }
                if let animation = track.animation(begin: begin) {
                    layer.add(animation, forKey: track.keyPath + (track.loops ? "" : ".once"))
                }
            }
        }
        CATransaction.commit()
    }

    static func flippedVertically(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// A skin that can run as Core Animation layers instead of a per-frame SwiftUI render.
protocol LayeredSkin: Skin {
    @MainActor func makeRig(size: CGSize, backing: CGFloat) -> SkinRig
}

/// Hosts a rig's layers. It never takes mouse events, so clicks and drags reach the panel as before.
final class CharacterLayerView: NSView {
    private struct Config: Equatable {
        var skin: String
        var size: CGSize
        var backing: CGFloat
    }

    private var rig: SkinRig?
    private var config: Config?
    private var shown: (mode: SkinMode, still: Bool)?
    private var pending: (skin: LayeredSkin, mode: SkinMode, still: Bool, size: CGSize, active: Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Settings previews are dropped when their page closes; free the rig at once so its animations stop.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window == nil {
                rig?.setPaused(true)
                rig?.root.removeFromSuperlayer()
                rig = nil
                config = nil
                shown = nil
            } else {
                refresh()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        MainActor.assumeIsolated { refresh() }
    }

    @MainActor
    func update(skin: LayeredSkin, mode: SkinMode, still: Bool, size: CGSize, active: Bool) {
        pending = (skin, mode, still, size, active)
        refresh()
    }

    @MainActor
    private func refresh() {
        guard let p = pending, let layer else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let wanted = Config(skin: p.skin.id, size: p.size, backing: backing)
        if wanted != config {
            rig?.root.removeFromSuperlayer()
            let next = p.skin.makeRig(size: p.size, backing: backing)
            layer.addSublayer(next.root)
            rig = next
            config = wanted
            shown = nil
        }
        guard let rig else { return }
        if shown?.mode != p.mode || shown?.still != p.still {
            rig.show(p.mode, still: p.still, now: CACurrentMediaTime())
            shown = (p.mode, p.still)
        }
        rig.setPaused(!p.active)
    }
}

struct CharacterLayerHost: NSViewRepresentable {
    let skin: LayeredSkin
    let mode: SkinMode
    let still: Bool
    let size: CGSize
    let active: Bool

    func makeNSView(context: Context) -> CharacterLayerView {
        CharacterLayerView(frame: CGRect(origin: .zero, size: size))
    }

    func updateNSView(_ view: CharacterLayerView, context: Context) {
        view.update(skin: skin, mode: mode, still: still, size: size, active: active)
    }
}
