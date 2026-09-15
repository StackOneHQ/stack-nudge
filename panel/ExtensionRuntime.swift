import Foundation

// Running an extension. Spawn-per-invocation, exactly like ClaudeCliQuotaProbe:
// no resident process, no supervision, no restart logic. That is a deliberate
// choice rather than the lazy one — child-process lifecycle has been the cause
// of three recent bugs in this app (a wedged daemon, a hook that outlived its
// prompt, a FIFO that outlived its hook), and a process that only exists for
// the duration of one call has none of those failure modes.
enum ExtensionRuntime {

    static let root = ("~/.stack-nudge/extensions" as NSString).expandingTildeInPath

    // Long enough for two HTTPS round trips on a slow connection, short enough
    // that a hung extension doesn't hold the pane past the next refresh tick.
    static let timeout: TimeInterval = 12

    // How a fetch ended. The three failure cases read differently to the user
    // because they mean different things: `missing` is an installation that's
    // broken, `transient` is a bad moment worth holding the last good document
    // through, and `malformed` is a bug in the extension that no amount of
    // retrying will fix.
    enum Fetch: Equatable {
        case ok(ExtensionDocument)
        case missing(String)
        case transient(String)
        case malformed(String)
    }

    static func directory(for id: String) -> String? {
        guard ExtensionManifest.isValidID(id) else { return nil }
        return "\(root)/\(id)"
    }

    // MARK: - Discovery

    // Every readable manifest under root, in name order so the tab strip has a
    // stable order across launches. A directory whose manifest doesn't parse is
    // skipped rather than reported: this runs at launch, before there is any
    // pane to report it in, and PR-reviewed extensions shouldn't reach here
    // malformed anyway. An id that disagrees with its own directory name is the
    // one case worth refusing outright — the directory is what everything else
    // addresses, so trusting the manifest would let one extension answer to
    // another's id.
    static func installed(in root: String = ExtensionRuntime.root,
                          fileManager: FileManager = .default) -> [ExtensionManifest] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted().compactMap { name in
            guard ExtensionManifest.isValidID(name),
                  let data = fileManager.contents(atPath: "\(root)/\(name)/manifest.json"),
                  case .success(let manifest) = ExtensionManifest.parse(data),
                  manifest.id == name
            else { return nil }
            return manifest
        }
    }

    // MARK: - Invocation

    // The child's whole environment. It replaces ours rather than extending it
    // — ProcessOutput passes `env` straight to Process, which does not merge —
    // so an extension sees exactly the keys its manifest declared plus enough
    // PATH to find an interpreter. That is not a sandbox (the script runs as the
    // user and can read anything the user can), but it does mean an extension
    // can't quietly depend on something it never declared and then break when
    // the app is launched from launchd with a different environment.
    static func environment(for manifest: ExtensionManifest,
                            config: [String: String] = ConfigFile.read(),
                            home: String = NSHomeDirectory()) -> [String: String] {
        var env = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "STACKNUDGE_EXTENSION_ID": manifest.id,
        ]
        for key in manifest.config where key.hasPrefix("STACKNUDGE_") {
            if let value = config[key], !value.isEmpty { env[key] = value }
        }
        return env
    }

    // argv rather than a request on stdin, because ProcessOutput has no stdin
    // support and adding one would mean a second place that can deadlock on a
    // pipe. An action is two flags; that is the entire panel→extension protocol.
    static func arguments(action: String?, row: String?) -> [String] {
        guard let action else { return [] }
        var args = ["--action", action]
        if let row { args += ["--row", row] }
        return args
    }

    static func fetch(_ manifest: ExtensionManifest,
                      action: String? = nil,
                      row: String? = nil,
                      directory: String? = nil,
                      fileManager: FileManager = .default,
                      spawn: (String, [String], String, [String: String]) -> ProcessOutput.Completion?
                          = { ProcessOutput.run($0, $1, timeout: timeout, cwd: $2, env: $3) }) -> Fetch {
        guard let dir = directory ?? Self.directory(for: manifest.id) else {
            return .missing("invalid id \"\(manifest.id)\"")
        }
        let executable = URL(fileURLWithPath: dir)
            .appendingPathComponent(manifest.run).standardized.path
        // standardized resolves any "." components the manifest used; the run
        // path was already refused if it contained "..", so this is belt and
        // braces rather than the guard itself.
        guard executable.hasPrefix(dir + "/"),
              fileManager.isExecutableFile(atPath: executable)
        else { return .missing("\(manifest.run) is missing or not executable") }

        guard let completion = spawn(executable,
                                     arguments(action: action, row: row),
                                     dir,
                                     environment(for: manifest))
        else { return .transient("didn't finish within \(Int(timeout))s") }

        return classify(completion)
    }

    // A non-zero exit is transient even when stdout parsed, because a script
    // that failed halfway may well have printed a partial document — believing
    // it would show stale rows as current. Empty stdout on a clean exit is the
    // same call: the extension ran, said nothing, and the last good document is
    // a better thing to show than a blank pane.
    static func classify(_ completion: ProcessOutput.Completion) -> Fetch {
        guard completion.status == 0 else {
            return .transient("exited \(completion.status)")
        }
        let trimmed = completion.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .transient("printed nothing") }
        guard let data = trimmed.data(using: .utf8) else {
            return .malformed("output wasn't UTF-8")
        }
        switch ExtensionDocument.parse(data) {
        case .success(let document):  return .ok(document)
        case .failure(let failure):   return .malformed(failure.message)
        }
    }
}
