import AppKit

// Read/write helper for ~/.stack-nudge/config. Preserves comments and
// untouched lines on write — replaces only the line that sets the given key,
// or appends if no uncommented line exists yet.
//
// Pure parsing/applying lives in `parse(_:)` and `apply(_:key:value:)` so
// tests can exercise them without touching disk; `read()` and `write(_:_:)`
// are thin wrappers that pin the on-disk path.
enum ConfigFile {

    static let path = ("~/.stack-nudge/config" as NSString).expandingTildeInPath

    static func read() -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        return parse(contents)
    }

    static func write(key: String, value: String) {
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = apply(contents, key: key, value: value)
        try? updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func bool(_ map: [String: String], _ key: String, default defaultValue: Bool) -> Bool {
        guard let value = map[key]?.lowercased() else { return defaultValue }
        return value == "true" || value == "1" || value == "yes"
    }

    // MARK: - Pure helpers (testable)

    /// Parse a config-file string into a key→value map. Skips comments and
    /// blank lines; strips surrounding single/double quotes from values.
    static func parse(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            result[key] = stripQuotes(value)
        }
        return result
    }

    /// Return `contents` with `key` set to `value`. If an uncommented line
    /// for the key exists, that line is replaced in place (preserving order
    /// and surrounding comments). Otherwise the assignment is appended,
    /// trailing blanks collapsed, and a final newline guaranteed.
    static func apply(_ contents: String, key: String, value: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        let newLine = "\(key)=\(value)"
        var replaced = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("\(key)=") else { continue }
            lines[index] = newLine
            replaced = true
            break
        }
        if !replaced {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines.append(newLine)
            lines.append("")
        }
        return lines.joined(separator: "\n")
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

// Menu-bar status item with quick toggles for banner / voice, plus a couple
// of action items. Reads the live config each time the menu opens so changes
// made by editing ~/.stack-nudge/config directly stay in sync.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private weak var panelController: PanelController?

    init(panelController: PanelController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panelController = panelController
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "StackNudge")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let config = ConfigFile.read()
        let banner = ConfigFile.bool(config, "STACKNUDGE_BANNER", default: true)
        let voice  = ConfigFile.bool(config, "STACKNUDGE_VOICE",  default: false)
        let mute   = ConfigFile.bool(config, "STACKNUDGE_MUTE_WHEN_FOCUSED", default: true)
        // Source of truth is nav.hotkeyDisplay so Settings recordings and
        // unset-default fallback agree. Reading raw config here used to
        // show a different default ("cmd+shift+n") than what Settings
        // displayed ("cmd+opt+n") and never reflected new combos until
        // the user manually edited the config file.
        let hotkey = panelController?.nav.hotkeyDisplay ?? "cmd+opt+n"

        let status = NSMenuItem(title: "Hotkey · \(hotkey)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(toggle("Show banners",        state: banner, key: "STACKNUDGE_BANNER"))
        menu.addItem(toggle("Voice notifications", state: voice,  key: "STACKNUDGE_VOICE"))
        menu.addItem(toggle("Mute when focused",   state: mute,   key: "STACKNUDGE_MUTE_WHEN_FOCUSED"))
        menu.addItem(.separator())

        menu.addItem(action("Show panel",         #selector(showPanelAction)))
        menu.addItem(action("Check permissions…", #selector(showPermissionsAction)))
        menu.addItem(action("Open config file…",  #selector(openConfigAction)))
        menu.addItem(.separator())

        menu.addItem(action("Quit StackNudge panel", #selector(quitAction), keyEquivalent: "q"))
    }

    private func toggle(_ title: String, state: Bool, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleAction(_:)), keyEquivalent: "")
        item.target = self
        item.state = state ? .on : .off
        item.representedObject = key
        return item
    }

    private func action(_ title: String, _ selector: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func toggleAction(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let enabling = sender.state == .off
        ConfigFile.write(key: key, value: enabling ? "true" : "false")
        guard enabling else { return }
        switch key {
        case "STACKNUDGE_BANNER": fireBanner(message: "Banner notifications enabled")
        case "STACKNUDGE_VOICE":  speak("Voice notifications enabled")
        default:                  break
        }
    }

    // Confirmation banner via the existing notifier app — same channel a real
    // nudge would use, so the user sees exactly what's being enabled.
    private func fireBanner(message: String) {
        let appPath = "\(NSHomeDirectory())/Applications/StackNudge.app"
        guard FileManager.default.fileExists(atPath: appPath) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [
            "-a", appPath, "--args",
            "--title",   "StackNudge",
            "--message", message,
            "--sound",   "Glass",
        ]
        try? task.run()
    }

    private func speak(_ text: String) {
        Speaker.speak(text)
    }

    @objc private func showPanelAction() {
        panelController?.showPanel()
    }

    @objc private func showPermissionsAction() {
        panelController?.showPermissions()
    }

    @objc private func openConfigAction() {
        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigFile.path))
    }

    @objc private func quitAction() {
        Bootstrap.userQuit()
    }
}
