import XCTest

@testable import StackNudgePanelCore

// TokenFormat is the shared abbreviated-count formatter (was duplicated across
// CompactView / Sessions / OutcomesView).
final class FormattingTests: XCTestCase {

    func test_short_underThousand() {
        XCTAssertEqual(TokenFormat.short(0), "0")
        XCTAssertEqual(TokenFormat.short(42), "42")
        XCTAssertEqual(TokenFormat.short(999), "999")
    }

    func test_short_thousands_roundedToK() {
        XCTAssertEqual(TokenFormat.short(1_000), "1K")
        XCTAssertEqual(TokenFormat.short(1_499), "1K")
        XCTAssertEqual(TokenFormat.short(1_500), "2K")
        XCTAssertEqual(TokenFormat.short(218_000), "218K")
    }

    func test_short_millions_oneDecimal() {
        XCTAssertEqual(TokenFormat.short(1_000_000), "1.0M")
        XCTAssertEqual(TokenFormat.short(1_900_000), "1.9M")
    }
}
