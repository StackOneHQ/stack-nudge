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
                           spec: AgentHookSpec? = nil) throws -> HookReconciler.Outcome {
        try HookReconciler.reconcile(hooks: hooks, spec: spec ?? claude, applied: applied, notifyPath: notify,
                                     ourScript: Bootstrap.isOurScript, everything: everything)
    }

    private var current: [String: Any] {
        ["Stop": [group("\(notify) claude-code stop", timeout: 30)],
         "PermissionRequest": [group("\(notify) claude-code permission", timeout: 600)]]
    }

    // MARK: The manifest itself

    private let agentArgs: [BootstrapAgent: String] = [
        .claude: "claude-code", .codex: "codex", .gemini: "gemini", .antigravity: "antigravity", .cursor: "cursor",
    ]

    // The hook events each agent defines, from its docs. A manifest row for a
    // new event needs it added here, after checking the agent really fires it.
    private let agentEvents: [BootstrapAgent: Set<String>] = [
        .claude: ["Stop", "PermissionRequest", "SessionStart", "SessionEnd", "UserPromptSubmit",
                  "Notification", "PreToolUse", "PostToolUse", "SubagentStop", "PreCompact"],
        .codex: ["Stop", "PermissionRequest", "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"],
        .gemini: ["AfterAgent", "Notification", "SessionStart", "SessionEnd", "BeforeAgent"],
        .antigravity: ["AfterAgent", "Notification", "SessionStart", "SessionEnd", "BeforeAgent"],
        .cursor: ["stop", "beforeSubmitPrompt", "afterAgentResponse"],
    ]

    func testTheRepoManifestCoversEveryAgent() throws {
        let manifest = try repoManifest()
        XCTAssertGreaterThan(manifest.version, 0)
        XCTAssertEqual(Set(manifest.agents.keys), Set(BootstrapAgent.allCases))
        for (agent, spec) in manifest.agents {
            XCTAssertFalse(spec.hooks.isEmpty, "\(agent) has no hooks")
            XCTAssertEqual(spec.agentArg, agentArgs[agent], "\(agent)'s notify.sh agent arg")
            for hook in spec.hooks {
                // notify.sh treats any other event as a no-op, so a row whose arg it
                // doesn't handle would wire a hook that silently does nothing.
                XCTAssertTrue(["stop", "permission"].contains(hook.arg), "\(agent) \(hook.event): notify.sh doesn't handle \(hook.arg)")
                // The agent never fires an event it doesn't define, so a typo'd
                // event name would be just as silent.
                XCTAssertTrue(agentEvents[agent, default: []].contains(hook.event), "\(hook.event) isn't a known \(agent) hook event")
            }
        }
        XCTAssertEqual(manifest.agents[.cursor]?.shape, .flat)
    }

    // The Claude Code plugin ships its own hook file; it must not drift from
    // what the app and install.sh wire.
    func testThePluginHookFileMatchesTheManifestForClaude() throws {
        let plugin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repoFile("hooks/hooks.json"))) as? [String: Any])
        let hooks = try XCTUnwrap(plugin["hooks"] as? [String: Any])
        var pluginCommands: [String: [String]] = [:]
        for event in hooks.keys { pluginCommands[event] = commands(hooks, event) }
        let manifest = try XCTUnwrap(repoManifest().agents[.claude])
        // Exactly one hook per event, in the same form the app writes, with the
        // plugin's own copy of notify.sh in place of the installed one.
        XCTAssertEqual(pluginCommands, Dictionary(uniqueKeysWithValues: manifest.hooks.map {
            ($0.event, ["${CLAUDE_PLUGIN_ROOT}/notify.sh \(manifest.agentArg) \($0.arg)"])
        }))
    }

    func testAManifestWithADuplicateEventOrNoVersionIsRefused() throws {
        let duplicate = #"{"version":1,"agents":{"claude":{"agent_arg":"claude-code","shape":"matcher-groups","hooks":[{"event":"Stop","arg":"stop"},{"event":"Stop","arg":"stop"}]}}}"#
        XCTAssertThrowsError(try HookManifest.parse(Data(duplicate.utf8)))
        XCTAssertThrowsError(try HookManifest.parse(Data(#"{"agents":{}}"#.utf8)))
    }

    func testOurScriptIsOnlyAnInstalledCopy() throws {
        XCTAssertTrue(Bootstrap.isOurScript("/Users/me/.stack-nudge/notify.sh"))
        XCTAssertTrue(Bootstrap.isOurScript("\"/Users/me/.stack-nudge/notify.sh\""))
        XCTAssertTrue(Bootstrap.isOurScript("/Users/me/.tinynudge/notify.sh"))
        XCTAssertFalse(Bootstrap.isOurScript("/Users/me/src/stack-nudge/notify.sh"), "a checkout wired by hand")
        XCTAssertFalse(Bootstrap.isOurScript("FOO=1"))
        XCTAssertFalse(Bootstrap.isOurScript("/Users/me/.stack-nudge/notify.sh.bak"))
        XCTAssertFalse(Bootstrap.isOurScript("/Users/me/.stack-nudge/notify.shx"))
    }

    // Only `<installed notify.sh> <agent> <arg>`, nothing more or less.
    func testOnlyTheExactFormIsOurs() {
        func ours(_ command: String) -> Bool {
            HookReconciler.isExactlyOurs(command, agentArg: "claude-code", ourScript: Bootstrap.isOurScript)
        }
        XCTAssertTrue(ours("\(notify) claude-code stop"))
        XCTAssertTrue(ours("\(notify) claude-code anything"), "any arg: a renamed one is still ours")
        XCTAssertFalse(ours("\(notify) claude-code stop 2>/dev/null"))
        XCTAssertFalse(ours("\(notify) claude-code stop>>/tmp/log"), "one token, but a redirect")
        XCTAssertFalse(ours("\(notify) claude-code stop&&say"))
        XCTAssertFalse(ours("\(notify) claude-code"))
        XCTAssertFalse(ours("\(notify) codex stop"), "another agent's")
        XCTAssertFalse(ours("/Users/me/.stack-nudge/notify.sh.bak claude-code stop"))
        XCTAssertFalse(ours("bash -c '\(notify) claude-code stop; say done'"))
    }

    // MARK: Launch pass

    func testAnExistingInstallGainsAHookANewVersionAdds() throws {
        let outcome = try reconcile(current, applied: nil)
        let result = try XCTUnwrap(outcome.hooks)
        XCTAssertEqual(commands(result, "SessionStart"), ["\(notify) claude-code session-start"])
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"], "not duplicated")
        XCTAssertEqual(outcome.applied, ["Stop", "PermissionRequest", "SessionStart"])
        XCTAssertNil(try reconcile(result, applied: outcome.applied).hooks, "a second launch changes nothing")
    }

    func testAHookTheUserDeletedStaysDeleted() throws {
        let hooks: [String: Any] = ["Stop": [group("\(notify) claude-code stop", timeout: 30)]]
        XCTAssertNil(try reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"]).hooks)
        // With no record, the legacy PermissionRequest counts as applied, so it isn't put back either.
        XCTAssertNil(commands(try reconcile(hooks, applied: nil).hooks ?? hooks, "PermissionRequest").first)
    }

    func testTheUsersOwnSettingsOnOurHooksAreKept() throws {
        var hooks = current
        hooks["PermissionRequest"] = [group("\(notify) claude-code permission", timeout: 3600, matcher: "Bash")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(try reconcile(hooks, applied: nil).hooks, "a raised timeout and a custom matcher are left alone")
    }

    func testWrappersAndHandAddedHooksAreNotOurs() throws {
        var hooks = current
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        hooks["Stop"] = [group("FOO=1 \(notify) claude-code stop || true", timeout: 30)]
        hooks["SubagentStop"] = [group("\(notify) claude-code stop")]
        let outcome = try reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"])
        XCTAssertNil(outcome.hooks, "the wrapper and the SubagentStop hook are the user's")
    }

    func testAStaleInstallPathIsRepointedInPlace() throws {
        var hooks = current
        hooks["Stop"] = [group("/usr/local/bin/other"), group("/Users/me/.tinynudge/notify.sh claude-code stop", timeout: 45, matcher: "x")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        let stop = try XCTUnwrap(result["Stop"] as? [[String: Any]])
        XCTAssertEqual(commands(result, "Stop"), ["/usr/local/bin/other", "\(notify) claude-code stop"])
        XCTAssertEqual(stop[1]["matcher"] as? String, "x")
        XCTAssertEqual((stop[1]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 45)
    }

    func testAnEventThisVersionDroppedIsRemoved() throws {
        var hooks = current
        hooks["UserPromptSubmit"] = [group("\(notify) claude-code prompt", timeout: 10), group("other")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(try reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart", "UserPromptSubmit"]).hooks)
        XCTAssertEqual(commands(result, "UserPromptSubmit"), ["other"])
        XCTAssertNil(try reconcile(hooks, applied: nil).hooks, "never applied by us: not ours to remove")
    }

    func testADroppedEventAlreadyGoneIsNotARewrite() throws {
        var hooks = current
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(try reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart", "UserPromptSubmit"]).hooks)
    }

    func testWrappedOrForeignCommandsUnderOurEventsAreLeftAlone() throws {
        var hooks = current
        hooks["Stop"] = [group("\(notify) claude-code stop 2>/dev/null", timeout: 30),
                         group("\(notify) codex stop"),
                         group("/Users/me/.stack-nudge/notify.sh.bak claude-code stop")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(try reconcile(hooks, applied: nil).hooks, "none of them is ours, and Stop was applied before")
        let reset = try XCTUnwrap(try reconcile(hooks, applied: nil, everything: true).hooks)
        XCTAssertEqual(commands(reset, "Stop"), ["\(notify) claude-code stop 2>/dev/null", "\(notify) codex stop",
                                                 "/Users/me/.stack-nudge/notify.sh.bak claude-code stop",
                                                 "\(notify) claude-code stop"])
    }

    func testARenamedArgIsRewrittenNotDuplicated() throws {
        var hooks = current
        hooks["Stop"] = [group("\(notify) claude-code done", timeout: 45)]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let launch = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(launch, "Stop"), ["\(notify) claude-code stop"])
        XCTAssertEqual(((launch["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 45,
                       "the timeout stays the user's on launch")
        let reset = try XCTUnwrap(try reconcile(hooks, applied: nil, everything: true).hooks)
        XCTAssertEqual(commands(reset, "Stop"), ["\(notify) claude-code stop"], "Set up doesn't leave the old arg firing too")
    }

    func testCopiesUnderDifferentMatchersAreBothKept() throws {
        var hooks = current
        hooks["PermissionRequest"] = [group("\(notify) claude-code permission", timeout: 600, matcher: "Bash"),
                                      group("\(notify) claude-code permission", timeout: 600, matcher: "Edit|Write")]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        XCTAssertNil(try reconcile(hooks, applied: nil).hooks, "each matcher covers its own tools")
        hooks["Stop"] = [group("\(notify) claude-code stop>>/tmp/log", timeout: 30)]
        XCTAssertNil(try reconcile(hooks, applied: nil).hooks, "a redirect glued to the arg is the user's")
        hooks["Stop"] = current["Stop"]
        hooks["PermissionRequest"] = [group("/Users/me/.tinynudge/notify.sh claude-code permission", matcher: "Bash"),
                                      group("/Users/me/.tinynudge/notify.sh claude-code permission", matcher: "Edit|Write")]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(result, "PermissionRequest"), ["\(notify) claude-code permission", "\(notify) claude-code permission"])
        XCTAssertEqual((result["PermissionRequest"] as? [[String: Any]])?.compactMap { $0["matcher"] as? String }, ["Bash", "Edit|Write"])
        XCTAssertNil(try reconcile(result, applied: ["Stop", "PermissionRequest", "SessionStart"]).hooks, "a second launch changes nothing")
    }

    // Stop fires without consulting a matcher, so two copies there are two banners.
    func testOnAMatcherlessEventCopiesUnderAnyMatcherBecomeOne() throws {
        var hooks = current
        hooks["Stop"] = [group("\(notify) claude-code stop", timeout: 30, matcher: "*"),
                         ["hooks": [["type": "command", "command": "\(notify) claude-code stop"]]]]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"])
    }

    func testTwoCopiesUnderOneMatcherBecomeOne() throws {
        var hooks = current
        hooks["Stop"] = [group("\(notify) claude-code stop", timeout: 30), group("\(notify) claude-code stop", timeout: 30)]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"])
    }

    func testRepointingLeavesASingleCopy() throws {
        var hooks = current
        hooks["Stop"] = [group("\"/Users/me/.tinynudge/notify.sh\" claude-code stop", timeout: 30),
                         group("\(notify) claude-code stop", timeout: 30)]
        hooks["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["\(notify) claude-code stop"])
    }

    func testAHomeWithASpaceIsQuotedAndStillRecognised() throws {
        let spaced = "/Users/Jo Smith/.stack-nudge/notify.sh"
        let outcome = try HookReconciler.reconcile(hooks: [:], spec: claude, applied: nil, notifyPath: spaced,
                                                   ourScript: Bootstrap.isOurScript, everything: true)
        let result = try XCTUnwrap(outcome.hooks)
        XCTAssertEqual(commands(result, "Stop"), ["'\(spaced)' claude-code stop"])
        XCTAssertNil(try HookReconciler.reconcile(hooks: result, spec: claude, applied: nil, notifyPath: spaced,
                                                  ourScript: Bootstrap.isOurScript, everything: true).hooks,
                     "the wizard doesn't append another copy")
        XCTAssertEqual(HookReconciler.tokens("\"/a b/notify.sh\" claude-code stop"), ["/a b/notify.sh", "claude-code", "stop"],
                       "a double-quoted path")
    }

    // Matches Python's shlex.quote, which install.sh uses, so both installers
    // write the same command and recognise each other's.
    func testAPathIsQuotedLikeShlexAndReadBack() {
        XCTAssertEqual(HookReconciler.shellQuoted("/Users/me/.stack-nudge/notify.sh"), "/Users/me/.stack-nudge/notify.sh")
        XCTAssertEqual(HookReconciler.shellQuoted("/Users/Jo Smith/x"), "'/Users/Jo Smith/x'")
        XCTAssertEqual(HookReconciler.shellQuoted("/Users/a@b%c+d=e:f,g/x"), "/Users/a@b%c+d=e:f,g/x", "shlex's safe set")
        XCTAssertEqual(HookReconciler.shellQuoted(""), "''")
        XCTAssertEqual(HookReconciler.shellQuoted("/Users/o'neil/$x"), #"'/Users/o'"'"'neil/$x'"#)
        for path in ["/Users/Jo Smith/.stack-nudge/notify.sh", "/Users/o'neil/$HOME/`x`/.stack-nudge/notify.sh"] {
            XCTAssertEqual(HookReconciler.tokens("\(HookReconciler.shellQuoted(path)) claude-code stop"), [path, "claude-code", "stop"])
        }
    }

    func testAMalformedEventValueIsRefused() {
        var hooks = current
        hooks["Stop"] = "not a list"
        XCTAssertThrowsError(try reconcile(hooks, applied: nil))
        XCTAssertThrowsError(try reconcile(hooks, applied: nil, everything: true))
        // An event that isn't ours, whatever its shape, is no reason to refuse.
        var other = current
        other["SessionStart"] = [group("\(notify) claude-code session-start", timeout: 10)]
        other["Elsewhere"] = 7
        XCTAssertNoThrow(try reconcile(other, applied: nil))
    }

    // MARK: Wizard and Set up

    func testEverythingRestoresAllHooksAndResetsOurs() throws {
        let hooks: [String: Any] = ["Stop": [group("\(notify) claude-code stop", timeout: 5), group("other")]]
        let result = try XCTUnwrap(try reconcile(hooks, applied: ["Stop", "PermissionRequest", "SessionStart"], everything: true).hooks)
        XCTAssertEqual(commands(result, "Stop"), ["other", "\(notify) claude-code stop"])
        XCTAssertEqual(commands(result, "PermissionRequest"), ["\(notify) claude-code permission"])
        XCTAssertEqual(commands(result, "SessionStart"), ["\(notify) claude-code session-start"])
        XCTAssertNil(try reconcile(result, applied: nil, everything: true).hooks, "already exact: no write")
    }

    func testEverythingAlsoDropsEventsThisVersionNoLongerLists() throws {
        var hooks = current
        hooks["UserPromptSubmit"] = [group("\(notify) claude-code prompt", timeout: 10), group("other")]
        let result = try XCTUnwrap(try reconcile(hooks, applied: ["Stop", "PermissionRequest", "UserPromptSubmit"], everything: true).hooks)
        XCTAssertEqual(commands(result, "UserPromptSubmit"), ["other"])
        XCTAssertEqual(commands(result, "SessionStart"), ["\(notify) claude-code session-start"])
    }

    func testCursorsFlatShape() throws {
        let cursor = AgentHookSpec(agentArg: "cursor", shape: .flat,
                                   hooks: [HookSpec(event: "stop", arg: "stop", timeout: nil, legacy: true)])
        let hooks: [String: Any] = ["stop": [["type": "command", "command": "keep-me"],
                                             ["type": "command", "command": "/x/.tinynudge/notify.sh cursor stop"]]]
        let result = try XCTUnwrap(try reconcile(hooks, applied: nil, spec: cursor).hooks)
        XCTAssertEqual(commands(result, "stop"), ["keep-me", "\(notify) cursor stop"])
        XCTAssertNil(try reconcile(result, applied: ["stop"], spec: cursor).hooks, "second pass changes nothing")
    }

    // Uninstall: broad under the events we've always wired, exact everywhere else.
    func testPruningIsBroadOnlyUnderOurEvents() throws {
        let wrapper = "bash -c '\(notify) claude-code stop; say done'"
        let hooks: [String: Any] = [
            "Stop": [group("\(notify) claude-code stop"), group(wrapper)],
            "SomeFutureEvent": [group("\(notify) claude-code future"), group("other")],
            "PreToolUse": [group(wrapper), group("/Users/me/.stack-nudge/notify.sh.bak claude-code stop"),
                           group("/Users/me/src/stack-nudge/notify.sh claude-code stop")],
        ]
        let result = HookReconciler.pruned(
            hooks, broadEvents: ["Stop"], isBroadlyOurs: { $0.contains("stack-nudge/notify.sh") },
            isExactlyOurs: { HookReconciler.isExactlyOurs($0, agentArg: "claude-code", ourScript: Bootstrap.isOurScript) })
        XCTAssertNil(result["Stop"])
        XCTAssertEqual(commands(result, "SomeFutureEvent"), ["other"])
        XCTAssertEqual(commands(result, "PreToolUse"), [wrapper, "/Users/me/.stack-nudge/notify.sh.bak claude-code stop",
                                                        "/Users/me/src/stack-nudge/notify.sh claude-code stop"])
    }
}
