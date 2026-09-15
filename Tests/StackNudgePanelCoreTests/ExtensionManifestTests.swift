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
             "config":["STACKNUDGE_DERBY_ORG"],
             "refresh":{"onOpen":false,"intervalSeconds":30,"whileFocusedOnly":false}}
            """
        guard let m = manifest(json) else { return }
        XCTAssertEqual(m.tab.label, "Derby")
        XCTAssertEqual(m.run, "bin/go")
        XCTAssertEqual(m.requires, ["python3"])
        XCTAssertEqual(m.config, ["STACKNUDGE_DERBY_ORG"])
        XCTAssertFalse(m.refresh.onOpen)
        XCTAssertEqual(m.refresh.intervalSeconds, 30)
        XCTAssertFalse(m.refresh.whileFocusedOnly)
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
            {"id":"NOT VALID","name":"D","version":"1","schema":2}
            """
        XCTAssertEqual(parse(json), .failure(.unsupportedSchema(2)))
    }

    func testTheUnsupportedSchemaMessageQuotesBothNumbers() {
        let message = ExtensionManifest.ParseFailure.unsupportedSchema(7).message
        XCTAssertTrue(message.contains("7"), message)
        XCTAssertTrue(message.contains("\(ExtensionManifest.supportedSchema)"), message)
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
}
