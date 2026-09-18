import SwiftUI
import XCTest

@testable import StackNudgePanelCore

// The pure parts of the extension renderer. These are static on the view
// precisely so they can be tested without one — colour parsing, the contrast
// clamp, sprite geometry — and every one of them takes input an extension
// wrote, so "it didn't crash" is not the bar.
final class ExtensionRenderingTests: XCTestCase {

    // MARK: - Colour parsing

    func testSixDigitHex() {
        XCTAssertEqual(ExtensionTabView.hexColor("#FF0000"), Color(.sRGB, red: 1, green: 0, blue: 0))
        XCTAssertEqual(ExtensionTabView.hexColor("#000000"), Color(.sRGB, red: 0, green: 0, blue: 0))
    }

    // #RGB expands by doubling each digit, so #f00 and #ff0000 are one colour.
    func testThreeDigitHexExpands() {
        XCTAssertEqual(ExtensionTabView.hexColor("#f00"), ExtensionTabView.hexColor("#ff0000"))
        XCTAssertEqual(ExtensionTabView.hexColor("#abc"), ExtensionTabView.hexColor("#aabbcc"))
    }

    func testHexIsCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(ExtensionTabView.hexColor("  #AbCdEf  "),
                       ExtensionTabView.hexColor("#abcdef"))
    }

    // Everything a real palette file gets wrong. Each returns nil so the caller
    // can fall back — a cell that silently doesn't draw reads as a render bug.
    func testRejectedColourStrings() {
        for raw in ["red", "ff0000", "#ff00", "#gggggg", "#", "", "#ff0000ff",
                    "#12345", "#1234567", "rgb(1,2,3)"] {
            XCTAssertNil(ExtensionTabView.hexColor(raw), raw)
        }
        XCTAssertNil(ExtensionTabView.hexColor(nil))
    }

    // MARK: - Contrast clamp

    // A well-formed #FFFFFF was an invisible bar in light mode and #111111 an
    // invisible one in dark, so rejecting only *malformed* hex left the half of
    // the problem that actually happens.
    func testWhiteIsDarkenedInLightMode() {
        guard let white = ExtensionTabView.hexColor("#FFFFFF"),
              let fixed = ExtensionTabView.readable(white, dark: false) else {
            return XCTFail("no colour")
        }
        XCTAssertLessThanOrEqual(ExtensionTabView.luminance(fixed),
                                 ExtensionTabView.luminanceCeiling + 0.01)
    }

    func testNearBlackIsLightenedInDarkMode() {
        guard let black = ExtensionTabView.hexColor("#111111"),
              let fixed = ExtensionTabView.readable(black, dark: true) else {
            return XCTFail("no colour")
        }
        XCTAssertGreaterThanOrEqual(ExtensionTabView.luminance(fixed),
                                    ExtensionTabView.luminanceFloor - 0.01)
    }

    // A colour that already reads well is returned untouched — the clamp must
    // not dull every palette on the way past.
    func testAReadableColourIsLeftAlone() {
        guard let mid = ExtensionTabView.hexColor("#7FD1B9") else { return XCTFail("no colour") }
        XCTAssertEqual(ExtensionTabView.readable(mid, dark: false), mid)
        XCTAssertEqual(ExtensionTabView.readable(mid, dark: true), mid)
    }

    // Blended toward the opposite end rather than snapped to grey, so a pale
    // yellow stays yellow — it just stops being white.
    func testClampingKeepsHue() {
        guard let paleYellow = ExtensionTabView.hexColor("#FFFFCC"),
              let fixed = ExtensionTabView.readable(paleYellow, dark: false) else {
            return XCTFail("no colour")
        }
        let rgb = NSColor(fixed).usingColorSpace(.sRGB) ?? .white
        XCTAssertGreaterThan(rgb.redComponent, rgb.blueComponent, "yellow must stay yellow")
        XCTAssertGreaterThan(rgb.greenComponent, rgb.blueComponent)
    }

    func testReadablePassesNilThrough() {
        XCTAssertNil(ExtensionTabView.readable(nil, dark: false))
    }

    // The clamp runs inside a Canvas draw and at launch, where NSApp can be nil.
    // Reading it unguarded was a crash, not a wrong colour.
    func testReadableWorksWithoutARunningApplication() {
        XCTAssertNotNil(ExtensionTabView.readable(ExtensionTabView.hexColor("#FFFFFF")))
    }

    // MARK: - Sprite geometry

    private func ornament(_ json: String) -> ExtensionDocument.Ornament {
        guard case .success(let document) = ExtensionDocument.parse(Data("""
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":\(json)}]}
            """.utf8)), let ornament = document.rows.first?.ornament else {
            fatalError("fixture ornament didn't parse")
        }
        return ornament
    }

    // One width across every frame. Sizing the canvas from the current frame
    // while anchoring from the global maximum made a ragged sprite resize and
    // jump on every tick, and park left of the fill edge.
    func testSpriteSizeIsTakenAcrossEveryFrame() {
        let ragged = ornament("""
            {"fps":4,"palette":{"H":"#fff"},"frames":[["HH"],["HHHH","HH"]]}
            """)
        XCTAssertEqual(SpriteView.columns(ragged), 4)
        XCTAssertEqual(SpriteView.rows(ragged), 2)
    }

    func testLeadingAnchorParksAtZero() {
        let sprite = ornament("""
            {"anchor":"leading","palette":{"H":"#fff"},"frames":[["HHHH"]]}
            """)
        XCTAssertEqual(sprite.anchor, .leading)
        XCTAssertEqual(ExtensionTabView.spriteOffset(sprite, fill: 0.5, width: 100), 0)
    }

    func testTrailingAnchorParksAtTheFarEdge() {
        let sprite = ornament("""
            {"anchor":"trailing","palette":{"H":"#fff"},"frames":[["HHHH"]]}
            """)
        let width = SpriteView.cell * 4
        XCTAssertEqual(ExtensionTabView.spriteOffset(sprite, fill: 0, width: 100), 100 - width)
    }

    // fill-edge is what makes a progress bar read as a race: the sprite rides
    // the head of the fill, centred on it.
    func testFillEdgeAnchorTracksTheFill() {
        let sprite = ornament("""
            {"anchor":"fill-edge","palette":{"H":"#fff"},"frames":[["HHHH"]]}
            """)
        let half = ExtensionTabView.spriteOffset(sprite, fill: 0.5, width: 100)
        let quarter = ExtensionTabView.spriteOffset(sprite, fill: 0.25, width: 100)
        XCTAssertGreaterThan(half, quarter)
        XCTAssertEqual(half, 50 - (SpriteView.cell * 4) / 2, accuracy: 0.01)
    }

    // Clamped at both ends, so a sprite at 0% or 100% still draws inside the
    // track rather than half off the pane.
    func testFillEdgeIsClampedInsideTheTrack() {
        let sprite = ornament("""
            {"anchor":"fill-edge","palette":{"H":"#fff"},"frames":[["HHHH"]]}
            """)
        let width = SpriteView.cell * 4
        XCTAssertEqual(ExtensionTabView.spriteOffset(sprite, fill: 0, width: 100), 0)
        XCTAssertEqual(ExtensionTabView.spriteOffset(sprite, fill: 1, width: 100), 100 - width)
    }

    // A sprite wider than the track can't be centred anywhere sensible; it must
    // still start at the left rather than at a negative offset.
    func testASpriteWiderThanTheTrackStartsAtTheLeft() {
        let sprite = ornament("""
            {"anchor":"fill-edge","palette":{"H":"#fff"},"frames":[["HHHHHHHH"]]}
            """)
        XCTAssertEqual(ExtensionTabView.spriteOffset(sprite, fill: 0.5, width: 4), 0)
    }

    // MARK: - Bar thickness

    // The fill is inset inside the track so a ghost behind it can't be hidden by
    // its own edge. Asked per-document: within one list every bar should be the
    // same thickness, but a document that never uses a ghost has no reason to
    // draw a half-height line in a full-height groove — which is exactly what it
    // looked like.
    func testAFillWithNothingBehindItFillsTheTrack() {
        XCTAssertEqual(ExtensionTabView.fillHeight(inset: false), ExtensionTabView.barHeight)
    }

    // Asserting "less than" passed for any value below the bar height, which
    // left the actual inset unpinned.
    func testAFillWithAGhostBehindItIsInsetToHalfTheTrack() {
        XCTAssertEqual(ExtensionTabView.fillHeight(inset: true), ExtensionTabView.barHeight / 2)
    }

    private func document(_ json: String) -> ExtensionDocument {
        guard case .success(let d) = ExtensionDocument.parse(Data(json.utf8)) else {
            fatalError("fixture didn't parse")
        }
        return d
    }

    func testADocumentWithNoGhostsDoesNotInset() {
        let d = document("""
            {"schema":1,"rows":[{"id":"a","title":"A","track":{"fill":0.5}},
                                {"id":"b","title":"B","track":{"fill":0.2}}]}
            """)
        XCTAssertFalse(d.usesGhostBars)
    }

    // One row using a ghost insets the whole list, so bars don't change
    // thickness partway down it.
    func testOneGhostAnywhereInsetsTheWholeDocument() {
        let d = document("""
            {"schema":1,"rows":[{"id":"a","title":"A","track":{"fill":0.5}},
                                {"id":"b","title":"B","track":{"fill":0.2,"ghost":0.4}}]}
            """)
        XCTAssertTrue(d.usesGhostBars)
    }

    func testADocumentWithNoTracksDoesNotInset() {
        XCTAssertFalse(document("{\"schema\":1,\"rows\":[{\"id\":\"a\",\"title\":\"A\"}]}").usesGhostBars)
    }

    // MARK: - Band height

    // The row's bar band has to make room for the sprite riding on it. Clipping
    // to the bar's own 6pt is how an 11-row horse became a 4-row smudge — the
    // overflow fix has to make room, not just cut.
    func testTheBandGrowsToFitATallSprite() {
        let horse = ornament("""
            {"fps":7,"palette":{"H":"#fff"},
             "frames":[["HHHH","HHHH","HHHH","HHHH","HHHH","HHHH",
                        "HHHH","HHHH","HHHH","HHHH","HHHH"]]}
            """)
        XCTAssertEqual(SpriteView.rows(horse), 11)
        let band = ExtensionTabView.bandHeight(for: horse)
        XCTAssertGreaterThanOrEqual(band, CGFloat(11) * SpriteView.cell,
                                    "an 11-row sprite must not be clipped")
    }

    // A short sprite doesn't shrink the band below the bar's own slot, so rows
    // with and without ornaments keep the same rhythm.
    func testAShortSpriteKeepsTheDefaultBand() {
        let small = ornament("{\"palette\":{\"H\":\"#fff\"},\"frames\":[[\"HH\",\"HH\"]]}")
        XCTAssertEqual(ExtensionTabView.bandHeight(for: small), 12)
        XCTAssertEqual(ExtensionTabView.bandHeight(for: nil), 12)
    }

    // A short marker beside a tall sprite must not shrink the band the sprite
    // needs — the finish post is 11 rows, but a 2-row one alongside a horse
    // would have clipped it if the band took the last ornament rather than the
    // tallest.
    func testTheBandFitsTheTallestOrnament() {
        let tall = ornament("""
            {"palette":{"H":"#fff"},
             "frames":[["H","H","H","H","H","H","H","H","H","H","H"]]}
            """)
        let short = ornament("{\"palette\":{\"W\":\"#fff\"},\"frames\":[[\"W\",\"W\"]]}")
        XCTAssertEqual(ExtensionTabView.bandHeight(for: [short, tall]),
                       ExtensionTabView.bandHeight(for: [tall]))
        XCTAssertGreaterThan(ExtensionTabView.bandHeight(for: [short, tall]),
                             ExtensionTabView.bandHeight(for: [short]))
    }

    func testAnEmptyOrnamentListKeepsTheDefaultBand() {
        XCTAssertEqual(ExtensionTabView.bandHeight(for: []), 12)
    }

    // The finish post is anchored trailing, so it parks at the far edge and
    // stays there whatever the fill does — that is what makes it a line rather
    // than something the horse drags along.
    func testATrailingOrnamentIgnoresTheFill() {
        let post = ornament("""
            {"anchor":"trailing","palette":{"W":"#fff"},"frames":[["WK"]]}
            """)
        let atStart = ExtensionTabView.spriteOffset(post, fill: 0, width: 100)
        let atEnd = ExtensionTabView.spriteOffset(post, fill: 1, width: 100)
        XCTAssertEqual(atStart, atEnd)
        XCTAssertEqual(atEnd, 100 - SpriteView.cell * 2)
    }

    // MARK: - Labels

    func testKeyCaps() {
        XCTAssertEqual(ExtensionTabView.keyCap("return"), "⏎")
        XCTAssertEqual(ExtensionTabView.keyCap("r"), "R")
        XCTAssertEqual(ExtensionTabView.keyCap("7"), "7")
    }

    // The spoken value for a bar on a row with no printed number.
    func testPercentLabelRoundsAndClamps() {
        XCTAssertEqual(ExtensionTabView.percentLabel(0.524), "52%")
        XCTAssertEqual(ExtensionTabView.percentLabel(0), "0%")
        XCTAssertEqual(ExtensionTabView.percentLabel(1), "100%")
        XCTAssertEqual(ExtensionTabView.percentLabel(-3), "0%")
        XCTAssertEqual(ExtensionTabView.percentLabel(4), "100%")
    }

    func testEveryToneHasAColour() {
        var seen = Set<String>()
        for tone in [ExtensionDocument.Tone.neutral, .success, .warning, .danger] {
            seen.insert(ExtensionTabView.color(tone).description)
        }
        XCTAssertEqual(seen.count, 4, "two tones render identically")
    }
}
