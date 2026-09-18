import XCTest

@testable import StackNudgePanelCore

final class ConfigFileTests: XCTestCase {

    // MARK: - parse

    func test_parse_readsKeyValuePairs() {
        let map = ConfigFile.parse("""
        STACKNUDGE_PANEL=true
        STACKNUDGE_VOICE=false
        """)
        XCTAssertEqual(map["STACKNUDGE_PANEL"], "true")
        XCTAssertEqual(map["STACKNUDGE_VOICE"], "false")
    }

    func test_parse_ignoresCommentsAndBlankLines() {
        let map = ConfigFile.parse("""
        # leading comment

        STACKNUDGE_PANEL=true
        # trailing comment
        STACKNUDGE_VOICE=true

        """)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["STACKNUDGE_PANEL"], "true")
        XCTAssertEqual(map["STACKNUDGE_VOICE"], "true")
    }

    func test_parse_stripsSurroundingQuotes() {
        let map = ConfigFile.parse("""
        STACKNUDGE_VOICE_NAME="af_aoede"
        STACKNUDGE_PANEL_HOTKEY='cmd+opt+n'
        """)
        XCTAssertEqual(map["STACKNUDGE_VOICE_NAME"], "af_aoede")
        XCTAssertEqual(map["STACKNUDGE_PANEL_HOTKEY"], "cmd+opt+n")
    }

    func test_parse_trimsWhitespaceAroundKeyAndValue() {
        let map = ConfigFile.parse("  STACKNUDGE_VOICE  =   true  ")
        XCTAssertEqual(map["STACKNUDGE_VOICE"], "true")
    }

    func test_parse_doesNotStripMismatchedQuotes() {
        // Quote mismatch shouldn't be silently dropped.
        let map = ConfigFile.parse(#"STACKNUDGE_VOICE_NAME="af_aoede'"#)
        XCTAssertEqual(map["STACKNUDGE_VOICE_NAME"], #""af_aoede'"#)
    }

    func test_parse_skipsLinesWithoutEqualsSign() {
        let map = ConfigFile.parse("""
        STACKNUDGE_PANEL=true
        not a key/value line
        STACKNUDGE_VOICE=false
        """)
        XCTAssertEqual(map.count, 2)
    }

    func test_parse_emptyInputYieldsEmptyMap() {
        XCTAssertTrue(ConfigFile.parse("").isEmpty)
    }

    func test_parse_lastValueWinsOnDuplicateKey() {
        let map = ConfigFile.parse("""
        STACKNUDGE_VOICE=false
        STACKNUDGE_VOICE=true
        """)
        XCTAssertEqual(map["STACKNUDGE_VOICE"], "true")
    }

    // MARK: - bool

    func test_bool_recognisedTruthyValues() {
        XCTAssertTrue(ConfigFile.bool(["k": "true"], "k", default: false))
        XCTAssertTrue(ConfigFile.bool(["k": "1"], "k", default: false))
        XCTAssertTrue(ConfigFile.bool(["k": "yes"], "k", default: false))
    }

    func test_bool_isCaseInsensitive() {
        XCTAssertTrue(ConfigFile.bool(["k": "TRUE"], "k", default: false))
        XCTAssertTrue(ConfigFile.bool(["k": "Yes"], "k", default: false))
    }

    func test_bool_falsyValuesReturnFalseRegardlessOfDefault() {
        XCTAssertFalse(ConfigFile.bool(["k": "false"], "k", default: true))
        XCTAssertFalse(ConfigFile.bool(["k": "no"], "k", default: true))
        XCTAssertFalse(ConfigFile.bool(["k": "0"], "k", default: true))
    }

    func test_bool_missingKeyUsesDefault() {
        XCTAssertTrue(ConfigFile.bool([:], "k", default: true))
        XCTAssertFalse(ConfigFile.bool([:], "k", default: false))
    }

    // MARK: - apply

    func test_apply_replacesExistingKeyInPlace() {
        let original = """
        # banner toggle
        STACKNUDGE_BANNER=true
        STACKNUDGE_VOICE=false
        """
        let updated = ConfigFile.apply(original, key: "STACKNUDGE_BANNER", value: "false")
        XCTAssertTrue(updated.contains("# banner toggle"), "preserved comments")
        XCTAssertTrue(updated.contains("STACKNUDGE_BANNER=false"))
        XCTAssertFalse(updated.contains("STACKNUDGE_BANNER=true"))
        // No duplication.
        XCTAssertEqual(updated.components(separatedBy: "STACKNUDGE_BANNER=").count - 1, 1)
    }

    func test_apply_appendsKeyIfMissing() {
        let original = "STACKNUDGE_PANEL=true\n"
        let updated = ConfigFile.apply(original, key: "STACKNUDGE_VOICE", value: "true")
        XCTAssertTrue(updated.contains("STACKNUDGE_PANEL=true"))
        XCTAssertTrue(updated.contains("STACKNUDGE_VOICE=true"))
        XCTAssertTrue(updated.hasSuffix("\n"), "preserves trailing newline")
    }

    func test_apply_doesNotReplaceCommentedAssignment() {
        let original = """
        # STACKNUDGE_VOICE=true
        STACKNUDGE_PANEL=true
        """
        let updated = ConfigFile.apply(original, key: "STACKNUDGE_VOICE", value: "true")
        XCTAssertTrue(updated.contains("# STACKNUDGE_VOICE=true"), "commented line untouched")
        XCTAssertTrue(updated.contains("STACKNUDGE_VOICE=true"), "real assignment appended")
    }

    func test_apply_doesNotMatchOnPrefixCollision() {
        // STACKNUDGE_VOICE_NAME starts with the same prefix as STACKNUDGE_VOICE
        // — but the key match requires "<key>=", so the longer key is safe.
        let original = """
        STACKNUDGE_VOICE_NAME=af_aoede
        """
        let updated = ConfigFile.apply(original, key: "STACKNUDGE_VOICE", value: "true")
        XCTAssertTrue(updated.contains("STACKNUDGE_VOICE_NAME=af_aoede"))
        XCTAssertTrue(updated.contains("STACKNUDGE_VOICE=true"))
    }

    func test_apply_emptyContentsAppendsNewLineFile() {
        let updated = ConfigFile.apply("", key: "STACKNUDGE_PANEL", value: "true")
        XCTAssertTrue(updated.contains("STACKNUDGE_PANEL=true"))
        XCTAssertTrue(updated.hasSuffix("\n"))
    }

    // MARK: - Key shape

    // The file is line-based and `apply` writes "key=value", so a key is not
    // just a name — it is text that lands in the file. An extension manifest
    // declaring a key with a newline in it used the settings form to write a
    // second, unrelated assignment; this is the sink-side half of that fix, so
    // a future caller building a key from anything but a literal can't reopen
    // it.
    func testAKeyCarryingANewlineIsNotWritable() {
        XCTAssertFalse(ConfigFile.isWritableKey("STACKNUDGE_A\nSTACKNUDGE_CLAUDE_PATH=/tmp/evil\n#"))
        XCTAssertFalse(ConfigFile.isWritableKey("STACKNUDGE_A\rB"))
    }

    func testAKeyCarryingAnEqualsOrSpaceIsNotWritable() {
        for key in ["STACKNUDGE_A=B", "STACKNUDGE A", "STACKNUDGE_A#", "", "  ",
                    "STACKNUDGE_A\u{2028}B", "STACKNUDGE_\u{0660}"] {
            XCTAssertFalse(ConfigFile.isWritableKey(key), key)
        }
    }

    func testOrdinaryKeysStayWritable() {
        // Every existing caller passes a literal of this shape.
        for key in ["STACKNUDGE_EXT_DERBY_ORG", "STACKNUDGE_SLACK_BOT_TOKEN",
                    "STACKNUDGE_EVENTS_PER_SESSION", "A1", "_"] {
            XCTAssertTrue(ConfigFile.isWritableKey(key), key)
        }
    }

    // What the injection actually produced, so the shape of the bug is on
    // record rather than only its fix: one appended line became three, and the
    // middle one was a live assignment the reader honours.
    func testTheInjectedAssignmentWouldHaveBeenReadBack() {
        let smuggled = "STACKNUDGE_EXT_DERBY_ORG\nSTACKNUDGE_CLAUDE_PATH=/tmp/evil\n#"
        let written = ConfigFile.apply("", key: smuggled, value: "StackOne")
        XCTAssertEqual(ConfigFile.parse(written)["STACKNUDGE_CLAUDE_PATH"], "/tmp/evil")
        // ...and the value the user actually typed went nowhere.
        XCTAssertNil(ConfigFile.parse(written)["STACKNUDGE_EXT_DERBY_ORG"])
        // Which is why write() refuses the key rather than trusting apply().
        XCTAssertFalse(ConfigFile.isWritableKey(smuggled))
    }
}
