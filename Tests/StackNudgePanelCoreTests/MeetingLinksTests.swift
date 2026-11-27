import XCTest

@testable import StackNudgePanelCore

final class MeetingLinksTests: XCTestCase {

    func testClassifiesGoogleDocTypes() {
        let text = """
        https://docs.google.com/document/d/abc/edit
        https://docs.google.com/spreadsheets/d/def/edit#gid=0
        https://docs.google.com/presentation/d/ghi/edit
        https://drive.google.com/file/d/jkl/view?usp=sharing
        https://drive.google.com/drive/folders/mno
        """
        let links = MeetingText.links(in: [text])
        XCTAssertEqual(links.docs.map(\.kind), [.doc, .sheet, .slides, .drive, .drive])
        XCTAssertTrue(links.others.isEmpty)
    }

    func testExcludesJoinLinksAndCalendarChrome() {
        let text = """
        Join: https://meet.google.com/abc-defg-hij
        https://acme.zoom.us/j/12345?pwd=x
        https://calendar.google.com/calendar/event?action=VIEW&eid=zzz
        https://example.com/agenda
        """
        let links = MeetingText.links(in: [text], joinUrl: "https://example.com/other")
        XCTAssertTrue(links.docs.isEmpty)
        XCTAssertEqual(links.others, ["https://example.com/agenda"])
    }

    func testExcludesTheJoinUrlItself() {
        let links = MeetingText.links(in: ["https://example.com/room"], joinUrl: "https://example.com/room")
        XCTAssertTrue(links.isEmpty)
    }

    func testUnwrapsTrackingRedirects() {
        let wrapped = "https://www.google.com/url?q=https://docs.google.com/document/d/abc/edit&sa=D&source=calendar"
        let links = MeetingText.links(in: [wrapped])
        XCTAssertEqual(links.docs, [DocLink(kind: .doc, url: "https://docs.google.com/document/d/abc/edit")])
    }

    func testReadsHrefsDecodesEntitiesAndDedupes() {
        let html = #"<a href="https://docs.google.com/spreadsheets/d/x/edit?a=1&amp;b=2">Sheet</a> https://docs.google.com/spreadsheets/d/x/edit?a=1&b=2."#
        let links = MeetingText.links(in: [html])
        XCTAssertEqual(links.docs, [DocLink(kind: .sheet, url: "https://docs.google.com/spreadsheets/d/x/edit?a=1&b=2")])
    }

    func testPlainTextStripsMarkupAndEntities() {
        let html = "<p>Hello&nbsp;&amp;   welcome</p><ul><li>One</li><li>Caf&#233; &#x41;</li></ul><br><br><br><br>Bye &lt;3"
        XCTAssertEqual(MeetingText.plain(html), "Hello & welcome\n- One\n- Café A\n\nBye <3")
    }

    func testPlainTextCollapsesWhitespaceOnPlainNotes() {
        XCTAssertEqual(MeetingText.plain("  a \t b \r\n\r\n\r\n\r\n c  "), "a b\n\nc")
    }
}
