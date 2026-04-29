import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = PanelController()
app.delegate = controller
app.run()
