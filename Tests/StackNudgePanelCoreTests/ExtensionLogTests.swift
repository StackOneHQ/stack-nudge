import XCTest

@testable import StackNudgePanelCore

// What an extension can put in app.log: one clean, capped line at a time, and
// only a few a minute.
@MainActor
final class ExtensionLogTests: XCTestCase {

    // A newline in something the extension sent can't start a line of its own
    // that reads as the app's.
    func testAnExtensionCantStartALineOfItsOwn() {
        let line = ExtensionLog.line("radar", "unknown signal \"x\nstack-nudge: fake\"")
        XCTAssertEqual(line, "stack-nudge: extension \"radar\" unknown signal \"x\\nstack-nudge: fake\"\n")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
    }

    func testControlAndFormattingCharactersAreWrittenOut() {
        XCTAssertEqual(ExtensionLog.clean("a\u{1B}[31mb\rc\u{202E}d\u{2028}e"),
                       "a\\u{1b}[31mb\\u{d}c\\u{202e}d\\u{2028}e")
        XCTAssertEqual(ExtensionLog.clean("Alex\u{2019}s Pixel \u{2014} \u{2318}6"), "Alex\u{2019}s Pixel \u{2014} \u{2318}6")
    }

    func testALongLineIsCut() {
        let cleaned = ExtensionLog.clean(String(repeating: "x", count: 64 * 1024))
        XCTAssertEqual(cleaned.count, ExtensionLog.maxLength + 1)
        XCTAssertTrue(cleaned.hasSuffix("\u{2026}"))
        XCTAssertEqual(ExtensionLog.clean("short"), "short")
    }

    // A letter carrying thousands of combining marks is one Character, and
    // still gets cut.
    func testCombiningMarksDontGetPastTheCut() {
        let cleaned = ExtensionLog.clean("a" + String(repeating: "\u{301}", count: 60_000))
        XCTAssertEqual(cleaned.unicodeScalars.count, ExtensionLog.maxLength + 1)
        XCTAssertLessThan(cleaned.utf8.count, 1000)
    }

    // A cut never leaves half an escape behind.
    func testAnEscapeIsKeptWholeOrLeftOut() {
        let text = String(repeating: "x", count: ExtensionLog.maxLength - 3) + "\u{1B}"
        XCTAssertEqual(ExtensionLog.clean(text), String(repeating: "x", count: ExtensionLog.maxLength - 3) + "\u{2026}")
    }

    // Past its allowance an extension's lines are counted, not written, and
    // the count comes with its first line once the minute is up.
    func testEachExtensionGetsAFewLinesAMinute() {
        var log = ExtensionLog()
        var written: [String] = []
        for i in 0..<25 { written += log.lines(for: "radar", "refused \(i)", at: 100 + Double(i)) }
        XCTAssertEqual(written.count, ExtensionLog.linesPerMinute)
        XCTAssertEqual(written.last, ExtensionLog.line("radar", "refused 9"))

        // Another extension's allowance is its own.
        XCTAssertEqual(log.lines(for: "away", "refused", at: 130).count, 1)

        XCTAssertEqual(log.lines(for: "radar", "refused 25", at: 160),
                       [ExtensionLog.line("radar", "15 more lines from it were dropped"),
                        ExtensionLog.line("radar", "refused 25")])
        // And the minute after that starts clean.
        XCTAssertEqual(log.lines(for: "radar", "refused 26", at: 161).count, 1)
    }

    func testOneDroppedLineIsSaidInTheSingular() {
        var log = ExtensionLog()
        for i in 0...ExtensionLog.linesPerMinute { _ = log.lines(for: "radar", "\(i)", at: 0) }
        XCTAssertEqual(log.lines(for: "radar", "next", at: 60).first,
                       ExtensionLog.line("radar", "1 more line from it was dropped"))
    }

    // A clock that goes backwards (the wall clock was set back) starts a new
    // minute rather than holding the extension silent until it catches up.
    func testAClockSetBackStartsANewMinute() {
        var log = ExtensionLog()
        for i in 0..<20 { _ = log.lines(for: "radar", "\(i)", at: 1000) }
        XCTAssertEqual(log.lines(for: "radar", "after", at: 10).last, ExtensionLog.line("radar", "after"))
    }
}
