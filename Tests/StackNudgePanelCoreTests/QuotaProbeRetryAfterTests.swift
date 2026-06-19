import XCTest

@testable import StackNudgePanelCore

final class QuotaProbeRetryAfterTests: XCTestCase {

    func testNilHeader() {
        XCTAssertNil(QuotaProbe.parseRetryAfter(nil))
    }

    func testEmptyHeader() {
        XCTAssertNil(QuotaProbe.parseRetryAfter(""))
        XCTAssertNil(QuotaProbe.parseRetryAfter("   "))
    }

    func testDeltaSeconds() {
        XCTAssertEqual(QuotaProbe.parseRetryAfter("30"), 30)
        XCTAssertEqual(QuotaProbe.parseRetryAfter("  120  "), 120)
        XCTAssertEqual(QuotaProbe.parseRetryAfter("0"), 0)
    }

    func testNegativeDeltaIsRejected() {
        // Per RFC 7231 delta-seconds must be non-negative — fall through to
        // date parsing (which fails) and return nil.
        XCTAssertNil(QuotaProbe.parseRetryAfter("-5"))
    }

    func testClampedToMax() {
        let huge = QuotaProbe.maxRetryAfter * 4
        XCTAssertEqual(QuotaProbe.parseRetryAfter("\(Int(huge))"),
                       QuotaProbe.maxRetryAfter)
    }

    func testHTTPDateInFuture() {
        let future = Date().addingTimeInterval(120)
        let f = DateFormatter()
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = f.string(from: future)

        let parsed = QuotaProbe.parseRetryAfter(header)
        XCTAssertNotNil(parsed)
        // Allow ±2s clock drift between Date() in the test and Date() inside
        // parseRetryAfter.
        XCTAssertEqual(parsed ?? 0, 120, accuracy: 2)
    }

    func testHTTPDateInPastReturnsZero() {
        let past = Date().addingTimeInterval(-3600)
        let f = DateFormatter()
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(QuotaProbe.parseRetryAfter(f.string(from: past)), 0)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(QuotaProbe.parseRetryAfter("not a number"))
        XCTAssertNil(QuotaProbe.parseRetryAfter("Mon, totally not a date"))
        XCTAssertNil(QuotaProbe.parseRetryAfter("3.14e10x"))
    }
}
