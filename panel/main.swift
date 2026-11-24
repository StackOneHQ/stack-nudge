import AppKit

// An MCP client launched this binary as its server: relay to the running app
// and exit, before anything AppKit starts. See MCPBridge.
MCPBridge.runIfAsked()

let app = NSApplication.shared
// Dev-only: renders fixture screenshots and exits. See ScreenshotRenderer.
ScreenshotRenderer.runIfAsked()
app.setActivationPolicy(.accessory)

let controller = PanelController()
app.delegate = controller
app.run()
