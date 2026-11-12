import XCTest

@testable import StackNudgePanelCore

// The manifest is the only thing standing between a directory name and a path
// the app builds, so the id and run-path guards are the ones that matter here.
final class ExtensionManifestTests: XCTestCase {

    private func parse(_ json: String) -> Result<ExtensionManifest, ExtensionManifest.ParseFailure> {
        ExtensionManifest.parse(Data(json.utf8))
    }

    private func manifest(_ json: String,
                          file: StaticString = #filePath, line: UInt = #line) -> ExtensionManifest? {
        guard case .success(let manifest) = parse(json) else {
            XCTFail("expected a manifest", file: file, line: line)
            return nil
        }
        return manifest
    }

    private let minimal = """
        {"id":"derby","name":"Token Derby","version":"1.2.0","schema":1}
        """

    // MARK: - Defaults

    func testOmittedFieldsTakeTheirDefaults() {
        guard let m = manifest(minimal) else { return }
        XCTAssertEqual(m.run, "./run")
        XCTAssertEqual(m.requires, [])
        XCTAssertEqual(m.config, [])
        XCTAssertTrue(m.refresh.onOpen)
        XCTAssertNil(m.refresh.intervalSeconds)
        XCTAssertTrue(m.refresh.whileFocusedOnly)
    }

    // The widget has room for one chip, so it is opt-in: an extension that
    // never asked for it can't take it.
    func testTheWidgetGlanceIsOffUnlessAsked() {
        XCTAssertEqual(manifest(minimal)?.glance, false)
        XCTAssertEqual(manifest("""
            {"id":"derby","name":"Token Derby","version":"1.2.0","schema":1,"glance":true}
            """)?.glance, true)
    }

    // A manifest with no tab block still contributes a tab; the name is a
    // better label than the id, which is a path component.
    func testTabLabelFallsBackToTheName() {
        XCTAssertEqual(manifest(minimal)?.tab.label, "Token Derby")
        XCTAssertEqual(manifest(minimal)?.tabEntry, ExtensionTab(id: "derby", label: "Token Derby"))
    }

    func testDeclaredFieldsWin() {
        let json = """
            {"id":"derby","name":"Token Derby","version":"1.2.0","schema":1,
             "tab":{"label":"Derby"},"run":"bin/go","requires":["python3"],
             "config":["STACKNUDGE_EXT_DERBY_ORG"],
             "refresh":{"onOpen":false,"intervalSeconds":30,"whileFocusedOnly":false}}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.tab.label, "Derby")
        XCTAssertEqual(m.run, "bin/go")
        XCTAssertEqual(m.requires, ["python3"])
        XCTAssertEqual(m.config.map(\.key), ["STACKNUDGE_EXT_DERBY_ORG"])
        XCTAssertFalse(m.refresh.onOpen)
        XCTAssertEqual(m.refresh.intervalSeconds, 30)
        XCTAssertFalse(m.refresh.whileFocusedOnly)
    }

    // The tab strip is a fixed-width row of buttons, and the label went into it
    // unvalidated while the id beside it was strictly checked — so an empty or
    // very long label pushed the other tabs off the strip.
    func testTabLabelsAreBounded() {
        let long = String(repeating: "wide", count: 40)
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,"tab":{"label":"\(long)"}}
            """
        XCTAssertEqual(manifest(json)?.tab.label.count, ExtensionManifest.maxTabLabelLength)
    }

    // A nameless tab is unclickable in practice; the id is always a real word.
    func testAnEmptyTabLabelFallsBackToTheID() {
        let json = """
            {"id":"derby","name":"  ","version":"1","schema":1,"tab":{"label":"   "}}
            """
        XCTAssertEqual(manifest(json)?.tab.label, "derby")
    }

    // MARK: - Ids

    func testValidIDs() {
        for id in ["derby", "a", "token-derby", "x9", String(repeating: "a", count: 32)] {
            XCTAssertTrue(ExtensionManifest.isValidID(id), id)
        }
    }

    // Every one of these would become a directory name, and the first four are
    // the ones that would escape ~/.stack-nudge/extensions entirely.
    func testRejectedIDs() {
        for id in ["..", "../../evil", "/etc", "a/b", "", "Derby", "der by", "der_by",
                   "derby!", String(repeating: "a", count: 33)] {
            XCTAssertFalse(ExtensionManifest.isValidID(id), id)
        }
    }

    func testAManifestWithABadIDIsRefusedRatherThanSanitised() {
        let json = """
            {"id":"../../evil","name":"Evil","version":"1","schema":1}
            """
        XCTAssertEqual(parse(json), .failure(.invalidID("../../evil")))
    }

    // MARK: - Run paths

    func testValidRunPaths() {
        for run in ["./run", "run", "bin/run", "a/b/c.py"] {
            XCTAssertTrue(ExtensionManifest.isValidRunPath(run), run)
        }
    }

    func testRejectedRunPaths() {
        for run in ["", "/bin/sh", "~/evil", "../run", "bin/../../run", "a/../../b"] {
            XCTAssertFalse(ExtensionManifest.isValidRunPath(run), run)
        }
    }

    func testAManifestWithAnEscapingRunPathIsRefused() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,"run":"../../../bin/sh"}
            """
        XCTAssertEqual(parse(json), .failure(.invalidRunPath("../../../bin/sh")))
    }

    // MARK: - Schema

    // A newer manifest is refused by schema, not by whichever field check it
    // happens to trip first — otherwise the message would blame the wrong thing.
    func testANewerSchemaIsRefusedBeforeAnythingElseIsJudged() {
        let json = """
            {"id":"NOT VALID","name":"D","version":"1","schema":3}
            """
        XCTAssertEqual(parse(json), .failure(.unsupportedSchema(3)))
    }

    func testTheUnsupportedSchemaMessageQuotesBothNumbers() {
        let message = ExtensionManifest.ParseFailure.unsupportedSchema(7).message
        XCTAssertTrue(message.contains("7"), message)
        XCTAssertTrue(message.contains("\(ExtensionManifest.supportedManifestSchemas.upperBound)"), message)
    }

    // MARK: - Malformed

    func testNotJSON() {
        guard case .failure(.malformed) = parse("{{{") else {
            return XCTFail("expected malformed")
        }
    }

    func testAMissingRequiredFieldNamesIt() {
        guard case .failure(.malformed(let why)) =
                parse(#"{"name":"D","version":"1","schema":1}"#) else {
            return XCTFail("expected malformed")
        }
        XCTAssertTrue(why.contains("id"), why)
    }

    func testAWrongTypeIsNotSilentlyCoerced() {
        guard case .failure(.malformed) =
                parse(#"{"id":"derby","name":"D","version":1,"schema":1}"#) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: - Config keys

    // The original form. Every manifest written before there was a settings
    // form uses it, and it has to keep working — `system` still ships it.
    func testABareStringIsStillAValidConfigKey() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":["STACKNUDGE_EXT_DERBY_ORG"]}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.config.count, 1)
        XCTAssertEqual(m.config[0].key, "STACKNUDGE_EXT_DERBY_ORG")
        XCTAssertNil(m.config[0].label)
    }

    // The object form is what lets Settings render a labelled field rather than
    // a raw environment variable name.
    func testTheObjectFormCarriesItsOwnLabelling() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":[{"key":"STACKNUDGE_EXT_DERBY_ORG","label":"Organisation",
                        "help":"Whose races to show.","placeholder":"stackone"}]}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.config[0].key, "STACKNUDGE_EXT_DERBY_ORG")
        XCTAssertEqual(m.config[0].label, "Organisation")
        XCTAssertEqual(m.config[0].help, "Whose races to show.")
        XCTAssertEqual(m.config[0].placeholder, "stackone")
    }

    // One list, both forms. Widening the element rather than adding a second
    // array is what keeps the passable keys and the form fields from drifting.
    func testBothFormsCanShareOneList() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":["STACKNUDGE_EXT_A",{"key":"STACKNUDGE_EXT_B","label":"B"}]}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.config.map(\.key), ["STACKNUDGE_EXT_A", "STACKNUDGE_EXT_B"])
        XCTAssertEqual(m.config.map(\.label), [nil, "B"])
    }

    // The settings form renders one field per entry, so two entries writing one
    // key is a form where the answer depends on which box you filled in last.
    func testARepeatedKeyIsKeptOnce() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":["STACKNUDGE_EXT_A",{"key":"STACKNUDGE_EXT_A","label":"Again"},
                       "STACKNUDGE_EXT_B"]}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.config.map(\.key), ["STACKNUDGE_EXT_A", "STACKNUDGE_EXT_B"])
        // First occurrence wins, so the list reads in declaration order.
        XCTAssertNil(m.config[0].label)
    }

    // The settings form writes declared keys into ~/.stack-nudge/config, which
    // is line-based, so a key is not just a name — it is text that ends up in a
    // file. A prefix test asks only where the key *starts*.
    //
    // This manifest rendered a labelled "Organisation" field. Saving it wrote
    // three lines, the middle one setting the claude CLI path that
    // ProcessOutput.claude() executes and notify.sh sources, while the typed
    // value landed in a discarded "#=" tail so nothing looked wrong. And the
    // line outlived the extension: uninstalling removed the directory and left
    // the assignment behind.
    func testAConfigKeyCannotCarryANewlineIntoTheConfigFile() {
        let smuggled = "STACKNUDGE_EXT_DERBY_ORG\nSTACKNUDGE_CLAUDE_PATH=/tmp/evil\n#"
        XCTAssertFalse(ExtensionManifest.isPassableConfigKey(smuggled))

        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":[{"key":"\(smuggled.replacingOccurrences(of: "\n", with: "\\n"))",
                        "label":"Organisation"}]}
            """
        guard case .failure(.invalidConfigKey) = parse(json) else {
            return XCTFail("a key carrying a newline must be refused")
        }
    }

    // The namespace has a shape, not just a beginning. Anything that isn't a
    // plain environment variable name is refused, in either declaration form.
    func testAConfigKeyMustLookLikeAnEnvironmentVariableName() {
        for tail in ["ORG ONE", "ORG=X", "ORG#", "ORG\nX", "org", "ORG-ONE", "ORG.ONE", "ORG\u{2028}X"] {
            let key = ExtensionManifest.configPrefix + tail
            XCTAssertFalse(ExtensionManifest.isPassableConfigKey(key), key)
        }
        for tail in ["ORG", "DERBY_ORG", "A1", "_", "DERBY_BASE_2"] {
            XCTAssertTrue(ExtensionManifest.isPassableConfigKey(
                ExtensionManifest.configPrefix + tail), tail)
        }
        // The bare prefix is still not a key.
        XCTAssertFalse(ExtensionManifest.isPassableConfigKey(ExtensionManifest.configPrefix))
    }

    // Pinning a subtlety rather than trusting it. The guard is a regex, and in
    // several engines "$" matches *before* a final newline — which would let a
    // trailing "\n" through, and the whole point of the check is that a key
    // cannot carry one. Swift's .regularExpression does not, but that is worth
    // a test rather than a belief: swapping the implementation, or adding
    // .anchorsMatchLines, would silently reopen it.
    func testTheKeyCheckIsAnchoredToTheWholeStringNotEachLine() {
        for key in ["STACKNUDGE_EXT_ORG\n", "STACKNUDGE_EXT_ORG\r\n",
                    "\nSTACKNUDGE_EXT_ORG", "STACKNUDGE_EXT_ORG\n\n",
                    " STACKNUDGE_EXT_ORG", "STACKNUDGE_EXT_ORG "] {
            XCTAssertFalse(ExtensionManifest.isPassableConfigKey(key), key.debugDescription)
        }
    }

    // The namespace guard is on the key, not on the form it arrived in — an
    // object is not a way around it.
    func testTheObjectFormIsHeldToTheSameNamespace() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":[{"key":"AWS_SECRET_ACCESS_KEY","label":"Harmless"}]}
            """
        XCTAssertEqual(parse(json), .failure(.invalidConfigKey("AWS_SECRET_ACCESS_KEY")))
    }

    // An object without a key is not a config key at all, and must not decode
    // into one with an empty name that then passes the prefix check by accident.
    func testAnObjectWithoutAKeyIsMalformed() {
        let json = """
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":[{"label":"Organisation"}]}
            """
        guard case .failure(.malformed) = parse(json) else {
            return XCTFail("expected malformed")
        }
    }

    // The label a form puts beside the field. Stripping the namespace is not
    // pretty, but an extension that declares nothing still gets a usable field
    // rather than STACKNUDGE_EXT_DERBY_ORG in a settings pane.
    func testDisplayLabelFallsBackToTheKeyWithoutItsNamespace() {
        let bare = ExtensionManifest.ConfigKey(
            key: "STACKNUDGE_EXT_DERBY_ORG", label: nil, help: nil, placeholder: nil)
        XCTAssertEqual(bare.displayLabel, "DERBY_ORG")

        let labelled = ExtensionManifest.ConfigKey(
            key: "STACKNUDGE_EXT_DERBY_ORG", label: "Organisation", help: nil, placeholder: nil)
        XCTAssertEqual(labelled.displayLabel, "Organisation")

        // A label of spaces is a label the extension forgot to fill in.
        let blank = ExtensionManifest.ConfigKey(
            key: "STACKNUDGE_EXT_DERBY_ORG", label: "   ", help: nil, placeholder: nil)
        XCTAssertEqual(blank.displayLabel, "DERBY_ORG")
    }

    // The index round-trips these, so a plain key list must not come back out
    // as a wall of single-field objects.
    func testEncodingKeepsWhicheverFormItCameIn() throws {
        let keys = [
            ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_A", label: nil,
                                       help: nil, placeholder: nil),
            ExtensionManifest.ConfigKey(key: "STACKNUDGE_EXT_B", label: "B",
                                       help: nil, placeholder: nil),
        ]
        let data = try JSONEncoder().encode(keys)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"STACKNUDGE_EXT_A\","), text)
        XCTAssertTrue(text.contains("\"label\":\"B\""), text)
        XCTAssertEqual(try JSONDecoder().decode([ExtensionManifest.ConfigKey].self, from: data),
                       keys)
    }

    // MARK: - Service mode

    private func service(_ fields: String, schema: Int = 2) -> Result<ExtensionManifest, ExtensionManifest.ParseFailure> {
        parse("""
            {"id":"away","name":"Away","version":"1","schema":\(schema)\(fields)}
            """)
    }

    func testAViewIsTheDefaultModeAndAsksForNothing() {
        guard let m = manifest(minimal) else { return }
        XCTAssertEqual(m.mode, .view)
        XCTAssertEqual(m.capabilities, [])
    }

    // Schema 2 isn't only for services: a view may say it and stays a view.
    func testAViewExtensionMaySaySchemaTwo() {
        guard case .success(let m) = service("") else { return XCTFail("schema 2 view refused") }
        XCTAssertEqual(m.schema, 2)
        XCTAssertEqual(m.mode, .view)
    }

    func testAServiceDeclaresItsModeAndCapabilities() {
        guard case .success(let m) = service(#","mode":"service","capabilities":["bluetooth","signal:presence","event:idle"]"#)
        else { return XCTFail("service manifest refused") }
        XCTAssertEqual(m.mode, .service)
        XCTAssertEqual(m.capabilities, [.bluetooth, .signalPresence, .eventIdle])
    }

    // On schema 1 an older host would read it too, and run it as a view that
    // never prints. The bump is the signal, so service mode without it is refused.
    func testServiceModeNeedsSchemaTwo() {
        XCTAssertEqual(service(#","mode":"service""#, schema: 1), .failure(.serviceNeedsSchema(1)))
        let message = ExtensionManifest.ParseFailure.serviceNeedsSchema(1).message
        XCTAssertTrue(message.contains("2"), message)
    }

    // A service that compiles itself first can ask for longer to answer
    // hello; nobody gets less than the default or more than the cap.
    func testAServiceMayAskForALongerHandshake() {
        func handshake(_ fields: String) -> TimeInterval? {
            guard case .success(let m) = service(#","mode":"service""# + fields) else { return nil }
            return m.handshakeSeconds
        }
        XCTAssertEqual(handshake(""), ExtensionManifest.defaultHandshakeSeconds)
        XCTAssertEqual(handshake(#","handshakeSeconds":90"#), 90)
        XCTAssertEqual(handshake(#","handshakeSeconds":2"#), ExtensionManifest.defaultHandshakeSeconds)
        XCTAssertEqual(handshake(#","handshakeSeconds":3600"#), ExtensionManifest.maximumHandshakeSeconds)
        guard case .success(let m) = service(#","mode":"service","handshakeSeconds":90"#) else { return XCTFail() }
        XCTAssertEqual(ServiceSupervisor.timing(for: m).handshake, 90)
        XCTAssertEqual(ServiceSupervisor.timing(for: m).pongTimeout, ServiceSupervisor.Timing().pongTimeout)
    }

    func testAnUnknownModeIsRefused() {
        XCTAssertEqual(service(#","mode":"daemon""#), .failure(.unknownMode("daemon")))
    }

    // Every capability the host knows, by the name a manifest uses for it.
    func testEveryKnownCapabilityIsAccepted() {
        let names = ["bluetooth", "signal:presence", "event:idle", "event:panel",
                     "event:session", "event:nudge", "feed"]
        let list = names.map { "\"\($0)\"" }.joined(separator: ",")
        guard case .success(let m) = service(#","mode":"service","capabilities":["# + list + "]")
        else { return XCTFail("known capabilities refused") }
        XCTAssertEqual(m.capabilities.map(\.rawValue), names)
        XCTAssertEqual(Set(names), Set(ExtensionCapability.allCases.map(\.rawValue)))
    }

    // A typo or a newer host's capability is refused out loud, naming it,
    // rather than dropped and leaving the extension without a feature.
    func testAnUnknownCapabilityIsRefusedByName() {
        XCTAssertEqual(service(#","mode":"service","capabilities":["event:idle","signal:mute"]"#),
                       .failure(.unknownCapability("signal:mute")))
        XCTAssertTrue(ExtensionManifest.ParseFailure.unknownCapability("signal:mute").message
            .contains("signal:mute"))
    }

    func testARepeatedCapabilityIsKeptOnce() {
        guard case .success(let m) = service(#","mode":"service","capabilities":["feed","event:idle","feed"]"#)
        else { return XCTFail("refused") }
        XCTAssertEqual(m.capabilities, [.feed, .eventIdle])
    }

    func testCapabilitiesThatArentStringsAreMalformed() {
        guard case .failure(.malformed) = service(#","mode":"service","capabilities":[1]"#) else {
            return XCTFail("expected malformed")
        }
    }

    // A service pushes its documents, so whatever refresh it declares, the host
    // never polls it or spawns it on open.
    func testRefreshIsIgnoredForAService() {
        guard case .success(let m) = service(
            #","mode":"service","refresh":{"onOpen":true,"intervalSeconds":30,"whileFocusedOnly":false}"#)
        else { return XCTFail("refused") }
        XCTAssertEqual(m.refresh, .pushed)
        XCTAssertFalse(m.refresh.onOpen)
        XCTAssertNil(m.refresh.intervalSeconds)
    }

    // The schema a script is told is the document's, never the manifest's: a
    // view on manifest schema 2 must not go printing a schema 2 document.
    func testTheScriptIsToldTheDocumentSchemaNotTheManifests() {
        guard case .success(let m) = service(#","mode":"service""#) else { return XCTFail("refused") }
        let env = ExtensionRuntime.serviceEnvironment(for: m, config: [:], home: "/Users/x")
        XCTAssertEqual(env["STACKNUDGE_EXT_SCHEMA"], "\(ExtensionManifest.supportedSchema)")
        XCTAssertEqual(env["STACKNUDGE_EXT_SCHEMA"], "1")
        XCTAssertEqual(env["STACKNUDGE_EXT_MODE"], "service")
        // Otherwise exactly the view environment.
        var view = env
        view["STACKNUDGE_EXT_MODE"] = nil
        XCTAssertEqual(view, ExtensionRuntime.environment(for: m, config: [:], home: "/Users/x"))
    }
}
