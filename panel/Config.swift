import Foundation

// Reads ~/.stack-nudge/config — the same file notify.sh sources.
// Parses simple `KEY=value` lines, ignoring comments and blank lines.
// notify.sh shell-sources it; we just need the subset relevant to the panel.
struct PanelConfig {
    var hotkeySpec: String = "cmd+opt+n"

    static func load() -> PanelConfig {
        var config = PanelConfig()
        let path = ("~/.stack-nudge/config" as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return config
        }
        for raw in contents.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))
            switch key {
            case "STACKNUDGE_PANEL_HOTKEY": config.hotkeySpec = value
            default: break
            }
        }
        return config
    }

    private static func stripQuotes(_ value: String) -> String {
        if value.count >= 2,
           let first = value.first, let last = value.last,
           first == last, first == "\"" || first == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
