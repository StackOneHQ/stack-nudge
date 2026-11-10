import XCTest

@testable import StackNudgePanelCore

// The rules for a value written to an extension's config key, carried over
// from the config page these used to live on.
final class ExtensionConfigValueTests: XCTestCase {

    // Not a trust boundary — the config file is the user's own. But a URL
    // silently downgraded to http sends a request the user believes is
    // encrypted, and nothing downstream would ever say so.
    func testAnAddressMustBeHTTPS() {
        XCTAssertNil(ExtensionConfigValue.problem(with: "https://example.test/api"))
        XCTAssertNil(ExtensionConfigValue.problem(with: "HTTPS://example.test"))
        XCTAssertNotNil(ExtensionConfigValue.problem(with: "http://example.test/api"))
        XCTAssertNotNil(ExtensionConfigValue.problem(with: "file:///etc/passwd"))
        XCTAssertNotNil(ExtensionConfigValue.problem(with: "ftp://example.test"))
    }

    func testAValueThatNamesNoSchemeIsNotTreatedAsAnAddress() {
        for value in ["", "stackone", "a/b", "http", "https"] {
            XCTAssertNil(ExtensionConfigValue.problem(with: value), value)
        }
    }

    // Leading and trailing too: the check runs before the trim a save makes.
    func testALineBreakAnywhereIsRefused() {
        for value in ["stackone\nSTACKNUDGE_SLACK_BOT_TOKEN=x", "\nstackone", "stackone\n", "a\rb",
                      "a\u{2028}b", "a\u{2029}b", "a\u{0085}b", "a\u{000B}b", "a\u{000C}b"] {
            XCTAssertNotNil(ExtensionConfigValue.problem(with: value), value.debugDescription)
        }
    }

    // A tab pasted out of a spreadsheet is a control character and not a line
    // break; being told about line breaks you didn't type is worse than nothing.
    func testAnInvisibleCharacterIsNamedForWhatItIs() {
        XCTAssertEqual(ExtensionConfigValue.problem(with: "a\nb"), "Line breaks aren't allowed here.")
        XCTAssertNotNil(ExtensionConfigValue.problem(with: "a\tb"))
        XCTAssertNotEqual(ExtensionConfigValue.problem(with: "a\tb"), "Line breaks aren't allowed here.")
    }
}
