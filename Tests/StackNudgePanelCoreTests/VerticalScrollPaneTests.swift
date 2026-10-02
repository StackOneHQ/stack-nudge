import AppKit
import XCTest

@testable import StackNudgePanelCore

// ↑/↓ on the Outcomes overview and Usage detail scroll whatever this finds; the
// tab strip used to be the match, which left both panes deaf to the arrow keys.
final class VerticalScrollPaneTests: XCTestCase {

    private func scrollView(viewport: CGSize, content: CGSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scrollView.documentView = NSView(frame: NSRect(origin: .zero, size: content))
        return scrollView
    }

    func test_skipsASidewaysStripAboveTheOverflowingPane() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        let tabStrip = scrollView(viewport: CGSize(width: 400, height: 28),
                                  content: CGSize(width: 900, height: 28))
        let pane = scrollView(viewport: CGSize(width: 560, height: 500),
                              content: CGSize(width: 560, height: 1400))
        root.addSubview(tabStrip)
        root.addSubview(pane)

        let actual = VerticalScrollPane.find(in: root)

        XCTAssertTrue(actual === pane)
    }

    func test_nothingOverflows_findsNothing() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        root.addSubview(scrollView(viewport: CGSize(width: 400, height: 28),
                                   content: CGSize(width: 900, height: 28)))
        root.addSubview(scrollView(viewport: CGSize(width: 560, height: 500),
                                   content: CGSize(width: 560, height: 300)))

        XCTAssertNil(VerticalScrollPane.find(in: root))
    }
}
