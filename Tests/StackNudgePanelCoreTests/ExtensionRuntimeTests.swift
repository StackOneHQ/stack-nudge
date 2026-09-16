import XCTest

@testable import StackNudgePanelCore

// Spawning is the part that touches the filesystem, so these run against a real
// temporary directory with real scripts in it — a stubbed FileManager would
// test the stub's idea of executability rather than the kernel's.
final class ExtensionRuntimeTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "stack-nudge-ext-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - Fixtures

    private func install(_ id: String,
                         manifest: String? = nil,
                         script: String? = nil,
                         run: String = "run") throws {
        let dir = "\(root)/\(id)"
        try FileManager.default.createDirectory(
            atPath: (dir + "/" + run as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let json = manifest ?? """
            {"id":"\(id)","name":"\(id)","version":"1","schema":1,"run":"./\(run)"}
            """
        try json.write(toFile: "\(dir)/manifest.json", atomically: true, encoding: .utf8)
        if let script {
            let path = "\(dir)/\(run)"
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    // Built directly rather than parsed, so a run path the manifest parser would
    // refuse can still be handed to the runtime — which is the only way to test
    // that the spawn guard stands on its own rather than leaning on the parser.
    private func manifest(_ id: String, run: String = "./run") -> ExtensionManifest {
        ExtensionManifest(id: id, name: id, version: "1", schema: 1,
                          tab: .init(label: id), run: run,
                          requires: [], config: [], refresh: .never)
    }

    private func fetch(_ id: String, action: String? = nil, row: String? = nil,
                       run: String = "./run") -> ExtensionRuntime.Fetch {
        ExtensionRuntime.fetch(manifest(id, run: run), action: action, row: row,
                              directory: "\(root)/\(id)")
    }

    // MARK: - Discovery

    func testInstalledReadsEveryValidManifestInNameOrder() throws {
        try install("radar")
        try install("derby")
        XCTAssertEqual(ExtensionRuntime.installed(in: root).map(\.id), ["derby", "radar"])
    }

    func testADirectoryWithNoManifestIsSkipped() throws {
        try FileManager.default.createDirectory(atPath: "\(root)/empty",
                                                withIntermediateDirectories: true)
        try install("derby")
        XCTAssertEqual(ExtensionRuntime.installed(in: root).map(\.id), ["derby"])
    }

    func testAMalformedManifestIsSkippedRatherThanTakingTheOthersWithIt() throws {
        try install("broken", manifest: "{{{")
        try install("derby")
        XCTAssertEqual(ExtensionRuntime.installed(in: root).map(\.id), ["derby"])
    }

    // The directory name is what every path and every tab id is built from, so
    // a manifest claiming a different id would let one extension answer to
    // another's — including one that isn't installed at all.
    func testAManifestWhoseIDDisagreesWithItsDirectoryIsRefused() throws {
        try install("derby", manifest: """
            {"id":"radar","name":"Impostor","version":"1","schema":1}
            """)
        XCTAssertEqual(ExtensionRuntime.installed(in: root), [])
    }

    func testADirectoryWithAnInvalidNameIsSkipped() throws {
        try install("Derby")
        XCTAssertEqual(ExtensionRuntime.installed(in: root), [])
    }

    // MARK: - Refusals

    // A refusal used to be dropped on the floor: no tab, no message, no log, no
    // stderr. That is indistinguishable from putting the folder in the wrong
    // place, and it made the schema policy unfalsifiable — the one message that
    // could say "update Stack Nudge" was unreachable from production.
    func testANewerSchemaIsReportedRatherThanSilentlySkipped() throws {
        try install("derby", manifest: """
            {"id":"derby","name":"Derby","version":"1","schema":2}
            """)
        let discovery = ExtensionRuntime.discover(in: root)
        XCTAssertEqual(discovery.installed, [])
        XCTAssertEqual(discovery.refused.map(\.id), ["derby"])
        guard let reason = discovery.refused.first?.reason else { return }
        XCTAssertTrue(reason.contains("2"), reason)
        XCTAssertTrue(reason.contains("\(ExtensionManifest.supportedSchema)"), reason)
    }

    func testAManifestClaimingAnotherIDSaysSo() throws {
        try install("derby", manifest: """
            {"id":"radar","name":"Impostor","version":"1","schema":1}
            """)
        let refused = ExtensionRuntime.discover(in: root).refused
        XCTAssertEqual(refused.count, 1)
        XCTAssertTrue(refused.first?.reason.contains("radar") == true, "\(refused)")
    }

    func testADirectoryWithNoManifestIsReportedRatherThanIgnored() throws {
        try FileManager.default.createDirectory(atPath: "\(root)/empty",
                                                withIntermediateDirectories: true)
        XCTAssertEqual(ExtensionRuntime.discover(in: root).refused.map(\.id), ["empty"])
    }

    // Dotfiles and stray files aren't failed extensions, so they aren't news.
    func testNonExtensionEntriesAreNotReportedAsRefusals() throws {
        try "x".write(toFile: "\(root)/.DS_Store", atomically: true, encoding: .utf8)
        try install("derby")
        let discovery = ExtensionRuntime.discover(in: root)
        XCTAssertEqual(discovery.installed.map(\.id), ["derby"])
        XCTAssertEqual(discovery.refused, [])
    }

    func testAMissingRootIsEmptyRatherThanAFailure() {
        XCTAssertEqual(ExtensionRuntime.installed(in: "\(root)/absent"), [])
    }

    // MARK: - Paths

    func testDirectoryRefusesATraversingID() {
        XCTAssertNil(ExtensionRuntime.directory(for: "../../evil"))
        XCTAssertNil(ExtensionRuntime.directory(for: ""))
        XCTAssertEqual(ExtensionRuntime.directory(for: "derby"),
                       "\(ExtensionRuntime.root)/derby")
    }

    // The one the lexical guard missed. `URL.standardized` collapses ".." and
    // "." textually and never touches the filesystem, so a run path whose
    // *spelling* stays inside the package can still resolve out of it through a
    // symlinked directory — and isExecutableFile and Process both follow links.
    // A tarball carries symlinks fine, so without this the manifest a reviewer
    // approved is not the thing that runs.
    func testARunPathThatEscapesThroughASymlinkedDirectoryIsNotSpawned() throws {
        try install("derby")
        let outside = "\(root)/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let canary = "\(outside)/canary"
        try "#!/bin/sh\necho pwned".write(toFile: canary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canary)
        try FileManager.default.createSymbolicLink(atPath: "\(root)/derby/vendor",
                                                   withDestinationPath: outside)

        // The manifest parser accepts this spelling — no ".." anywhere — so the
        // spawn guard is the only thing standing in the way.
        XCTAssertTrue(ExtensionManifest.isValidRunPath("vendor/canary"))
        guard case .missing = fetch("derby", run: "vendor/canary") else {
            return XCTFail("spawned a binary outside the extension directory")
        }
    }

    // A symlinked run file itself, rather than a symlinked parent directory.
    func testARunFileThatIsASymlinkOutOfTheDirectoryIsNotSpawned() throws {
        try install("derby")
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/whoami") else { return }
        try FileManager.default.createSymbolicLink(atPath: "\(root)/derby/run",
                                                   withDestinationPath: "/usr/bin/whoami")
        guard case .missing = fetch("derby") else {
            return XCTFail("spawned /usr/bin/whoami through a symlinked run file")
        }
    }

    // A symlink that stays *inside* the package is legitimate and must still run
    // — the guard is about containment, not about banning links.
    func testASymlinkThatStaysInsideTheDirectoryStillRuns() throws {
        try install("derby", script: """
            #!/bin/sh
            echo '{"schema":1,"rows":[{"id":"a","title":"A"}]}'
            """, run: "real")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/derby/run",
                                                   withDestinationPath: "\(root)/derby/real")
        guard case .ok = fetch("derby") else {
            return XCTFail("an in-package symlink must still spawn")
        }
    }

    // Both sides of the containment check are resolved, not just the executable.
    // A user's extensions root can itself sit behind a symlink — a relocated or
    // symlinked home directory is ordinary — and resolving only one side would
    // then make the prefix test fail for every legitimate extension, reporting
    // the whole install as missing.
    func testAnExtensionRootBehindASymlinkStillSpawns() throws {
        try install("derby", script: """
            #!/bin/sh
            echo '{"schema":1,"rows":[{"id":"a","title":"A"}]}'
            """)
        let link = NSTemporaryDirectory() + "stack-nudge-link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: link) }

        guard case .ok = ExtensionRuntime.fetch(manifest("derby"),
                                                directory: "\(link)/derby") else {
            return XCTFail("a symlinked extensions root must still spawn")
        }
    }

    // Belt and braces over the manifest's own run-path guard: even if a path
    // that escapes the directory got this far, nothing outside it is spawned.
    // The canary is planted where an escaping run would land.
    func testAnEscapingRunPathIsNotSpawned() throws {
        let canary = "\(root)/canary"
        try "#!/bin/sh\necho pwned".write(toFile: canary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canary)
        try install("derby")
        XCTAssertEqual(fetch("derby", run: "../canary"),
                       .missing("../canary is missing or not executable"))
    }

    // MARK: - Spawning

    func testAValidDocument() throws {
        try install("derby", script: """
            #!/bin/sh
            echo '{"schema":1,"rows":[{"id":"a","title":"A"}]}'
            """)
        guard case .ok(let document) = fetch("derby") else {
            return XCTFail("expected a document")
        }
        XCTAssertEqual(document.rows.map(\.id), ["a"])
    }

    func testAMissingRunFileIsMissingNotTransient() throws {
        try install("derby")
        guard case .missing = fetch("derby") else { return XCTFail("expected missing") }
    }

    // A script without the executable bit is an installation that didn't
    // finish, which reads the same to the user as one that isn't there.
    func testANonExecutableRunFileIsMissing() throws {
        try install("derby")
        try "#!/bin/sh\necho hi".write(toFile: "\(root)/derby/run", atomically: true, encoding: .utf8)
        guard case .missing = fetch("derby") else { return XCTFail("expected missing") }
    }

    func testMalformedOutputIsTheExtensionsBugNotATransientOne() throws {
        try install("derby", script: "#!/bin/sh\necho 'not json'")
        guard case .malformed = fetch("derby") else { return XCTFail("expected malformed") }
    }

    // A script that failed halfway may have printed a partial document, so a
    // non-zero exit is not believed even when stdout parses.
    func testANonZeroExitIsTransientEvenWhenStdoutParsed() throws {
        try install("derby", script: """
            #!/bin/sh
            echo '{"schema":1,"rows":[{"id":"a","title":"A"}]}'
            exit 3
            """)
        XCTAssertEqual(fetch("derby"), .transient("exited 3"))
    }

    func testAnInterpreterThatIsNotThereIsTransientRatherThanACrash() throws {
        try install("derby", script: "#!/nonexistent/interpreter\necho hi")
        guard case .transient = fetch("derby") else { return XCTFail("expected transient") }
    }

    func testCleanExitWithNoOutputHoldsWhateverWasThereBefore() {
        XCTAssertEqual(ExtensionRuntime.classify(.init(status: 0, output: "   \n")),
                       .transient("printed nothing"))
    }

    // MARK: - Arguments

    func testArgumentsAreEmptyForAPlainRefresh() {
        XCTAssertEqual(ExtensionRuntime.arguments(action: nil, row: nil), [])
        XCTAssertEqual(ExtensionRuntime.arguments(action: nil, row: "h1"), [])
    }

    func testAnActionIsTwoFlags() {
        XCTAssertEqual(ExtensionRuntime.arguments(action: "open", row: "h1"),
                       ["--action", "open", "--row", "h1"])
        XCTAssertEqual(ExtensionRuntime.arguments(action: "refresh", row: nil),
                       ["--action", "refresh"])
    }

    func testTheScriptSeesTheActionItWasGiven() throws {
        try install("derby", script: """
            #!/bin/sh
            echo "{\\"schema\\":1,\\"rows\\":[{\\"id\\":\\"a\\",\\"title\\":\\"$*\\"}]}"
            """)
        guard case .ok(let document) = fetch("derby", action: "open", row: "h1") else {
            return XCTFail("expected a document")
        }
        XCTAssertEqual(document.rows[0].title, "--action open --row h1")
    }

    // MARK: - Environment

    // The child's environment replaces ours rather than extending it, so an
    // extension can't quietly depend on a variable it never declared and then
    // break when the app is launched from launchd with a different one.
    func testOnlyDeclaredConfigKeysArePassedThrough() {
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":["STACKNUDGE_DERBY_ORG","STACKNUDGE_ABSENT"]}
            """.utf8)) else { return XCTFail("fixture didn't parse") }

        let env = ExtensionRuntime.environment(for: m, config: [
            "STACKNUDGE_DERBY_ORG": "stackone",
            "STACKNUDGE_SLACK_TOKEN": "xoxb-secret",
            "STACKNUDGE_ABSENT": "",
        ], home: "/Users/test")

        XCTAssertEqual(env["STACKNUDGE_DERBY_ORG"], "stackone")
        XCTAssertNil(env["STACKNUDGE_SLACK_TOKEN"])
        // Declared but unset is the same as undeclared: an empty string would
        // read as a configured value to a script checking for presence.
        XCTAssertNil(env["STACKNUDGE_ABSENT"])
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["STACKNUDGE_EXTENSION_ID"], "derby")
        XCTAssertNotNil(env["PATH"])
        // The only way a script can adapt to an older host before it prints.
        XCTAssertEqual(env["STACKNUDGE_SCHEMA"], "\(ExtensionManifest.supportedSchema)")
    }

    // A manifest can only pass through our own namespace, so declaring PATH or
    // anything else doesn't let it rewrite the environment it runs in.
    func testAManifestCannotDeclareItsWayIntoNonStackNudgeKeys() {
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"derby","name":"D","version":"1","schema":1,
             "config":["PATH","HOME","AWS_SECRET_ACCESS_KEY"]}
            """.utf8)) else { return XCTFail("fixture didn't parse") }

        let env = ExtensionRuntime.environment(for: m, config: [
            "PATH": "/evil", "HOME": "/evil", "AWS_SECRET_ACCESS_KEY": "shh",
        ], home: "/Users/test")

        XCTAssertNotEqual(env["PATH"], "/evil")
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
    }

    func testTheChildGetsNothingItDidNotAskFor() throws {
        try install("derby", script: """
            #!/bin/sh
            echo "{\\"schema\\":1,\\"rows\\":[{\\"id\\":\\"a\\",\\"title\\":\\"${STACKNUDGE_EXTENSION_ID}/$(env | wc -l | tr -d ' ')\\"}]}"
            """)
        guard case .ok(let document) = fetch("derby") else {
            return XCTFail("expected a document")
        }
        // PATH, HOME, STACKNUDGE_EXTENSION_ID, plus whatever /bin/sh adds for
        // itself — an inherited environment would be an order of magnitude more.
        XCTAssertTrue(document.rows[0].title.hasPrefix("derby/"), document.rows[0].title)
        let count = Int(document.rows[0].title.split(separator: "/")[1]) ?? .max
        XCTAssertLessThan(count, 12, "child inherited more than it declared")
    }
}
