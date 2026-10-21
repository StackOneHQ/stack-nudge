import XCTest

@testable import StackNudgePanelCore

final class HookManifestTests: XCTestCase {

    // Walks up from the working directory rather than #filePath, like
    // ChangelogTests: the no-Xcode runner compiles these out of a temp stage.
    private func repoFile(_ name: String) throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        // Never a skip: a test that quietly passes on a missing input is worse than none.
        XCTFail("\(name) not found above \(FileManager.default.currentDirectoryPath)")
        throw CocoaError(.fileNoSuchFile)
    }

    private func repoManifest() throws -> HookManifest {
        try HookManifest.parse(Data(contentsOf: repoFile("hook-manifest.json")))
    }

    private let notify = "/Users/me/.stack-nudge/notify.sh"

    private let claude = AgentHookSpec(agentArg: "claude-code", shape: .matcherGroups, hooks: [
        HookSpec(event: "Stop", arg: "stop", timeout: 30, legacy: true),
        HookSpec(event: "PermissionRequest", arg: "permission", timeout: 600, legacy: true),
        HookSpec(event: "SessionStart", arg: "session-start", timeout: 10, legacy: false),
    ])

    private func group(_ command: String, timeout: Int? = nil, matcher: String = "") -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": command]
        hook["timeout"] = timeout
        return ["matcher": matcher, "hooks": [hook]]
    }

    private func commands(_ hooks: [String: Any], _ event: String) -> [String] {
        (hooks[event] as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? [group]).compactMap { $0["command"] as? String }
        }
    }

    private func reconcile(_ hooks: [String: Any], applied: Set<String>?, everything: Bool = false,
                           spec: AgentHookSpec? = nil) -> HookReconciler.Outcome {
        HookReconciler.reconcile(hooks: hooks, spec: spec ?? claude, applied: applied, notifyPath: notify,
                                 ourScript: Bootstrap.isOurScript, everything: everything)
    }

    private var current: [String: Any] {
        ["Stop": [group("\(notify) claude-code stop", timeout: 30)],
         "PermissionRequest": [group("\(notify) claude-code permission", timeout: 600)]]
    }

    // MARK: The manifest itself

    func testTheRepoManifestCoversEveryAgent() throws {
        let manifest = try repoManifest()
        XCTAssertGreaterThan(manifest.version, 0)
        XCTAssertEqual(Set(manifest.agents.keys), Set(BootstrapAgent.allCases))
        for (agent, spec) in manifest.agents {
            XCTAssertFalse(spec.hooks.isEmpty, "\(agent) has no hooks")
            // notify.sh treats any other event as a no-op, so a row whose arg it
            // doesn't handle would wire a hook that silently does nothing.
            for hook in spec.hooks {
                XCTAssertTrue(["stop", "permission"].contains(hook.arg), "\(agent) \(hook.event): notify.sh doesn't handle \(hook.arg)")
            }
        }
        XCTAssertEqual(manifest.agents[.cursor]?.shape, .flat)
    }

    // The Claude Code plugin ships its own hook file; it must not drift from
    // what the app and install.sh wire.
    func testThePluginHookFileMatchesTheManifestForClaude() throws {
        let plugin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repoFile("hooks/hooks.json"))) as? [String: Any])
        let hooks = try XCTUnwrap(plugin["hooks"] as? [String: Any])
        var pluginArgs: [String: String] = [:]
        for event in hooks.keys {
            let command = try XCTUnwrap(commands(hooks, event).first)
            pluginArgs[event] = command.split(separator: " ").last.map(String.init)
        }
        let manifest = try XCTUnwrap(repoManifest().agents[.claude])
        XCTAssertEqual(pluginArgs, Dictionary(uniqueKeysWithValues: manifest.hooks.map { ($0.event, $0.arg) }))
    }

    func testAManifestWithADuplicateEventOrNoVersionIsRefused() {
        let duplicate = #"{"version":1,"agents":{"claude":{"agent_arg":"claude-code","shape":"matcher-groups","hooks":[{"event":"Stop","arg":"stop"},{"event":"Stop","arg":"stop"}]}}}"#
        XCTAssertThrowsError(try HookManifest.parse(Data(duplicate.utf8)))
        XCTAssertThrowsError(try HookManifest.parse(Data(#"{"agents":{}}"#.utf8)))
    }

    func testOurScriptIsOnlyAnInstalledCopy() {
        XCTAssertTrue(Bootstrap.isOurScript("/Users/me/.stack-nudge/notify.sh"))
        XCTAssertTrue(Bootstrap.isOurScript("\"/Users/me/.stack-nudge/notify.sh\""))
        XCTAssertTrue(Bootstrap.isOurScript("/Users/me/.tinynudge/notify.sh"))
        XCTAssertFalse(Bootstrap.isOurScript("/Users/me/src/stack-nudge/notify.sh"), "a checkout wired by hand")
        XCTAssertFalse(Bootstrap.isOurScript("FOO=1"))
    }

    // MARK: Launch pass

    func testAnExistingInstallGainsAHookANewVersionAdds() throws {
        let outcome = reconcile(current, applied: nil)
        let result = try XCTUnwrap(outcome.hooks)
        XCTAssertEqual(commands(result, "SessionStart"), ["\(notify) claude-code session-start"])
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"], "not duplicated")
        XCTAssertEqual(outcome.applied, ["Stop", "PermissionRequest", "SessionStart"])
        XCTAssertNil(reconcile(result, applied: outcome.applied).hooks, "a second launch changes nothing")
    }

    func testAHookTheUserDeletedStaysDeleted() {
        let hooks: [String: Any] = ["Stop": [group("\(notify) claude-code stop", timeout: 30)]]
        XCTAssertNil(reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"]).hooks)
        // With no record, the legacy PermissionRequest counts as applied, so it isn't put back either.
        XCTAssertNil(commands(reconcile(hooks, applied: nil).hooks ?? hooks, "PermissionRequest").first)
    }

    func testTheUsersOwnSettingsOnOurHooksAreKept() {
        var hooks = current
        hooks["PermissionRequest"] = [group("\(notify) claude-code permission", timeout: 3600, matcher: "Bash")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(reconcile(hooks, applied: nil).hooks, "a raised timeout and a custom matcher are left alone")
    }

    func testWrappersAndHandAddedHooksAreNotOurs() {
        var hooks = current
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        hooks["Stop"] = [group("FOO=1 \(notify) claude-code stop || true", timeout: 30)]
        hooks["SubagentStop"] = [group("\(notify) claude-code stop")]
        let outcome = reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"])
        XCTAssertNil(outcome.hooks, "the wrapper and the SubagentStop hook are the user's")
    }

    func testAStaleInstallPathIsRepointedInPlace() throws {
        var hooks = current
        hooks["Stop"] = [group("/usr/local/bin/other"), group("/Users/me/.tinynudge/notify.sh claude-code stop", timeout: 45, matcher: "x")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(reconcile(hooks, applied: nil).hooks)
        let stop = try XCTUnwrap(result["Stop"] as? [[String: Any]])
        XCTAssertEqual(commands(result, "Stop"), ["/usr/local/bin/other", "\(notify) claude-code stop"])
        XCTAssertEqual(stop[1]["matcher"] as? String, "x")
        XCTAssertEqual((stop[1]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 45)
    }

    func testAnEventThisVersionDroppedIsRemoved() throws {
        var hooks = current
        hooks["UserPromptSubmit"] = [group("\(notify) claude-code prompt", timeout: 10), group("other")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart", "UserPromptSubmit"]).hooks)
        XCTAssertEqual(commands(result, "UserPromptSubmit"), ["other"])
        XCTAssertNil(reconcile(hooks, applied: nil).hooks, "never applied by us: not ours to remove")
    }

    func testADroppedEventAlreadyGoneIsNotARewrite() {
        var hooks = current
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart", "UserPromptSubmit"]).hooks)
    }

    func testRepointingLeavesASingleCopy() throws {
        var hooks = current
        hooks["Stop"] = [group("\"/Users/me/.tinynudge/notify.sh\" claude-code stop", timeout: 30),
                         group("\(notify) claude-code stop", timeout: 30)]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"])
    }

    func testAHomeWithASpaceIsQuotedAndStillRecognised() throws {
        let spaced = "/Users/Jo Smith/.stack-nudge/notify.sh"
        let outcome = HookReconciler.reconcile(hooks: [:], spec: claude, applied: nil, notifyPath: spaced,
                                               ourScript: Bootstrap.isOurScript, everything: true)
        let result = try XCTUnwrap(outcome.hooks)
        XCTAssertEqual(commands(result, "Stop"), ["\"\(spaced)\" claude-code stop"])
        XCTAssertNil(HookReconciler.reconcile(hooks: result, spec: claude, applied: nil, notifyPath: spaced,
                                              ourScript: Bootstrap.isOurScript, everything: true).hooks,
                     "the wizard doesn't append another copy")
        XCTAssertEqual(HookReconciler.tokens("\"/a b/notify.sh\" claude-code stop"), ["\"/a b/notify.sh\"", "claude-code", "stop"])
    }

    // MARK: Wizard and Set up

    func testEverythingRestoresAllHooksAndResetsOurs() throws {
        let hooks: [String: Any] = ["Stop": [group("\(notify) claude-code stop", timeout: 5), group("other")]]
        let result = try XCTUnwrap(reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"], everything: true).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["other", "\(notify) claude-code stop"])
        XCTAssertEqual(commands(result, "PermissionRequest"), ["\(notify) claude-code permission"])
        XCTAssertEqual(commands(result, "SessionStart"), ["\(notify) claude-code session-start"])
        XCTAssertNil(reconcile(result, applied: nil, everything: true).hooks, "already exact: no write")
    }

    func testCursorsFlatShape() throws {
        let cursor = AgentHookSpec(agentArg: "cursor", shape: .flat,
                                   hooks: [HookSpec(event: "stop", arg: "stop", timeout: nil, legacy: true)])
        let hooks: [String: Any] = ["stop": [["type": "command", "command": "keep-me"],
                                             ["type": "command", "command": "/x/.tinynudge/notify.sh cursor stop"]]]
        let result = try XCTUnwrap(reconcile(hooks, applied: nil, spec: cursor).hooks)
        XCTAssertEqual(commands(result, "stop"), ["keep-me", "\(notify) cursor stop"])
        XCTAssertNil(reconcile(result, applied: ["stop"], spec: cursor).hooks, "second pass changes nothing")
    }

    func testPruningRemovesOursFromEveryEvent() {
        let hooks: [String: Any] = ["Stop": [group("\(notify) claude-code stop")],
                                    "SomeFutureEvent": [group("\(notify) claude-code future"), group("other")]]
        let result = HookReconciler.pruned(hooks, isOurs: { $0.contains("stack-nudge/notify.sh") })
        XCTAssertNil(result["Stop"])
        XCTAssertEqual(commands(result, "SomeFutureEvent"), ["other"])
    }
}
