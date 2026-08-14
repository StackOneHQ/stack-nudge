import XCTest

@testable import StackNudgePanelCore

// The poll cadence used to key off `panel.isVisible` alone. In compact mode the
// widget pill IS the panel window and is never ordered out, so that stayed true
// forever: every widget user polled the `claude` CLI every 60 seconds and
// Settings → Poll frequency did nothing. These pin the collapsed-widget case,
// which is the one that regressed.
final class QuotaPollIntervalTests: XCTestCase {

    private let hidden: TimeInterval = 300  // 5 min, the shipped default
    private let visible: TimeInterval = 60

    // The regression: pill on screen, collapsed, so the user's setting applies.
    func testCollapsedWidgetUsesConfiguredInterval() {
        XCTAssertEqual(
            PanelController.quotaPollInterval(visible: true,
                                              compactMode: true,
                                              compactExpanded: false,
                                              hiddenInterval: hidden),
            hidden)
    }

    // Expanded out of the pill, the Usage tab is reachable, so poll fast.
    func testExpandedWidgetUsesVisibleInterval() {
        XCTAssertEqual(
            PanelController.quotaPollInterval(visible: true,
                                              compactMode: true,
                                              compactExpanded: true,
                                              hiddenInterval: hidden),
            visible)
    }

    func testFullPanelOpenUsesVisibleInterval() {
        XCTAssertEqual(
            PanelController.quotaPollInterval(visible: true,
                                              compactMode: false,
                                              compactExpanded: false,
                                              hiddenInterval: hidden),
            visible)
    }

    func testHiddenPanelUsesConfiguredInterval() {
        XCTAssertEqual(
            PanelController.quotaPollInterval(visible: false,
                                              compactMode: false,
                                              compactExpanded: false,
                                              hiddenInterval: hidden),
            hidden)
    }

    // A window that isn't on screen can't be showing usage, whatever the compact
    // flags say.
    func testNotVisibleWinsOverExpandedFlag() {
        XCTAssertEqual(
            PanelController.quotaPollInterval(visible: false,
                                              compactMode: true,
                                              compactExpanded: true,
                                              hiddenInterval: hidden),
            hidden)
    }
}
