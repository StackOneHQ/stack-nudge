import Foundation

/// CSS-style timing: cubic-bezier(x1, y1, x2, y2) solved by bisection.
struct MotionTiming {
    let x1, y1, x2, y2: Double

    static let linear = MotionTiming(x1: 0, y1: 0, x2: 1, y2: 1)
    static let ease = MotionTiming(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let easeInOut = MotionTiming(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let easeIn = MotionTiming(x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let easeOut = MotionTiming(x1: 0, y1: 0, x2: 0.58, y2: 1)

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func axis(_ a: Double, _ b: Double, _ t: Double) -> Double {
            3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if axis(x1, x2, mid) < x { lo = mid } else { hi = mid }
        }
        return axis(y1, y2, (lo + hi) / 2)
    }
}

/// Keyframe sampler: `timing` eases each interval, like CSS animation-timing-function.
func motionSample(_ p: Double, _ keys: [(Double, Double)], _ timing: MotionTiming) -> Double {
    for i in 1..<keys.count where p <= keys[i].0 {
        let (a, va) = keys[i - 1]
        let (b, vb) = keys[i]
        return va + (vb - va) * timing((p - a) / (b - a))
    }
    return keys[keys.count - 1].1
}

func motionCycle(_ t: Double, _ seconds: Double) -> Double {
    t.truncatingRemainder(dividingBy: seconds) / seconds
}

/// A value that glides to each new target over `duration` seconds with CSS `ease`, from wherever it was (the
/// resting angle of an ear that changes with the state).
struct MotionEase {
    var from: Double, to: Double, start: Double
    var duration = 0.6

    func value(at now: Double) -> Double {
        from + (to - from) * MotionTiming.ease((now - start) / duration)
    }

    mutating func set(_ target: Double, at now: Double, snap: Bool) {
        guard target != to else { return }
        from = snap ? target : value(at: now)
        to = target
        start = now
    }
}
