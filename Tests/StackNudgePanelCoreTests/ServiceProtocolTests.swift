import XCTest

@testable import StackNudgePanelCore

// The line protocol: what the host writes, what it accepts back, and how a byte
// stream becomes lines whatever the reads look like.
final class ServiceProtocolTests: XCTestCase {

    private func line(_ message: ServiceProtocol.HostMessage) -> String {
        String(decoding: ServiceProtocol.encode(message), as: UTF8.self)
    }

    private func decode(_ json: String) -> ServiceProtocol.Inbound {
        ServiceProtocol.decode(Data(json.utf8))
    }

    // MARK: - Encoding

    func testHostMessagesAreOneSortedLineEach() {
        XCTAssertEqual(line(.hello(protocol: 1, capabilities: ["event:idle", "signal:presence"])),
                       #"{"capabilities":["event:idle","signal:presence"],"protocol":1,"type":"hello"}"# + "\n")
        XCTAssertEqual(line(.config(values: ["STACKNUDGE_EXT_AWAY_WAIT": "30"])),
                       #"{"type":"config","values":{"STACKNUDGE_EXT_AWAY_WAIT":"30"}}"# + "\n")
        XCTAssertEqual(line(.event(name: "idle", fields: ["seconds": .int(42)])),
                       #"{"name":"idle","seconds":42,"type":"event"}"# + "\n")
        XCTAssertEqual(line(.event(name: "panel", fields: ["open": .bool(true)])),
                       #"{"name":"panel","open":true,"type":"event"}"# + "\n")
        XCTAssertEqual(line(.ping(id: 17)), #"{"id":17,"type":"ping"}"# + "\n")
        XCTAssertEqual(line(.stop), #"{"type":"stop"}"# + "\n")
    }

    // A newline in a value would split the message into two lines, the second
    // of which the extension would read as a message of its own.
    func testANewlineInAValueCannotSplitTheLine() {
        let encoded = line(.config(values: ["STACKNUDGE_EXT_X": "a\n{\"type\":\"stop\"}"]))
        XCTAssertEqual(encoded.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(encoded.hasSuffix("\n"))
    }

    // An event's fields can't rename it or turn it into another message.
    func testEventFieldsCannotOverrideTheTypeOrName() {
        let encoded = line(.event(name: "idle", fields: ["type": .string("stop"), "name": .string("nudge")]))
        XCTAssertEqual(encoded, #"{"name":"idle","type":"event"}"# + "\n")
    }

    // MARK: - Decoding

    func testExtensionMessagesDecode() {
        XCTAssertEqual(decode(#"{"type":"ready","protocol":1}"#), .message(.ready(protocol: 1)))
        XCTAssertEqual(decode(#"{"type":"signal","name":"presence","value":"away"}"#),
                       .message(.signal(name: "presence", value: "away")))
        XCTAssertEqual(decode(#"{"type":"pong","id":17}"#), .message(.pong(id: 17)))
        XCTAssertEqual(decode(#"{"type":"feed","event":{"title":"Left","tag":"away"}}"#),
                       .message(.feed(event: Data(#"{"tag":"away","title":"Left"}"#.utf8))))
        guard case .message(.document(let document)) = decode(
            #"{"type":"document","document":{"schema":1,"header":{"title":"Away"},"rows":[]}}"#)
        else { return XCTFail("expected a document") }
        XCTAssertEqual(document.header?.title, "Away")
    }

    // Additive: a type this host doesn't know is skipped, not an error.
    func testAnUnknownTypeIsIgnored() {
        XCTAssertEqual(decode(#"{"type":"telemetry","x":1}"#), .ignored(type: "telemetry"))
    }

    func testBrokenLinesSayWhy() {
        XCTAssertEqual(decode("not json"), .invalid("not a JSON object"))
        XCTAssertEqual(decode("[1,2]"), .invalid("not a JSON object"))
        XCTAssertEqual(decode(#"{"name":"presence"}"#), .invalid("no \"type\""))
        guard case .invalid = decode(#"{"type":"signal","name":"presence"}"#) else {
            return XCTFail("a signal without a value")
        }
        guard case .invalid = decode(#"{"type":"pong","id":"17"}"#) else {
            return XCTFail("a pong with a string id")
        }
    }

    // NSNumber reads `true` as 1, which would make `"id": true` a valid pong.
    func testABooleanIsNotANumber() {
        guard case .invalid = decode(#"{"type":"pong","id":true}"#) else {
            return XCTFail("true is not an id")
        }
        guard case .invalid = decode(#"{"type":"ready","protocol":1.5}"#) else {
            return XCTFail("1.5 is not a protocol")
        }
    }

    // A document that doesn't parse is the extension's bug, and reported as a
    // document problem so the tab can say so.
    func testAnUnparseableDocumentIsReportedAsADocumentProblem() {
        guard case .invalidDocument = decode(#"{"type":"document","document":{"schema":2}}"#) else {
            return XCTFail("schema 2 document")
        }
        guard case .invalidDocument = decode(#"{"type":"document","document":"nope"}"#) else {
            return XCTFail("document that isn't an object")
        }
    }

    // A control line has a much lower ceiling than a document.
    func testAControlLineOver64KBIsOversizedButADocumentIsNot() {
        let padding = String(repeating: "x", count: ServiceProtocol.maxLineBytes)
        let signal = #"{"type":"signal","name":"presence","value":"away","pad":"\#(padding)"}"#
        XCTAssertEqual(decode(signal), .oversized(bytes: signal.utf8.count))
        let document = #"{"type":"document","document":{"schema":1,"header":{"title":"\#(padding)"}}}"#
        guard case .message(.document) = decode(document) else {
            return XCTFail("a large document is still a document")
        }
    }

    // MARK: - Splitting

    func testALineSplitAcrossReadsIsReassembled() {
        var splitter = ServiceProtocol.LineSplitter()
        XCTAssertEqual(splitter.feed(Data(#"{"type":"#.utf8)), [])
        XCTAssertEqual(splitter.feed(Data(#""pong","id""#.utf8)), [])
        XCTAssertEqual(splitter.feed(Data(":1}\n".utf8)), [.line(Data(#"{"type":"pong","id":1}"#.utf8))])
    }

    func testOneReadCanCarryManyLinesAndTheStartOfAnother() {
        var splitter = ServiceProtocol.LineSplitter()
        XCTAssertEqual(splitter.feed(Data("a\nb\r\n\nc".utf8)),
                       [.line(Data("a".utf8)), .line(Data("b".utf8))])
        XCTAssertEqual(splitter.feed(Data("\n".utf8)), [.line(Data("c".utf8))])
    }

    // An overlong line is dropped once it crosses the limit, without being
    // buffered to the end, and reported when it finishes. The next line is fine.
    func testALineOverTheLimitIsDroppedAndReportedAndTheNextOneSurvives() {
        var splitter = ServiceProtocol.LineSplitter(limit: 8)
        XCTAssertEqual(splitter.feed(Data("12345".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("67890".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("abc".utf8)), [])
        XCTAssertEqual(splitter.feed(Data("\nok\n".utf8)),
                       [.oversized(bytes: 13), .line(Data("ok".utf8))])
    }

    func testALineExactlyAtTheLimitIsKept() {
        var splitter = ServiceProtocol.LineSplitter(limit: 4)
        XCTAssertEqual(splitter.feed(Data("abcd\nabcde\n".utf8)),
                       [.line(Data("abcd".utf8)), .oversized(bytes: 5)])
    }

    func testTheDefaultLimitIsTheDocumentCeiling() {
        XCTAssertEqual(ServiceProtocol.LineSplitter().limit, 8 * 1024 * 1024)
        XCTAssertEqual(ServiceProtocol.maxLineBytes, 64 * 1024)
    }
}
