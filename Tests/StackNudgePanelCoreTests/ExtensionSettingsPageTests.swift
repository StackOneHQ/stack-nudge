import XCTest

@testable import StackNudgePanelCore

// Where an extension appears, and its config as typed controls on its own
// Settings page. See docs/design/service-extensions.md, "Where an extension
// appears".
@MainActor
final class ExtensionSettingsPageTests: XCTestCase {

    private func parse(_ fields: String) -> Result<ExtensionManifest, ExtensionManifest.ParseFailure> {
        ExtensionManifest.parse(Data("""
            {"id":"away","name":"Away","version":"1","schema":2\(fields.isEmpty ? "" : ",")\(fields)}
            """.utf8))
    }

    private func manifest(_ fields: String, file: StaticString = #filePath,
                          line: UInt = #line) -> ExtensionManifest? {
        switch parse(fields) {
        case .success(let m): return m
        case .failure(let failure):
            XCTFail("refused: \(failure.message)", file: file, line: line)
            return nil
        }
    }

    private func refusal(_ fields: String) -> String? {
        if case .failure(let failure) = parse(fields) { return failure.message }
        return nil
    }

    // MARK: - Surfaces

    func testATabIsTheDefaultAndSettingsCanReplaceOrJoinIt() {
        XCTAssertEqual(manifest("")?.surfaces, [.tab])
        XCTAssertEqual(manifest(#""surfaces":["settings"]"#)?.surfaces, [.settings])
        XCTAssertEqual(manifest(#""surfaces":["tab","settings","tab"]"#)?.surfaces, [.tab, .settings])
        XCTAssertEqual(manifest(#""surfaces":["settings"]"#)?.hasTab, false)
    }

    func testAnUnknownOrEmptySurfaceListIsRefusedWithAReason() {
        XCTAssertEqual(refusal(#""surfaces":["sidebar"]"#), #"unknown surface "sidebar""#)
        XCTAssertTrue(refusal(#""surfaces":[]"#)?.contains("empty") == true)
    }

    // MARK: - Typed config

    private let typed = #"""
        "config":[
          {"key":"STACKNUDGE_EXT_A","type":"toggle","default":true},
          {"key":"STACKNUDGE_EXT_B","type":"choice",
           "options":[{"value":"low","label":"Low"},{"value":"high","label":"High"}]},
          {"key":"STACKNUDGE_EXT_C","type":"number","options":[15,90,120],"unit":"seconds","default":120},
          {"key":"STACKNUDGE_EXT_D","type":"dynamic"},
          {"key":"STACKNUDGE_EXT_E","label":"Plain"}]
        """#

    func testEachTypeParses() {
        guard let m = manifest(typed) else { return }
        XCTAssertEqual(m.config.map(\.kind), [
            .toggle,
            .choice([ConfigOption(value: "low", label: "Low"), ConfigOption(value: "high", label: "High")]),
            .number([15, 90, 120], unit: .seconds),
            .dynamic,
            .text,
        ])
        XCTAssertEqual(m.config[0].defaultValue, "true")
        XCTAssertEqual(m.config[2].defaultValue, "120")
    }

    func testBadTypesAreRefusedNamingTheKey() {
        func config(_ entry: String) -> String? { refusal(#""config":["# + entry + "]") }
        XCTAssertEqual(config(#"{"key":"STACKNUDGE_EXT_A","type":"slider"}"#),
                       #"config key "STACKNUDGE_EXT_A" has unknown type "slider""#)
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"choice"}"#))
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"number","options":["a"]}"#))
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"number","options":[1],"unit":"parsecs"}"#))
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"number","options":[1,1]}"#))
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"toggle","options":[1]}"#))
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"number","options":[10],"default":20}"#))
        // An option value is written into the line-based config file.
        XCTAssertNotNil(config(#"{"key":"STACKNUDGE_EXT_A","type":"choice","options":[{"value":"a\nb","label":"x"}]}"#))
    }

    func testSecondsReadAsAPersonWouldSayThem() {
        XCTAssertEqual(ConfigKind.format(15, unit: .seconds), "15 s")
        XCTAssertEqual(ConfigKind.format(90, unit: .seconds), "90 s")
        XCTAssertEqual(ConfigKind.format(120, unit: .seconds), "2 min")
        XCTAssertEqual(ConfigKind.format(600, unit: .seconds), "10 min")
        XCTAssertEqual(ConfigKind.format(7200, unit: .seconds), "2 h")
        XCTAssertEqual(ConfigKind.format(90, unit: nil), "90")
    }

    func testSavedValuesMustBeOneOfTheDeclaredOrOfferedOptions() {
        let offered = [ConfigOption(value: "Pixel", label: "Pixel · −70 dBm")]
        XCTAssertTrue(ConfigKind.toggle.accepts("true", offered: []))
        XCTAssertFalse(ConfigKind.toggle.accepts("yes", offered: []))
        XCTAssertTrue(ConfigKind.number([15, 90], unit: .seconds).accepts("90", offered: []))
        XCTAssertFalse(ConfigKind.number([15, 90], unit: .seconds).accepts("30", offered: []))
        XCTAssertTrue(ConfigKind.dynamic.accepts("Pixel", offered: offered))
        XCTAssertFalse(ConfigKind.dynamic.accepts("Galaxy", offered: offered))
        // The saved value is always among what a dynamic picker shows.
        XCTAssertEqual(ConfigKind.dynamic.options(offered: offered, saved: "Galaxy").map(\.value),
                       ["Galaxy", "Pixel"])
    }

    // The config page still edits a typed key as text (an extension with a
    // tab only), and refuses a value that isn't one of its options.
    func testTheConfigPageChecksATypedKeysValue() {
        let key = ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_C", label: nil, help: nil,
                                              placeholder: nil, kind: .number([15, 90], unit: .seconds))
        XCTAssertNil(ExtensionConfigValue.problem(with: "90", for: key, offered: [], saved: nil))
        XCTAssertNil(ExtensionConfigValue.problem(with: "", for: key, offered: [], saved: nil))
        XCTAssertEqual(ExtensionConfigValue.problem(with: "30", for: key, offered: [], saved: nil),
                       "Use one of: 15, 90.")
        XCTAssertNil(ExtensionConfigValue.problem(with: "30", for: key, offered: [], saved: "30"),
                     "what's already saved can stay")
    }

    // MARK: - The choices message

    func testChoicesDecodeAndBreakingTheirRulesIsInvalid() {
        func decode(_ json: String) -> ServiceProtocol.Inbound { ServiceProtocol.decode(Data(json.utf8)) }
        XCTAssertEqual(decode(#"{"type":"choices","key":"STACKNUDGE_EXT_AWAY_PHONE","options":[{"value":"Pixel","label":"Pixel · −70 dBm"},{"value":"Pixel","label":"again"}]}"#),
                       .message(.choices(key: "STACKNUDGE_EXT_AWAY_PHONE",
                                         options: [ConfigOption(value: "Pixel", label: "Pixel · −70 dBm")])))
        guard case .invalid = decode(#"{"type":"choices","key":"STACKNUDGE_SLACK_TOKEN","options":[]}"#)
        else { return XCTFail("a key outside the extension namespace was accepted") }
        guard case .invalid = decode(#"{"type":"choices","key":"STACKNUDGE_EXT_A","options":[{"value":"a\nb","label":"x"}]}"#)
        else { return XCTFail("a value the config file can't hold was accepted") }
        let many = (0...ServiceProtocol.maxChoices).map { #"{"value":"v\#($0)","label":"l"}"# }.joined(separator: ",")
        guard case .invalid = decode(#"{"type":"choices","key":"STACKNUDGE_EXT_A","options":["# + many + "]}")
        else { return XCTFail("more choices than the cap were accepted") }
    }

    // MARK: - The page in nav

    private var written: [(String, String?)] = []
    private var changed: [String] = []

    private var removed: [String] = []
    private var updated: [String] = []

    nonisolated static func installed(_ id: String, available: String? = nil, refused: String? = nil) -> ExtensionRow {
        ExtensionRow(id: id, name: id.capitalized, description: "", installedVersion: refused == nil ? "1.0.0" : nil,
                     availableVersion: available, refusedReason: refused, requires: [], config: [])
    }

    // Away installed, its page open through the real way in: the Extensions
    // list's row, then ⏎.
    private func nav(saved: [String: String] = [:], holder: String? = nil,
                     available: String? = nil) -> PanelNav {
        guard let m = manifest(typed) else { fatalError("fixture manifest didn't parse") }
        let nav = PanelNav()
        nav.persistExtensionValue = { [unowned self] key, value in self.written.append((key, value)) }
        nav.onExtensionConfigChanged = { [unowned self] id in self.changed.append(id) }
        nav.onRemoveExtension = { [unowned self] id in self.removed.append(id) }
        nav.onUpdateExtension = { [unowned self] id in self.updated.append(id) }
        nav.installedExtensions = [Self.installed("away", available: available)]
        nav.extensionSettingsPages = [ExtensionSettingsPage(id: "away", name: "Away", keys: m.config)]
        nav.extensionConfigValues = saved
        nav.presenceHolderID = holder
        nav.settingsCategory = .extensions
        XCTAssertTrue(nav.enterSettingsCategory())
        nav.selectedSettingIndex = nav.index(of: .installedExtension("away"))
        nav.activate()
        XCTAssertEqual(nav.settingsCategory, .extensionPage("away"))
        XCTAssertTrue(nav.settingsDetailFocused)
        return nav
    }

    private func select(_ nav: PanelNav, _ key: String, onList: Bool = false) {
        if onList {
            nav.selectedSettingIndex = nav.index(of: .browseExtensions)
            return
        }
        nav.selectedSettingIndex = nav.index(of: .extensionSetting("away", key))
        XCTAssertEqual(nav.selectedRow, .extensionSetting("away", key))
    }

    // The page is a level below Extensions, not a sidebar entry: the sidebar
    // keeps Extensions lit, and ⌘↓ moves on from Extensions as usual.
    func testThePageLivesUnderExtensionsNotInTheSidebar() {
        let nav = nav()
        XCTAssertEqual(nav.settingsCategories, SettingsCategory.allCases)
        XCTAssertEqual(nav.sidebarCategory, .extensions)
        XCTAssertEqual(nav.label(for: .extensionPage("away")), "Away")
        XCTAssertEqual(nav.selectedRow, .extensionSetting("away", "STACKNUDGE_EXT_A"), "lands on the first row")
        nav.selectNextCategory()
        XCTAssertEqual(nav.settingsCategory, .panel)
    }

    // Settings, then the app's lock row, then Update when there is one, then
    // Remove.
    func testThePageRowsInOrder() {
        let keys = ["STACKNUDGE_EXT_A", "STACKNUDGE_EXT_B", "STACKNUDGE_EXT_C", "STACKNUDGE_EXT_D",
                    "STACKNUDGE_EXT_E"].map { SettingsRow.extensionSetting("away", $0) }
        XCTAssertEqual(nav().rows(in: .extensionPage("away")), keys + [.extensionRemove("away")])
        XCTAssertEqual(nav(holder: "away", available: "1.2.0").rows(in: .extensionPage("away")),
                       keys + [.awayLock, .extensionUpdate("away"), .extensionRemove("away")])
    }

    // ← goes back to the list, on the row the page was opened from.
    func testBackFromThePageLandsOnItsRow() {
        let nav = nav()
        nav.settingsBack()
        XCTAssertEqual(nav.settingsCategory, .extensions)
        XCTAssertTrue(nav.settingsDetailFocused)
        XCTAssertEqual(nav.selectedRow, .installedExtension("away"))
        nav.settingsBack()
        XCTAssertFalse(nav.settingsDetailFocused, "and from the list out to the sidebar")
    }

    // Uninstalled while open: back to the list, where it no longer is.
    func testAPageWhoseExtensionGoesHandsThePaneBackToTheList() {
        let nav = nav()
        nav.installedExtensions = []
        nav.extensionSettingsPages = []
        XCTAssertEqual(nav.settingsCategory, .extensions)
        XCTAssertEqual(nav.selectedRow, .browseExtensions)
    }

    func testUpdateRunsAndRemoveTakesOnlyCommandDelete() {
        let nav = nav(available: "1.2.0")
        nav.selectedSettingIndex = nav.index(of: .extensionUpdate("away"))
        XCTAssertNil(nav.selectedRemovableExtension)
        nav.activate()
        XCTAssertEqual(updated, ["away"])

        nav.selectedSettingIndex = nav.index(of: .extensionRemove("away"))
        XCTAssertEqual(nav.selectedRemovableExtension, "away", "⌘⌫ removes from here")
        nav.activate()
        nav.cycleForward()
        XCTAssertTrue(removed.isEmpty, "⏎, Space and arrows never remove")

        // And the list row, which ⌘⌫ also removes from; no other row does.
        nav.settingsBack()
        XCTAssertEqual(nav.selectedRemovableExtension, "away")
        select(nav, "STACKNUDGE_EXT_A", onList: true)
        XCTAssertNil(nav.selectedRemovableExtension)
    }

    // A refused extension has no settings: its page is Remove alone.
    func testARefusedExtensionsPageIsRemoveAlone() {
        let nav = PanelNav()
        nav.installedExtensions = [Self.installed("broken", refused: "needs schema 9")]
        nav.settingsCategory = .extensions
        nav.enterSettingsCategory()
        nav.activate()
        XCTAssertEqual(nav.settingsCategory, .extensionPage("broken"))
        XCTAssertEqual(nav.settingsRows, [.extensionRemove("broken")])
    }

    // A picker: arrows do nothing until Space starts it, step only the value
    // on screen while it runs, and settling writes once and tells the host.
    func testAPickerStepsADraftAndWritesOnceWhenItSettles() {
        let nav = nav()
        select(nav, "STACKNUDGE_EXT_C")
        XCTAssertTrue(nav.selectedRowIsPicker)
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_C"), "2 min", "shows the default")

        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_C"), "2 min", "arrows before a pick")

        nav.activate()
        XCTAssertTrue(nav.pickingValue)
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_C"), "15 s", "wraps to the first")
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_C"), "90 s")
        XCTAssertTrue(written.isEmpty, "nothing is written mid-pick")

        nav.activate()
        XCTAssertFalse(nav.pickingValue)
        XCTAssertEqual(written.map(\.0), ["STACKNUDGE_EXT_C"])
        XCTAssertEqual(written.map(\.1), ["90"])
        XCTAssertEqual(changed, ["away"])
        XCTAssertEqual(nav.extensionConfigValues["STACKNUDGE_EXT_C"], "90")
    }

    func testSettlingWhereItStartedWritesNothing() {
        let nav = nav(saved: ["STACKNUDGE_EXT_C": "90"])
        select(nav, "STACKNUDGE_EXT_C")
        nav.activate()
        nav.cycleForward()
        nav.cycleBackward()
        nav.activate()
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(changed.isEmpty)
    }

    // Moving to another row settles a pick where it stands, as on every page.
    func testMovingOffThePickerSettlesIt() {
        let nav = nav()
        select(nav, "STACKNUDGE_EXT_B")
        nav.activate()
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_B"), "Low")
        nav.pickingValue = false
        nav.selectNextRow()
        XCTAssertEqual(written.map(\.1), ["low"])
    }

    // No default to show: the picker starts on "Default", which unsets it.
    func testAKeyWithoutADefaultCanBeUnsetAgain() {
        let nav = nav(saved: ["STACKNUDGE_EXT_B": "high"])
        select(nav, "STACKNUDGE_EXT_B")
        nav.activate()
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_B"), "Default")
        nav.activate()
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.1)
        XCTAssertNil(nav.extensionConfigValues["STACKNUDGE_EXT_B"])
    }

    // A toggle flips on ⏎ or Space, and never on an arrow.
    func testAToggleFlipsOnActivateOnly() {
        let nav = nav()
        select(nav, "STACKNUDGE_EXT_A")
        XCTAssertFalse(nav.selectedRowIsPicker)
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_A"), "On")
        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertTrue(written.isEmpty)
        nav.activate()
        XCTAssertEqual(written.map(\.1), ["false"])
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_A"), "Off")
        XCTAssertEqual(changed, ["away"])
    }

    // What the service offers, plus the saved phone even while it isn't heard.
    func testADynamicPickerStepsThroughWhatTheServiceOffers() {
        let nav = nav(saved: ["STACKNUDGE_EXT_D": "Galaxy"])
        nav.extensionChoices = ["away": ["STACKNUDGE_EXT_D": [
            ConfigOption(value: "Pixel", label: "Pixel · −70 dBm"),
        ]]]
        select(nav, "STACKNUDGE_EXT_D")
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_D"), "Galaxy")
        nav.activate()
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_D"), "Pixel · −70 dBm")
        nav.activate()
        XCTAssertEqual(written.map(\.1), ["Pixel"])
    }

    // A text key isn't a picker: ⏎ hands its row a field, ⏎ in the field
    // saves (trimmed), and a refused value keeps the field with the reason.
    func testATextRowEditsInPlace() {
        let nav = nav(saved: ["STACKNUDGE_EXT_E": "old"])
        select(nav, "STACKNUDGE_EXT_E")
        XCTAssertFalse(nav.selectedRowIsPicker)
        nav.activate()
        XCTAssertFalse(nav.pickingValue)
        XCTAssertEqual(nav.extensionTextEdit?.value, "old")

        nav.updateExtensionTextEdit("http://example.test")
        XCTAssertFalse(nav.commitExtensionTextEdit())
        XCTAssertEqual(nav.extensionTextProblem, "Only https:// addresses are allowed.")
        XCTAssertNotNil(nav.extensionTextEdit)

        nav.updateExtensionTextEdit("  stackone ")
        XCTAssertNil(nav.extensionTextProblem, "a fresh edit clears the reason")
        XCTAssertTrue(nav.commitExtensionTextEdit())
        XCTAssertNil(nav.extensionTextEdit)
        XCTAssertEqual(written.map(\.1), ["stackone"])
        XCTAssertEqual(changed, ["away"])
    }

    func testEmptyingATextRowUnsetsItAndCancellingKeepsTheSavedValue() {
        let nav = nav(saved: ["STACKNUDGE_EXT_E": "old"])
        select(nav, "STACKNUDGE_EXT_E")
        nav.activate()
        nav.updateExtensionTextEdit("new")
        nav.cancelExtensionTextEdit()
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_E"), "old")

        nav.activate()
        nav.updateExtensionTextEdit("")
        XCTAssertTrue(nav.commitExtensionTextEdit())
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.1)
    }

    // A line break typed or pasted is refused before any trim.
    func testATextRowRefusesALineBreak() {
        let nav = nav()
        select(nav, "STACKNUDGE_EXT_E")
        nav.activate()
        nav.updateExtensionTextEdit("\nSTACKNUDGE_AWAY_LOCK=false")
        XCTAssertFalse(nav.commitExtensionTextEdit())
        XCTAssertTrue(written.isEmpty)
    }

    // Leaving Settings drops a half-typed value.
    func testLeavingSettingsCancelsTheEdit() {
        let nav = nav()
        nav.mode = .settings
        select(nav, "STACKNUDGE_EXT_E")
        nav.activate()
        nav.mode = .events
        XCTAssertNil(nav.extensionTextEdit)
        XCTAssertTrue(written.isEmpty)
    }

    // MARK: - The status line

    func testTheStatusLineIsTheBadgeThenTheFirstRow() {
        guard case .success(let document) = ExtensionDocument.parse(Data(#"""
            {"schema":1,"header":{"title":"Away","badge":{"text":"Present","tone":"success"}},
             "rows":[{"id":"phone","title":"Alex's Pixel 9","value":"−74 dBm · 3 s ago"},
                     {"id":"other","title":"Headphones","value":"−40 dBm"}]}
            """#.utf8)) else { return XCTFail("fixture document didn't parse") }
        XCTAssertEqual(ExtensionHost.statusLine(.init(document: document)),
                       "Present · Alex's Pixel 9 · −74 dBm · 3 s ago")
        XCTAssertEqual(ExtensionHost.statusLine(.init(document: document, status: .stale("restarting in 2s"))),
                       "Present · Alex's Pixel 9 · −74 dBm · 3 s ago · restarting in 2s")
        XCTAssertNil(ExtensionHost.statusLine(.init()))
    }

    // MARK: - Line breaks never reach the config file

    // Leading, trailing, inside, CR alone, the Unicode separators and NUL.
    private let breaking = ["\nSTACKNUDGE_AWAY_LOCK=false", "Pixel\n", "Pi\nxel", "Pixel\r",
                            "\rPixel", "Pi\u{0085}xel", "Pi\u{2028}xel", "Pi\u{2029}xel", "Pi\u{0}xel"]

    func testNoValueWithALineBreakIsStorable() {
        for value in breaking {
            XCTAssertTrue(ConfigFile.containsLineBreak(value), value.debugDescription)
            XCTAssertFalse(ConfigKind.isStorable(value), value.debugDescription)
        }
        XCTAssertTrue(ConfigKind.isStorable("Alex's Pixel 9"))
    }

    func testAChoicesMessageWithALineBreakIsRefused() {
        for value in breaking {
            let line = try! JSONSerialization.data(withJSONObject: [
                "type": "choices", "key": "STACKNUDGE_EXT_AWAY_PHONE",
                "options": [["value": value, "label": "x"]],
            ])
            guard case .invalid = ServiceProtocol.decode(line) else {
                return XCTFail("accepted \(value.debugDescription)")
            }
            let label = try! JSONSerialization.data(withJSONObject: [
                "type": "choices", "key": "STACKNUDGE_EXT_AWAY_PHONE",
                "options": [["value": "ok", "label": value]],
            ])
            guard case .invalid = ServiceProtocol.decode(label) else {
                return XCTFail("accepted a label \(value.debugDescription)")
            }
        }
    }

    func testAManifestOptionWithALineBreakIsRefused() {
        for value in breaking {
            let option = try! JSONSerialization.data(withJSONObject: ["value": value, "label": "x"])
            let entry = #"{"key":"STACKNUDGE_EXT_A","type":"choice","options":["#
                + String(decoding: option, as: UTF8.self) + "]}"
            XCTAssertNotNil(refusal(#""config":["# + entry + "]"), value.debugDescription)
        }
    }

    // The last line of defence: the writer itself leaves the file alone.
    func testTheConfigWriterRefusesALineBreak() {
        let contents = "STACKNUDGE_AWAY_LOCK=true\n"
        for value in breaking {
            XCTAssertEqual(ConfigFile.apply(contents, key: "STACKNUDGE_EXT_AWAY_PHONE", value: value),
                           contents, value.debugDescription)
        }
        XCTAssertEqual(ConfigFile.apply(contents, key: "STACKNUDGE_EXT_AWAY_PHONE", value: "Pixel"),
                       "STACKNUDGE_AWAY_LOCK=true\nSTACKNUDGE_EXT_AWAY_PHONE=Pixel\n")
    }

    // Even an option that got into nav some other way isn't saved.
    func testThePageDoesNotSaveALineBreak() {
        let nav = nav()
        nav.extensionChoices = ["away": ["STACKNUDGE_EXT_D": [
            ConfigOption(value: "\nSTACKNUDGE_AWAY_LOCK=false", label: "evil"),
        ]]]
        select(nav, "STACKNUDGE_EXT_D")
        nav.activate()
        nav.cycleForward()
        XCTAssertEqual(nav.extensionValueLabel("away", "STACKNUDGE_EXT_D"), "evil")
        nav.activate()
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(changed.isEmpty)
    }

    // MARK: - A page with nothing to set

    // No rows at all (an id that isn't installed): can't be stepped into, so
    // the selection can never land on the attention banner above the split.
    func testAPageWithNoRowsCannotBeEntered() {
        let nav = PanelNav()
        nav.updateAvailable = "9.9.9"
        nav.settingsCategory = .extensionPage("radar")
        XCTAssertFalse(nav.canEnterSettingsCategory)
        XCTAssertFalse(nav.enterSettingsCategory())
        XCTAssertFalse(nav.settingsDetailFocused)
        nav.openExtensionPage("radar")
        XCTAssertFalse(nav.settingsDetailFocused, "nor opened from the list")
        nav.settingsCategory = .about
        XCTAssertTrue(nav.enterSettingsCategory())
        XCTAssertEqual(nav.selectedRow, .openRepo)
    }

    // MARK: - The lock row always has a home

    func testTheLockRowIsOnTheHoldersPageOrTheListAsAFallback() {
        let nav = PanelNav()
        nav.installedExtensions = [Self.installed("away")]
        nav.presenceHolderID = "away"
        // A holder with no page (it never loaded): on the Extensions list.
        XCTAssertEqual(nav.rows(in: .extensions),
                       [.installedExtension("away"), .awayLock, .browseExtensions])

        // Its page: there, and only there.
        nav.extensionSettingsPages = [ExtensionSettingsPage(id: "away", name: "Away", keys: [])]
        XCTAssertEqual(nav.rows(in: .extensions), [.installedExtension("away"), .browseExtensions])
        XCTAssertEqual(nav.rows(in: .extensionPage("away")), [.awayLock, .extensionRemove("away")])

        // Nobody holding presence: no lock row anywhere.
        nav.presenceHolderID = nil
        let everywhere = (nav.settingsCategories + [.extensionPage("away")]).flatMap { nav.rows(in: $0) }
        XCTAssertFalse(everywhere.contains(.awayLock))
    }

    // MARK: - The selection follows its row

    func testTheSelectionFollowsItsRowWhenThePageChanges() {
        let nav = nav(holder: "away")
        select(nav, "STACKNUDGE_EXT_C")
        guard let m = manifest(typed) else { return }
        let extra = ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_Z", label: nil, help: nil, placeholder: nil)
        nav.extensionSettingsPages = [ExtensionSettingsPage(id: "away", name: "Away", keys: [extra] + m.config)]
        XCTAssertEqual(nav.selectedRow, .extensionSetting("away", "STACKNUDGE_EXT_C"))

        // The lock row going away under the cursor lands on the first row,
        // not on whatever took its index.
        nav.selectedSettingIndex = nav.index(of: .awayLock)
        XCTAssertEqual(nav.selectedRow, .awayLock)
        nav.presenceHolderID = nil
        XCTAssertEqual(nav.selectedRow, .extensionSetting("away", "STACKNUDGE_EXT_Z"))
    }

    // Installing or removing another extension while the list is open keeps
    // the selection on the row it was on.
    func testTheListSelectionFollowsItsRowAsExtensionsComeAndGo() {
        let nav = PanelNav()
        nav.installedExtensions = [Self.installed("away"), Self.installed("derby")]
        nav.settingsCategory = .extensions
        nav.enterSettingsCategory()
        nav.selectedSettingIndex = nav.index(of: .installedExtension("derby"))
        nav.installedExtensions = [Self.installed("alpha"), Self.installed("away"), Self.installed("derby")]
        XCTAssertEqual(nav.selectedRow, .installedExtension("derby"))
        nav.installedExtensions = [Self.installed("alpha"), Self.installed("away")]
        XCTAssertEqual(nav.selectedRow, .installedExtension("alpha"), "a removed row hands over to the first")
    }

    // MARK: - Keys and footer

    func testRightOpensAListRowAndOnlyStepsAPickerElsewhere() {
        let right: UInt16 = 124
        XCTAssertEqual(PanelController.settingsDetailKeyAction(keyCode: right, modifiers: [], picking: false,
                                                               rightOpens: true), .activate)
        XCTAssertEqual(PanelController.settingsDetailKeyAction(keyCode: right, modifiers: [], picking: false,
                                                               rightOpens: false), .step(1))
        XCTAssertEqual(PanelController.settingsDetailKeyAction(keyCode: right, modifiers: [], picking: true,
                                                               rightOpens: true), .step(1))
        XCTAssertEqual(PanelController.settingsDetailKeyAction(keyCode: 123, modifiers: [], picking: false), .back)
        // ⌘⌫ is resolved before this table, so it is nothing here.
        XCTAssertNil(PanelController.settingsDetailKeyAction(keyCode: 51, modifiers: .command, picking: false))
    }

    func testOnlyAListRowOpensOnRight() {
        let nav = nav()
        XCTAssertFalse(nav.selectedRowOpensOnRight)
        nav.settingsBack()
        XCTAssertTrue(nav.selectedRowOpensOnRight)
        nav.selectedSettingIndex = nav.index(of: .browseExtensions)
        XCTAssertTrue(nav.selectedRowOpensOnRight)
    }

    func testTheFooterKeepsItsHintsAndDimsWhatDoesNotApply() {
        func hints(_ opens: Bool, removeRow: Bool = false, removable: Bool = false,
                   onPage: Bool = false) -> [FooterHintSpec] {
            SettingsView.detailFooterHints(picker: false, opensPage: opens, removeRow: removeRow,
                                           removable: removable, inExtensions: true, onPage: onPage,
                                           editingText: false)
        }
        let list = hints(true, removable: true)
        XCTAssertEqual(list.map(\.label), ["Move", "Category", "Open", "Remove", "Categories"])
        XCTAssertEqual(list[2].keys, ["→", "⏎"])
        XCTAssertFalse(list[3].dimmed)

        let remove = hints(false, removeRow: true, removable: true, onPage: true)
        XCTAssertEqual(remove.map(\.label), ["Move", "Category", "Act", "Remove", "Extensions"])
        XCTAssertTrue(remove[2].dimmed, "⏎ does nothing on Remove")

        let setting = hints(false, onPage: true)
        XCTAssertTrue(setting[3].dimmed)
        XCTAssertEqual(setting.count, remove.count, "the bar doesn't reflow")

        let elsewhere = SettingsView.detailFooterHints(picker: true, opensPage: false, removeRow: false,
                                                       removable: false, inExtensions: false,
                                                       onPage: false, editingText: false)
        XCTAssertEqual(elsewhere.map(\.label), ["Move", "Category", "Pick", "Categories"])
        XCTAssertEqual(SettingsView.detailFooterHints(picker: false, opensPage: false, removeRow: false,
                                                      removable: false, inExtensions: true, onPage: true,
                                                      editingText: true).map(\.label), ["Save"])
    }

    // MARK: - The list's status

    func testTheListStatusPrecedence() {
        func status(refused: Bool = false, update: String? = nil, service: Bool = false,
                    state: String? = nil, holds: Bool = false, away: Bool = false,
                    tab: String? = nil) -> String {
            ExtensionListStatus.text(refused: refused, update: update, isService: service,
                                     serviceState: state, holdsPresence: holds, isAway: away, tab: tab)
        }
        XCTAssertEqual(status(update: "1.2.0", service: true, state: "Broken"), "Update 1.2.0")
        XCTAssertEqual(status(refused: true), "Not loaded")
        XCTAssertEqual(status(service: true, state: "Running", holds: true), "Present")
        XCTAssertEqual(status(service: true, state: "Running", holds: true, away: true), "Away")
        XCTAssertEqual(status(service: true, state: "Starting", holds: true), "Starting")
        XCTAssertEqual(status(service: true, state: "Running"), "Running")
        XCTAssertEqual(status(service: true, state: "Broken"), "Broken")
        XCTAssertEqual(status(service: true), "Stopped")
        XCTAssertEqual(status(tab: "Tab ⌘5"), "Tab ⌘5")
        XCTAssertEqual(status(), "")
        XCTAssertEqual(ExtensionHost.stateLabel(.running), "Running")
        XCTAssertEqual(ExtensionHost.stateLabel(nil), "Stopped")
    }

    func testCapabilitiesReadInPlainWords() {
        XCTAssertEqual(ExtensionCapability.bluetooth.plainWords, "Bluetooth")
        XCTAssertEqual(ExtensionCapability.signalPresence.plainWords, "Tell StackNudge you're away")
        for capability in ExtensionCapability.allCases {
            XCTAssertFalse(capability.plainWords.contains(":"), "\(capability) reads as a key")
        }
    }

    // MARK: - Autorepeat

    private func key(_ code: UInt16, repeat isRepeat: Bool, characters: String = "\r") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)!
    }

    // A held ⏎ in the browser neither installs nor answers its own question.
    func testAHeldReturnInTheBrowserIsSwallowed() {
        XCTAssertEqual(PanelController.extensionsKeyAction(for: key(36, repeat: false)), .activate)
        XCTAssertEqual(PanelController.extensionsKeyAction(for: key(36, repeat: true)), .swallow)
        XCTAssertEqual(PanelController.extensionsKeyAction(for: key(76, repeat: true)), .swallow)
        XCTAssertEqual(PanelController.extensionsKeyAction(for: key(125, repeat: true, characters: "")),
                       .moveSelection(1), "holding ↓ still walks the list")
    }

    // A held ⏎, Space or opening → in Settings can't open a page and then
    // fire its first row; arrows and stepping still repeat.
    func testAHeldActivateInSettingsIsIgnored() {
        func action(_ code: UInt16, _ isRepeat: Bool, picking: Bool = false, opens: Bool = false) -> PanelController.SettingsDetailKeyAction? {
            PanelController.settingsDetailKeyAction(for: key(code, repeat: isRepeat, characters: ""),
                                                    picking: picking, rightOpens: opens)
        }
        XCTAssertEqual(action(36, false), .activate)
        XCTAssertEqual(action(36, true), .ignoreRepeat)
        XCTAssertEqual(action(49, true), .ignoreRepeat)
        XCTAssertEqual(action(124, true, opens: true), .ignoreRepeat)
        XCTAssertEqual(action(124, true, picking: true), .step(1))
        XCTAssertEqual(action(125, true), .moveRow(1))
    }

    // MARK: - Help and placeholder

    func testAKeysHelpIsItsRowsSecondLine() {
        let nav = nav()
        XCTAssertNil(nav.extensionRowDetail("away", "STACKNUDGE_EXT_A"))
        // The real manifest, read from the checkout: both test runners start in
        // the repository root (the no-Xcode one copies the tests elsewhere, so
        // #filePath wouldn't find it).
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent(),
        ].map { $0.appendingPathComponent("extensions/away/manifest.json") }
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              case .success(let away) = ExtensionManifest.parse(data)
        else { return XCTFail("Away's manifest didn't parse") }
        nav.extensionSettingsPages = [ExtensionSettingsPage(id: "away", name: "Away", keys: away.config)]
        XCTAssertEqual(nav.extensionRowDetail("away", "STACKNUDGE_EXT_AWAY_PHONE"),
                       away.config.first?.help)
        XCTAssertTrue(nav.extensionRowDetail("away", "STACKNUDGE_EXT_AWAY_PHONE")?.contains("paired") == true)
    }

    // MARK: - The page's Update row confirms

    func testThePagesUpdateRowAsksAgainAndMovingOffWithdrawsIt() {
        let nav = nav(available: "1.2.0")
        var cancelled = 0
        nav.onCancelUpdateConfirmation = { cancelled += 1; nav.extensionConfirming = nil }
        nav.onUpdateExtension = { [unowned self] id in
            self.updated.append(id)
            nav.extensionConfirming = id   // what the catalogue does on a first press
        }
        nav.mode = .settings
        nav.selectedSettingIndex = nav.index(of: .extensionUpdate("away"))
        nav.activate()
        XCTAssertEqual(nav.extensionConfirming, "away")
        XCTAssertEqual(cancelled, 0, "staying on the row keeps the question")
        nav.selectedSettingIndex = nav.index(of: .extensionRemove("away"))
        XCTAssertEqual(cancelled, 1)
        XCTAssertNil(nav.extensionConfirming)
    }

    // MARK: - Restored checks

    func testOnlyDeclaredSetKeysReachTheSettingsPages() {
        let pages = [ExtensionSettingsPage(id: "away", name: "Away", keys: [
            .init(key: "STACKNUDGE_EXT_AWAY_PHONE", label: nil, help: nil, placeholder: nil),
            .init(key: "STACKNUDGE_EXT_AWAY_IDLE", label: nil, help: nil, placeholder: nil),
        ])]
        let config = ["STACKNUDGE_EXT_AWAY_PHONE": "Pixel", "STACKNUDGE_EXT_AWAY_IDLE": "",
                      "STACKNUDGE_SLACK_BOT_TOKEN": "xoxb-secret", "STACKNUDGE_EXT_DERBY_ORG": "x"]
        XCTAssertEqual(PanelController.extensionConfigValues(config, pages: pages),
                       ["STACKNUDGE_EXT_AWAY_PHONE": "Pixel"])
    }

    func testAWhitespaceOnlyValueUnsetsTheKey() {
        let nav = nav(saved: ["STACKNUDGE_EXT_E": "old"])
        select(nav, "STACKNUDGE_EXT_E")
        nav.activate()
        nav.updateExtensionTextEdit("   ")
        XCTAssertTrue(nav.commitExtensionTextEdit())
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.1)
        XCTAssertNil(nav.extensionConfigValues["STACKNUDGE_EXT_E"])
    }

    // Esc in a field on Settings puts back an extension's text setting; the
    // other pages keep theirs.
    func testCancellingAFieldInSettingsCancelsTheExtensionValue() {
        XCTAssertEqual(PanelController.fieldToCancel(in: .settings, renaming: false), .extensionValue)
        XCTAssertEqual(PanelController.fieldToCancel(in: .extensions, renaming: false), .catalogueQuery)
        XCTAssertEqual(PanelController.fieldToCancel(in: .events, renaming: false), .historyQuery)
        XCTAssertEqual(PanelController.fieldToCancel(in: .sessions, renaming: true), .rename)
        XCTAssertNil(PanelController.fieldToCancel(in: .sessions, renaming: false))
        XCTAssertEqual(PanelController.fieldToCancel(in: .phrases, renaming: false), .phraseDraft)
    }

    // One footnote line; placement only when there's a tab to mention.
    func testThePageFootnoteIsOneLine() {
        func page(_ allowed: [String], tab: String?) -> ExtensionSettingsPage {
            ExtensionSettingsPage(id: "x", name: "X", keys: [], allowed: allowed, tab: tab)
        }
        XCTAssertEqual(SettingsView.extensionPageTrailerText(page(["Bluetooth", "Tell StackNudge you're away"], tab: nil)),
                       "Allowed: Bluetooth \u{00B7} Tell StackNudge you're away")
        XCTAssertEqual(SettingsView.extensionPageTrailerText(page([], tab: "Tab \u{2318}6")),
                       "Allowed: nothing beyond running \u{00B7} Also a tab \u{00B7} \u{2318}6")
        XCTAssertEqual(SettingsView.extensionPageTrailerText(page([], tab: "Tab")),
                       "Allowed: nothing beyond running \u{00B7} Also a tab")
    }
}
