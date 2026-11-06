import AppKit

// The companion's submenu in the shared menu (menu bar icon and the
// character's right-click): size and Reset position, plus a Debug submenu that
// only shows while Option is held.
final class CompanionMenu: NSObject {

    private let nav: PanelNav

    init(nav: PanelNav) {
        self.nav = nav
    }

    // One "Companion" entry, so the character's settings sit together rather
    // than spread among the app's own items.
    func addItems(to menu: NSMenu) {
        let companion = NSMenu()
        companion.addItem(sizeItem())
        companion.addItem(.separator())
        let reset = NSMenuItem(title: "Reset position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        companion.addItem(reset)
        let item = NSMenuItem(title: "Companion", action: nil, keyEquivalent: "")
        item.submenu = companion
        menu.addItem(item)
    }

    // The Debug submenu. It is always built and hidden unless Option is held;
    // MenuBarController shows and hides it live while the menu is open.
    // The previews are views only: nothing here appends an event or writes a log.
    func addDebugItems(to menu: NSMenu, optionHeld: Bool) {
        let debug = NSMenu()
        debug.addItem(heading("Pose preview"))
        let off = entry("Off (show real state)", #selector(previewPose(_:)))
        off.tag = -1
        off.state = nav.companionPreviewPose == nil ? .on : .off
        debug.addItem(off)
        for (index, mode) in SkinMode.allCases.enumerated() {
            let item = entry("    " + mode.label, #selector(previewPose(_:)))
            item.tag = index
            item.state = nav.companionPreviewPose == mode ? .on : .off
            debug.addItem(item)
        }
        debug.addItem(entry("    Info (nod)", #selector(previewNod)))
        let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        item.submenu = debug
        item.tag = Self.optionOnlyTag
        item.isHidden = Self.isDebugHidden(optionHeld: optionHeld)
        menu.addItem(item)
    }

    static let optionOnlyTag = 0x0F7

    static func isDebugHidden(optionHeld: Bool) -> Bool { !optionHeld }

    func applyOption(_ held: Bool, to menu: NSMenu) {
        for item in menu.items where item.tag == Self.optionOnlyTag { item.isHidden = Self.isDebugHidden(optionHeld: held) }
    }

    private func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func entry(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func sizeItem() -> NSMenuItem {
        let sizes = NSMenu()
        for size in CompanionSize.allCases {
            let item = NSMenuItem(title: size.label, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = nav.companionSize == size ? .on : .off
            sizes.addItem(item)
        }
        let item = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        item.submenu = sizes
        return item
    }

    @objc private func resetPosition() {
        nav.actions?.resetCompanionPosition()
    }

    @objc private func previewPose(_ sender: NSMenuItem) {
        nav.companionPreviewPose = SkinMode.allCases.indices.contains(sender.tag) ? SkinMode.allCases[sender.tag] : nil
    }

    @objc private func previewNod() {
        nav.companionInputs.nodRequests &+= 1
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = CompanionSize(rawValue: raw) else { return }
        nav.setCompanionSize(size)
    }
}
