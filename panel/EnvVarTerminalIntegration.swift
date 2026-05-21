import Foundation

// Generic conformer for terminals that expose per-tab identity via an
// environment variable inherited by the agent process. Warp and Ghostty
// both set TERM_SESSION_ID; this class is parameterised so both share
// one implementation. No AppleScript or AX needed — the env var alone
// is enough to give us a stable per-tab id.
//
// Limitations: we get a tabId (so per-tab renames + accent colors
// work) but no tab name — the terminals don't expose a way to read it
// from outside without AX. That can be layered in later if either
// terminal ships a richer scripting surface.
final class EnvVarTerminalIntegration: TerminalIntegration {

    let name: String
    private let terminalApps: Set<String>
    private let envVar: String

    init(name: String, terminalApps: Set<String>, envVar: String) {
        self.name = name
        self.terminalApps = terminalApps
        self.envVar = envVar
    }

    func enrich(_ sessions: [Session]) -> [Session] {
        let pids = sessions
            .filter { applies(terminalApp: $0.terminalApp) }
            .map(\.pid)
        guard !pids.isEmpty else { return sessions }

        let envValues = Self.envValueMap(forPids: pids, envVar: envVar)
        guard !envValues.isEmpty else { return sessions }

        return sessions.map { session in
            guard applies(terminalApp: session.terminalApp),
                  let value = envValues[session.pid]
            else { return session }
            var copy = session
            copy.tabId = value
            // No tabName: see header comment.
            return copy
        }
    }

    private func applies(terminalApp: String?) -> Bool {
        guard let terminalApp else { return false }
        return terminalApps.contains(terminalApp)
    }

    // Batched lookup of a single env var across many pids. Mirrors the
    // VSCode integration's parser but takes the var name as a parameter
    // so the same code services Warp, Ghostty, and whatever else lands
    // next.
    static func envValueMap(forPids pids: [Int], envVar: String) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map { String($0) }.joined(separator: ",")
        let raw = ProcessOutput.read("/bin/ps", ["eww", "-o", "pid=,command=", "-p", pidList])
        return parseEnvValues(raw, envVar: envVar)
    }

    // Pulled out for testability — given the raw ps output and a target
    // env var name, return a map of pid → value. No subprocess.
    static func parseEnvValues(_ raw: String, envVar: String) -> [Int: String] {
        let needle = "\(envVar)="
        var result: [Int: String] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<space]) else { continue }
            let rest = trimmed[trimmed.index(after: space)...]
            guard let range = rest.range(of: needle) else { continue }
            let valueStart = range.upperBound
            let valueEnd = rest[valueStart...].firstIndex(where: { $0 == " " }) ?? rest.endIndex
            let value = String(rest[valueStart..<valueEnd])
            guard !value.isEmpty else { continue }
            result[pid] = value
        }
        return result
    }
}
