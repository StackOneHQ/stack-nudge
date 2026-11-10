import AppKit

let app = NSApplication.shared
// Dev-only: renders fixture screenshots and exits. See ScreenshotRenderer.
ScreenshotRenderer.runIfAsked()
app.setActivationPolicy(.accessory)

let controller = PanelController()
app.delegate = controller
app.run()
