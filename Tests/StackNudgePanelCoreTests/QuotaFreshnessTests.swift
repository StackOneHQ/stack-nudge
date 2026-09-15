import XCTest

@testable import StackNudgePanelCore

// The Usage pane reported whichever client polled last, not the one you were
// looking at. A failing Claude read "Updated 12s ago" because Codex had just
// succeeded — beside the error saying it hadn't refreshed.
@MainActor
final class QuotaFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEachClientCarriesItsOwnTimestamp() {
        let nav = PanelNav()
        nav.quotaUpdatedAt[.codex] = now
        XCTAssertEqual(nav.quotaUpdatedAt[.codex], now)
        XCTAssertNil(nav.quotaUpdatedAt[.claude])
        XCTAssertNil(nav.quotaUpdatedAt[.antigravity])
    }

    // The exact shape from the bug report: Codex fresh, Claude stale and erroring.
    func testOneClientSucceedingDoesNotRefreshAnother() {
        let nav = PanelNav()
        nav.quotaUpdatedAt[.claude] = now.addingTimeInterval(-3600)
        nav.quotaUpdatedAt[.codex] = now
        nav.quotaErrors[.claude] = "Can't find the claude CLI"

        XCTAssertEqual(nav.quotaUpdatedAt[.claude], now.addingTimeInterval(-3600))
        XCTAssertNotEqual(nav.quotaUpdatedAt[.claude], nav.quotaUpdatedAt[.codex])
        XCTAssertNotNil(nav.quotaErrors[.claude])
        XCTAssertNil(nav.quotaErrors[.codex])
    }

    // "Never synced" has to stay reachable per client, or a client that has
    // never polled inherits a sibling's timestamp.
    func testAClientThatNeverPolledHasNoTimestamp() {
        let nav = PanelNav()
        nav.quotaUpdatedAt[.claude] = now
        XCTAssertNil(nav.quotaUpdatedAt[.codex])
    }
}
