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
}
