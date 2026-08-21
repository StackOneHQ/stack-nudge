import CoreGraphics
import Foundation

// Pure geometry + persistence helpers for the compact widget's position.
// No AppKit window/screen access lives here so the math is unit-testable in
// isolation; PanelController supplies the concrete screen frame and window
// size at call time.
enum CompactPlacement {

    // Which corner a pill centred at `center` is closest to, within
    // `visibleFrame`. AppKit coordinates: y grows upward, so a center below
    // the vertical midpoint is a *bottom* corner. A center exactly on midX/midY
    // ties to the right/top (the `<` comparisons are false).
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

    // Index of the first frame that contains `point`, or nil if the point is
    // on no frame. Used to find which screen a free-placed pill lives on.
    static func frameIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    // The region a free-placed pill may occupy on a screen: full width and down
    // to the physical bottom of `frame` (so it can sit over the Dock), but
    // capped at the top of `visibleFrame` (just under the menu bar). Clamping a
    // pill into this keeps it fully on-screen while allowing Dock-level
    // placement. AppKit coords (y up): the menu bar is at the top, so
    // visibleFrame.maxY is the underside of the menu bar.
    static func placementBounds(frame: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: frame.width, height: visibleFrame.maxY - frame.minY)
    }

    // Parse a persisted "x,y" string into a point. Returns nil for missing or
    // malformed input so callers can fall back to a corner origin.
    static func parsePosition(_ raw: String?) -> CGPoint? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)), x.isFinite,
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)), y.isFinite
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    // Format a point for persistence as integer "x,y".
    static func formatPosition(_ p: CGPoint) -> String {
        "\(Int(p.x.rounded())),\(Int(p.y.rounded()))"
    }
}
