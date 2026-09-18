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

    // MARK: - Unknown enum values

    // Every enum-ish field falls back rather than failing, but nothing pinned
    // the fallbacks — the fixtures always sent a valid value, so the defaults
    // could be changed to anything without a test noticing.
    func testAnUnknownBadgeToneFallsBackToNeutral() {
        let json = """
            {"schema":1,"header":{"title":"T","badge":{"text":"X","tone":"critical"}}}
            """
        XCTAssertEqual(document(json)?.header?.badge?.tone, .neutral)
    }

    // Case-sensitive, so a capitalised tone is an unknown one.
    func testToneMatchingIsCaseSensitive() {
        let json = """
            {"schema":1,"header":{"title":"T","badge":{"text":"X","tone":"DANGER"}}}
            """
        XCTAssertEqual(document(json)?.header?.badge?.tone, .neutral)
    }

    func testAMissingBadgeToneIsNeutral() {
        let json = """
            {"schema":1,"header":{"title":"T","badge":{"text":"X"}}}
            """
        XCTAssertEqual(document(json)?.header?.badge?.tone, .neutral)
    }

    // fill-edge is the default because it is what makes a bar read as a race;
    // the other two anchors also have to actually parse.
    func testEveryAnchorParsesAndUnknownFallsBackToFillEdge() {
        let expected: [String: ExtensionDocument.Ornament.Anchor] = [
            "fill-edge": .fillEdge, "leading": .leading, "trailing": .trailing,
            "middle": .fillEdge, "FILL-EDGE": .fillEdge, "": .fillEdge,
        ]
        for (raw, anchor) in expected {
            let json = """
                {"schema":1,"rows":[{"id":"a","title":"A","ornament":
                    {"anchor":"\(raw)","palette":{"H":"#fff"},"frames":[["H"]]}}]}
                """
            XCTAssertEqual(document(json)?.rows.first?.ornament?.anchor, anchor, raw)
        }
    }

    func testAMissingAnchorIsFillEdge() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":"A","ornament":
                {"palette":{"H":"#fff"},"frames":[["H"]]}}]}
            """
        XCTAssertEqual(document(json)?.rows.first?.ornament?.anchor, .fillEdge)
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

    // A shell script emitting "" for a field it has no value for is the natural
    // thing for a shell script to do. Rendering that as a present-but-empty
    // element reserved layout for nothing, so one row sat indented past its
    // neighbours with no visible cause.
    func testEmptyOptionalTextIsTreatedAsAbsent() {
        let json = """
            {"schema":1,"message":"","header":{"title":"T","trailing":"  "},
             "rows":[{"id":"a","title":"A","lead":"","subtitle":"","value":"","footnote":" "}]}
            """
        guard let d = document(json), let row = d.rows.first else { return XCTFail("no row") }
        XCTAssertNil(row.lead)
        XCTAssertNil(row.subtitle)
        XCTAssertNil(row.value)
        XCTAssertNil(row.footnote)
        XCTAssertNil(d.header?.trailing)
        XCTAssertNil(d.message)
    }

    // Only *optional* fields. A title is what a row is, so an empty one drops
    // the row rather than quietly rendering a blank one.
    func testAnEmptyTitleStillDropsTheRow() {
        let json = """
            {"schema":1,"rows":[{"id":"a","title":""},{"id":"b","title":"B"}]}
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

    // Sprite frames were capped and the things around them were not, which is
    // the same hole one level out: a script printing a million rows inside the
    // timeout has them all parsed before LazyVStack ever declines to draw them.
    func testTheRowListIsCapped() {
        let rows = (0..<(ExtensionDocument.maxRows + 500))
            .map { "{\"id\":\"r\($0)\",\"title\":\"R\"}" }.joined(separator: ",")
        XCTAssertEqual(document("{\"schema\":1,\"rows\":[\(rows)]}")?.rows.count,
                       ExtensionDocument.maxRows)
    }

    func testTheActionListIsCapped() {
        let actions = (0..<(ExtensionDocument.maxActions + 20))
            .map { "{\"id\":\"a\($0)\",\"label\":\"A\"}" }.joined(separator: ",")
        XCTAssertEqual(document("{\"schema\":1,\"actions\":[\(actions)]}")?.actions.count,
                       ExtensionDocument.maxActions)
    }

    // Truncated rather than refused: an over-long title is a formatting slip,
    // and every field is line-limited on screen anyway. The cap is about what
    // gets parsed and held.
    func testOverlongTextIsTruncatedNotRejected() {
        let long = String(repeating: "x", count: ExtensionDocument.maxTextLength + 400)
        let json = """
            {"schema":1,"message":"\(long)",
             "header":{"title":"\(long)","trailing":"\(long)"},
             "rows":[{"id":"a","title":"\(long)","subtitle":"\(long)","value":"\(long)",
                      "footnote":"\(long)","lead":"\(long)"}]}
            """
        guard let d = document(json), let row = d.rows.first else { return XCTFail("no row") }
        let cap = ExtensionDocument.maxTextLength
        XCTAssertEqual(row.title.count, cap)
        XCTAssertEqual(row.subtitle?.count, cap)
        XCTAssertEqual(row.value?.count, cap)
        XCTAssertEqual(row.footnote?.count, cap)
        XCTAssertEqual(row.lead?.count, cap)
        XCTAssertEqual(d.header?.title.count, cap)
        XCTAssertEqual(d.header?.trailing?.count, cap)
        XCTAssertEqual(d.message?.count, cap)
    }

    // Capped after the malformed ones are dropped, so a bad row doesn't cost a
    // good one its place in the list.
    func testTheRowCapIsAppliedAfterDroppingMalformedRows() {
        let bad = (0..<10).map { "{\"id\":\"bad\($0)\"}" }.joined(separator: ",")
        let good = (0..<ExtensionDocument.maxRows)
            .map { "{\"id\":\"g\($0)\",\"title\":\"G\"}" }.joined(separator: ",")
        let d = document("{\"schema\":1,\"rows\":[\(bad),\(good)]}")
        XCTAssertEqual(d?.rows.count, ExtensionDocument.maxRows)
        XCTAssertEqual(d?.rows.first?.id, "g0")
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

    // MARK: - Multiple ornaments

    // A row can want more than one decoration: a marker fixed at the end of the
    // track and something riding the fill are anchored two different ways, and
    // one `ornament` could only ever be one of them.
    func testARowCanCarrySeveralOrnaments() {
        guard case .success(let document) = ExtensionDocument.parse(Data("""
            {"schema":1,"rows":[{"id":"a","title":"A","ornaments":[
              {"anchor":"trailing","palette":{"W":"#fff"},"frames":[["W","W"]]},
              {"anchor":"fill-edge","fps":7,"palette":{"H":"#f00"},"frames":[["HH"],["H"]]}
            ]}]}
            """.utf8)) else { return XCTFail("didn't parse") }
        let ornaments = document.rows[0].ornaments
        XCTAssertEqual(ornaments.count, 2)
        XCTAssertEqual(ornaments[0].anchor, .trailing)
        XCTAssertEqual(ornaments[1].anchor, .fillEdge)
    }

    // The singular spelling is what every document written before this used, so
    // it keeps working and keeps meaning the same thing.
    func testTheSingularSpellingStillWorks() {
        guard case .success(let document) = ExtensionDocument.parse(Data("""
            {"schema":1,"rows":[{"id":"a","title":"A",
             "ornament":{"anchor":"leading","palette":{"H":"#fff"},"frames":[["H"]]}}]}
            """.utf8)) else { return XCTFail("didn't parse") }
        XCTAssertEqual(document.rows[0].ornaments.count, 1)
        XCTAssertEqual(document.rows[0].ornament?.anchor, .leading)
    }

    // Both, in the order written — the singular reads first, so a document
    // using it plus a list doesn't have its original decoration reordered.
    func testBothSpellingsCombineInOrder() {
        guard case .success(let document) = ExtensionDocument.parse(Data("""
            {"schema":1,"rows":[{"id":"a","title":"A",
             "ornament":{"anchor":"leading","palette":{"H":"#fff"},"frames":[["H"]]},
             "ornaments":[{"anchor":"trailing","palette":{"W":"#fff"},"frames":[["W"]]}]}]}
            """.utf8)) else { return XCTFail("didn't parse") }
        XCTAssertEqual(document.rows[0].ornaments.map(\.anchor), [.leading, .trailing])
    }

    // Capped like everything else a document can send a list of.
    func testOrnamentsAreCapped() {
        // ## delimiters: the payload contains "#fff", and "# would close a
        // single-# raw string in the middle of it.
        let one = ##"{"anchor":"leading","palette":{"H":"#fff"},"frames":[["H"]]}"##
        let many = Array(repeating: one, count: 10).joined(separator: ",")
        guard case .success(let document) = ExtensionDocument.parse(Data("""
            {"schema":1,"rows":[{"id":"a","title":"A","ornaments":[\(many)]}]}
            """.utf8)) else { return XCTFail("didn't parse") }
        XCTAssertEqual(document.rows[0].ornaments.count, ExtensionDocument.maxOrnaments)
    }

    func testARowWithNoOrnamentHasAnEmptyList() {
        guard case .success(let document) =
                ExtensionDocument.parse(Data(#"{"schema":1,"rows":[{"id":"a","title":"A"}]}"#.utf8))
        else { return XCTFail("didn't parse") }
        XCTAssertTrue(document.rows[0].ornaments.isEmpty)
        XCTAssertNil(document.rows[0].ornament)
    }
}
