import Carbon.HIToolbox
import Foundation

// Carbon RegisterEventHotKey wrapper. Works on modern macOS without
// Accessibility entitlements — the panel only needs a global hotkey,
// not arbitrary key capture.
final class Hotkey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void
    private let hotKeyIDValue: UInt32

    init?(spec: String, id: UInt32 = 1, onTrigger: @escaping () -> Void) {
        guard let parsed = Hotkey.parse(spec) else { return nil }
        self.onTrigger = onTrigger
        self.hotKeyIDValue = id
        guard install(modifiers: parsed.modifiers, keyCode: parsed.keyCode) else {
            return nil
        }
    }

    deinit {
        if let handler = handlerRef { RemoveEventHandler(handler) }
        if let key = hotKeyRef { UnregisterEventHotKey(key) }
    }

    private func install(modifiers: UInt32, keyCode: UInt32) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4447), id: hotKeyIDValue) // 'SNDG'
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                            GetApplicationEventTarget(),
                                            0, &hotKeyRef)
        guard regStatus == noErr else { return false }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, ctx in
                guard let ctx = ctx else { return noErr }
                let me = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
                // Every handler installed on the app target sees all hotkey
                // events, so only fire for this instance's own id.
                var pressed = EventHotKeyID()
                if let event = event {
                    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                }
                if pressed.id == me.hotKeyIDValue {
                    DispatchQueue.main.async { me.onTrigger() }
                }
                return noErr
            },
            1, &eventType, context, &handlerRef
        )
        return installStatus == noErr
    }

    // MARK: - Spec parsing

    static func parse(_ spec: String) -> (modifiers: UInt32, keyCode: UInt32)? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyName: String?
        for part in parts {
            switch part {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift":          modifiers |= UInt32(shiftKey)
            case "opt", "alt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default: keyName = part
            }
        }
        guard let name = keyName, let code = keyCodes[name] else { return nil }
        return (modifiers, code)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
        "space": 49, "return": 36, "tab": 48, "escape": 53,
    ]

    private static let codeToKey: [UInt16: String] = {
        var inverted: [UInt16: String] = [:]
        for (name, code) in keyCodes { inverted[UInt16(code)] = name }
        return inverted
    }()

    // Reverse of `parse`: build a "cmd+shift+n" spec string from an NSEvent's
    // modifiers + keyCode. Returns nil if the keyCode isn't one we can name.
    static func encode(eventModifiers: UInt, keyCode: UInt16) -> String? {
        guard let key = codeToKey[keyCode] else { return nil }
        var parts: [String] = []
        if eventModifiers & 0x100000 != 0 { parts.append("cmd")   } // NSEvent.ModifierFlags.command
        if eventModifiers & 0x040000 != 0 { parts.append("ctrl")  } // .control
        if eventModifiers & 0x080000 != 0 { parts.append("opt")   } // .option
        if eventModifiers & 0x020000 != 0 { parts.append("shift") } // .shift
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
