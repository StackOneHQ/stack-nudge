import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let notifier = Notifier(config: Config())
app.delegate = notifier
app.run()
