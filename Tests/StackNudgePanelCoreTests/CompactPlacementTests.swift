import XCTest
import CoreGraphics

@testable import StackNudgePanelCore

final class CompactPlacementTests: XCTestCase {

    // A 1000x1000 frame at origin (0,0); midpoint is (500, 500).
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    // MARK: - nearestCorner (AppKit coords: y grows upward)

    func test_nearestCorner_quadrants() {
        // Below-mid Y = bottom; left/right by X.
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 100, y: 100), in: frame), .bottomLeft)
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 900, y: 100), in: frame), .bottomRight)
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 100, y: 900), in: frame), .topLeft)
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 900, y: 900), in: frame), .topRight)
    }

    func test_nearestCorner_respectsFrameOrigin() {
        // Frame shifted to a second display; midpoint is (2500, 500).
        let shifted = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 2100, y: 900), in: shifted), .topLeft)
        XCTAssertEqual(CompactPlacement.nearestCorner(toCenter: CGPoint(x: 2900, y: 100), in: shifted), .bottomRight)
    }

    // MARK: - frameIndex(containing:in:)

    func test_frameIndex_findsContainingFrame() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100),
                      CGRect(x: 200, y: 0, width: 100, height: 100)]
        XCTAssertEqual(CompactPlacement.frameIndex(containing: CGPoint(x: 50, y: 50), in: frames), 0)
        XCTAssertEqual(CompactPlacement.frameIndex(containing: CGPoint(x: 250, y: 50), in: frames), 1)
    }

    func test_frameIndex_nilWhenPointOnNoFrame() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        XCTAssertNil(CompactPlacement.frameIndex(containing: CGPoint(x: 500, y: 500), in: frames))
        XCTAssertNil(CompactPlacement.frameIndex(containing: CGPoint(x: 50, y: 50), in: []))
    }

    func test_frameIndex_returnsFirstMatchWhenFramesOverlap() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100),
                      CGRect(x: 50, y: 50, width: 100, height: 100)]
        // (60,60) is inside both; expect the first.
        XCTAssertEqual(CompactPlacement.frameIndex(containing: CGPoint(x: 60, y: 60), in: frames), 0)
    }

    // MARK: - clamp

    func test_clamp_insideFrame_isUnchanged() {
        let p = CompactPlacement.clamp(origin: CGPoint(x: 400, y: 400),
                                       size: CGSize(width: 100, height: 50),
                                       into: frame, inset: 14)
        XCTAssertEqual(p, CGPoint(x: 400, y: 400))
    }

    func test_clamp_pullsBackWithinInsetOnAllSides() {
        let size = CGSize(width: 100, height: 50)
        // Off the bottom-left.
        XCTAssertEqual(CompactPlacement.clamp(origin: CGPoint(x: -50, y: -50),
                                              size: size, into: frame, inset: 14),
                       CGPoint(x: 14, y: 14))
        // Off the top-right (maxX = 1000-100-14 = 886, maxY = 1000-50-14 = 936).
        XCTAssertEqual(CompactPlacement.clamp(origin: CGPoint(x: 5000, y: 5000),
                                              size: size, into: frame, inset: 14),
                       CGPoint(x: 886, y: 936))
    }

    func test_clamp_degenerateFrameSmallerThanPill_pinsToMinInset() {
        // Frame narrower/shorter than pill+insets: pin to min inset, no NaN/flip.
        let tiny = CGRect(x: 0, y: 0, width: 80, height: 40)
        let p = CompactPlacement.clamp(origin: CGPoint(x: 999, y: 999),
                                       size: CGSize(width: 100, height: 50),
                                       into: tiny, inset: 14)
        XCTAssertEqual(p, CGPoint(x: 14, y: 14))
    }

    // MARK: - parse / format

    func test_parsePosition_roundTrip() {
        let p = CGPoint(x: 123, y: 456)
        XCTAssertEqual(CompactPlacement.parsePosition(CompactPlacement.formatPosition(p)), p)
    }

    func test_parsePosition_toleratesWhitespace() {
        XCTAssertEqual(CompactPlacement.parsePosition(" 12 , 34 "), CGPoint(x: 12, y: 34))
    }

    func test_parsePosition_rejectsMalformedAndNil() {
        XCTAssertNil(CompactPlacement.parsePosition(nil))
        XCTAssertNil(CompactPlacement.parsePosition(""))
        XCTAssertNil(CompactPlacement.parsePosition("123"))
        XCTAssertNil(CompactPlacement.parsePosition("a,b"))
        XCTAssertNil(CompactPlacement.parsePosition("1,2,3"))
    }

    func test_formatPosition_roundsToIntegers() {
        XCTAssertEqual(CompactPlacement.formatPosition(CGPoint(x: 12.6, y: 34.2)), "13,34")
    }
}
