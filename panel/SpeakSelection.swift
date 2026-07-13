import AppKit
import ApplicationServices

// Global "speak the current selection" action, driven by a hotkey. Reads the
// focused element's selected text via the Accessibility API; when that's empty
// (some apps don't expose it), falls back to synthesizing ⌘C and reading the
// pasteboard, restoring the original clipboard afterwards. The text is spoken
// through the stackvox daemon. Pressing the hotkey again interrupts the current
// read; pressing it with nothing selected just stops.
enum SpeakSelection {

    static func trigger() {
        let text = selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        Speaker.cancel()  // interrupt whatever's currently playing
        guard let text, !text.isEmpty else { return }  // nothing selected → acts as stop
        Speaker.speak(text, normalize: true)
    }

    // MARK: - Selection capture

    private static func selectedText() -> String? {
        if let ax = axSelectedText(), !ax.isEmpty { return ax }
        return clipboardSelectedText()
    }

    /// kAXSelectedTextAttribute on the system-wide focused UI element.
    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        let element = focused as! AXUIElement
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Fallback: save the clipboard, synthesize ⌘C, read the copied text, then
    /// restore the original clipboard so we don't clobber it.
    private static func clipboardSelectedText() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let beforeCount = pasteboard.changeCount

        sendCommandC()

        // Poll briefly for the copy to land, then read it.
        var copied: String?
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != beforeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
            usleep(15_000)
        }

        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return copied
    }

    private static func sendCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8  // 'c'
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
