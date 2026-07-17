import CoreGraphics
import Foundation

// Pure geometry + persistence helpers for the compact widget's position.
// No AppKit window/screen access lives here so the math is unit-testable in
// isolation; PanelController supplies the concrete screen frame and window
// size at call time.
enum CompactPlacement {

    // Which corner a pill centred at `center` is closest to, within
    // `visibleFrame`. AppKit coordinates: y grows upward, so a center below
    // the vertical midpoint is a *bottom* corner.
    static func nearestCorner(toCenter center: CGPoint,
                              in visibleFrame: CGRect) -> CompactCorner {
        switch (center.x < visibleFrame.midX, center.y < visibleFrame.midY) {
        case (true,  false): return .topLeft
        case (false, false): return .topRight
        case (true,  true):  return .bottomLeft
        case (false, true):  return .bottomRight
        }
    }

    // Clamp a pill of `size` positioned at `origin` so it stays fully inside
    // `visibleFrame`, keeping `inset` clearance from every edge. If the frame
    // is smaller than the pill plus insets (maxN < minN), pin to the min inset
    // rather than producing an inverted range.
    static func clamp(origin: CGPoint, size: CGSize,
                      into visibleFrame: CGRect, inset: CGFloat) -> CGPoint {
        let minX = visibleFrame.minX + inset
        let maxX = visibleFrame.maxX - size.width - inset
        let minY = visibleFrame.minY + inset
        let maxY = visibleFrame.maxY - size.height - inset
        let x = maxX >= minX ? min(max(origin.x, minX), maxX) : minX
        let y = maxY >= minY ? min(max(origin.y, minY), maxY) : minY
        return CGPoint(x: x, y: y)
    }

    // Parse a persisted "x,y" string into a point. Returns nil for missing or
    // malformed input so callers can fall back to a corner origin.
    static func parsePosition(_ raw: String?) -> CGPoint? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    // Format a point for persistence as integer "x,y".
    static func formatPosition(_ p: CGPoint) -> String {
        "\(Int(p.x.rounded())),\(Int(p.y.rounded()))"
    }
}
