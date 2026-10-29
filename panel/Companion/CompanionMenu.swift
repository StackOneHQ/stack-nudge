import AppKit

// The companion's submenu in the shared menu (menu bar icon and the
// character's right-click). For now it holds the size.
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
        let item = NSMenuItem(title: "Companion", action: nil, keyEquivalent: "")
        item.submenu = companion
        menu.addItem(item)
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

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = CompanionSize(rawValue: raw) else { return }
        nav.setCompanionSize(size)
    }
}
