import XCTest

@testable import StackNudgePanelCore

// The pill has room for one extension chip. Which one, and how the rest are
// counted, is the part of the widget that can be got wrong without drawing it.
final class CompactGlanceTests: XCTestCase {

    private func glance(_ id: String, _ tone: ExtensionDocument.Tone) -> ExtensionGlance {
        ExtensionGlance(id: id, label: id, text: "1 DUE", tone: tone, trailing: nil)
    }

    func testNothingToShowShowsNothing() {
        XCTAssertNil(CompactView.glanceToShow([]))
    }

    func testOneGlanceIsShownWithNothingBehindIt() {
        XCTAssertEqual(CompactView.glanceToShow([glance("pylon", .warning)]),
                       .init(glance: glance("pylon", .warning), more: 0))
    }

    // Danger outranks warning wherever it sits in tab order, and the others
    // are counted rather than dropped, so "+1" says there's more to see.
    func testTheMostSevereIsShownAndTheRestCounted() {
        let shown = CompactView.glanceToShow([glance("radar", .warning),
                                              glance("pylon", .danger),
                                              glance("derby", .danger)])
        XCTAssertEqual(shown?.glance.id, "pylon")
        XCTAssertEqual(shown?.more, 2)
    }

    func testAmongEqualsTabOrderWins() {
        XCTAssertEqual(CompactView.glanceToShow([glance("radar", .warning),
                                                 glance("pylon", .warning)])?.glance.id,
                       "radar")
    }
}
