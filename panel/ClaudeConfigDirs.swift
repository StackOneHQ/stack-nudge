import Foundation

// The Claude Code config dirs on this machine besides the default one. Claude
// Code keeps a login per config dir: run with CLAUDE_CONFIG_DIR=~/.claude-work
// it reads ~/.claude-work/.claude.json and that dir's own Keychain entry, so a
// second account lives in its own dir and the default `claude /usage` never
// sees it.
//
// Found two ways: every ~/.claude-* directory with a signed-in .claude.json,
// which is how people name them, and STACKNUDGE_CLAUDE_CONFIG_DIRS for one kept
// anywhere else. Only dirs with a login count; a dir someone made and never
// signed in from has no usage to read.
enum ClaudeConfigDirs {

    static let configKey = "STACKNUDGE_CLAUDE_CONFIG_DIRS"

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
                         defaultAccount: String?,
                         fileManager: FileManager = .default) -> [Dir] {
        var seenPaths: Set<String> = []
        var seenAccounts: Set<String> = defaultAccount.map { [$0] } ?? []
        var found: [Dir] = []
        let defaultDir = ("\(home)/.claude" as NSString).resolvingSymlinksInPath
        for candidate in candidates(home: home, setting: setting, fileManager: fileManager) {
            let path = (candidate as NSString).resolvingSymlinksInPath
            guard path != defaultDir, seenPaths.insert(path).inserted,
                  let account = ClaudeUsageCache.currentAccount(
                      path: ClaudeUsageCache.path(configDir: path)),
                  seenAccounts.insert(account).inserted
            else { continue }
            found.append(Dir(path: path, account: account))
        }
        return found
    }

    // The setting's entries first, in the order written, then ~/.claude-* by
    // name, so the order rows appear in doesn't move between polls.
    static func candidates(home: String, setting: String?,
                           fileManager: FileManager = .default) -> [String] {
        var paths = entries(setting, home: home)
        let names = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        for name in names.sorted() where name.hasPrefix(".claude-") {
            var isDirectory: ObjCBool = false
            let path = "\(home)/\(name)"
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                paths.append(path)
            }
        }
        return paths
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
}
