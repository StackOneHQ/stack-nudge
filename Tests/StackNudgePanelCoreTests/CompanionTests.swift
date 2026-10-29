import XCTest
import CoreGraphics

@testable import StackNudgePanelCore

final class CompanionModeTests: XCTestCase {

    func testQuietCompanionIdlesThenSleeps() {
        XCTAssertEqual(CompanionMode.mode(for: CompanionSignals()), .idle)
        let justShort = CompanionSignals(quietFor: CompanionMode.sleepAfter - 1)
        XCTAssertEqual(CompanionMode.mode(for: justShort), .idle)
        let quiet = CompanionSignals(quietFor: CompanionMode.sleepAfter)
        XCTAssertEqual(CompanionMode.mode(for: quiet), .sleeping)
    }

    func testSessionsKeepItAwake() {
        XCTAssertEqual(CompanionMode.mode(for: CompanionSignals(sessionsLive: true, quietFor: 3600)), .polling)
        XCTAssertEqual(CompanionMode.mode(for: CompanionSignals(sessionBusy: true, sessionsLive: true)), .thinking)
    }

    // Each signal must win over everything below it; a reordering of the ifs
    // would otherwise only show up as the wrong pose on someone's desktop.
    // A preview shows over everything, mute included.
    func testAPreviewOutranksEverything() {
        let s = CompanionSignals(preview: .sleeping, muted: true, permissionWaiting: true, quotaStressed: true,
                                 eventWaiting: true, sessionBusy: true, sessionsLive: true)
        XCTAssertEqual(CompanionMode.mode(for: s), .sleeping)
    }

    func testPriorityOrder() {
        var s = CompanionSignals(muted: true, permissionWaiting: true, quotaStressed: true,
                                 eventWaiting: true, sessionBusy: true, sessionsLive: true)
        XCTAssertEqual(CompanionMode.mode(for: s), .muted)
        s.muted = false
        XCTAssertEqual(CompanionMode.mode(for: s), .alert, "quota stress is the alert")
        s.quotaStressed = false
        XCTAssertEqual(CompanionMode.mode(for: s), .pending)
        s.eventWaiting = false
        XCTAssertEqual(CompanionMode.mode(for: s), .pending, "a prompt waits, it doesn't alarm")
        s.permissionWaiting = false
        XCTAssertEqual(CompanionMode.mode(for: s), .thinking)
    }
}

final class CompanionPlacementTests: XCTestCase {

    private let size = CGSize(width: 130, height: 144)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testAnchorInsideScreenIsLeftAlone() {
        let p = CGPoint(x: 600, y: 300)
        XCTAssertEqual(CompanionPlacement.clamp(p, size: size, screens: [screen]), p)
    }

    // The anchor is the bottom-right corner, so the whole character must fit
    // to its left and above it.
    func testAnchorIsPulledSoTheWholeCharacterShows() {
        XCTAssertEqual(CompanionPlacement.clamp(CGPoint(x: 50, y: -40), size: size, screens: [screen]),
                       CGPoint(x: 130, y: 0))
        XCTAssertEqual(CompanionPlacement.clamp(CGPoint(x: 1200, y: 790), size: size, screens: [screen]),
                       CGPoint(x: 1000, y: 656))
    }

    // A spot saved on a display that is gone lands on the nearest one left.
    func testAnchorOnMissingDisplayMovesToNearestScreen() {
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let clamped = CompanionPlacement.clamp(CGPoint(x: 2500, y: 400), size: size, screens: [screen, right])
        XCTAssertEqual(clamped, CGPoint(x: 2000, y: 400))
    }

    func testNoScreensKeepsTheAnchor() {
        let p = CGPoint(x: -5000, y: 9000)
        XCTAssertEqual(CompanionPlacement.clamp(p, size: size, screens: []), p)
    }

    // The panel opens into the open side of the screen: above a character in
    // the bottom half, below one in the top half, never off the edge.
    func testPanelOpensAboveCharacterInBottomRight() {
        let character = CGRect(x: 850, y: 20, width: 130, height: 144)
        let frame = CompanionPlacement.panelFrame(character: character, visible: screen,
                                                  size: CGSize(width: 600, height: 320))
        XCTAssertEqual(frame, CGRect(x: 380, y: 168, width: 600, height: 320))
    }

    func testPanelOpensBelowCharacterInTopLeft() {
        let character = CGRect(x: 20, y: 640, width: 130, height: 144)
        let frame = CompanionPlacement.panelFrame(character: character, visible: screen,
                                                  size: CGSize(width: 600, height: 320))
        XCTAssertEqual(frame, CGRect(x: 20, y: 316, width: 600, height: 320))
    }

    func testPanelStaysOnScreenWhenThereIsNoRoom() {
        let character = CGRect(x: 850, y: 600, width: 130, height: 144)
        let frame = CompanionPlacement.panelFrame(character: character, visible: screen,
                                                  size: CGSize(width: 600, height: 700))
        XCTAssertTrue(screen.contains(frame), "\(frame)")
    }

    func testOriginSitsLeftOfTheAnchor() {
        XCTAssertEqual(CompanionPlacement.origin(anchor: CGPoint(x: 900, y: 40), size: size),
                       CGPoint(x: 770, y: 40))
    }
}

final class CompanionSkinsTests: XCTestCase {

    // A config written by a newer build can name a skin this one lacks; the
    // companion must still show someone rather than nothing.
    func testUnknownSkinFallsBackToDefault() {
        XCTAssertEqual(CompanionSkins.skin(id: "no-such-skin").id, CompanionSkins.defaultID)
        XCTAssertEqual(CompanionSkins.skin(id: nil).id, CompanionSkins.defaultID)
        XCTAssertTrue(CompanionSkins.ids().contains(CompanionSkins.defaultID))
    }

    // Every skin is drawn in a 90:100 frame, at every size.
    func testSizesKeepTheSkinAspect() {
        for size in CompanionSize.allCases {
            let p = size.points
            XCTAssertEqual(p.height, (p.width * 100 / 90).rounded(), "\(size)")
        }
    }

    // Every registered skin needs its baked art in the repo, or the app ships
    // a character with nothing to draw. Found from the working directory, as in
    // ChangelogTests: the no-Xcode runner compiles out of a temp stage.
    func testEverySkinHasBakedArt() throws {
        let manager = FileManager.default
        var directory = URL(fileURLWithPath: manager.currentDirectoryPath)
        var found: URL?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("assets/skins")
            if manager.fileExists(atPath: candidate.path) { found = candidate; break }
            directory = directory.deletingLastPathComponent()
        }
        let root = try XCTUnwrap(found, "no assets/skins above \(manager.currentDirectoryPath)")
        for id in CompanionSkins.ids() {
            let manifest = root.appendingPathComponent("\(id)/manifest.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "no baked art for \(id)")
        }
    }
}

@MainActor
final class CompanionSettingsTests: XCTestCase {

    func testCompanionRowsLiveInTheirOwnCategory() {
        let nav = PanelNav()
        nav.companionEnabled = true
        XCTAssertEqual(nav.rows(in: .companion),
                       [.companionBadge, .companionSize, .companionPreviewPose, .companionResetPosition])
        XCTAssertEqual(nav.rows(in: .appearance).first, .floatingWidget)
        XCTAssertFalse(nav.rows(in: .appearance).contains(.companionTurnOn))
    }

    // Off, the way in leads the tab so the keyboard lands on it.
    func testTheTabLeadsWithTurnOnWhileTheCompanionIsOff() {
        let nav = PanelNav()
        nav.companionEnabled = false
        XCTAssertEqual(nav.rows(in: .companion).first, .companionTurnOn)
        XCTAssertEqual(nav.rows(in: .companion).count, 5)
    }

    func testFloatingWidgetFollowsTheTwoFlags() {
        let nav = PanelNav()
        nav.companionEnabled = true
        nav.widgetPreferred = true
        XCTAssertEqual(nav.floatingWidget, .companion)
        nav.companionEnabled = false
        XCTAssertEqual(nav.floatingWidget, .pill)
        nav.widgetPreferred = false
        XCTAssertEqual(nav.floatingWidget, .off)
    }

    // Existing installs are offered the companion once; the offer goes away
    // when it is on or has been seen.
    func testTheOfferIsForInstallsThatHaveNeitherTurnedItOnNorSeenIt() {
        let nav = PanelNav()
        nav.companionEnabled = false
        nav.companionOffered = false
        XCTAssertTrue(nav.showCompanionOffer)
        nav.companionOffered = true
        XCTAssertFalse(nav.showCompanionOffer)
        nav.companionOffered = false
        nav.companionEnabled = true
        XCTAssertFalse(nav.showCompanionOffer)
    }
}

final class CompanionBadgeTests: XCTestCase {

    func testCountsReadAsAnAppIconBadgeDoes() {
        XCTAssertEqual(CompanionCountBadge.text(1), "1")
        XCTAssertEqual(CompanionCountBadge.text(99), "99")
        XCTAssertEqual(CompanionCountBadge.text(100), "99+")
    }
}

final class FloatingWidgetMigrationTests: XCTestCase {

    private func resolve(_ config: [String: String]) -> FloatingWidget {
        FloatingWidget.resolve(config)
    }

    func testTheNewKeyWins() {
        XCTAssertEqual(resolve(["STACKNUDGE_FLOATING_WIDGET": "off", "STACKNUDGE_COMPANION": "true"]), .off)
        XCTAssertEqual(resolve(["STACKNUDGE_FLOATING_WIDGET": "pill", "STACKNUDGE_COMPACT_MODE": "false"]), .pill)
        XCTAssertEqual(resolve(["STACKNUDGE_FLOATING_WIDGET": "companion"]), .companion)
    }

    func testCompanionOnMeansCompanionWhateverTheWidgetKeySays() {
        XCTAssertEqual(resolve(["STACKNUDGE_COMPANION": "true"]), .companion)
        XCTAssertEqual(resolve(["STACKNUDGE_COMPANION": "true", "STACKNUDGE_COMPACT_MODE": "false"]), .companion)
    }

    func testWidgetOnMeansPillAndWidgetOffMeansOff() {
        XCTAssertEqual(resolve(["STACKNUDGE_COMPANION": "false"]), .pill)
        XCTAssertEqual(resolve(["STACKNUDGE_COMPACT_MODE": "true"]), .pill)
        XCTAssertEqual(resolve(["STACKNUDGE_COMPACT_MODE": "false"]), .off)
    }

    func testAnEmptyConfigKeepsThePill() {
        XCTAssertEqual(resolve([:]), .pill)
    }

    func testAnUnknownValueFallsBackToTheOldKeys() {
        XCTAssertEqual(resolve(["STACKNUDGE_FLOATING_WIDGET": "blob", "STACKNUDGE_COMPACT_MODE": "false"]), .off)
    }
}
