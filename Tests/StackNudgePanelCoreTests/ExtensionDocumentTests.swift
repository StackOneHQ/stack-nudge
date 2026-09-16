import XCTest

@testable import StackNudgePanelCore

// The view document is a contract with anything we ever publish, so these are
// tests of what the host promises to do with each shape — including the hostile
// ones, since a document is only as trustworthy as the extension that printed
// it and a malformed one must degrade rather than take the pane down.
final class ExtensionDocumentTests: XCTestCase {

    private func parse(_ json: String) -> Result<ExtensionDocument, ExtensionDocument.ParseFailure> {
        ExtensionDocument.parse(Data(json.utf8))
    }

    private func document(_ json: String,
                          file: StaticString = #filePath, line: UInt = #line) -> ExtensionDocument? {
        guard case .success(let document) = parse(json) else {
            XCTFail("expected a document", file: file, line: line)
            return nil
        }
        return document
    }

    // MARK: - Shape

    func testAFullDocument() {
        let json = """
            {"schema":1,"state":"ok",
             "header":{"title":"League","badge":{"text":"LIVE","tone":"success"},"trailing":"5h44m"},
             "rows":[{"id":"h1","lead":"1","title":"black & white","subtitle":"Yashika",
                      "value":"14.5M","footnote":"36K/15m",
                      "track":{"fill":0.52,"ghost":0.6,"tint":"#FFFFFF"},
                      "actions":[{"id":"open","label":"Open","key":"return"}]}],
             "actions":[{"id":"refresh","label":"Sync now","key":"r"}]}
            """
        guard let d = document(json) else { return }
        XCTAssertEqual(d.state, .ok)
        XCTAssertEqual(d.header?.title, "League")
        XCTAssertEqual(d.header?.badge, .init(text: "LIVE", tone: .success))
        XCTAssertEqual(d.header?.trailing, "5h44m")
        XCTAssertEqual(d.rows.count, 1)
        XCTAssertEqual(d.rows[0].track, .init(fill: 0.52, ghost: 0.6, tint: "#FFFFFF"))
        XCTAssertEqual(d.rows[0].actions, [.init(id: "open", label: "Open", key: "return")])
        XCTAssertEqual(d.actions, [.init(id: "refresh", label: "Sync now", key: "r")])
        XCTAssertNil(d.placeholder)
    }

    func testAMinimalDocumentIsEmptyRatherThanNil() {
        guard let d = document("{\"schema\":1}") else { return }
        XCTAssertEqual(d.state, .ok)
        XCTAssertNil(d.header)
        XCTAssertEqual(d.rows, [])
        XCTAssertEqual(d.actions, [])
    }

    // MARK: - States

    func testPlaceholderTextPerState() {
        XCTAssertEqual(document("{\"schema\":1,\"state\":\"empty\",\"message\":\"No race\"}")?.placeholder,
                       "No race")
        XCTAssertEqual(document("{\"schema\":1,\"state\":\"error\",\"message\":\"AWS down\"}")?.placeholder,
                       "AWS down")
        // An extension that reports a state without saying why still gets a
        // pane that reads as deliberate rather than as a rendering bug.
        XCTAssertNotNil(document("{\"schema\":1,\"state\":\"empty\"}")?.placeholder)
        XCTAssertNotNil(document("{\"schema\":1,\"state\":\"error\"}")?.placeholder)
    }

    // "ok" with nothing in it is the same picture as "empty", and an extension
    // shouldn't have to get the distinction right to avoid a blank pane.
    func testOKWithNoRowsStillShowsAPlaceholder() {
        XCTAssertNotNil(document("{\"schema\":1,\"state\":\"ok\"}")?.placeholder)
    }

    // The rows are the substance. Throwing them away over a state string we
    // don't recognise would lose more than it protects.
    func testAnUnknownStateIsReadAsOK() {
        let d = document("{\"schema\":1,\"state\":\"wat\",\"rows\":[{\"id\":\"a\",\"title\":\"A\"}]}")
        XCTAssertEqual(d?.state, .ok)
        XCTAssertEqual(d?.rows.count, 1)
    }

    // MARK: - Schema

    func testANewerSchemaIsRefused() {
        XCTAssertEqual(parse("{\"schema\":2}"), .failure(.unsupportedSchema(2)))
    }

    func testMissingSchemaIsMalformedNotAssumedToBeOne() {
        guard case .failure(.malformed) = parse("{\"rows\":[]}") else {
            return XCTFail("expected malformed")
        }
    }

    func testNotJSON() {
        guard case .failure(.malformed) = parse("<html>nope</html>") else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: - Rows

    // Two rows with one id would collapse under ForEach, and an action naming
    // that id would be ambiguous about which row it meant.
    func testDuplicateRowIDsCollapseToTheFirst() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"First"},{"id":"a","title":"Second"},
                                {"id":"b","title":"Third"}]}
            """
        XCTAssertEqual(document(json)?.rows.map(\.title), ["First", "Third"])
    }

    func testRowsWithNoIDAreDropped() {
        let json = """
            {"schema":1,"rows":[{"id":"","title":"Anonymous"},{"id":"b","title":"Named"}]}
            """
        XCTAssertEqual(document(json)?.rows.map(\.id), ["b"])
    }

    // MARK: - Tracks

    // An arithmetic slip in an extension draws a full or empty bar; it does not
    // cost the user the whole pane, and it does not draw outside the track.
    func testTrackFractionsAreClampedNotRejected() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","track":{"fill":1.4,"ghost":-0.3}}]}
            """
        XCTAssertEqual(document(json)?.rows[0].track, .init(fill: 1, ghost: 0, tint: nil))
    }

    // A non-finite fill would reach CoreGraphics as a width, which is a real
    // crash. JSONDecoder refuses the literal before the clamp ever sees it, so
    // the document is malformed rather than half-rendered — the clamp's own
    // isFinite guard stays as insurance for any other route to a Double.
    func testATrackFractionOutsideDoubleIsRefusedByTheDecoder() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","track":{"fill":1e400}}]}
            """
        guard case .failure(.malformed) = parse(json) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: - Ornaments

    private let sprite = """
        {"schema":1,"rows":[{"id":"a","title":"A","ornament":
            {"kind":"sprite","fps":7,"anchor":"fill-edge",
             "palette":{"H":"#FFFFFF"},"frames":[["..HH"],["HH.."]]}}]}
        """

    func testASprite() {
        guard let o = document(sprite)?.rows[0].ornament else { return XCTFail("no ornament") }
        XCTAssertEqual(o.fps, 7)
        XCTAssertEqual(o.anchor, .fillEdge)
        XCTAssertEqual(o.palette, ["H": "#FFFFFF"])
        XCTAssertEqual(o.frames, [["..HH"], ["HH.."]])
    }

    // A second ornament kind would be additive; the old host must drop it
    // rather than render it as a sprite and look subtly wrong.
    func testAnUnknownOrnamentKindIsDropped() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":{"kind":"video","frames":[["H"]]}}]}
            """
        XCTAssertNil(document(json)?.rows[0].ornament)
    }

    func testAnOrnamentWithNoFramesIsDropped() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":{"frames":[]}}]}
            """
        XCTAssertNil(document(json)?.rows[0].ornament)
    }

    // fps drives a 1/fps timeline interval, so zero or negative would be a
    // division by zero; it means "don't animate" instead.
    func testNonPositiveFPSMeansStill() {
        for fps in ["0", "-4"] {
            let json = """
                {"schema":1,"rows":[{"id":"a","title":"A","ornament":{"fps":\(fps),"frames":[["H"],["."]]}}]}
                """
            XCTAssertEqual(document(json)?.rows[0].ornament?.fps, 0, fps)
        }
    }

    func testFPSIsCappedSoASpriteCannotSpinTheRenderLoop() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":{"fps":9000,"frames":[["H"]]}}]}
            """
        XCTAssertEqual(document(json)?.rows[0].ornament?.fps, 30)
    }

    // MARK: - Actions

    func testActionsWithNoIDOrADuplicateAreDropped() {
        let json = """
            {"schema":1,"actions":[{"id":"","label":"Anon"},{"id":"r","label":"One"},
                                   {"id":"r","label":"Two"}]}
            """
        XCTAssertEqual(document(json)?.actions.map(\.label), ["One"])
    }

    // MARK: - Leniency is per row

    // One malformed item in an API response used to cost the whole pane. Row
    // failures drop the row, matching how duplicate and empty ids already
    // behave — a partial list beats a blank tab.
    func testAMalformedRowDropsThatRowAndKeepsTheRest() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A"},
                                {"id":"b"},
                                {"id":"c","title":null},
                                {"id":"d","title":"D"}]}
            """
        XCTAssertEqual(document(json)?.rows.map(\.id), ["a", "d"])
    }

    // A row is its id and its title: one addresses it, the other is the only
    // thing guaranteed to be drawn. Everything else degrades rather than drops.
    func testAMalformedTrackCostsTheTrackNotTheRow() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","track":{}}]}
            """
        guard let row = document(json)?.rows.first else { return XCTFail("row was dropped") }
        XCTAssertNil(row.track)
        XCTAssertEqual(row.title, "A")
    }

    func testAnActionWithoutALabelDropsTheActionNotTheDocument() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A"}],"actions":[{"id":"r"}]}
            """
        XCTAssertEqual(document(json)?.rows.count, 1)
        XCTAssertEqual(document(json)?.actions, [])
    }

    // A header missing its title loses the header, not the list behind it.
    func testAMalformedHeaderDropsTheHeaderNotTheDocument() {
        let json = """
            {"schema":1,"header":{"badge":{"text":"LIVE"}},"rows":[{"id":"a","title":"A"}]}
            """
        XCTAssertNil(document(json)?.header)
        XCTAssertEqual(document(json)?.rows.count, 1)
    }

    // MARK: - Sprite bounds

    // fps was capped so a sprite couldn't spin the render loop, but rows,
    // columns and frame count were unbounded — and a single million-column frame
    // parses happily, then asks Canvas to fill a million cells every tick.
    func testSpriteDimensionsAreCapped() {
        let wide = String(repeating: "H", count: 5_000)
        let frames = (0..<200).map { _ in
            "[" + (0..<200).map { _ in "\"\(wide)\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":{"fps":7,"frames":[\(frames)]}}]}
            """
        guard let o = document(json)?.rows.first?.ornament else { return XCTFail("no ornament") }
        XCTAssertLessThanOrEqual(o.frames.count, ExtensionDocument.maxSpriteFrames)
        XCTAssertLessThanOrEqual(o.frames.map(\.count).max() ?? 0, ExtensionDocument.maxSpriteRows)
        XCTAssertLessThanOrEqual(o.frames.flatMap { $0 }.map(\.count).max() ?? 0,
                                 ExtensionDocument.maxSpriteColumns)
    }

    // MARK: - Key allowlist

    func testGrantedKeys() {
        for key in ["a", "z", "0", "9", "return"] {
            XCTAssertEqual(ExtensionKey.grant(key), key, key)
        }
        XCTAssertEqual(ExtensionKey.grant("R"), "r")
        XCTAssertEqual(ExtensionKey.grant("RETURN"), "return")
    }

    // Esc is the only way out of the panel, ⌘-digits are the tab numbers, and
    // the arrows are how you move within and between tabs. None of them are an
    // extension's to take.
    func testRefusedKeys() {
        for key in ["esc", "escape", "cmd+r", "up", "down", "left", "right",
                    "tab", "space", " ", "", "delete", "ab"] {
            XCTAssertNil(ExtensionKey.grant(key), key)
        }
        XCTAssertNil(ExtensionKey.grant(nil))
    }

    // Built from explicit scalars rather than written as literals. `count` is a
    // grapheme count, so every one of these is one Character with more than one
    // scalar, and the old guard inspected only the base — granting a binding the
    // key handler can never match (it sees a plain "a") while the footer
    // advertised it. Spelling them out also means an editor normalising this
    // file can't silently flip the test: a literal "é" passes either way
    // precomposed and fails decomposed.
    func testMultiScalarKeysAreRefused() {
        let cases: [(String, String)] = [
            ("e\u{0301}", "decomposed é"),
            ("a\u{FE0F}", "a + variation selector"),
            ("a\u{200D}", "a + zero-width joiner"),
            ("a\u{20DD}", "a + enclosing circle"),
            ("1\u{FE0F}\u{20E3}", "keycap 1"),
            ("\u{0130}", "İ, which lowercases to two scalars"),
        ]
        for (key, what) in cases {
            XCTAssertNil(ExtensionKey.grant(key), what)
        }
    }

    // The precomposed form is a single scalar and still has to be refused for
    // being non-ASCII — the two guards catch different things.
    func testPrecomposedNonASCIIIsRefused() {
        XCTAssertNil(ExtensionKey.grant("\u{00E9}"), "precomposed é")
    }

    // A refused key doesn't cost the action its button — it just has no
    // shortcut, which is the least surprising thing to do with a bad request.
    func testAnActionRequestingARefusedKeyKeepsTheActionAndLosesTheKey() {
        let json = """
            {"schema":1,"actions":[{"id":"quit","label":"Quit","key":"esc"}]}
            """
        XCTAssertEqual(document(json)?.actions, [.init(id: "quit", label: "Quit", key: nil)])
    }
}
