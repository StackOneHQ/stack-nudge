import XCTest

@testable import StackNudgePanelCore

// The per-extension configuration form. Every side effect is injected, so the
// save path is driven here without touching ~/.stack-nudge/config.
@MainActor
final class ExtensionConfigTests: XCTestCase {

    private func key(_ name: String, label: String? = nil,
                     placeholder: String? = nil) -> ExtensionManifest.ConfigKey {
        .init(key: name, label: label, help: nil, placeholder: placeholder)
    }

    private func model(keys: [ExtensionManifest.ConfigKey],
                       existing: [String: String] = [:],
                       persist: @escaping (String, String?) -> Void = { _, _ in },
                       didChange: @escaping () -> Void = {},
                       onRemove: @escaping () -> Void = {}) -> ExtensionConfigModel {
        let row = ExtensionRow(id: "derby", name: "Token Derby", description: "",
                               installedVersion: "1.0.0", availableVersion: nil,
                               refusedReason: nil, requires: [], config: keys)
        return ExtensionConfigModel(row: row, read: { existing }, persist: persist,
                                    didChange: didChange, onRemove: onRemove)
    }

    // MARK: - Seeding

    func testTheFormStartsFromWhatIsAlreadyInTheConfigFile() {
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")],
                      existing: ["STACKNUDGE_EXT_DERBY_ORG": "stackone"])
        XCTAssertEqual(m.values["STACKNUDGE_EXT_DERBY_ORG"], "stackone")
    }

    func testAKeyWithNoValueYetStartsEmptyRatherThanAbsent() {
        // The form iterates the declared keys, so a missing entry would be a
        // field bound to nil rather than a field showing nothing.
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")])
        XCTAssertEqual(m.values["STACKNUDGE_EXT_DERBY_ORG"], "")
    }

    // The config file holds forty-odd keys and one of them is a Slack bot
    // token. Reading the whole file into the form would put every one of them
    // behind an extension's page.
    func testOnlyTheDeclaredKeysReachTheForm() {
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")],
                      existing: ["STACKNUDGE_EXT_DERBY_ORG": "stackone",
                                 "STACKNUDGE_SLACK_BOT_TOKEN": "xoxb-a-real-looking-token"])
        XCTAssertEqual(Set(m.values.keys), ["STACKNUDGE_EXT_DERBY_ORG"])
        XCTAssertFalse(m.values.values.contains { $0.hasPrefix("xoxb-") })
    }

    // MARK: - Saving

    func testSavingWritesEveryDeclaredKey() {
        var written: [String: String?] = [:]
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG"), key("STACKNUDGE_EXT_DERBY_BASE")],
                      persist: { written[$0] = $1 })
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = "stackone"
        m.values["STACKNUDGE_EXT_DERBY_BASE"] = "https://example.test/api"
        m.save()

        XCTAssertEqual(written["STACKNUDGE_EXT_DERBY_ORG"], "stackone")
        XCTAssertEqual(written["STACKNUDGE_EXT_DERBY_BASE"], "https://example.test/api")
    }

    // The runtime treats a declared-but-empty key as absent, so writing "" would
    // leave a line in the config file that means nothing and reads like a
    // configured value.
    func testClearingAFieldRemovesTheKeyRatherThanWritingAnEmptyOne() {
        var written: [String: String?] = [:]
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")],
                      existing: ["STACKNUDGE_EXT_DERBY_ORG": "stackone"],
                      persist: { written[$0] = $1 })
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = ""
        m.save()

        XCTAssertTrue(written.keys.contains("STACKNUDGE_EXT_DERBY_ORG"))
        XCTAssertEqual(written["STACKNUDGE_EXT_DERBY_ORG"], String?.none)
    }

    func testSurroundingWhitespaceIsNotPartOfTheValue() {
        var written: [String: String?] = [:]
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")], persist: { written[$0] = $1 })
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = "  stackone  "
        m.save()
        XCTAssertEqual(written["STACKNUDGE_EXT_DERBY_ORG"], "stackone")

        // And a field of nothing but spaces is an empty field, not a value.
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = "   "
        m.save()
        XCTAssertEqual(written["STACKNUDGE_EXT_DERBY_ORG"], String?.none)
    }

    // Saving is not enough on its own: the child's environment is rebuilt for
    // each invocation, so the tab only shows the new value once it runs again.
    func testSavingAsksForTheExtensionToBeRunAgain() {
        var reruns = 0
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")], didChange: { reruns += 1 })
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = "stackone"
        m.save()
        XCTAssertEqual(reruns, 1)
    }

    func testTheSavedConfirmationBelongsToWhatIsOnScreen() {
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG")])
        XCTAssertFalse(m.saved)
        m.save()
        XCTAssertTrue(m.saved)

        // Editing through the binding is what the field does, and it has to
        // retract a confirmation that no longer describes the form.
        m.binding(for: key("STACKNUDGE_EXT_DERBY_ORG")).wrappedValue = "stackone"
        XCTAssertFalse(m.saved)
    }

    // Every installed extension opens a page, including one declaring no keys:
    // the page is where Remove lives, and a row that opened nothing would make
    // Enter mean something different depending on the extension.
    func testAnExtensionWithNoKeysStillHasAPage() {
        let m = model(keys: [])
        XCTAssertTrue(m.keys.isEmpty)
        XCTAssertTrue(m.isValid)
        XCTAssertEqual(m.name, "Token Derby")
    }

    func testRemoveIsAskedForRatherThanDoneHere() {
        var removals = 0
        let m = model(keys: [], onRemove: { removals += 1 })
        m.onRemove()
        XCTAssertEqual(removals, 1)
    }

    // MARK: - Validation

    // Not a trust boundary — the config file is the user's own and they can
    // write anything into it by hand. But a URL silently downgraded to http
    // sends a request the user believes is encrypted, and nothing downstream
    // would ever say so.
    func testAnAddressMustBeHTTPS() {
        XCTAssertNil(ExtensionConfigModel.problem(with: "https://example.test/api"))
        XCTAssertNotNil(ExtensionConfigModel.problem(with: "http://example.test/api"))
        XCTAssertNotNil(ExtensionConfigModel.problem(with: "file:///etc/passwd"))
        XCTAssertNotNil(ExtensionConfigModel.problem(with: "ftp://example.test"))
    }

    func testTheSchemeCheckIsCaseInsensitive() {
        XCTAssertNil(ExtensionConfigModel.problem(with: "HTTPS://example.test"))
    }

    // Most values are not URLs, and an organisation name must not have to look
    // like one to be accepted.
    func testAValueThatNamesNoSchemeIsNotTreatedAsAnAddress() {
        for value in ["", "stackone", "a/b", "http", "https"] {
            XCTAssertNil(ExtensionConfigModel.problem(with: value), value)
        }
    }

    // The config file is line-based, and ConfigFile rewrites the single line
    // that sets a key. A pasted value carrying a newline doesn't set a long
    // value — it sets a short one and appends whatever followed as its own
    // directive, which is how a field for an org name becomes a way to set
    // any other key in the file.
    func testALineBreakIsRefused() {
        XCTAssertNotNil(ExtensionConfigModel.problem(
            with: "stackone\nSTACKNUDGE_SLACK_BOT_TOKEN=xoxb-nope"))
        XCTAssertNotNil(ExtensionConfigModel.problem(with: "a\rb"))
    }

    // CharacterSet.controlCharacters is Cc+Cf and does not contain U+2028 /
    // U+2029, which are Zl/Zp — and both are line terminators to plenty of
    // readers. CharacterSet.newlines does contain them, along with U+0085.
    func testAUnicodeLineSeparatorIsRefusedToo() {
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"] {
            XCTAssertNotNil(ExtensionConfigModel.problem(with: "stackone\(separator)more"),
                            separator.debugDescription)
        }
    }

    // A tab pasted out of a spreadsheet is a control character and not a line
    // break. Being told about line breaks you didn't type is worse than being
    // told nothing.
    func testAnInvisibleCharacterIsNamedForWhatItIs() {
        XCTAssertEqual(ExtensionConfigModel.problem(with: "a\nb"),
                       "Line breaks aren't allowed here.")
        XCTAssertNotEqual(ExtensionConfigModel.problem(with: "a\tb"),
                          "Line breaks aren't allowed here.")
        XCTAssertNotNil(ExtensionConfigModel.problem(with: "a\tb"))
    }

    func testAnInvalidFormRefusesToSaveAnyOfIt() {
        var written: [String: String?] = [:]
        let m = model(keys: [key("STACKNUDGE_EXT_DERBY_ORG"), key("STACKNUDGE_EXT_DERBY_BASE")],
                      persist: { written[$0] = $1 })
        m.values["STACKNUDGE_EXT_DERBY_ORG"] = "stackone"
        m.values["STACKNUDGE_EXT_DERBY_BASE"] = "http://example.test"
        XCTAssertFalse(m.isValid)
        m.save()
        // Not even the valid field: half a saved form is a configuration the
        // user never chose.
        XCTAssertTrue(written.isEmpty)
    }

    func testTheProblemIsReportedAgainstTheFieldThatHasIt() {
        let bad = key("STACKNUDGE_EXT_DERBY_BASE")
        let good = key("STACKNUDGE_EXT_DERBY_ORG")
        let m = model(keys: [good, bad])
        m.values[bad.key] = "http://example.test"
        XCTAssertNotNil(m.problem(for: bad))
        XCTAssertNil(m.problem(for: good))
    }
}
