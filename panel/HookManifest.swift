import Foundation

// The hooks this version of StackNudge wants in each agent's config, read from
// hook-manifest.json (bundled in Resources; install.sh reads the same file). Hooks are
// tied to the app version rather than written once by the setup wizard: every
// launch reconciles each wired agent against the manifest, so a release that
// adds an event reaches existing installs without a manual re-wire.

struct HookSpec: Equatable {
    let event: String
    let arg: String
    let timeout: Int?
    // Present before the manifest existed. With no record of what was applied
    // (an install from before reconciling), these count as already applied, so
    // one a user deleted by hand isn't put back.
    let legacy: Bool
}

enum HookShape: String {
    // Claude, Codex, Gemini, Antigravity: event → [{matcher, hooks: [{type, command, timeout}]}]
    case matcherGroups = "matcher-groups"
    // Cursor: event → [{type, command}]
    case flat
}

struct AgentHookSpec: Equatable {
    let agentArg: String
    let shape: HookShape
    let hooks: [HookSpec]
}

struct HookManifest: Equatable {
    // Bumped whenever the hook list changes. A build whose manifest is older
    // than the one last applied leaves hooks alone, so two installed versions
    // don't undo each other on alternate launches.
    let version: Int
    let agents: [BootstrapAgent: AgentHookSpec]

    enum ParseError: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self { case .malformed(let detail): return "hook-manifest.json: \(detail)" }
        }
    }

    static func parse(_ data: Data) throws -> HookManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int, version > 0,
              let agents = root["agents"] as? [String: Any]
        else { throw ParseError.malformed("expected an object with \"version\" and \"agents\"") }
        var parsed: [BootstrapAgent: AgentHookSpec] = [:]
        for (key, value) in agents {
            guard let agent = BootstrapAgent(rawValue: key) else { continue }
            guard let object = value as? [String: Any],
                  let agentArg = object["agent_arg"] as? String, !agentArg.isEmpty,
                  let shape = (object["shape"] as? String).flatMap(HookShape.init(rawValue:)),
                  let hooks = object["hooks"] as? [[String: Any]]
            else { throw ParseError.malformed("bad entry for \(key)") }
            let specs = try hooks.map { hook -> HookSpec in
                guard let event = hook["event"] as? String, !event.isEmpty,
                      let arg = hook["arg"] as? String, !arg.isEmpty
                else { throw ParseError.malformed("bad hook for \(key)") }
                return HookSpec(event: event, arg: arg, timeout: hook["timeout"] as? Int,
                                legacy: hook["legacy"] as? Bool ?? false)
            }
            guard Set(specs.map(\.event)).count == specs.count else {
                throw ParseError.malformed("duplicate event for \(key)")
            }
            parsed[agent] = AgentHookSpec(agentArg: agentArg, shape: shape, hooks: specs)
        }
        return HookManifest(version: version, agents: parsed)
    }

    // nil on a build that didn't bundle hook-manifest.json; callers then leave hooks alone.
    static func bundled() -> HookManifest? {
        guard let url = Bundle.main.url(forResource: "hook-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? parse(data)
    }
}

// Pure: the hooks dictionary of one agent's config, in and out.
//
// Two modes. A launch pass is deliberately narrow: within the manifest's events
// (and any it applied before), it adds hooks this version introduced, removes
// the ones it dropped, and repoints a stale script path in place. It recognises
// only commands in our exact form, `<…/notify.sh> <agent> <arg>`, so a wrapper,
// a hand-added hook under another event, a raised timeout or a custom matcher
// is the user's and stays as it is. `everything` (the wizard, "Set up") instead
// resets our entries for the manifest's events to exactly what it lists.
enum HookReconciler {

    struct Outcome {
        // nil when nothing should be written.
        let hooks: [String: Any]?
        // The events now recorded as applied for this agent.
        let applied: Set<String>
    }

    // `ourScript` decides whether a command's first token is our notify.sh,
    // at the current path or an old one.
    static func reconcile(hooks: [String: Any], spec: AgentHookSpec, applied: Set<String>?,
                          notifyPath: String, ourScript: (String) -> Bool,
                          everything: Bool) -> Outcome {
        let known = applied ?? Set(spec.hooks.filter(\.legacy).map(\.event))
        let manifestEvents = Set(spec.hooks.map(\.event))
        let newApplied = manifestEvents
        // Quoted when the path has a space (a home folder like "/Users/Jo Smith"),
        // or the agent's shell would split it.
        let script = notifyPath.contains(" ") ? "\"\(notifyPath)\"" : notifyPath
        func canonical(_ hook: HookSpec) -> String { "\(script) \(spec.agentArg) \(hook.arg)" }
        // Ours in exactly the form we write: script, agent arg, event arg, nothing else.
        func ours(_ command: String, event: String) -> Bool {
            let parts = tokens(command)
            guard parts.count == 3, parts[1] == spec.agentArg, ourScript(parts[0]) else { return false }
            if let hook = spec.hooks.first(where: { $0.event == event }) { return parts[2] == hook.arg }
            return true
        }

        var result = hooks
        var changed = false

        if everything {
            for hook in spec.hooks {
                var list = removing(from: result[hook.event], where: { ours($0, event: hook.event) })
                list.append(entry(canonical(hook), timeout: hook.timeout, shape: spec.shape))
                result[hook.event] = list
            }
            return Outcome(hooks: equal(result, hooks) ? nil : result, applied: newApplied)
        }

        // Events this version dropped: they were ours to apply, so ours to remove.
        for event in known.subtracting(manifestEvents) {
            guard let old = result[event] as? [[String: Any]] else { continue }
            let list = removing(from: old, where: { ours($0, event: event) })
            if list.count != old.count || commands(in: list).count != commands(in: old).count {
                result[event] = list.isEmpty ? nil : list
                changed = true
            }
        }
        for hook in spec.hooks {
            let present = commands(in: result[hook.event]).filter { ours($0, event: hook.event) }
            if present.isEmpty {
                // New in this version; one applied before and now missing was removed by hand.
                guard !known.contains(hook.event) else { continue }
                var list = result[hook.event] as? [[String: Any]] ?? []
                list.append(entry(canonical(hook), timeout: hook.timeout, shape: spec.shape))
                result[hook.event] = list
                changed = true
            } else if present.count > 1 || present[0] != canonical(hook) {
                // An older install path: repoint the first where it stands, and
                // drop any other copy of ours so the hook doesn't fire twice.
                var first = true
                let deduped = removing(from: result[hook.event], where: { command in
                    guard ours(command, event: hook.event) else { return false }
                    defer { first = false }
                    return !first
                })
                result[hook.event] = rewriting(deduped, where: { ours($0, event: hook.event) }, to: canonical(hook))
                changed = true
            }
        }
        return Outcome(hooks: changed ? result : nil, applied: newApplied)
    }

    // Every event: a hook a newer version wired stays ours to remove after a
    // downgrade, and uninstall must catch it too. `isOurs` is broad on purpose
    // here; this only runs on uninstall.
    static func pruned(_ hooks: [String: Any], isOurs: (String) -> Bool) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks where value is [[String: Any]] {
            let list = removing(from: value, where: isOurs)
            result[event] = list.isEmpty ? nil : list
        }
        return result
    }

    // Space-separated tokens, where a leading double-quoted token may contain spaces.
    static func tokens(_ command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") {
            let head = String(trimmed[...close])
            let rest = trimmed[trimmed.index(after: close)...].split(separator: " ").map(String.init)
            return [head] + rest
        }
        return trimmed.split(separator: " ").map(String.init)
    }

    // MARK: List helpers (matcher groups hold `hooks`; Cursor's entries are flat)

    private static func entry(_ command: String, timeout: Int?, shape: HookShape) -> [String: Any] {
        switch shape {
        case .matcherGroups:
            var hook: [String: Any] = ["type": "command", "command": command]
            hook["timeout"] = timeout
            return ["matcher": "", "hooks": [hook]]
        case .flat:
            return ["type": "command", "command": command]
        }
    }

    private static func commands(in value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).flatMap { item in
            (item["hooks"] as? [[String: Any]] ?? [item]).compactMap { $0["command"] as? String }
        }
    }

    private static func removing(from value: Any?, where matches: (String) -> Bool) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            if let inner = item["hooks"] as? [[String: Any]] {
                let remaining = inner.filter { !matches(($0["command"] as? String) ?? "") }
                if remaining.isEmpty { return nil }
                if remaining.count == inner.count { return item }
                var copy = item
                copy["hooks"] = remaining
                return copy
            }
            return matches((item["command"] as? String) ?? "") ? nil : item
        }
    }

    // Changes only the command string, so the entry keeps its timeout, matcher
    // and position.
    private static func rewriting(_ value: Any?, where matches: (String) -> Bool, to command: String) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).map { item in
            if let inner = item["hooks"] as? [[String: Any]] {
                var copy = item
                copy["hooks"] = inner.map { hook in
                    guard matches((hook["command"] as? String) ?? "") else { return hook }
                    var updated = hook
                    updated["command"] = command
                    return updated
                }
                return copy
            }
            guard matches((item["command"] as? String) ?? "") else { return item }
            var updated = item
            updated["command"] = command
            return updated
        }
    }

    private static func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }
}
