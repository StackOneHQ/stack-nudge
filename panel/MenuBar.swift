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
        persist(apply(contents, key: key, value: value))
    }

    // Drop a key entirely. Used to scrub a secret that was planted here for
    // provisioning once it has been moved into the Keychain.
    static func remove(key: String) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        persist(strip(contents, key: key))
    }

    // An atomic write replaces the file, so the mode has to be reapplied every
    // time or it reverts to the umask default (0644 in practice). Nothing in
    // here benefits from being world-readable, and secrets pass through during
    // provisioning.
    static func persist(_ contents: String, to path: String = ConfigFile.path) {
        // Create the directory first: before Bootstrap has run there is no
        // ~/.stack-nudge, and the write would otherwise fail silently.
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: path)
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

    /// Return `contents` with every uncommented assignment of `key` removed,
    /// leaving surrounding lines and comments untouched.
    static func strip(_ contents: String, key: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.hasPrefix("\(key)=")
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("")
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
            button.image = MenuBarController.brandMarkImage()
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu bar icon

    // StackOne brand green (#00AF66), taken from the official icon SVG and
    // pinned to sRGB so the mark renders identically regardless of the display's
    // colour space.
    private static let brandGreen = NSColor(srgbRed: 0, green: 0xAF / 255.0, blue: 0x66 / 255.0, alpha: 1)

    // The StackOne interlocking-"S" logomark, reproduced from the official 16×16
    // icon SVG (stackone-logos.com) as a resolution-independent vector: pixel-exact
    // to the brand, point-symmetric by construction, crisp at any menu bar height
    // and on Retina, and with no raster asset to ship. The source places the mark
    // in y∈[3.5, 12.4744] of a 16-unit box (the top-right / bottom-left corners are
    // the transparent cut-outs); we map that into the icon rect, flipping y for
    // AppKit's bottom-left origin. Deliberately a *coloured* (non-template) icon —
    // the brand green is the point — so it does not tint for light/dark; the
    // negative space is transparent and shows the menu bar through, reading on both.
    static func brandMarkImage(height: CGFloat = 15) -> NSImage {
        let svgTop: CGFloat = 3.5, svgBottom: CGFloat = 12.4744
        let markSpan = svgBottom - svgTop
        let aspect = 16.0 / markSpan
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let width = rect.width, boxHeight = rect.height
            // Official SVG coords (x∈[0,16], y-down) → icon rect (y-up).
            func point(_ svgX: CGFloat, _ svgY: CGFloat) -> NSPoint {
                NSPoint(x: svgX / 16.0 * width, y: (svgBottom - svgY) / markSpan * boxHeight)
            }
            brandGreen.set()

            // Upper half: the solid top-left path plus the top-centre fill; their
            // union is the complete upper block of the mark.
            let top = NSBezierPath()
            top.move(to: point(10.6666, 3.5))
            top.line(to: point(0, 3.5))
            top.line(to: point(0, 9.48291))
            top.line(to: point(5.35111, 9.48291))
            top.line(to: point(5.35111, 6.49199))
            top.line(to: point(5.35037, 6.36528))
            top.curve(to: point(8.31328, 3.5), controlPoint1: point(5.34098, 4.78548), controlPoint2: point(6.67026, 3.5))
            top.close()
            top.fill()

            let topInner = NSBezierPath()
            topInner.move(to: point(5.33325, 6.49145))
            topInner.line(to: point(10.6666, 6.49145))
            topInner.line(to: point(10.6666, 3.5))
            topInner.line(to: point(8.11901, 3.5))
            topInner.curve(to: point(5.33325, 5.06865), controlPoint1: point(6.58047, 3.5), controlPoint2: point(5.33325, 3.5))
            topInner.close()
            topInner.fill()

            // Lower half: 180°-symmetric to the upper half.
            let bottom = NSBezierPath()
            bottom.move(to: point(5.33325, 12.4741))
            bottom.line(to: point(15.9999, 12.4741))
            bottom.line(to: point(15.9999, 6.49121))
            bottom.line(to: point(10.6488, 6.49121))
            bottom.line(to: point(10.6488, 9.48212))
            bottom.line(to: point(10.6496, 9.60883))
            bottom.curve(to: point(7.68664, 12.4741), controlPoint1: point(10.6589, 11.1886), controlPoint2: point(9.32965, 12.4741))
            bottom.close()
            bottom.fill()

            let bottomInner = NSBezierPath()
            bottomInner.move(to: point(10.6666, 9.48291))
            bottomInner.line(to: point(5.33325, 9.48291))
            bottomInner.line(to: point(5.33325, 12.4743))
            bottomInner.line(to: point(7.88081, 12.4743))
            bottomInner.curve(to: point(10.6666, 10.9057), controlPoint1: point(9.41933, 12.4743), controlPoint2: point(10.6666, 12.4743))
            bottomInner.close()
            bottomInner.fill()
            return true
        }
        image.isTemplate = false
        return image
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

        addMuteSection(to: menu)
        menu.addItem(.separator())

        menu.addItem(action("Show panel",         #selector(showPanelAction)))
        menu.addItem(action("Check permissions…", #selector(showPermissionsAction)))
        menu.addItem(action("Open config file…",  #selector(openConfigAction)))
        menu.addItem(.separator())

        menu.addItem(action("Quit StackNudge panel", #selector(quitAction), keyEquivalent: "q"))
    }

    // MARK: - Timed mute

    // Read from the panel's transient nav.muteUntil. The menu rebuilds on
    // every open, so this is always current: a countdown + Resume while muted,
    // a duration submenu otherwise.
    private func addMuteSection(to menu: NSMenu) {
        guard let panel = panelController else { return }
        if let until = panel.nav.muteUntil, until > Date() {
            let info = NSMenuItem(
                title: "Muted · \(PanelNav.muteRemainingLabel(until: until)) left",
                action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            menu.addItem(action("Resume notifications", #selector(resumeMuteAction)))
        } else {
            let parent = NSMenuItem(title: "Mute notifications", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for minutes in PanelNav.muteDurationOptions {
                let item = NSMenuItem(title: "For \(muteDurationLabel(minutes))",
                                      action: #selector(muteMinutesAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = minutes
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    private func muteDurationLabel(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    // Sole owner of the status item's appearance. Two independent signals share
    // it: the mute countdown takes the icon while muted, and the count of
    // permission prompts still blocking an agent rides alongside either way —
    // that count is the only trace left once a banner has expired into
    // Notification Center, so it must survive a mute.
    func refreshStatusBadge(muteUntil: Date?, pendingPrompts: Int) {
        guard let button = statusItem.button else { return }
        let muted = muteUntil.map { $0 > Date() } ?? false
        var parts: [String] = []

        if muted, let muteUntil {
            let img = NSImage(systemSymbolName: "bell.slash.fill",
                              accessibilityDescription: "StackNudge (muted)")
            img?.isTemplate = true
            button.image = img
            parts.append(PanelNav.muteRemainingLabel(until: muteUntil))
        } else {
            button.image = MenuBarController.brandMarkImage()
        }

        if pendingPrompts > 0 {
            parts.append("\(pendingPrompts)⏳")
        }
        button.imagePosition = .imageLeft
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        button.toolTip = pendingPrompts > 0
            ? "\(pendingPrompts) prompt\(pendingPrompts == 1 ? "" : "s") waiting for you"
            : nil
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

    @objc private func muteMinutesAction(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        panelController?.muteFor(minutes: minutes)
    }

    @objc private func resumeMuteAction() {
        panelController?.resumeNotifications()
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
