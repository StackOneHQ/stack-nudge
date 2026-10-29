import AppKit
import ImageIO

/// One entry of a baked layer tree: an animated group with a pivot, or an image with its box.
/// Coordinates are viewBox units of the design sheet the art was baked from.
struct BakedItem: Decodable {
    let type: String
    let classes: [String]?
    let pivot: [Double]?
    let vars: Vars?
    let children: [BakedItem]?
    let src: String?
    let x: Double?, y: Double?, w: Double?, h: Double?
    let blink: Bool?
    let anim: Anim?
    /// A glide group (the ears) rests at this rotation, in degrees about its pivot, and eases to it over `glide`
    /// seconds from the previous state's angle. Its images are baked upright.
    let rest: Double?
    let glide: Double?
    /// A group the sheet dims as a whole (muted), so overlapping parts do not show through each other.
    let opacity: Double?

    struct Vars: Decodable { let dx: Double, dy: Double }

    /// A group's CSS motion sampled by the bake over one loop: `transform` is six numbers per sample (a b c d e f of
    /// the matrix about the pivot), `opacity` one per sample, `steps` when opacity jumps instead of fading. `delay`
    /// holds the first sample for that many seconds (a mark that appears late), and `still` is the point of the loop,
    /// 0 to 1, that reduced motion draws.
    struct Anim: Decodable {
        let period: Double
        let transform: [Double]?
        let opacity: [Double]?
        let steps: Bool?
        var delay: Double? = nil
        var still: Double? = nil
    }
}

struct BakedManifest: Decodable {
    let viewBox: [Double]
    let states: [String: [BakedItem]]
}

/// Motion of one layer group of a baked skin: the CSS keyframes of its design sheet. Transforms are about the
/// group's pivot; the closures take the position in the loop, 0 to 1.
struct BakedMotion {
    var period: Double
    /// CSS animation-delay in seconds; a negative one starts the loop part-way, which is how parts lag the body.
    var delay = 0.0
    /// Seconds the first sample is held before the loop starts.
    var startDelay = 0.0
    /// Where reduced motion draws the loop, 0 to 1.
    var stillAt = 0.0
    var transform: ((Double) -> CGAffineTransform)?
    var opacity: ((Double) -> Double)?
    /// Opacity changes in jumps (the thought dots), sampled in this many equal slots.
    var steps: Int?

    func phase(_ t: Double) -> Double {
        let cycle = (max(t - startDelay, 0) - delay).truncatingRemainder(dividingBy: period) / period
        return cycle < 0 ? cycle + 1 : cycle
    }
}

extension BakedMotion {
    /// The motion a bake recorded for a group (see `BakedItem.Anim`), played back by interpolating its samples.
    init(sampled anim: BakedItem.Anim) {
        self.init(period: anim.period)
        startDelay = anim.delay ?? 0
        stillAt = anim.still ?? 0
        if let samples = anim.transform, samples.count >= 12 {
            let count = samples.count / 6
            transform = { p in
                let x = p * Double(count)
                let i = Int(x) % count, j = (i + 1) % count, f = x - Double(Int(x))
                func v(_ k: Int) -> Double { samples[i * 6 + k] + (samples[j * 6 + k] - samples[i * 6 + k]) * f }
                return CGAffineTransform(a: v(0), b: v(1), c: v(2), d: v(3), tx: v(4), ty: v(5))
            }
        }
        if let samples = anim.opacity, !samples.isEmpty {
            let count = samples.count
            opacity = { p in
                let x = p * Double(count)
                let i = Int(x) % count, j = (i + 1) % count, f = x - Double(Int(x))
                return anim.steps == true ? samples[i] : samples[i] + (samples[j] - samples[i]) * f
            }
            if anim.steps == true { steps = count }
        }
    }
}

/// CSS `translate rotate scale skewX`, in that order, about the origin.
func cssTransform(dx: Double = 0, dy: Double = 0, rotate: Double = 0, sx: Double = 1, sy: Double = 1,
                  skew: Double = 0) -> CGAffineTransform {
    CGAffineTransform(a: 1, b: 0, c: tan(skew * .pi / 180), d: 1, tx: 0, ty: 0)
        .concatenating(CGAffineTransform(scaleX: sx, y: sy))
        .concatenating(CGAffineTransform(rotationAngle: rotate * .pi / 180))
        .concatenating(CGAffineTransform(translationX: dx, y: dy))
}

/// A skin as layers built from a baked manifest. The PNGs are the design sheet's SVG clay filters rendered once
/// at build time, so the app runs no filters; motion is keyframe animations the render server runs.
/// Subclasses say how each group of the sheet moves.
@MainActor
class BakedRig: SkinRig {
    private let assets: URL
    private let manifest: BakedManifest?
    private var loaded: [String: CGImage] = [:]
    private var glides: [String: MotionEase] = [:]

    init(size: CGSize, backing: CGFloat, assets: URL, name: String, fallbackBox: [Double]) {
        self.assets = assets
        let decoded = (try? Data(contentsOf: assets.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONDecoder().decode(BakedManifest.self, from: $0) }
        if decoded == nil { NSLog("stack-nudge: \(name) assets missing at \(assets.path)") }
        manifest = decoded
        let v = decoded?.viewBox ?? fallbackBox
        super.init(box: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), size: size, backing: backing)
    }

    static func bundled(_ folder: String) -> URL {
        (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("skins/\(folder)")
    }

    /// The motion of a manifest group, or nil when it holds still in `mode`. `vars` carries a puff's drift.
    func motion(_ classes: [String], mode: SkinMode, vars: (dx: Double, dy: Double)?) -> BakedMotion? { nil }

    /// The eyelid layer that closes for a blink (a manifest image marked `blink`).
    func blink(mode: SkinMode) -> BakedMotion? { nil }

    /// A shape in viewBox units that a group is masked to, for parts that must not leave a window as they move.
    func clip(_ classes: [String], mode: SkinMode) -> CGPath? { nil }

    private func pivoted(_ pivot: [Double], _ m: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -pivot[0], y: -pivot[1]).concatenating(m)
            .concatenating(CGAffineTransform(translationX: pivot[0], y: pivot[1]))
    }

    private func image(at path: String) -> CGImage? {
        if let hit = loaded[path] { return hit }
        guard let source = CGImageSourceCreateWithURL(assets.appendingPathComponent(path) as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let flipped = Self.flippedVertically(raw)
        else { return nil }
        loaded[path] = flipped
        return flipped
    }

    private func tracks(_ motion: BakedMotion?, pivot: [Double]?, still: Bool, animated: Bool) -> [LayerTrack] {
        guard let motion, !still else { return [] }
        let period: Double? = animated ? motion.period : nil
        var result: [LayerTrack] = []
        if let transform = motion.transform {
            let pivot = pivot ?? [0, 0]
            var track = LayerTrack.transform(period: period) { self.pivoted(pivot, transform(motion.phase($0))) }
            track.delay = motion.startDelay
            result.append(track)
        }
        if let opacity = motion.opacity {
            var track = LayerTrack(keyPath: "opacity", at: { Float(opacity(motion.phase($0))) }, period: period)
            track.steps = motion.steps
            track.delay = motion.startDelay
            result.append(track)
        }
        return result
    }

    private func rotation(_ pivot: [Double], _ degrees: Double) -> CGAffineTransform {
        pivoted(pivot, CGAffineTransform(rotationAngle: degrees * .pi / 180))
    }

    /// Tracks of a glide group: it holds its resting angle and, when the state just changed, eases there from the
    /// angle the previous state left it at. The first tree after the rig is made, and reduced motion, snap.
    private func restTracks(_ item: BakedItem, rest: Double, key: String, now: CFTimeInterval, still: Bool,
                            animated: Bool, steady: Bool) -> [LayerTrack] {
        let pivot = item.pivot ?? [0, 0]
        let glide = item.glide ?? 0.6
        let first = glides[key] == nil
        var ease = glides[key] ?? MotionEase(from: rest, to: rest, start: now, duration: glide)
        ease.set(rest, at: now, snap: still || first)
        glides[key] = ease
        var result: [LayerTrack] = []
        if !steady { result.append(.transform(period: nil) { _ in self.rotation(pivot, rest) }) }
        let from = ease.value(at: now)
        if animated, abs(from - rest) > 0.01 {
            var track = LayerTrack.transform(period: glide) {
                self.rotation(pivot, from + (rest - from) * MotionTiming.ease($0 / glide))
            }
            track.loops = false
            result.append(track)
        }
        return result
    }

    override func show(_ mode: SkinMode, still: Bool, now: CFTimeInterval, frozenAt: Double? = nil) {
        let animated = !still && frozenAt == nil
        beginBuild()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let top = group()
        guard let items = manifest?.states[String(describing: mode)] else {
            finishBuild(start: now, frozenAt: frozenAt)
            return
        }

        func build(_ items: [BakedItem], in parent: CALayer) {
            for item in items {
                if item.type == "node" {
                    let classes = item.classes ?? []
                    let vars = item.vars.map { (dx: $0.dx, dy: $0.dy) }
                    let motion = item.anim.map { BakedMotion(sampled: $0) } ?? motion(classes, mode: mode, vars: vars)
                    var holder = parent
                    if let path = clip(classes, mode: mode) {
                        holder = group(in: parent)
                        let mask = CAShapeLayer()
                        mask.bounds = box
                        mask.anchorPoint = .zero
                        mask.position = box.origin
                        mask.path = path
                        holder.mask = mask
                    }
                    var nodeTracks = tracks(motion, pivot: item.pivot, still: still, animated: animated)
                    if let rest = item.rest {
                        nodeTracks += restTracks(item, rest: rest, key: classes.joined(separator: "."), now: now, still: still,
                                                 animated: animated, steady: motion?.transform != nil)
                    }
                    let node = group(nodeTracks, in: holder)
                    if let opacity = item.opacity { node.opacity = Float(opacity) }
                    if still, item.anim != nil, let motion {
                        // Reduced motion draws the pose the sheet shows at `still` (its first moment by default), not a part
                        // that is hidden or displaced by it.
                        if let transform = motion.transform {
                            node.transform = CATransform3DMakeAffineTransform(pivoted(item.pivot ?? [0, 0], transform(motion.stillAt)))
                        }
                        if let opacity = motion.opacity { node.opacity = Float(opacity(motion.stillAt)) }
                    }
                    if still, let rest = item.rest { node.transform = CATransform3DMakeAffineTransform(rotation(item.pivot ?? [0, 0], rest)) }
                    build(item.children ?? [], in: node)
                } else if let src = item.src, let picture = image(at: src),
                          let x = item.x, let y = item.y, let w = item.w, let h = item.h {
                    let blinking = item.blink == true
                    let motion = blinking ? blink(mode: mode) : nil
                    let layer = art(picture, crop: CGRect(x: x, y: y, width: w, height: h),
                                    tracks: tracks(motion, pivot: nil, still: still, animated: animated), in: parent)
                    layer.minificationFilter = .trilinear
                    if blinking { layer.opacity = 0 }
                }
            }
        }
        build(items, in: top)
        finishBuild(start: now, frozenAt: frozenAt)
    }
}
