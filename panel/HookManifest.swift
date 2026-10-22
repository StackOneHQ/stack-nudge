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
// the ones it dropped, and rewrites a command of ours in place when its script
// path or event arg differs from the manifest's. It recognises only commands in
// our exact form, `<…/notify.sh> <agent> <arg>`, so a wrapper or a hand-added
// hook under another event is the user's. Timeouts and matchers on our entries
// are the user's too: a manifest change to a timeout reaches existing installs
// only through `everything` (the wizard, "Set up"), which resets our entries for
// the manifest's events to exactly what it lists.
enum HookReconciler {

    // A managed event's value isn't a list of objects: someone else's shape,
    // so the config is refused rather than overwritten with ours.
    struct Malformed: Error, CustomStringConvertible {
        let event: String
        var description: String { "hooks.\(event) isn't a list of objects" }
    }

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
                          everything: Bool) throws -> Outcome {
        let known = applied ?? Set(spec.hooks.filter(\.legacy).map(\.event))
        let manifestEvents = Set(spec.hooks.map(\.event))
        let newApplied = manifestEvents
        for event in known.union(manifestEvents) {
            if let value = hooks[event], !(value is [[String: Any]]) { throw Malformed(event: event) }
        }
        // The agent runs the command through a shell, so a home folder like
        // "/Users/Jo Smith" must be quoted. Quoted the way install.sh's
        // shlex.quote does, so both installers write the same string.
        let script = shellQuoted(notifyPath)
        func canonical(_ hook: HookSpec) -> String { "\(script) \(spec.agentArg) \(hook.arg)" }
        // Any event arg: under a manifest event, one that differs is an older
        // name for the same hook, so a renamed arg is rewritten rather than
        // left firing next to the new one.
        func ours(_ command: String) -> Bool {
            isExactlyOurs(command, agentArg: spec.agentArg, ourScript: ourScript)
        }

        var result = hooks

        // Events this version dropped: they were ours to apply, so ours to
        // remove, in both modes.
        for event in known.subtracting(manifestEvents) {
            guard let old = result[event] as? [[String: Any]] else { continue }
            let list = removing(from: old, where: ours)
            result[event] = list.isEmpty ? nil : list
        }

        if everything {
            for hook in spec.hooks {
                var list = removing(from: result[hook.event], where: ours)
                list.append(entry(canonical(hook), timeout: hook.timeout, shape: spec.shape))
                result[hook.event] = list
            }
        } else {
            for hook in spec.hooks {
                if commands(in: result[hook.event]).contains(where: ours) {
                    // Repoint ours in place (an older install path or arg), and
                    // drop a second copy so the hook doesn't fire twice. On an
                    // event that filters by matcher, copies under different
                    // matchers (`Bash`, `Edit|Write`) each cover their own tools.
                    result[hook.event] = rewriting(dedupedPerMatcher(result[hook.event], where: ours,
                                                                     byMatcher: !matcherlessEvents.contains(hook.event)),
                                                   where: ours, to: canonical(hook))
                } else if !known.contains(hook.event) {
                    // New in this version; one applied before and now missing was removed by hand.
                    var list = result[hook.event] as? [[String: Any]] ?? []
                    list.append(entry(canonical(hook), timeout: hook.timeout, shape: spec.shape))
                    result[hook.event] = list
                }
            }
        }
        return Outcome(hooks: equal(result, hooks) ? nil : result, applied: newApplied)
    }

    // `<our notify.sh> <agent> <arg>` and nothing else: no wrapper, redirect or
    // extra argument, and the script an installed copy rather than a checkout.
    // The arg must be a plain word: `tokens` doesn't split on shell operators,
    // so `stop>>/tmp/log` or `stop&&say` is one token, and the user's.
    static func isExactlyOurs(_ command: String, agentArg: String, ourScript: (String) -> Bool) -> Bool {
        let parts = tokens(command)
        return parts.count == 3 && parts[1] == agentArg && ourScript(parts[0])
            && !parts[2].isEmpty && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // Uninstall. Under `broadEvents` (the events we've always wired) `isBroadlyOurs`
    // decides, as uninstall always has, so older hand-tweaked entries go too.
    // Every other event, including ones a newer version wired before a downgrade,
    // loses only commands in our exact form: a wrapper, a .bak copy or a
    // checkout's notify.sh there is the user's.
    static func pruned(_ hooks: [String: Any], broadEvents: Set<String>,
                       isBroadlyOurs: (String) -> Bool, isExactlyOurs: (String) -> Bool) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks where value is [[String: Any]] {
            let list = removing(from: value, where: broadEvents.contains(event) ? isBroadlyOurs : isExactlyOurs)
            result[event] = list.isEmpty ? nil : list
        }
        return result
    }

    // Python's shlex.quote: bare when every character is shell-safe, otherwise
    // single-quoted with any ' written as '"'"'.
    static func shellQuoted(_ word: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !word.isEmpty, word.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    // The command's shell words with quoting removed: '…', "…" (where \ escapes
    // $ ` " \), and \ outside quotes. Enough to read back what shellQuoted wrote,
    // and a double-quoted path.
    static func tokens(_ command: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var chars = command.makeIterator()
        while let c = chars.next() {
            switch c {
            case " ", "\t", "\n":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                while let q = chars.next(), q != "'" { word.append(q) }
            case "\"":
                inWord = true
                while let q = chars.next(), q != "\"" {
                    if q == "\\", let next = chars.next() {
                        if !"$`\"\\".contains(next) { word.append(q) }
                        word.append(next)
                    } else {
                        word.append(q)
                    }
                }
            case "\\":
                inWord = true
                if let next = chars.next() { word.append(next) }
            default:
                inWord = true
                word.append(c)
            }
        }
        if inWord { words.append(word) }
        return words
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

    // Events the agents fire without consulting a matcher, so a copy of ours
    // under any matcher fires on every one of them. Unknown events keep their
    // matchers apart: a duplicate banner beats a lost permission prompt.
    static let matcherlessEvents: Set<String> = ["Stop", "SubagentStop", "UserPromptSubmit", "AfterAgent", "stop"]

    // Keeps the first command of ours under each matcher (or, with `byMatcher`
    // off, the first overall) and removes the rest. Cursor's flat entries have
    // no matcher, so they share one.
    private static func dedupedPerMatcher(_ value: Any?, where matches: (String) -> Bool,
                                          byMatcher: Bool) -> [[String: Any]] {
        var seen = Set<String>()
        return (value as? [[String: Any]] ?? []).compactMap { item in
            let matcher = byMatcher ? item["matcher"] as? String ?? "" : ""
            if let inner = item["hooks"] as? [[String: Any]] {
                let remaining = inner.filter { hook in
                    guard matches((hook["command"] as? String) ?? "") else { return true }
                    return seen.insert(matcher).inserted
                }
                if remaining.isEmpty { return nil }
                if remaining.count == inner.count { return item }
                var copy = item
                copy["hooks"] = remaining
                return copy
            }
            guard matches((item["command"] as? String) ?? "") else { return item }
            return seen.insert(matcher).inserted ? item : nil
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
