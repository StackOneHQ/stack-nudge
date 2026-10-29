import Foundation

enum WizardPose {
    private static let sine = MotionTiming(x1: 0.37, y1: 0, x2: 0.63, y2: 1)
    private static let pend = MotionTiming(x1: 0.45, y1: 0.05, x2: 0.55, y2: 0.95)
    private static let soft = MotionTiming(x1: 0.36, y1: 0, x2: 0.3, y2: 1.08)
    private static let out = MotionTiming(x1: 0.2, y1: 0.6, x2: 0.3, y2: 1)

    private static func css(dx: Double = 0, dy: Double = 0, rotate: Double = 0, sx: Double = 1, sy: Double = 1,
                            skew: Double = 0) -> CGAffineTransform {
        cssTransform(dx: dx, dy: dy, rotate: rotate, sx: sx, sy: sy, skew: skew)
    }

    private static func swing(_ p: Double, _ a: Double, _ b: Double, _ timing: MotionTiming) -> Double {
        motionSample(p, [(0, a), (0.5, b), (1, a)], timing)
    }

    private static func tempo(_ mode: SkinMode) -> Double {
        switch mode {
        case .polling: 0.9
        case .pending: 0.8
        case .sleeping: 1.4
        case .muted: 1.15
        default: 1
        }
    }

    private static func breathPeriod(_ mode: SkinMode) -> Double {
        switch mode {
        case .polling: 2.4
        case .thinking: 3.2
        case .pending: 2.8
        case .sleeping: 5
        case .muted: 4.4
        default: 3.6
        }
    }

    private static func amplitude(_ mode: SkinMode) -> Double {
        switch mode {
        case .sleeping: 1.8
        case .muted: 0.8
        default: 1
        }
    }

    /// A part that follows the body, `lag` seconds behind it on its own period.
    private static func lagging(_ period: Double, lag: Double, _ transform: @escaping (Double) -> CGAffineTransform)
        -> BakedMotion {
        BakedMotion(period: period, delay: lag - period, transform: transform)
    }

    private static func uniform(_ s: Double, dx: Double = 0, dy: Double = 0) -> CGAffineTransform {
        css(dx: dx, dy: dy, sx: s, sy: s)
    }

    private static func puff(_ period: Double, delay: Double, dx: Double, dy: Double) -> BakedMotion {
        BakedMotion(period: period, delay: delay, transform: {
            let e = out($0)
            return uniform(0.5 + 0.75 * e, dx: dx * e, dy: dy * e)
        }, opacity: { motionSample($0, [(0, 0), (0.25, 1), (1, 0)], out) })
    }

    private static func spark(_ period: Double, delay: Double = 0) -> BakedMotion {
        BakedMotion(period: period, delay: delay, transform: { uniform(0.6 + 0.8 * out($0)) },
                     opacity: { motionSample($0, [(0, 0), (0.3, 1), (1, 0)], out) })
    }

    private static func pulse(_ period: Double) -> BakedMotion {
        BakedMotion(period: period, transform: { uniform(swing($0, 0.9, 1.06, sine)) },
                     opacity: { swing($0, 0.75, 1, sine) })
    }

    /// The motion of a manifest group, or nil when it holds still in `mode`. `vars` carries a puff's drift.
    static func motion(_ classes: [String], mode: SkinMode, vars: (dx: Double, dy: Double)?) -> BakedMotion? {
        let t = tempo(mode)
        let alert = mode == .alert
        func has(_ c: String) -> Bool { classes.contains(c) }
        let b = has("b"), c = has("c")

        if has("body") {
            switch mode {
            case .alert:
                return BakedMotion(period: 0.3, transform: {
                    css(dx: motionSample($0, [(0, 0), (0.25, -1.2), (0.75, 1.2), (1, 0)], .linear))
                })
            case .error:
                return BakedMotion(period: 2.6, transform: { css(rotate: swing($0, -1.6, 1.6, pend)) })
            default:
                let a = amplitude(mode)
                return BakedMotion(period: breathPeriod(mode), transform: {
                    css(dy: swing($0, 0, -0.8 * a, sine),
                        sx: swing($0, 1 + 0.004 * a, 1 - 0.005 * a, sine), sy: swing($0, 1 - 0.006 * a, 1 + 0.012 * a, sine))
                })
            }
        }
        if has("head") {
            return alert ? nil : lagging(3.9 * t, lag: 0.08) {
                css(dy: swing($0, 0.3, -0.3, pend), rotate: swing($0, -0.5, 0.6, pend))
            }
        }
        if has("hat") {
            return alert ? nil : lagging(4.3 * t, lag: 0.1) { css(rotate: swing($0, -0.8, 1, soft)) }
        }
        if has("tip") {
            if alert { return BakedMotion(period: 0.6, delay: -0.3, transform: { css(rotate: swing($0, -4, 6, soft)) }) }
            return lagging(4.7 * t, lag: 0.15) { css(rotate: swing($0, -3.2, 4.6, soft)) }
        }
        if has("beard") {
            if alert { return BakedMotion(period: 0.6, delay: -0.15, transform: { css(rotate: swing($0, -4, 6, soft)) }) }
            let sway: (Double) -> CGAffineTransform = {
                css(rotate: swing($0, -2.2, 2.2, soft), sy: swing($0, 1, 1.01, soft))
            }
            return mode == .thinking ? lagging(1.8, lag: 0.1, sway) : lagging(3.9 * t, lag: 0.12, sway)
        }
        if has("armL") {
            return alert ? nil : lagging(3.3 * t, lag: 0.1) { css(rotate: swing($0, -0.8, 0.9, pend)) }
        }
        if has("robe") {
            return alert ? BakedMotion(period: 0.6, transform: {
                css(sx: swing($0, 1, 1.05, pend), sy: swing($0, 1, 0.99, pend), skew: swing($0, 0, -3, pend))
            }) : nil
        }
        if has("handL") {
            switch mode {
            case .thinking: return BakedMotion(period: 1.8, transform: { css(dy: swing($0, -3, 6, pend)) })
            case .pending: return BakedMotion(period: 1, transform: { css(rotate: swing($0, -7, 7, pend)) })
            default: return nil
            }
        }
        if has("glow") {
            switch mode {
            case .alert:
                return BakedMotion(period: 0.5, transform: { uniform(swing($0, 1, 1.28, sine)) },
                                    opacity: { swing($0, 0.9, 1, sine) })
            case .error: return nil
            case .thinking: return pulse(3)
            case .pending: return pulse(1)
            case .sleeping: return pulse(5)
            default: return pulse(2.8 * t)
            }
        }
        if has("orbglow") { return pulse(1.4) }
        if has("swirl") { return BakedMotion(period: 4, transform: { css(rotate: $0 * 360) }) }
        if has("bubble") { return BakedMotion(period: 2.4, transform: { css(dy: swing($0, 0, -3, pend)) }) }
        if has("d1") || has("d2") || has("d3") {
            let delay = has("d1") ? 0.0 : has("d2") ? 0.4 : 0.8
            return BakedMotion(period: 2.4, delay: delay, opacity: { $0 < 0.25 ? 0 : 1 }, steps: 24)
        }
        if has("tw") { return spark(1) }
        if has("sp") { return spark(0.5, delay: b ? -0.25 : 0) }
        if has("smoke"), let v = vars { return puff(2.4, delay: b ? -0.8 : c ? -1.6 : 0, dx: v.dx, dy: v.dy) }
        if has("estar") {
            let i = has("es1") ? 0.0 : has("es2") ? 1.0 : 2.0
            let th = i * 2 * Double.pi / 3
            return BakedMotion(period: 2.2, transform: {
                let a = th + $0 * 2 * Double.pi
                return css(dx: 27 * (cos(a) - cos(th)), dy: 7 * (sin(a) - sin(th)))
            })
        }
        if has("zz") {
            return BakedMotion(period: 3.4, delay: b ? -1.7 : 0, transform: {
                let e = out($0)
                return uniform(0.7 + 0.4 * e, dx: -14 * e, dy: -26 * e)
            }, opacity: { motionSample($0, [(0, 0), (0.25, 1), (1, 0)], out) })
        }
        if has("ring") {
            return BakedMotion(period: 3.6, delay: b ? -1.2 : c ? -2.4 : 0, transform: {
                let e = out($0)
                return uniform(0.4 + 0.9 * e, dx: -14 * e, dy: -46 * e)
            }, opacity: { motionSample($0, [(0, 0), (0.15, 1), (0.75, 0.9), (1, 0)], out) })
        }
        return nil
    }

    /// The eyelid layer that closes for a blink; each state blinks on its own period so they never sync.
    static func blink(mode: SkinMode) -> BakedMotion? {
        let (period, delay): (Double, Double) = switch mode {
        case .idle: (5.3, 0)
        case .polling: (6.1, -2)
        case .thinking: (4.7, -1)
        case .pending: (7.3, -3)
        case .alert: (5.9, -4)
        case .muted: (6.7, -5)
        default: (0, 0)
        }
        guard period > 0 else { return nil }
        return BakedMotion(period: period, delay: delay, opacity: { $0 >= 0.935 && $0 < 0.97 ? 1 : 0 }, steps: 100)
    }
}
