import Foundation

// The Codex logins on this machine besides the default one. Codex keeps a
// login per CODEX_HOME (default ~/.codex): run with CODEX_HOME=<dir> it signs in
// from <dir>/auth.json and writes its sessions under <dir>, so a second account
// lives in its own dir and the default app-server never sees it.
//
// Found the way ClaudeConfigDirs finds Claude's (see LoginDirs): the scan under
// home, CODEX_HOME in the environment of any `codex` running now (remembered in
// rememberedPath), and STACKNUDGE_CODEX_HOMES. Unlike Claude's, nothing on disk
// says who a dir is signed in as short of opening auth.json, which holds the
// tokens and is never read, only checked for. So a dir found here is a
// candidate until its own app-server's `account/read` answers, and logins(...)
// sorts out which candidates are logins and which repeat one.
enum CodexHomes {

    static let configKey = "STACKNUDGE_CODEX_HOMES"

    static let rememberedPath = "\(NSHomeDirectory())/.stack-nudge/codex-homes"

    // As ClaudeConfigDirs.scanInterval: a CODEX_HOME is made by hand and rarely
    // moves.
    static let scanInterval: TimeInterval = 3600

    // Each extra login is a whole `codex app-server` started up, so they
    // refresh at most this often however fast the panel is polling.
    static let refreshInterval: TimeInterval = 300

    static func defaultHome(home: String = NSHomeDirectory()) -> String { "\(home)/.codex" }

    // The setting's entries first, in the order written, then everything else by
    // path, so rows don't move as sessions come and go. Each resolved and listed
    // once, never the default home, and only while it holds an auth.json: a dir
    // with none has no login to probe.
    static func candidates(home: String = NSHomeDirectory(),
                           setting: String? = ConfigFile.read()[configKey],
                           found: [String],
                           fileManager: FileManager = .default) -> [String] {
        let defaultPath = (defaultHome(home: home) as NSString).resolvingSymlinksInPath
        var seen: Set<String> = [defaultPath]
        return (LoginDirs.entries(setting, home: home) + Set(found).sorted()).compactMap { candidate in
            let path = (candidate as NSString).resolvingSymlinksInPath
            guard seen.insert(path).inserted, hasAuth(path, fileManager: fileManager) else { return nil }
            return path
        }
    }

    // Candidates in order, minus any not signed in (or not yet asked) and any on
    // an account already counted, the default's included, since that would only
    // repeat its numbers. The same email in another workspace is another set of
    // limits, and counts (see CodexAccount.id).
    static func logins(candidates: [String], accounts: [String: CodexAccount],
                       defaultAccount: String?) -> [CodexLogin] {
        var seen: Set<String> = defaultAccount.map { [$0] } ?? []
        return candidates.compactMap { home in
            guard let account = accounts[home], let id = account.id, seen.insert(id).inserted
            else { return nil }
            return CodexLogin(codexHome: home, label: label(path: home), account: id, info: account.info)
        }
    }

    // How the Usage tab names it, from the dir, since Codex reports no
    // organization: "work" for ~/.codex-work, and for a CODEX_HOME that's a
    // `.codex` inside something else (~/work/.codex), that something.
    static func label(path: String) -> String {
        let base = (path as NSString).lastPathComponent
        if base == ".codex" {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent.isEmpty || parent == "/" ? base : parent
        }
        let trimmed = base.hasPrefix(".codex-") ? String(base.dropFirst(".codex-".count)) : base
        return trimmed.isEmpty ? base : trimmed
    }

    // MARK: - Scan

    // An auth.json alone isn't Codex's: pi keeps one in ~/.pi/agent, and other
    // tools in ~/.config/<tool>. Probing such a dir would have `codex` fill it
    // with its own databases and logs, so the scan also wants a file Codex writes
    // on its first run there. A dir found running or named in the setting is
    // Codex's already and needs only the auth.json.
    static let firstRunMarkers = ["installation_id", "version.json"]

    static func scan(home: String = NSHomeDirectory(),
                     fileManager: FileManager = .default) -> [String] {
        LoginDirs.scan(home: home, fileManager: fileManager) { path in
            hasAuth(path, fileManager: fileManager)
                && firstRunMarkers.contains { fileManager.fileExists(atPath: "\(path)/\($0)") }
        }
    }

    // Exists, and nothing more: never opened.
    static func hasAuth(_ path: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: "\(path)/auth.json")
    }

    // MARK: - Running and remembered

    static func running() -> [String] {
        LoginDirs.running(agent: "codex", envVar: "CODEX_HOME")
    }

    static func remembered(path: String = rememberedPath) -> [String] {
        LoginDirs.remembered(path: path)
    }

    static func remember(_ running: [String], path: String = rememberedPath,
                         fileManager: FileManager = .default) {
        LoginDirs.remember(running, path: path, fileManager: fileManager)
    }
}
