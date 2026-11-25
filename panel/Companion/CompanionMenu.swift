import AppKit

// The companion's submenu in the shared menu (menu bar icon and the
// character's right-click): Character, Size and Reset position, plus a Debug submenu that
// only shows while Option is held.
// Highlighting a character shows it on the companion; closing the menu without
// a click puts the saved one back.
final class CompanionMenu: NSObject, NSMenuDelegate {

    private let nav: PanelNav

    init(nav: PanelNav) {
        self.nav = nav
    }

    // One "Companion" entry, so the character's settings sit together rather
    // than spread among the app's own items.
    func addItems(to menu: NSMenu) {
        let companion = NSMenu()
        companion.addItem(characterItem())
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

    private func characterItem() -> NSMenuItem {
        let characters = NSMenu()
        characters.delegate = self
        for family in Self.families() {
            if family.skins.count == 1, let only = family.skins.first {
                characters.addItem(skinEntry(only, title: family.name))
                continue
            }
            let variants = NSMenu()
            variants.delegate = self
            for skin in family.skins { variants.addItem(skinEntry(skin, title: skin.displayName)) }
            let parent = NSMenuItem(title: family.name, action: nil, keyEquivalent: "")
            parent.submenu = variants
            parent.state = family.skins.contains { $0.id == nav.companionSkin } ? .on : .off
            characters.addItem(parent)
        }
        let item = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        item.submenu = characters
        return item
    }

    private func skinEntry(_ skin: LayeredSkin, title: String) -> NSMenuItem {
        let item = entry(title, #selector(selectSkin(_:)))
        // Only skin entries carry an id, so highlighting a family or another
        // row clears the preview rather than leaving a stale one up.
        item.representedObject = skin.id
        item.state = skin.id == nav.companionSkin ? .on : .off
        return item
    }

    // Families in picker order, each listed once where it first appears.
    static func families() -> [(name: String, skins: [LayeredSkin])] {
        var groups: [(name: String, skins: [LayeredSkin])] = []
        for skin in CompanionSkins.all {
            if let i = groups.firstIndex(where: { $0.name == skin.family }) {
                groups[i].skins.append(skin)
            } else {
                groups.append((skin.family, [skin]))
            }
        }
        return groups
    }

    // MARK: - NSMenuDelegate

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        nav.companionPreviewSkin = item?.representedObject as? String
    }

    func menuDidClose(_ menu: NSMenu) {
        nav.companionPreviewSkin = nil
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

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        nav.companionPreviewSkin = nil
        nav.selectCompanionSkin(id)
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
