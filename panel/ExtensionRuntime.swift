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

    // What a directory under root turned out to be. A refusal is kept rather
    // than dropped: a v2 extension on a v1 app used to produce no tab, no error
    // and no log, which is indistinguishable from putting the folder in the
    // wrong place — and it made the whole versioning policy unfalsifiable, since
    // the one message that could say "update Stack Nudge" was unreachable.
    struct Discovery: Equatable {
        var installed: [ExtensionManifest] = []
        var refused: [Refusal] = []
    }

    struct Refusal: Equatable {
        let id: String
        let reason: String
    }

    // Every manifest under root, in name order so the tab strip is stable across
    // launches. An id that disagrees with its own directory name is refused: the
    // directory is what everything else addresses, so trusting the manifest
    // would let one extension answer to another's id.
    static func discover(in root: String = ExtensionRuntime.root,
                         fileManager: FileManager = .default) -> Discovery {
        let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        var result = Discovery()
        for name in names.sorted() {
            // Not a refusal worth reporting: dotfiles and stray files aren't
            // attempts at being an extension, and .DS_Store is not news.
            guard ExtensionManifest.isValidID(name) else { continue }
            guard let data = fileManager.contents(atPath: "\(root)/\(name)/manifest.json")
            else {
                result.refused.append(Refusal(id: name, reason: "no manifest.json"))
                continue
            }
            switch ExtensionManifest.parse(data) {
            case .success(let manifest) where manifest.id == name:
                result.installed.append(manifest)
            case .success(let manifest):
                result.refused.append(Refusal(
                    id: name, reason: "manifest claims id \"\(manifest.id)\""))
            case .failure(let failure):
                result.refused.append(Refusal(id: name, reason: failure.message))
            }
        }
        return result
    }

    static func installed(in root: String = ExtensionRuntime.root,
                          fileManager: FileManager = .default) -> [ExtensionManifest] {
        discover(in: root, fileManager: fileManager).installed
    }

    // MARK: - Invocation

    // The child's whole environment. It replaces ours rather than extending it
    // — ProcessOutput passes `env` straight to Process, which does not merge —
    // so an extension sees exactly the keys its manifest declared plus enough
    // PATH to find an interpreter.
    //
    // Only the STACKNUDGE_EXT_ namespace is passable. A STACKNUDGE_ prefix was
    // not a filter: the config file holds forty-odd keys and one of them is
    // STACKNUDGE_SLACK_BOT_TOKEN, which SlackCredentials deliberately leaves in
    // plaintext when the Keychain is locked — exactly the window in which a
    // manifest naming it would walk off with a live bot token. A deny-list would
    // need extending every time a key is added, which is the same bug deferred;
    // a separate namespace makes it unnameable. An extension therefore can't quietly depend
    // on something it never declared and then break when the app is launched
    // from launchd with a different environment.
    //
    // This is not a sandbox, and it is worth being exact about the ceiling,
    // because curation is the only real control and this is what a reviewer is
    // deciding against. macOS attributes AppleEvents and Full Disk Access to the
    // *responsible* process, which a spawned child inherits unless the parent
    // disclaims — and Foundation's Process exposes no way to disclaim. This app
    // holds an Automation grant (see Permissions). So an extension can do what
    // the user can do *without being asked*: an osascript one-liner that would
    // raise a consent prompt from a fresh binary should run silently under our
    // grant. "Runs as the user" undersells it.
    static func environment(for manifest: ExtensionManifest,
                            config: [String: String] = ConfigFile.read(),
                            home: String = NSHomeDirectory()) -> [String: String] {
        var env = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "\(ExtensionManifest.configPrefix)ID": manifest.id,
            // The one thing an extension needs to adapt to an older host. Free
            // now and impossible to retrofit: without it "additive only" has no
            // migration path, because a script has no way to ask what this host
            // can read before it prints.
            "\(ExtensionManifest.configPrefix)SCHEMA": "\(ExtensionManifest.supportedSchema)",
        ]
        for key in manifest.config where ExtensionManifest.isPassableConfigKey(key) {
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
        // Symlinks are resolved on both sides before comparing. `standardized`
        // is purely lexical — it collapses "." and ".." textually and never
        // touches the filesystem — so a prefix test over it proves only that the
        // *spelling* starts inside the package. `isExecutableFile` and Process
        // then both follow links, so a `vendor -> /usr/bin` entry with
        // "run": "vendor/whoami" passed the guard and spawned /usr/bin/whoami.
        //
        // That matters here precisely because the model is curation rather than
        // sandboxing: this guard is the assurance a reviewer relies on when they
        // read a manifest and conclude the executed bytes are the ones in the
        // package. A tarball carries symlinks perfectly well, so without this the
        // manifest can lie and the host signs off on it.
        //
        // Still TOCTOU against a swap between here and the spawn. Closing that
        // needs O_NOFOLLOW on every component; closing the review-time hole is
        // what this is for.
        let root = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let executable = URL(fileURLWithPath: dir)
            .appendingPathComponent(manifest.run)
            .resolvingSymlinksInPath().path
        guard executable.hasPrefix(root + "/"),
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
        // Truncated output is the host's deadline, not the extension's fault, so
        // it must not be reported as malformed — and a half-written document
        // must never be parsed as a whole one.
        guard !completion.truncated else {
            return .transient("output was cut off")
        }
        guard completion.status == 0 else {
            // terminationStatus after a signal is the signal number, not an exit
            // code, so wording it as an exit would report SIGSEGV as "exited 11".
            return .transient(completion.signalled
                ? "killed by signal \(completion.status)"
                : "exited \(completion.status)")
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
