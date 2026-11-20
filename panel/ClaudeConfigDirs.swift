import Foundation

// The Claude Code config dirs on this machine besides the default one. Claude
// Code keeps a login per config dir: run with CLAUDE_CONFIG_DIR=<dir> it reads
// <dir>/.claude.json and that dir's own Keychain entry, so a second account
// lives in its own dir and the default `claude /usage` never sees it.
//
// A dir can be called anything and live anywhere, so nothing here goes by its
// name. What every one has is a .claude.json with a login in it, and three
// sources look for that:
//   - scan: the dirs under home, two levels down, every so often;
//   - running: CLAUDE_CONFIG_DIR in the environment of any `claude` running
//     now, which finds a dir wherever it is, and is remembered so the login
//     keeps its row once that session ends;
//   - STACKNUDGE_CLAUDE_CONFIG_DIRS, for a dir neither would find.
// Only dirs with a login count; a dir someone made and never signed in from
// has no usage to read.
enum ClaudeConfigDirs {

    static let configKey = "STACKNUDGE_CLAUDE_CONFIG_DIRS"

    // Dirs seen in a running `claude`'s environment, one path per line.
    static let rememberedPath = "\(NSHomeDirectory())/.stack-nudge/claude-config-dirs"

    // A config dir is made by hand and rarely moves, so the scan runs at launch
    // and then hourly rather than on every poll.
    static let scanInterval: TimeInterval = 3600

    struct Dir: Equatable {
        let path: String
        // ClaudeUsageCache.currentAccount: the account and its organization.
        let account: String
    }

    // The default login is passed in so a dir signed in to the same account and
    // organization isn't probed twice: it would only repeat the default's
    // numbers. The same account in another organization is another seat with
    // its own quota, and counts.
    static func discover(home: String = NSHomeDirectory(),
                         setting: String? = ConfigFile.read()[configKey],
                         found: [String],
                         defaultAccount: String?) -> [Dir] {
        var seenPaths: Set<String> = []
        var seenAccounts: Set<String> = defaultAccount.map { [$0] } ?? []
        var dirs: [Dir] = []
        // Home holds the default login's .claude.json, so it would otherwise
        // read as one more signed-in dir.
        let defaults = Set([home, "\(home)/.claude"].map { ($0 as NSString).resolvingSymlinksInPath })
        for candidate in candidates(home: home, setting: setting, found: found) {
            let path = (candidate as NSString).resolvingSymlinksInPath
            guard !defaults.contains(path), seenPaths.insert(path).inserted,
                  let account = ClaudeUsageCache.currentAccount(
                      path: ClaudeUsageCache.path(configDir: path)),
                  seenAccounts.insert(account).inserted
            else { continue }
            dirs.append(Dir(path: path, account: account))
        }
        return dirs
    }

    // The setting's entries first, in the order written, then everything else
    // by path, so the order rows appear in doesn't move as sessions come and go.
    static func candidates(home: String, setting: String?, found: [String]) -> [String] {
        entries(setting, home: home) + Set(found).sorted()
    }

    // Comma-separated, `~` expanded. Anything else relative is dropped: it would
    // resolve against whatever directory the app happened to launch from.
    static func entries(_ setting: String?, home: String) -> [String] {
        (setting ?? "").split(separator: ",").compactMap { raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if entry == "~" { return home }
            if entry.hasPrefix("~/") { return home + entry.dropFirst() }
            return entry.hasPrefix("/") ? entry : nil
        }
    }

    // MARK: - Scan

    // Never listed. The folders macOS guards (Desktop, Documents, Downloads and
    // the media ones) would each raise a permission prompt the moment we looked
    // inside; Library and the package and VCS dirs are large and never hold a
    // login. A dir in any of them is found once it runs, or from the setting.
    static let skippedNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Library", ".Trash", "node_modules", ".git",
    ]

    // Every dir up to two levels under home holding a .claude.json: home's own
    // children (~/.claude-work) and theirs (~/accounts/work). It only looks for
    // the file; whether there's a login in it is discover's question.
    static func scan(home: String = NSHomeDirectory(),
                     fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        var level = [home]
        for _ in 0..<2 {
            var next: [String] = []
            for parent in level {
                let names = (try? fileManager.contentsOfDirectory(atPath: parent)) ?? []
                for name in names where !skippedNames.contains(name) {
                    let path = "\(parent)/\(name)"
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else { continue }
                    if fileManager.fileExists(atPath: "\(path)/.claude.json") { found.append(path) }
                    next.append(path)
                }
            }
            level = next
        }
        return found
    }

    // MARK: - Running

    // CLAUDE_CONFIG_DIR of every `claude` running now, from one `ps` for the
    // pids and one `ps eww` for their environments. Only our own processes'
    // environments are readable, which are the only ones we want.
    static func running() -> [String] {
        let table = ProcessOutput.read("/bin/ps", ["-axo", "pid=,args="], timeout: 2) ?? ""
        let values = EnvVarTerminalIntegration.envValueMap(
            forPids: claudePids(psOutput: table), envVar: "CLAUDE_CONFIG_DIR")
        return Set(values.values).filter { $0.hasPrefix("/") }.sorted()
    }

    // Pids of the `claude` lines in `ps -axo pid=,args=` output, by
    // SessionStore's definition of one.
    static func claudePids(psOutput: String) -> [Int] {
        psOutput.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int(line[..<space]) else { return nil }
            let args = line[space...].trimmingCharacters(in: .whitespaces)
            return SessionStore.detectAgent(args: args) == "claude" ? pid : nil
        }
    }

    // MARK: - Remembered

    static func remembered(path: String = rememberedPath) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    // Adds what's running to what was remembered, and drops a dir that's been
    // deleted. One that's only signed out stays: signing back in brings its row
    // back without waiting for that session to run again.
    static func remember(_ running: [String], path: String = rememberedPath,
                         fileManager: FileManager = .default) {
        let previous = remembered(path: path)
        let kept = Set(previous + running).filter { fileManager.fileExists(atPath: $0) }.sorted()
        guard kept != previous else { return }
        try? (kept.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
