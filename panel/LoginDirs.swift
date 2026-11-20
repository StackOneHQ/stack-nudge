import Foundation

// What ClaudeConfigDirs and CodexHomes share. Both CLIs keep one login per dir,
// picked by an environment variable, so a second account is a second dir, and
// both are found the same three ways: a scan under home, the variable in a
// running session's environment (remembered once seen), and a setting.
enum LoginDirs {

    // Never listed. The folders macOS guards (Desktop, Documents, Downloads and
    // the media ones) would each raise a permission prompt the moment we looked
    // inside; Library and the package and VCS dirs are large and never hold a
    // login. A dir in any of them is found once it runs, or from the setting.
    static let skippedNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Library", ".Trash", "node_modules", ".git",
    ]

    // Every dir up to two levels under home that `isLoginDir` accepts: home's
    // own children (~/.claude-work) and theirs (~/accounts/work).
    static func scan(home: String, fileManager: FileManager = .default,
                     isLoginDir: (String) -> Bool) -> [String] {
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
                    if isLoginDir(path) { found.append(path) }
                    next.append(path)
                }
            }
            level = next
        }
        return found
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

    // `envVar` of every `agent` running now, from one `ps` for the pids and one
    // `ps eww` for their environments. Only our own processes' environments are
    // readable, which are the only ones we want.
    static func running(agent: String, envVar: String) -> [String] {
        let table = ProcessOutput.read("/bin/ps", ["-axo", "pid=,args="], timeout: 2) ?? ""
        let values = EnvVarTerminalIntegration.envValueMap(
            forPids: pids(psOutput: table, agent: agent), envVar: envVar)
        return Set(values.values).filter { $0.hasPrefix("/") }.sorted()
    }

    // Pids of the `agent` lines in `ps -axo pid=,args=` output, by
    // SessionStore's definition of one.
    static func pids(psOutput: String, agent: String) -> [Int] {
        psOutput.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int(line[..<space]) else { return nil }
            let args = line[space...].trimmingCharacters(in: .whitespaces)
            return SessionStore.detectAgent(args: args) == agent ? pid : nil
        }
    }

    // One path per line.
    static func remembered(path: String) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    // Adds what's running to what was remembered, and drops a dir that's been
    // deleted. One that's only signed out stays: signing back in brings its row
    // back without waiting for that session to run again.
    static func remember(_ running: [String], path: String, fileManager: FileManager = .default) {
        let previous = remembered(path: path)
        let kept = Set(previous + running).filter { fileManager.fileExists(atPath: $0) }.sorted()
        guard kept != previous else { return }
        try? (kept.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
