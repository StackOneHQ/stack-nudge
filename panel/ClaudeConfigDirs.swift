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
        // How the Usage tab names it. See label(for:path:).
        var label: String = ""
        // Who it's signed in as, for the top of its card.
        var info = AccountInfo()
    }

    // The organization's name, which is what tells a team seat from your own
    // plan. Claude Code names a personal plan's organization "<email>'s
    // Organization", which says nothing a row needs, so that falls back to the
    // dir's own name ("org-publisher" for ~/.claude-org-publisher), as does a
    // login with no name at all.
    static func label(for login: ClaudeUsageCache.Login, path: String) -> String {
        if let name = login.teamName { return name }
        let base = (path as NSString).lastPathComponent
        let trimmed = base.hasPrefix(".claude-") ? String(base.dropFirst(".claude-".count)) : base
        return trimmed.isEmpty ? base : trimmed
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
                  let login = ClaudeUsageCache.login(path: ClaudeUsageCache.path(configDir: path)),
                  seenAccounts.insert(login.id).inserted
            else { continue }
            dirs.append(Dir(path: path, account: login.id, label: label(for: login, path: path),
                            info: login.info))
        }
        return dirs
    }

    // The setting's entries first, in the order written, then everything else
    // by path, so the order rows appear in doesn't move as sessions come and go.
    static func candidates(home: String, setting: String?, found: [String]) -> [String] {
        entries(setting, home: home) + Set(found).sorted()
    }

    static func entries(_ setting: String?, home: String) -> [String] {
        LoginDirs.entries(setting, home: home)
    }

    // MARK: - Scan

    // Every dir up to two levels under home holding a .claude.json (see
    // LoginDirs.scan). It only looks for the file; whether there's a login in it
    // is discover's question.
    static func scan(home: String = NSHomeDirectory(),
                     fileManager: FileManager = .default) -> [String] {
        LoginDirs.scan(home: home, fileManager: fileManager) {
            fileManager.fileExists(atPath: "\($0)/.claude.json")
        }
    }

    // MARK: - Running

    // CLAUDE_CONFIG_DIR of every `claude` running now.
    static func running() -> [String] {
        LoginDirs.running(agent: "claude", envVar: "CLAUDE_CONFIG_DIR")
    }

    static func claudePids(psOutput: String) -> [Int] {
        LoginDirs.pids(psOutput: psOutput, agent: "claude")
    }

    // MARK: - Remembered

    static func remembered(path: String = rememberedPath) -> [String] {
        LoginDirs.remembered(path: path)
    }

    static func remember(_ running: [String], path: String = rememberedPath,
                         fileManager: FileManager = .default) {
        LoginDirs.remember(running, path: path, fileManager: fileManager)
    }
}
